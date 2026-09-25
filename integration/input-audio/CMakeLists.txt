cmake_minimum_required(VERSION 3.25)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(cod3_input_audio_adapter LANGUAGES CXX)
endif()

add_library(cod3_input_audio_adapter STATIC
    src/input_audio_adapter.cpp)
add_library(cod3::input_audio ALIAS cod3_input_audio_adapter)

target_compile_features(cod3_input_audio_adapter PUBLIC cxx_std_23)
target_include_directories(cod3_input_audio_adapter
    PUBLIC "${CMAKE_CURRENT_LIST_DIR}/include")
target_compile_options(cod3_input_audio_adapter PRIVATE
    -fno-strict-aliasing -ffp-model=strict)

# The adapter has no dependency on ReXGlue, SDL, XInput, or Xenia binaries.
# It is intentionally a small host-boundary library so that its policy tests
# can run before the native game target is touched.
function(cod3_enable_input_audio target_name)
    if(NOT TARGET "${target_name}")
        message(FATAL_ERROR "Unknown input/audio host target ${target_name}")
    endif()
    target_link_libraries("${target_name}" PRIVATE cod3::input_audio)
    target_include_directories("${target_name}" PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include")
endfunction()
