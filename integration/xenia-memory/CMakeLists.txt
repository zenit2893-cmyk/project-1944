cmake_minimum_required(VERSION 3.25)

# This is a standalone contract target.  It deliberately has no dependency on
# the active ReXGlue SDK, generated game sources, Xenia executable, or GUI.
project(cod3_xenia_memory_contract LANGUAGES CXX)

add_library(cod3_xenia_memory_contract INTERFACE)
target_include_directories(cod3_xenia_memory_contract INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_features(cod3_xenia_memory_contract INTERFACE cxx_std_20)

