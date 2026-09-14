cmake_minimum_required(VERSION 3.16)

project(orocos_opcua_fixture VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(OROCOS-RTT 3.0 REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(
  RTT_OPCUA
  REQUIRED
  IMPORTED_TARGET
  rtt_opcua-${OROCOS_TARGET}
)
find_package(open62541 CONFIG REQUIRED)
find_package(open62541pp 0.21.2 CONFIG REQUIRED)

include(${OROCOS-RTT_USE_FILE})
set(OROCOS_NO_AUTO_LINKING TRUE)

orocos_typekit(fixture-types fixture_typekit.cpp)
target_compile_features(fixture-types PRIVATE cxx_std_20)
target_include_directories(fixture-types PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

orocos_plugin(fixture-opcua-transport fixture_transport.cpp)
target_compile_features(fixture-opcua-transport PRIVATE cxx_std_20)
target_include_directories(
  fixture-opcua-transport
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(
  fixture-opcua-transport
  PkgConfig::RTT_OPCUA
  open62541pp::open62541pp
)

add_library(fixture-component-implementation STATIC fixture_components.cpp)
set_target_properties(
  fixture-component-implementation
  PROPERTIES POSITION_INDEPENDENT_CODE ON
)
target_compile_features(fixture-component-implementation PRIVATE cxx_std_20)
target_include_directories(
  fixture-component-implementation
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
  PRIVATE
    ${OROCOS-RTT_INCLUDE_DIRS}
)
target_link_libraries(
  fixture-component-implementation
  PUBLIC
    ${OROCOS-RTT_LIBRARIES}
    ${OROCOS-RTT_TYPEKIT_LIBRARIES}
)

orocos_component(fixture-components fixture_plugin.cpp)
target_compile_features(fixture-components PRIVATE cxx_std_20)
target_include_directories(fixture-components PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(
  fixture-components
  fixture-component-implementation
  ${OROCOS-RTT_LIBRARIES}
  ${OROCOS-RTT_TYPEKIT_LIBRARIES}
)

add_executable(fixture-server fixture_server.cpp)
orocos_configure_executable(fixture-server)
target_compile_features(fixture-server PRIVATE cxx_std_20)
target_include_directories(fixture-server PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(
  fixture-server
  fixture-component-implementation
  PkgConfig::RTT_OPCUA
  open62541pp::open62541pp
  ${OROCOS-RTT_TYPEKIT_LIBRARIES}
)

add_executable(fixture-client fixture_client.cpp)
orocos_configure_executable(fixture-client)
target_compile_features(fixture-client PRIVATE cxx_std_20)
target_include_directories(fixture-client PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(
  fixture-client
  PkgConfig::RTT_OPCUA
  open62541pp::open62541pp
  ${OROCOS-RTT_TYPEKIT_LIBRARIES}
)

foreach(
  target
  fixture-types
  fixture-opcua-transport
  fixture-component-implementation
  fixture-components
  fixture-server
  fixture-client
)
  # Keep strict warnings on fixture code, including with a custom Boost prefix.
  target_include_directories(${target} SYSTEM PRIVATE ${OROCOS-RTT_INCLUDE_DIRS})
  if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(
      ${target}
      PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -Werror
    )
  endif()
endforeach()

install(
  TARGETS fixture-server fixture-client
  RUNTIME DESTINATION bin
)
install(FILES fixture_types.hpp DESTINATION include/orocos/orocos_opcua_fixture)
install(
  FILES fixture_components.hpp
  DESTINATION include/orocos/orocos_opcua_fixture
)
install(
  FILES
    deployer-endpoint-only.ops
    deployer-no-start.ops
    deployer-service-load.ops
    deployer-start.ops
  DESTINATION share/orocos-opcua-fixture
)

orocos_generate_package(orocos_opcua_fixture-${OROCOS_TARGET})
