cmake_minimum_required(VERSION 3.25)
project(cod3_xenos_semantics LANGUAGES NONE)

find_package(Python3 COMPONENTS Interpreter REQUIRED)
enable_testing()

file(REAL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../.." COD3_WORKSPACE_ROOT)
add_test(
    NAME cod3_xenos_semantics
    COMMAND "${Python3_EXECUTABLE}" "${COD3_WORKSPACE_ROOT}/tests/xenos-semantics/test_xenos_semantics.py" "${COD3_WORKSPACE_ROOT}"
)
set_tests_properties(cod3_xenos_semantics PROPERTIES WORKING_DIRECTORY "${COD3_WORKSPACE_ROOT}")

