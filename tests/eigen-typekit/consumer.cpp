#include <rtt/OperationCaller.hpp>
#include <rtt/Port.hpp>
#include <rtt/TaskContext.hpp>
#include <rtt/os/main.h>
#include <rtt/marsh/PropertyLoader.hpp>
#include <rtt/plugin/PluginLoader.hpp>
#include <rtt/typekit/RealTimeTypekit.hpp>
#include <rtt/types/Types.hpp>
#ifdef EIGEN_TEST_MQUEUE
#include <rtt/transports/mqueue/MQLib.hpp>
#include <chrono>
#include <thread>
#endif
#include <eigen_typekit/eigen_typekit.hpp>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

Eigen::Vector3d echoVector(Eigen::Vector3d value) {
    return value;
}

Eigen::Quaterniond echoQuaternion(Eigen::Quaterniond value) { return value; }

void checkQuaternion() {
    const Eigen::Quaterniond expected(1.0, 2.0, 3.0, 4.0);
    RTT::Property<Eigen::Quaterniond> property("Orientation", "Quaternion CPF", expected);
    RTT::TaskContext task("quaternion_consumer");
    task.properties()->addProperty(property);
    RTT::marsh::PropertyLoader loader(&task);
    require(loader.store("Quaterniond.cpf"), "could not write quaternion CPF");
    property.set(Eigen::Quaterniond::Identity());
    require(loader.configure("Quaterniond.cpf", true) && property.get().coeffs().isApprox(expected.coeffs()),
            "quaternion CPF changed coefficient order or normalized the value");
    std::remove("Quaterniond.cpf");
    task.provides()->addOperation("echoQuaternion", &echoQuaternion, RTT::ClientThread);
    RTT::OperationCaller<Eigen::Quaterniond(Eigen::Quaterniond)> echo = task.getOperation("echoQuaternion");
    require(echo.ready() && echo(expected).coeffs().isApprox(expected.coeffs()), "quaternion operation failed");
    RTT::OutputPort<Eigen::Quaterniond> output("output");
    RTT::InputPort<Eigen::Quaterniond> input("input");
    require(output.connectTo(&input), "quaternion ports could not connect");
    require(output.write(expected) == RTT::WriteSuccess, "quaternion port write failed");
    Eigen::Quaterniond received = Eigen::Quaterniond::Identity();
    require(input.read(received) == RTT::NewData && received.coeffs().isApprox(expected.coeffs()),
            "quaternion port round trip failed");
    output.disconnect();
}

void checkMatrixProperty() {
    RTT::Property<Eigen::Matrix3d> property("Matrix", "", Eigen::Matrix3d::Identity());
    auto row = property.getTypeInfo()->getMember(property.getDataSource(), "1");
    auto column = row->getTypeInfo()->getMember(row, "2");
    auto writable = RTT::internal::AssignableDataSource<double>::narrow(column.get());
    require(writable != nullptr, "matrix property element is not writable");
    writable->set(8.0);
    require(property.get()(1, 2) == 8.0, "matrix assignment only modified a temporary row");
}

RTT::PropertyBag vectorBag(int size) {
    RTT::PropertyBag bag("/Eigen/VectorXd");
    for (int i = 0; i < size; ++i)
        bag.ownProperty(new RTT::Property<double>(std::to_string(i + 1), "", 99.0));
    return bag;
}

void checkInvalidCpf() {
    RTT::Property<Eigen::Vector3d> vector("Vector", "", Eigen::Vector3d::Ones());
    auto values = vectorBag(4);
    values.setType("/Eigen/Vector3d");
    RTT::Property<RTT::PropertyBag> bag("Vector", "", values);
    require(!vector.compose(bag) && vector.get().isApprox(Eigen::Vector3d::Ones()),
            "fixed vector CPF accepted the wrong dimensions or partially changed its value");
    RTT::Property<Eigen::Matrix2d> matrix("Matrix", "", Eigen::Matrix2d::Identity());
    RTT::PropertyBag rows("/Eigen/Matrix2d");
    rows.ownProperty(new RTT::Property<RTT::PropertyBag>("1", "", vectorBag(2)));
    rows.ownProperty(new RTT::Property<RTT::PropertyBag>("2", "", vectorBag(3)));
    RTT::Property<RTT::PropertyBag> matrixBag("Matrix", "", rows);
    require(!matrix.compose(matrixBag) && matrix.get().isApprox(Eigen::Matrix2d::Identity()),
            "ragged matrix CPF accepted or partially modified the matrix");
    rows.setType("/Eigen/Matrix3d");
    RTT::Property<Eigen::Matrix3d> fixed("Matrix", "", Eigen::Matrix3d::Identity());
    RTT::Property<RTT::PropertyBag> wrongShape("Matrix", "", rows);
    require(!fixed.compose(wrongShape) && fixed.get().isApprox(Eigen::Matrix3d::Identity()),
            "matrix CPF with incorrect fixed dimensions was accepted");
}

template<class T>
void checkCpf(const char* name, int rows, int columns) {
    T expected(rows, columns);
    for (int row = 0; row < rows; ++row) {
        for (int column = 0; column < columns; ++column) {
            expected(row, column) = 10.0 * row + column + 0.25;
        }
    }
    RTT::Property<T> property("Value", "Eigen CPF round trip", expected);
    const std::string canonical = std::string("/Eigen/") + name;
    require(property.getType() == canonical, "C++ property has the wrong canonical name");
    RTT::TaskContext task("cpf_consumer");
    task.properties()->addProperty(property);
    RTT::marsh::PropertyLoader loader(&task);
    const std::string filename = std::string(name) + ".cpf";
    require(loader.store(filename), "could not write Eigen CPF");
    {
        std::ifstream file(filename);
        const std::string xml{std::istreambuf_iterator<char>(file), {}};
        require(xml.find("type=\"" + canonical + "\"") != std::string::npos,
                "CPF did not write the canonical Eigen name");
        require(xml.find("eigen_vector") == std::string::npos &&
                xml.find("eigen_matrix") == std::string::npos,
                "CPF contains a legacy Eigen name");
    }
    if constexpr (T::SizeAtCompileTime == Eigen::Dynamic) property.set().resize(1, 1);
    property.set().setZero();
    require(loader.configure(filename, true), "could not load and compose Eigen CPF");
    require(property.getType() == canonical && property.get().rows() == rows &&
            property.get().cols() == columns && property.get().isApprox(expected),
            "Eigen CPF changed the type or value");
    std::remove(filename.c_str());
}

#ifdef EIGEN_TEST_MQUEUE
template<class T>
void checkMqueue(const T& expected) {
    RTT::TaskContext task("eigen_mqueue_consumer");
    RTT::OutputPort<T> output("mq_output");
    RTT::InputPort<T> input("mq_input");
    task.ports()->addPort(output);
    task.ports()->addPort(input);
    require(output.getTypeInfo()->getProtocol(ORO_MQUEUE_PROTOCOL_ID) != nullptr,
            "canonical Eigen type has no mqueue protocol");
    output.setDataSample(expected);
    auto policy = RTT::ConnPolicy::buffer(2);
    policy.transport = ORO_MQUEUE_PROTOCOL_ID;
    policy.data_size = 4096;
    policy.init = false;
    require(output.connectTo(&input, policy), "Eigen mqueue connection failed");
    require(output.write(expected) == RTT::WriteSuccess, "Eigen mqueue write failed");
    T received;
    bool read = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    do {
        read = input.read(received) == RTT::NewData;
        if (!read) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (!read && std::chrono::steady_clock::now() < deadline);
    output.disconnect();
    input.disconnect();
    require(read && received.rows() == expected.rows() && received.cols() == expected.cols() &&
            received.isApprox(expected), "Eigen mqueue round trip failed");
}
#endif
}

int ORO_main(int argc, char** argv) {
    try {
        require(argc == 2, "expected the installed Eigen plugin directory");
        require(RTT::types::RealTimeTypekitPlugin().loadTypes(), "could not load RTT built-in types");
        require(RTT::plugin::PluginLoader::Instance()->loadTypekits(argv[1]),
                "could not load the installed Eigen typekit");
        auto types = RTT::types::Types();
        const auto dotted = types->getDottedTypes();
        for (const auto* name : {"VectorXd", "Vector2d", "Vector3d", "Vector4d",
                                "Vector6d", "MatrixXd", "Matrix2d", "Matrix3d", "Matrix4d", "Quaterniond"}) {
            const std::string canonical = std::string("/Eigen/") + name;
            const std::string script = std::string("Eigen.") + name;
            const auto type = types->type(canonical);
            require(type != nullptr, "missing canonical Eigen type");
            require(type == types->type(script), "dotted lookup has a different type binding");
            require(type->getTypeName() == canonical && type->getTypeNames().size() == 1,
                    "Eigen type must have one canonical registration");
            require(std::count(dotted.begin(), dotted.end(), script) == 1,
                    "TaskBrowser type list must include each dotted Eigen name once");
        }
        for (const auto* legacy : {"eigen_vector", "eigen_vector2", "eigen_vector3",
                                  "eigen_vector4", "eigen_vector6", "eigen_matrix",
                                  "eigen_matrix2", "eigen_matrix3", "eigen_matrix4"}) {
            require(types->type(legacy) == nullptr, "legacy Eigen type is still registered");
        }
        require(!RTT::plugin::PluginLoader::Instance()->isLoaded("kdl_typekit"),
                "Eigen import unexpectedly loaded KDL");

        const Eigen::Vector3d expected(1.0, 2.0, 3.0);
        RTT::Property<Eigen::Vector3d> position("Position", "", expected);
        require(position.getType() == "/Eigen/Vector3d", "Eigen property has the wrong RTT type");
        const auto member = position.getTypeInfo()->getMember(position.getDataSource(), "1");
        const auto writable = RTT::internal::AssignableDataSource<double>::narrow(member.get());
        require(writable != nullptr, "Eigen vector member is not writable");
        writable->set(4.0);
        require(position.get()[1] == 4.0, "Eigen member assignment did not reach the property");

        RTT::TaskContext task("eigen_consumer");
        task.provides()->addOperation("echoVector", &echoVector, RTT::ClientThread);
        RTT::OperationCaller<Eigen::Vector3d(Eigen::Vector3d)> echo = task.getOperation("echoVector");
        require(echo.ready(), "Eigen operation caller is not ready");
        require(echo(expected).isApprox(expected), "Eigen operation round trip failed");

        RTT::OutputPort<Eigen::Vector3d> output("output");
        RTT::InputPort<Eigen::Vector3d> input("input");
        require(output.connectTo(&input), "Eigen ports could not connect");
        output.write(expected);
        Eigen::Vector3d received = Eigen::Vector3d::Zero();
        require(input.read(received) == RTT::NewData && received.isApprox(expected),
                "Eigen port round trip failed");
        output.disconnect();

        checkCpf<Eigen::VectorXd>("VectorXd", 5, 1);
        checkCpf<Eigen::Vector2d>("Vector2d", 2, 1);
        checkCpf<Eigen::Vector3d>("Vector3d", 3, 1);
        checkCpf<Eigen::Vector4d>("Vector4d", 4, 1);
        checkCpf<Eigen::Vector6d>("Vector6d", 6, 1);
        checkCpf<Eigen::MatrixXd>("MatrixXd", 2, 3);
        checkCpf<Eigen::Matrix2d>("Matrix2d", 2, 2);
        checkCpf<Eigen::Matrix3d>("Matrix3d", 3, 3);
        checkCpf<Eigen::Matrix4d>("Matrix4d", 4, 4);
        checkCpf<Eigen::VectorXd>("VectorXd", 0, 1);
        checkCpf<Eigen::MatrixXd>("MatrixXd", 0, 0);
        checkCpf<Eigen::MatrixXd>("MatrixXd", 0, 5);
        checkCpf<Eigen::MatrixXd>("MatrixXd", 3, 0);
        checkMatrixProperty();
        checkQuaternion();
        checkInvalidCpf();
#ifdef EIGEN_TEST_MQUEUE
        checkMqueue<Eigen::VectorXd>(Eigen::VectorXd::LinSpaced(5, 1.0, 5.0));
        Eigen::MatrixXd matrix(2, 3);
        matrix << 1, 2, 3, 4, 5, 6;
        checkMqueue(matrix);
#endif
        std::cout << "Installed Eigen typekit: canonical names, members, operations, ports and CPF passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
