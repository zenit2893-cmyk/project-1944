cmake_minimum_required(VERSION 3.25)
project(cod3_input_audio_native_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../integration/input-audio"
                 input_audio_adapter)

add_executable(input_audio_native_test input_audio_native_test.cpp)
target_link_libraries(input_audio_native_test PRIVATE cod3::input_audio)
target_compile_options(input_audio_native_test PRIVATE
    -fno-strict-aliasing -ffp-model=strict)

enable_testing()
add_test(NAME input_audio_policy_contract
    COMMAND input_audio_native_test
            "${CMAKE_CURRENT_LIST_DIR}/../../integration/input-audio")
set_tests_properties(input_audio_policy_contract PROPERTIES TIMEOUT 20)
