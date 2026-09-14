cmake_minimum_required(VERSION 3.16)
project(orocos_http_fixture LANGUAGES CXX)

find_package(OROCOS-RTT 3.0 REQUIRED)
find_package(rtt_http CONFIG REQUIRED)
include(CTest)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Reuse the ordinary RTT fixture used by OPC UA. These targets do not link
# either protocol or include either codec SDK.
set(FIXTURE_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../opcua-custom-datatypes")
add_library(http-fixture-types MODULE ${FIXTURE_SOURCE}/fixture_typekit.cpp)
add_library(http-fixture-components STATIC ${FIXTURE_SOURCE}/fixture_components.cpp)
foreach(target http-fixture-types http-fixture-components)
  target_include_directories(${target} PRIVATE ${FIXTURE_SOURCE})
  target_include_directories(${target} SYSTEM PRIVATE ${OROCOS-RTT_INCLUDE_DIRS})
  target_compile_options(${target} PRIVATE ${OROCOS-RTT_DEFINITIONS})
  target_link_libraries(${target} PRIVATE ${OROCOS-RTT_LIBRARIES} ${OROCOS-RTT_TYPEKIT_LIBRARIES})
endforeach()
if(MSVC)
  # The shared component fixture instantiates enough RTT templates to exceed
  # the ordinary COFF object-file section limit.
  target_compile_options(http-fixture-components PRIVATE /bigobj)
endif()

add_library(http-fixture-transport MODULE fixture_http_transport.cpp)
target_include_directories(http-fixture-transport PRIVATE ${FIXTURE_SOURCE})
target_link_libraries(http-fixture-transport PRIVATE rtt_http::rtt_http)
foreach(target http-fixture-types http-fixture-transport)
  # RTT classifies an explicit library path by its immediate parent directory.
  # Keep the same types/ layout that consumers use in an installed prefix.
  set_target_properties(${target} PROPERTIES OUTPUT_NAME ${target}-${OROCOS_TARGET}
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/types"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/types")
  foreach(config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(${target} PROPERTIES
      LIBRARY_OUTPUT_DIRECTORY_${config} "${CMAKE_CURRENT_BINARY_DIR}/types"
      RUNTIME_OUTPUT_DIRECTORY_${config} "${CMAKE_CURRENT_BINARY_DIR}/types")
  endforeach()
endforeach()

add_executable(http-fixture-sdk-check fixture_sdk_check.cpp)
target_include_directories(http-fixture-sdk-check PRIVATE ${FIXTURE_SOURCE})
target_link_libraries(http-fixture-sdk-check PRIVATE http-fixture-components rtt_http::rtt_http
  ${OROCOS-RTT_TYPEKIT_LIBRARIES})
add_test(NAME http-custom-codec-sdk COMMAND http-fixture-sdk-check
  $<TARGET_FILE:http-fixture-types> $<TARGET_FILE:http-fixture-transport>)
set_tests_properties(http-custom-codec-sdk PROPERTIES TIMEOUT 20)

foreach(target http-fixture-types http-fixture-components http-fixture-transport http-fixture-sdk-check)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /WX)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
  endif()
endforeach()
