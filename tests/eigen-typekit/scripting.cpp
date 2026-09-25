#include <rtt/TaskContext.hpp>
#include <rtt/os/main.h>
#include <rtt/internal/DataSources.hpp>
#include <rtt/plugin/PluginLoader.hpp>
#include <rtt/scripting/Parser.hpp>
#include <rtt/scripting/ScriptingService.hpp>
#include <rtt/typekit/RealTimeTypekit.hpp>
#include <rtt/types/TypekitRepository.hpp>
#include <rtt/types/Types.hpp>
#include <eigen_typekit/eigen_typekit.hpp>
#include <cmath>
#include <algorithm>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
using RTT::internal::DataSource;
using RTT::internal::AssignableDataSource;
using Source = RTT::base::DataSourceBase::shared_ptr;

struct Script {
    RTT::TaskContext task{"eigen_script"};
    RTT::scripting::Parser parser;
    Source parseStatement(const std::string& code) {
        return code.rfind("set ", 0) == 0 ? parser.parseExpression(code.substr(4), &task)
                                         : parser.parseValueStatement(code, &task);
    }
    void statement(const std::string& code) {
        try {
            auto result = parseStatement(code);
            require(result && result->evaluate(), "statement failed: " + code);
        } catch (const RTT::parse_exception& error) {
            throw std::runtime_error(code + ": " + error.what());
        }
    }
    template<class T> T expression(const std::string& code) {
        try {
            auto result = parser.parseExpression(code, &task);
            auto typed = DataSource<T>::narrow(result.get());
            require(typed != nullptr, "unexpected expression type: " + code);
            return typed->get();
        } catch (const RTT::parse_exception& error) {
            throw std::runtime_error(code + ": " + error.what());
        }
    }
    void rejects(const std::string& code, bool statementCode = false) {
        bool failed = false;
        try {
            auto value = statementCode ? parseStatement(code) : parser.parseExpression(code, &task);
            if (value) {
                failed = !value->evaluate();
                // RTT defers operation/functor exceptions until the result is read.
                if (!failed) value->getRawConstPointer();
            }
        } catch (const std::exception&) { failed = true; }
        catch (const RTT::parse_exception&) { failed = true; }
        require(failed, "invalid input was accepted: " + code);
        require(expression<int>("1 + 1") == 2, "parser did not recover after invalid input");
    }
};

template<class T> void checkDefaults(const char* name) {
    auto type = RTT::types::Types()->getTypeInfo<T>();
    auto expected = [](const T& value) {
        if constexpr (std::is_same_v<T, Eigen::Quaterniond>)
            return value.coeffs().isApprox(Eigen::Quaterniond::Identity().coeffs());
        else if constexpr (T::SizeAtCompileTime == Eigen::Dynamic) return value.size() == 0;
        else return value.isZero(0);
    };
    auto check = [&](Source source) {
        auto typed = DataSource<T>::narrow(source.get());
        require(typed && expected(typed->get()), std::string("uninitialized RTT factory: ") + name);
    };
    check(type->buildValue());
    std::unique_ptr<RTT::base::AttributeBase> variable(type->buildVariable("value"));
    check(variable->getDataSource());
    std::unique_ptr<RTT::base::AttributeBase> attribute(type->buildAttribute("value", nullptr));
    check(attribute->getDataSource());
    std::unique_ptr<RTT::base::PropertyBase> property(type->buildProperty("Value", ""));
    check(property->getDataSource());
    Script script;
    script.statement(std::string("var Eigen.") + name + " value");
    require(expected(script.expression<T>("value")), std::string("uninitialized script variable: ") + name);
}

template<class T> void checkVector(const char* name, int size) {
    Script script;
    const std::string type = std::string("Eigen.") + name;
    script.statement("var " + type + " v = " + type + "(Float64Array(" + std::to_string(size) + ", 2.0))");
    script.statement("set v[0] = 3.0");
    T expected = T::Constant(size, 2.0);
    expected[0] = 3;
    require(script.expression<T>("v").isApprox(expected), "vector assignment failed");
    require(script.expression<int>("v.size") == size, "vector size failed");
    require(script.expression<T>("(2 * v + v * 2.0 - v) / 3.0").isApprox(expected), "vector arithmetic failed");
    require(script.expression<T>("-v").isApprox(-expected), "vector negation failed");
    require(std::abs(script.expression<double>(type + ".norm(v)") - expected.norm()) < 1e-12, "vector norm failed");
    require(script.expression<T>(type + ".normalized(v)").isApprox(expected.normalized()), "vector normalization failed");
    require(std::abs(script.expression<double>(type + ".dot(v, v)") - expected.squaredNorm()) < 1e-12, "vector dot failed");
    const std::string dims = T::SizeAtCompileTime == Eigen::Dynamic ? std::to_string(size) : "";
    require(script.expression<T>(type + ".zero(" + dims + ")").isZero(0), "vector zero factory failed");
    require(script.expression<T>(type + ".constant(" + (dims.empty() ? "" : dims + ", ") + "5.0)")
            .isApprox(T::Constant(size, 5.0)), "vector constant factory failed");
    script.rejects("v[-1]");
    script.rejects("v[" + std::to_string(size) + "] = 9.0", false);
    script.rejects("v / 0.0");
    script.rejects(type + ".normalized(" + type + ".zero(" + dims + "))");
    script.rejects(type + "(-1)");
    if constexpr (T::SizeAtCompileTime != Eigen::Dynamic) {
        require(script.expression<T>(type + "(Eigen.VectorXd(v))").isApprox(expected), "vector explicit conversion failed");
        script.rejects(type + "(Eigen.VectorXd(7))");
        script.rejects(type + "(Float64Array(7, 0.0))");
        script.rejects("v + Eigen.VectorXd(v)");
    }
}

template<class T> void checkMatrix(const char* name, int rows, int cols) {
    Script script;
    const std::string type = std::string("Eigen.") + name;
    const std::string shape = std::to_string(rows) + ", " + std::to_string(cols);
    script.statement("var " + type + " m = " + type + "(" + shape + ", 2.0)");
    script.statement("var Int32 row = 0");
    script.statement("var Int32 col = 1");
    // Retain the parsed assignment, then change the index. No captured element pointer is safe here.
    auto assignment = script.parseStatement("set m[row][col] = 7.0");
    require(assignment->evaluate(), "matrix element assignment failed");
    script.statement("set row = 1");
    require(assignment->evaluate(), "matrix element reassignment failed");
    T expected = T::Constant(rows, cols, 2.0);
    expected(0, 1) = expected(1, 1) = 7;
    require(script.expression<T>("m").isApprox(expected), "matrix write did not reach the source");
    require(script.expression<Eigen::VectorXd>("m[1]").isApprox(expected.row(1).transpose()), "matrix row read failed");
    require(script.expression<int>("m.rows") == rows && script.expression<int>("m.cols") == cols &&
            script.expression<int>("m.size") == rows * cols, "matrix dimension members failed");
    const auto data = script.expression<std::vector<double>>("m.data");
    require(data.size() == static_cast<size_t>(rows * cols) && data[1] == 7 && data[cols + 1] == 7,
            "matrix data is not a row-major snapshot");
    script.statement("var Float64Array values = Float64Array(" + std::to_string(rows * cols) + ", 2.0)");
    script.statement("set values[1] = 7.0");
    script.statement("set values[" + std::to_string(cols + 1) + "] = 7.0");
    require(script.expression<T>(type + "(" + shape + ", values)").isApprox(expected), "row-major constructor failed");
    require(script.expression<T>("(2.0 * m + m - m) / 2").isApprox(expected), "matrix arithmetic failed");
    require(script.expression<T>("-m").isApprox(-expected), "matrix negation failed");
    require(script.expression<T>(type + ".transpose(m)").isApprox(expected.transpose()), "matrix transpose failed");
    const auto text = script.expression<std::string>(type + ".toString(m)");
    require(std::count(text.begin(), text.end(), '\n') == rows - 1 && text.find('7') != std::string::npos,
            "matrix text display omitted rows or coefficients");
    const std::string dims = T::SizeAtCompileTime == Eigen::Dynamic ? shape : "";
    require(script.expression<T>(type + ".identity(" + dims + ")").isApprox(T::Identity(rows, cols)), "matrix identity failed");
    require(script.expression<T>(type + ".zero(" + dims + ")").isZero(0), "matrix zero failed");
    require(script.expression<T>(type + ".constant(" + (dims.empty() ? "" : dims + ", ") + "5.0)")
            .isApprox(T::Constant(rows, cols, 5)), "matrix constant failed");
    require(script.expression<double>("(" + type + ".transpose(m))[1][0]") == 7, "expression indexing failed");
    script.rejects("m[-1][0]");
    script.rejects("m[0][" + std::to_string(cols) + "]");
    script.rejects("set m[" + std::to_string(rows) + "][0] = 5.0", true);
    script.rejects("m / 0");
    script.rejects(type + "(-1, 2)");
    script.rejects(type + "(" + shape + ", Float64Array(1, 0.0))");
    if constexpr (T::SizeAtCompileTime != Eigen::Dynamic) {
        require(script.expression<T>(type + "(values)").isApprox(expected), "fixed row-major constructor failed");
        require(script.expression<T>(type + "(Eigen.MatrixXd(m))").isApprox(expected), "matrix conversion failed");
        require(script.expression<T>("m * " + type + ".identity()").isApprox(expected), "fixed matrix product failed");
        script.rejects(type + "(Eigen.MatrixXd(5, 2))");
        script.rejects("m + Eigen.MatrixXd(m)");
        const std::string vectorType = "Eigen.Vector" + std::to_string(rows) + "d";
        using V = Eigen::Matrix<double, T::RowsAtCompileTime, 1>;
        require(script.expression<V>("m * " + vectorType + ".constant(1.0)").isApprox(expected.rowwise().sum()), "fixed matrix-vector product failed");
    } else {
        require(script.expression<T>("m * " + type + ".transpose(m)").isApprox(expected * expected.transpose()), "dynamic matrix product failed");
        require(script.expression<Eigen::VectorXd>("m * Eigen.VectorXd(" + std::to_string(cols) + ", 1.0)")
                .isApprox(expected.rowwise().sum()), "dynamic matrix-vector product failed");
        script.rejects("m + Eigen.MatrixXd(1, 1)");
        script.rejects("m * Eigen.MatrixXd(1, 1)");
        script.rejects("m * Eigen.VectorXd(1)");
        script.statement("set m = Eigen.MatrixXd(1, 1)");
        bool failed = false;
        try { assignment->evaluate(); } catch (const std::exception&) { failed = true; }
        require(failed && script.expression<T>("m").isZero(0), "matrix alias survived an invalid resize without checking bounds");
    }
}

void checkQuaternion() {
    Script script;
    script.statement("var Eigen.Quaterniond q = Eigen.Quaterniond(1.0, 2.0, 3.0, 4.0)");
    const Eigen::Quaterniond expected(1, 2, 3, 4);
    require(script.expression<Eigen::Quaterniond>("q").coeffs().isApprox(expected.coeffs()), "quaternion coefficient order failed");
    for (const auto* member : {"w", "x", "y", "z"}) script.statement(std::string("set q.") + member + " = 0.0");
    script.statement("set q.z = 1.0"); // 180 degrees about Z
    const Eigen::Quaterniond rotation(0, 0, 0, 1);
    require(script.expression<Eigen::Quaterniond>("q").coeffs().isApprox(rotation.coeffs()), "quaternion member writes failed");
    script.statement("var Eigen.Vector3d v = Eigen.Vector3d.constant(1.0)");
    const Eigen::Vector3d rotated(-1, -1, 1);
    require(script.expression<Eigen::Vector3d>("q * v").isApprox(rotated), "quaternion vector rotation failed");
    require(script.expression<Eigen::Vector3d>("Eigen.Quaterniond.rotate(q, v)").isApprox(rotated), "rotation service failed");
    require(script.expression<Eigen::Matrix3d>("Eigen.Quaterniond.toRotationMatrix(q)")
            .isApprox(rotation.toRotationMatrix()), "rotation matrix conversion failed");
    require(script.expression<Eigen::Quaterniond>("Eigen.Quaterniond(Eigen.Quaterniond.toRotationMatrix(q))")
            .toRotationMatrix().isApprox(rotation.toRotationMatrix()), "rotation matrix constructor failed");
    require(script.expression<Eigen::Quaterniond>("Eigen.Quaterniond.fromRotationMatrix(Eigen.Quaterniond.toRotationMatrix(q))")
            .toRotationMatrix().isApprox(rotation.toRotationMatrix()), "rotation matrix service failed");
    require(script.expression<Eigen::Quaterniond>("q * Eigen.Quaterniond.inverse(q)")
            .coeffs().isApprox(Eigen::Quaterniond::Identity().coeffs()), "quaternion inverse/composition failed");
    require(script.expression<Eigen::Quaterniond>("Eigen.Quaterniond.inverse(Eigen.Quaterniond(1.0, 2.0, 3.0, 4.0))")
            .coeffs().isApprox(expected.inverse().coeffs()), "non-unit quaternion inverse failed");
    require(script.expression<Eigen::Quaterniond>("Eigen.Quaterniond.conjugate(q)")
            .coeffs().isApprox(rotation.conjugate().coeffs()), "quaternion conjugate failed");
    require(script.expression<double>("Eigen.Quaterniond.norm(q)") == 1, "quaternion norm failed");
    require(script.expression<Eigen::Quaterniond>("Eigen.Quaterniond.normalized(Eigen.Quaterniond(1.0, 2.0, 3.0, 4.0))")
            .coeffs().isApprox(expected.normalized().coeffs()), "quaternion normalization failed");
    require(script.expression<Eigen::Quaterniond>("Eigen.Quaterniond.identity()")
            .coeffs().isApprox(Eigen::Quaterniond::Identity().coeffs()), "quaternion identity failed");
    script.rejects("Eigen.Quaterniond.normalized(Eigen.Quaterniond(0.0, 0.0, 0.0, 0.0))");
    script.rejects("Eigen.Quaterniond.inverse(Eigen.Quaterniond(0.0, 0.0, 0.0, 0.0))");
    script.rejects("Eigen.Quaterniond(2.0, 0.0, 0.0, 0.0) * v");
    script.rejects("Eigen.Quaterniond.toRotationMatrix(Eigen.Quaterniond(2.0, 0.0, 0.0, 0.0))");
    script.rejects("Eigen.Quaterniond(Eigen.Matrix3d.zero())");
    script.rejects("Eigen.Quaterniond(Float64Array(3, 0.0))");
}

void checkPrograms() {
    Script script;
    auto scripting = RTT::scripting::ScriptingService::Create(&script.task);
    script.statement("var Eigen.VectorXd first");
    script.statement("var Eigen.VectorXd second");
    script.statement("var Eigen.Matrix4d defaults");
    // Function invocation copies unbound local variables and their member data
    // sources. Each call must write its own matrix, including a returned row.
    script.parser.runScript(R"(
        Eigen.VectorXd makeRow(Float64 value) {
            var Eigen.MatrixXd m = Eigen.MatrixXd(2, 3)
            var Int32 row = 1
            var Int32 col = 2
            set m[row][col] = value
            return m[row]
        }
        set first = makeRow(4.0)
        set second = makeRow(9.0)
        set defaults[0][3] = first[2] + second[2]
    )", &script.task, scripting.get(), "eigen-functions.ops");
    require(script.expression<Eigen::VectorXd>("first").isApprox(Eigen::Vector3d(0, 0, 4)) &&
            script.expression<Eigen::VectorXd>("second").isApprox(Eigen::Vector3d(0, 0, 9)) &&
            script.expression<double>("defaults[0][3]") == 13, "copied function members refer to the wrong matrix");
    bool failed = false;
    try { failed = !scripting->eval("set defaults[4][0] = 1.0"); }
    catch (const std::exception&) { failed = true; }
    catch (const RTT::file_parse_exception&) { failed = true; }
    require(failed && script.expression<double>("defaults[0][3]") == 13, "invalid script assignment changed the matrix");
    require(scripting->eval("set defaults[0][3] = 14.0") && script.expression<double>("defaults[0][3]") == 14,
            "scripting service did not recover after invalid indexing");
    require(script.expression<Eigen::Vector3d>("Eigen.Vector3d.cross(Eigen.Vector3d(first), Eigen.Vector3d.constant(1.0))")
            .isApprox(Eigen::Vector3d(-4, 4, 0)),
            "vector cross product failed");
}
} // namespace

int ORO_main(int argc, char** argv) {
    try {
        require(argc == 2, "expected Eigen plugin directory");
        RTT::types::TypekitRepository::Import(new RTT::types::RealTimeTypekitPlugin);
        require(RTT::plugin::PluginLoader::Instance()->loadTypekits(argv[1]), "could not import Eigen typekit");
#define DEFAULT(T) checkDefaults<Eigen::T>(#T)
        DEFAULT(VectorXd); DEFAULT(Vector2d); DEFAULT(Vector3d); DEFAULT(Vector4d); DEFAULT(Vector6d);
        DEFAULT(MatrixXd); DEFAULT(Matrix2d); DEFAULT(Matrix3d); DEFAULT(Matrix4d); DEFAULT(Quaterniond);
#undef DEFAULT
        checkVector<Eigen::VectorXd>("VectorXd", 5);
        checkVector<Eigen::Vector2d>("Vector2d", 2);
        checkVector<Eigen::Vector3d>("Vector3d", 3);
        checkVector<Eigen::Vector4d>("Vector4d", 4);
        checkVector<Eigen::Vector6d>("Vector6d", 6);
        checkMatrix<Eigen::MatrixXd>("MatrixXd", 2, 3);
        checkMatrix<Eigen::Matrix2d>("Matrix2d", 2, 2);
        checkMatrix<Eigen::Matrix3d>("Matrix3d", 3, 3);
        checkMatrix<Eigen::Matrix4d>("Matrix4d", 4, 4);
        checkQuaternion();
        checkPrograms();
        std::cout << "Eigen parser: defaults, members, arithmetic, conversions, quaternion and rejected inputs passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    } catch (const RTT::parse_exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    } catch (const RTT::file_parse_exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
