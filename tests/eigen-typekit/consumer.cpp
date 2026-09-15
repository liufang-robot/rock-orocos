#include <eigen_typekit/eigen_typekit.hpp>
#include <rtt/OperationCaller.hpp>
#include <rtt/Port.hpp>
#include <rtt/TaskContext.hpp>
#include <rtt/plugin/PluginLoader.hpp>
#include <rtt/types/Types.hpp>

#include <iostream>
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
}

int main(int argc, char** argv) {
    try {
        require(argc == 2, "expected the installed Eigen plugin directory");
        require(RTT::plugin::PluginLoader::Instance()->loadTypekits(argv[1]),
                "could not load the installed Eigen typekit");
        for (const auto* name : {"eigen_vector", "eigen_vector2", "eigen_vector3",
                                "eigen_vector4", "eigen_vector6", "eigen_matrix",
                                "eigen_matrix2", "eigen_matrix3", "eigen_matrix4"}) {
            require(RTT::types::Types()->type(name) != nullptr, "missing Eigen type");
        }
        require(!RTT::plugin::PluginLoader::Instance()->isLoaded("kdl_typekit"),
                "Eigen import unexpectedly loaded KDL");

        const Eigen::Vector3d expected(1.0, 2.0, 3.0);
        RTT::Property<Eigen::Vector3d> position("Position", "", expected);
        require(position.getType() == "eigen_vector3", "Eigen property has the wrong RTT type");
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
        std::cout << "Installed Eigen typekit: types, members, operations and ports passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
