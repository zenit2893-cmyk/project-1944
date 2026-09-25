cmake_minimum_required(VERSION 3.25)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(cod3_xenon_timebase_adapter LANGUAGES CXX)
endif()

if(NOT TARGET rex::runtime)
  find_package(rexglue 0.10.0.5 EXACT REQUIRED CONFIG)
endif()

add_library(cod3_xenon_timebase_adapter STATIC
  rexglue_xenon_timebase.cpp)
add_library(cod3::xenon_timebase ALIAS cod3_xenon_timebase_adapter)

target_compile_features(cod3_xenon_timebase_adapter PUBLIC cxx_std_23)
target_include_directories(cod3_xenon_timebase_adapter
  PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(cod3_xenon_timebase_adapter PUBLIC rex::runtime)
target_compile_options(cod3_xenon_timebase_adapter PRIVATE
  -ffp-model=strict -fno-strict-aliasing -fwrapv)

function(cod3_enable_xenon_timebase_adapter target_name)
  if(NOT TARGET "${target_name}")
    message(FATAL_ERROR "Unknown Xenon timebase adapter host ${target_name}")
  endif()
  target_link_libraries("${target_name}" PRIVATE cod3::xenon_timebase)
endfunction()
