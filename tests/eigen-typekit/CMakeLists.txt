cmake_minimum_required(VERSION 3.16)
project(orocos_eigen_consumer LANGUAGES CXX)

find_package(OROCOS-RTT REQUIRED)
find_package(Eigen3 REQUIRED NO_MODULE)
find_package(PkgConfig REQUIRED)
pkg_check_modules(EIGEN_TYPEKIT REQUIRED IMPORTED_TARGET eigen_typekit-${OROCOS_TARGET})
pkg_get_variable(EIGEN_PLUGIN_DIR eigen_typekit-${OROCOS_TARGET} orocos_libdir)

include(CTest)
add_executable(eigen-consumer consumer.cpp)
target_compile_features(eigen-consumer PRIVATE cxx_std_20)
target_link_libraries(eigen-consumer PRIVATE PkgConfig::EIGEN_TYPEKIT Eigen3::Eigen
  ${OROCOS-RTT_TYPEKIT_LIBRARIES})
if(MSVC)
  target_compile_options(eigen-consumer PRIVATE /bigobj)
endif()
add_test(NAME installed-eigen-consumer COMMAND eigen-consumer "${EIGEN_PLUGIN_DIR}")
set_tests_properties(installed-eigen-consumer PROPERTIES TIMEOUT 20)
