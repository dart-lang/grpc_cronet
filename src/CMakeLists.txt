# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(grpc_cronet_library VERSION 0.0.1 LANGUAGES CXX C)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CXX_STANDARD 11)
add_definitions(-DDART_SHARED_LIB)

add_library(grpc_cronet SHARED
  "grpc_cronet.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dart/dart_api_dl.c"
)

set_target_properties(grpc_cronet PROPERTIES
  PUBLIC_HEADER grpc_cronet.h
  OUTPUT_NAME "grpc_cronet"
)

set_target_properties(grpc_cronet PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_include_directories(grpc_cronet PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dart"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dart/runtime"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cronet"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/grpc_support"
)

target_compile_definitions(grpc_cronet PUBLIC DART_SHARED_LIB)

add_library("cronet.104.0.5108.0" SHARED IMPORTED)
set_target_properties("cronet.104.0.5108.0" PROPERTIES IMPORTED_IMPLIB "${CMAKE_CURRENT_SOURCE_DIR}/../windows/lib/cronet.104.0.5108.0.dll.lib")
set_target_properties("cronet.104.0.5108.0" PROPERTIES IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/../linux/lib/libcronet.104.0.5108.0.so")
target_link_libraries(grpc_cronet "cronet.104.0.5108.0")
