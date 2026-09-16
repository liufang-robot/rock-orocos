# Eigen Typekit

The toolchain includes `eigen_typekit` for Eigen vectors, matrices and quaternions. Its
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
| `Eigen::Quaterniond` | `/Eigen/Quaterniond` | `Eigen.Quaterniond` |

`Vector6d` is the alias supplied by the typekit header. Version 0.1.12 adds
the scripting operations below and `Quaterniond`.

## Declaring and Inspecting Values

```text
var Eigen.Matrix4d transform
transform[0][3] = 2.5
transform
transform[0]
transform[0][3]
transform.rows
transform.cols
transform.size
Eigen.Matrix4d.toString(transform)
```

`var Eigen.Matrix4d transform` creates a **zero** 4×4 matrix. Use
`Eigen.Matrix4d.identity()` when you need an identity transform. Indices start at
zero, and `matrix[row][column] = value` updates the original matrix. A row read,
`matrix[row]`, returns a `VectorXd` snapshot; assign individual elements through
the matrix to modify it.

The TaskBrowser displays matrix dimensions and `data`, a read-only
`Float64Array` snapshot in **row-major** order: all columns of row 0, then all
columns of row 1, and so on. `size` is the total coefficient count. `rows`,
`cols`, `size` and `data` are read-only; replace a dynamic matrix to resize it.

The TaskBrowser abbreviates long arrays. `Eigen.Matrix4d.toString(transform)`
prints every coefficient as matrix rows; each matrix type has this helper.

| Declaration | Initial value |
| --- | --- |
| Fixed vector or matrix | All coefficients zero |
| `Eigen.VectorXd` | Empty vector |
| `Eigen.MatrixXd` | 0×0 matrix |
| `Eigen.Quaterniond` | Identity: `(w=1, x=0, y=0, z=0)` |

These defaults apply to RTT factories and scripts. Native C++ Eigen default
construction retains Eigen's own initialization behavior.

## Constructors and Conversions

```text
var Eigen.MatrixXd dynamic = Eigen.MatrixXd(2, 3)
var Eigen.Matrix4d fixed = Eigen.Matrix4d(4, 4)
var Eigen.MatrixXd filled = Eigen.MatrixXd(2, 3, 5.0)
var Eigen.Matrix4d identity = Eigen.Matrix4d.identity()
var Eigen.MatrixXd rectangular = Eigen.MatrixXd.identity(2, 3)
var Eigen.Matrix4d constant = Eigen.Matrix4d.constant(2.0)
```

All matrix types accept `(rows, cols)` for zeros and `(rows, cols, value)` for
constant coefficients. Fixed types require their exact dimensions.

To supply coefficients, use `(rows, cols, Float64Array)` for any matrix, or
`(Float64Array)` for a fixed matrix. Array length must equal `rows * cols`:

```text
var Float64Array coefficients = Float64Array(4, 0.0)
coefficients[0] = 1.0
coefficients[1] = 2.0
coefficients[2] = 3.0
coefficients[3] = 4.0
var Eigen.Matrix2d matrix = Eigen.Matrix2d(coefficients)
// matrix has rows [1, 2] and [3, 4].
```

Vectors accept `(Float64Array)`, `(size)` for zeros, or `(size, value)` for
constants. Fixed vectors require the matching size. Vector indexing is writable;
`vector.size` and its compatibility synonym `vector.capacity` report the length.

Convert fixed and dynamic Eigen containers explicitly:

```text
var Eigen.MatrixXd dynamic_copy = Eigen.MatrixXd(identity)
var Eigen.Matrix4d fixed_copy = Eigen.Matrix4d(dynamic_copy)
var Eigen.Vector3d position = Eigen.Vector3d.constant(1.0)
var Eigen.VectorXd dynamic_position = Eigen.VectorXd(position)
var Eigen.Vector3d fixed_position = Eigen.Vector3d(dynamic_position)
```

Fixed/dynamic conversions preserve coefficients and reject dimension mismatches.
They are not implicit in assignment, operation arguments or arithmetic. The
existing `Float64Array` to vector conversion remains available.

## Arithmetic and Helpers

```text
var Eigen.Vector3d a = Eigen.Vector3d.constant(2.0)
var Eigen.Vector3d b = (2 * a + a - a) / 2.0
var Float64 length = Eigen.Vector3d.norm(b)
var Float64 projection = Eigen.Vector3d.dot(a, b)
var Eigen.Vector3d unit = Eigen.Vector3d.normalized(b)
var Eigen.Vector3d normal = Eigen.Vector3d.cross(a, b)
var Eigen.Matrix3d rotation = Eigen.Matrix3d.identity()
var Eigen.Vector3d rotated = rotation * a
var Eigen.Matrix3d product = rotation * rotation
var Eigen.Matrix3d transposed = Eigen.Matrix3d.transpose(product)
```

| Operation | Supported operands |
| --- | --- |
| `a + b`, `a - b`, `-a` | Vectors or matrices of the same type and dimensions |
| `a * scalar`, `scalar * a`, `a / scalar` | Vectors or matrices; scalar multiplication accepts `Int32` and `Float64` |
| `a * b` | Same matrix type; `a.cols == b.rows` |
| `matrix * vector` | `Matrix2d/Vector2d`, `Matrix3d/Vector3d`, `Matrix4d/Vector4d`, or `MatrixXd/VectorXd` |
| `q * p` | Quaternion composition |
| `q * vector` | Unit `Quaterniond` rotating `Vector3d` |

Results own their coefficients. For mixed fixed/dynamic arithmetic, explicitly
convert an operand first. There is no implicit padding, truncation or resizing
of fixed values.

Helpers are global services named after each type:

| Type family | Helpers |
| --- | --- |
| Fixed vectors | `zero()`, `constant(value)`, `norm(v)`, `normalized(v)`, `dot(a, b)` |
| `VectorXd` | `zero(size)`, `constant(size, value)`, `norm(v)`, `normalized(v)`, `dot(a, b)` |
| `Vector3d` | Also `cross(a, b)` |
| Fixed matrices | `zero()`, `identity()`, `constant(value)`, `transpose(m)`, `toString(m)` |
| `MatrixXd` | `zero(rows, cols)`, `identity(rows, cols)`, `constant(rows, cols, value)`, `transpose(m)`, `toString(m)` |

## Quaternions

```text
var Eigen.Quaterniond q
var Eigen.Quaterniond half_turn = Eigen.Quaterniond(0.0, 0.0, 0.0, 1.0)
q.z = 1.0
q = Eigen.Quaterniond.normalized(q)
var Eigen.Vector3d direction = Eigen.Vector3d.constant(1.0)
var Eigen.Vector3d turned = half_turn * direction
var Eigen.Quaterniond inverse = Eigen.Quaterniond.inverse(half_turn)
var Eigen.Quaterniond combined = half_turn * inverse
var Eigen.Matrix3d rotation_matrix = Eigen.Quaterniond.toRotationMatrix(half_turn)
var Eigen.Quaterniond restored = Eigen.Quaterniond.fromRotationMatrix(rotation_matrix)
```

The constructor, `Float64Array` constructor and CPF fields use **`w, x, y, z`**
order. Members `.w`, `.x`, `.y`, `.z` are writable. This differs from the internal
order of Eigen's C++ `coeffs()` array. For the example above, `turned` is
`[-1, -1, 1]`.

`Eigen.Quaterniond` supplies `identity()`, `norm(q)`, `normalized(q)`,
`conjugate(q)`, `inverse(q)`, `rotate(q, vector)`, `toRotationMatrix(q)` and
`fromRotationMatrix(matrix)`. `Eigen.Quaterniond(matrix)` also accepts an explicit
`Matrix3d` rotation matrix.

Rotation requires a unit quaternion, within `1e-9` of unit norm. Normalize
explicitly after editing coefficients. Composition and CPF round trips preserve
coefficients without silently normalizing them. Inverse accepts finite nonzero
quaternions; conjugate negates the vector part. A rotation matrix must be finite,
orthonormal and have determinant +1, with tolerance `1e-9`. In a composition
`q * p`, `p` acts first when rotating a vector.

## Errors and Script Files

Negative dimensions, mismatched fixed dimensions, invalid coefficient counts,
indices outside the value, incompatible arithmetic, zero/nonfinite divisors,
and normalization of zero/nonfinite vectors report errors. Quaternions also
reject zero normalization/inversion and non-unit rotations. The TaskBrowser
remains usable after a failed command. A failed `.ops` statement causes script
execution to fail; check the deployer log for the diagnostic.

In `.ops` files, prefix assignments with `set` and import with `do`. The checked
script exercises the complete API with the real deployer:

```bash
source ~/.orocos/env.sh
deployer-gnulinux --check tests/eigen-typekit/runtime.ops
```

CPF keeps the existing numbered vector elements and numbered matrix rows. Empty
matrices with zero rows record a `cols` property so a 0×N shape survives a round
trip. Quaternion CPF stores the four named coefficients. Invalid CPF dimensions
or ragged rows are rejected without partially overwriting the affected value.

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
writable vector/matrix members, quaternion operation calls and local port
transfer, and CPF round trips for all ten types, including empty shapes. Parser
tests exercise arithmetic, conversions, function-local matrix members and
recovery after rejected input. Linux builds also check dynamic vector and matrix
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
`Eigen.MatrixXd`; fixed-size and quaternion mqueue support is not included. Windows installs
the base typekit. CORBA is disabled by the toolchain policy.

`Isometry3d`, `Affine3d` and generated composite types with Eigen members
require separate implementation and validation. Importing this
typekit does not add Typelib, OPC UA or HTTP transport support for Eigen types.
The existing dynamic containers, registration and reflection paths carry no
new realtime-safety guarantee.
