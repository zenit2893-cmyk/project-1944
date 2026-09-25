cmake_minimum_required(VERSION 3.25)
project(cod3_xenia_memory_contract_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../integration/xenia-memory" xenia-memory-contract)

add_executable(xenia_memory_contract_tests xenia_memory_contract_tests.cpp)
target_link_libraries(xenia_memory_contract_tests PRIVATE cod3_xenia_memory_contract)

enable_testing()
add_test(NAME xenia_memory_contract COMMAND xenia_memory_contract_tests)
set_tests_properties(xenia_memory_contract PROPERTIES TIMEOUT 20)

