cmake_minimum_required(VERSION 3.25)
project(cod3_nonlocal_flow_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(rexglue CONFIG REQUIRED)

add_library(nonlocal_test_guest SHARED tests/dll_frame.cpp)
target_include_directories(nonlocal_test_guest PRIVATE generated/main)
target_link_libraries(nonlocal_test_guest PRIVATE rex::runtime)
rexglue_apply_target_settings(nonlocal_test_guest)

add_executable(nonlocal_flow_probe tests/main.cpp)
target_include_directories(nonlocal_flow_probe PRIVATE generated/main)
target_link_libraries(nonlocal_flow_probe PRIVATE rex::runtime nonlocal_test_guest)
rexglue_apply_target_settings(nonlocal_flow_probe)
enable_testing()
add_test(NAME nonlocal_cross_dll COMMAND nonlocal_flow_probe)

