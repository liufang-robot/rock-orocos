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
var eigen_vector vector = eigen_vector(3, 0.0)
vector[0] = 1.0
```

The current type names are:

| C++ type | RTT type |
| --- | --- |
| `Eigen::VectorXd` | `eigen_vector` |
| `Eigen::Vector2d`, `Vector3d`, `Vector4d`, `Vector6d` | `eigen_vector2`, `eigen_vector3`, `eigen_vector4`, `eigen_vector6` |
| `Eigen::MatrixXd` | `eigen_matrix` |
| `Eigen::Matrix2d`, `Matrix3d`, `Matrix4d` | `eigen_matrix2`, `eigen_matrix3`, `eigen_matrix4` |

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

## C++ Consumers

After activating `dev-env.sh` or the Windows `dev-env.ps1`, consumers locate
RTT, Eigen3 and the typekit from the installation:

```cmake
find_package(OROCOS-RTT REQUIRED)
find_package(Eigen3 3.3 REQUIRED NO_MODULE)
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
header and library, registered names, writable vector members, operation calls
and local port transfer:

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
RTT provides mqueue. Windows installs the base typekit. CORBA is disabled by
the toolchain policy.

This integration retains the existing vector and matrix API. `Quaterniond`,
`Isometry3d`, `Affine3d`, `/Eigen/...` names and generated composite types with
Eigen members require separate implementation and validation. Importing this
typekit does not add Typelib, OPC UA or HTTP transport support for Eigen types.
The existing dynamic containers, registration and reflection paths carry no
new realtime-safety guarantee.
