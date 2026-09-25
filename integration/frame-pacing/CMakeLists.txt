cmake_minimum_required(VERSION 3.25)
project(cod3_frame_pacing LANGUAGES CXX)

if(NOT WIN32 OR NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  message(FATAL_ERROR
    "Native frame pacing currently requires Windows and the verified Clang toolchain")
endif()

add_library(cod3_frame_pacing STATIC frame_pacing.cpp)
add_library(cod3::frame_pacing ALIAS cod3_frame_pacing)
target_compile_features(cod3_frame_pacing PUBLIC cxx_std_20)
target_include_directories(cod3_frame_pacing PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(cod3_frame_pacing PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(cod3_frame_pacing PRIVATE -fno-strict-aliasing -ffp-model=strict)

option(COD3_FRAME_PACING_BUILD_TESTS
       "Build deterministic native scheduler tests, not gameplay" ON)
if(COD3_FRAME_PACING_BUILD_TESTS)
  enable_testing()
  add_executable(cod3_frame_pacing_test
                 "${CMAKE_CURRENT_SOURCE_DIR}/../../tests/frame-pacing/frame_pacing_test.cpp")
  target_link_libraries(cod3_frame_pacing_test PRIVATE cod3::frame_pacing)
  target_compile_features(cod3_frame_pacing_test PRIVATE cxx_std_20)
  target_compile_options(cod3_frame_pacing_test PRIVATE -fno-strict-aliasing)
  add_test(NAME frame_pacing_native COMMAND cod3_frame_pacing_test)
endif()
