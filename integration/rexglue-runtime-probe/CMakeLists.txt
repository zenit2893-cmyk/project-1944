cmake_minimum_required(VERSION 3.25)
project(rexglue_runtime_module_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(rexglue CONFIG REQUIRED)
add_executable(rexglue_runtime_module_probe main.cpp)
target_link_libraries(rexglue_runtime_module_probe PRIVATE rex::runtime)
rexglue_apply_target_settings(rexglue_runtime_module_probe)

# Compile the proposed source patch independently, without linking it into the
# probe or changing the installed SDK. This checks C++/header consistency only.
add_library(runtime_xex_patch_syntax OBJECT EXCLUDE_FROM_ALL
    ../rexglue-patches/candidate/src/system/xex_module.cpp)
target_include_directories(runtime_xex_patch_syntax BEFORE PRIVATE
    ../rexglue-patches/candidate/include
    ../../tools/rexglue-source/thirdparty)
target_link_libraries(runtime_xex_patch_syntax PRIVATE rex::runtime)
rexglue_apply_target_settings(runtime_xex_patch_syntax)

add_executable(runtime_xex_patch_candidate_probe EXCLUDE_FROM_ALL
    ../../tests/runtime-module-probe/candidate_main.cpp
    $<TARGET_OBJECTS:runtime_xex_patch_syntax>)
target_include_directories(runtime_xex_patch_candidate_probe BEFORE PRIVATE
    ../rexglue-patches/candidate/include
    ../../tools/rexglue-source/thirdparty)
target_link_libraries(runtime_xex_patch_candidate_probe PRIVATE rex::runtime)
rexglue_apply_target_settings(runtime_xex_patch_candidate_probe)
