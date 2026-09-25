cmake_minimum_required(VERSION 3.25)
project(cod3_xenia_threads_contract LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The Xenia/ReXGlue thread contract probe requires Windows x64.")
endif()

find_package(rexglue 0.10.0.5 EXACT REQUIRED CONFIG)

add_executable(cod3_xenia_threads_contract
  "${CMAKE_CURRENT_LIST_DIR}/../../tests/xenia-threads/native_contract_test.cpp")
target_link_libraries(cod3_xenia_threads_contract PRIVATE rex::runtime)
rexglue_apply_target_settings(cod3_xenia_threads_contract)

enable_testing()
add_test(NAME xenia_rexglue_thread_contract
  COMMAND cod3_xenia_threads_contract)
set_tests_properties(xenia_rexglue_thread_contract PROPERTIES TIMEOUT 45)
