# Eigen Typekit

The toolchain includes `eigen_typekit` for Eigen vectors and matrices. Its
runtime plugin is part of `orocos`; headers and build metadata are part of
`orocos-dev`. Native source builds install both through the normal setup command.

The sources come from the maintained `rtt_geometry` repository at the revision
recorded in `packaging/source-lock.json`. The build selects its `eigen_typekit/`
subdirectory. The sibling `kdl_typekit` package and the ROS `rtt_geometry`
metapackage are not built or installed; neither KDL nor ROS is required.

## Runtime Use

Activate the installed runtime and import the package in the TaskBrowser or an
Orocos script:

```text
import("eigen_typekit")
var Eigen.VectorXd vector = Eigen.VectorXd(3, 0.0)
vector[0] = 1.0
```

Each C++ type has one canonical RTT registration. CPF files use the slash form;
TaskBrowser `.types`, scripts and constructors use the dotted form. RTT resolves
both spellings to the same type.

| C++ type | RTT / CPF name | TaskBrowser / script name |
| --- | --- | --- |
| `Eigen::VectorXd` | `/Eigen/VectorXd` | `Eigen.VectorXd` |
| `Eigen::Vector2d` | `/Eigen/Vector2d` | `Eigen.Vector2d` |
| `Eigen::Vector3d` | `/Eigen/Vector3d` | `Eigen.Vector3d` |
| `Eigen::Vector4d` | `/Eigen/Vector4d` | `Eigen.Vector4d` |
| `Eigen::Vector6d` | `/Eigen/Vector6d` | `Eigen.Vector6d` |
| `Eigen::MatrixXd` | `/Eigen/MatrixXd` | `Eigen.MatrixXd` |
| `Eigen::Matrix2d` | `/Eigen/Matrix2d` | `Eigen.Matrix2d` |
| `Eigen::Matrix3d` | `/Eigen/Matrix3d` | `Eigen.Matrix3d` |
| `Eigen::Matrix4d` | `/Eigen/Matrix4d` | `Eigen.Matrix4d` |

`Vector6d` is the alias supplied by the typekit header. Fixed vectors can be
constructed from an RTT `Float64Array` with the matching number of elements; vector
elements support indexing and assignment. Initialize values explicitly: Eigen
default construction does not promise zeros.

The checked script in `tests/eigen-typekit/runtime.ops` exercises import,
construction, indexing and assignment with the real deployer:

```bash
source ~/.orocos/env.sh
deployer-gnulinux --check tests/eigen-typekit/runtime.ops
```

## Migrating From 0.1.10

> [!IMPORTANT]
> Version 0.1.11 replaces the legacy Eigen type names. The old names are not
> registered as aliases. Update existing scripts, CPF files and string-based
> RTT type lookups before upgrading, then restart the deployer and components.

Replace `eigen_vector` with `Eigen.VectorXd` in scripts, and replace
`eigen_vector2`, `eigen_vector3`, `eigen_vector4` and `eigen_vector6` with the
corresponding `Eigen.Vector2d`, `Eigen.Vector3d`, `Eigen.Vector4d` and
`Eigen.Vector6d`. Replace `eigen_matrix` with `Eigen.MatrixXd`, and
`eigen_matrix2`, `eigen_matrix3` and `eigen_matrix4` with `Eigen.Matrix2d`,
`Eigen.Matrix3d` and `Eigen.Matrix4d`.

CPF `type` attributes and canonical RTT lookups use the slash names in the
table. Migrate nested matrix rows too: their type is `/Eigen/VectorXd`.
For example, `type="eigen_vector3"` becomes `type="/Eigen/Vector3d"`.
The package is still imported with `import("eigen_typekit")`, and C++ consumers
continue to use the Eigen namespace and types shown above.

## C++ Consumers

After activating `dev-env.sh` or the Windows `dev-env.ps1`, consumers locate
RTT, Eigen3 and the typekit from the installation:

```cmake
find_package(OROCOS-RTT REQUIRED)
find_package(Eigen3 REQUIRED NO_MODULE)
find_package(PkgConfig REQUIRED)
pkg_check_modules(EIGEN_TYPEKIT REQUIRED IMPORTED_TARGET
                  eigen_typekit-${OROCOS_TARGET})
target_link_libraries(my_component PRIVATE
                      PkgConfig::EIGEN_TYPEKIT Eigen3::Eigen)
```

Include `<eigen_typekit/eigen_typekit.hpp>` at the RTT integration boundary
and import the plugin before exposing Eigen operations, properties or ports.
A standalone numerical library can include Eigen directly and remain
independent of RTT.

The independent consumer under `tests/eigen-typekit` verifies the installed
header and library, canonical and dotted names, absence of legacy aliases,
writable vector members, operation calls, local port transfer and CPF round
trips for all nine types. Linux builds also check dynamic vector and matrix
mqueue transfers:

```bash
source ~/.orocos/dev-env.sh
cmake -S tests/eigen-typekit -B /tmp/eigen-consumer
cmake --build /tmp/eigen-consumer
ctest --test-dir /tmp/eigen-consumer --output-on-failure
```

Windows uses the same consumer with its activated development environment and
`--config Release` / `ctest -C Release` for a Visual Studio generator.

## Supported Boundaries

Linux `gnulinux` and Xenomai builds include the typekit's mqueue plugin when
RTT provides mqueue. This transport supports `Eigen.VectorXd` and
`Eigen.MatrixXd`; fixed-size transport support is not included. Windows installs
the base typekit. CORBA is disabled by the toolchain policy.

This integration retains the existing vector and matrix API. `Quaterniond`,
`Isometry3d`, `Affine3d` and generated composite types with
Eigen members require separate implementation and validation. Importing this
typekit does not add Typelib, OPC UA or HTTP transport support for Eigen types.
The existing dynamic containers, registration and reflection paths carry no
new realtime-safety guarantee.
