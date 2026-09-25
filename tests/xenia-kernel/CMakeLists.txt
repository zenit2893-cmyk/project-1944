cmake_minimum_required(VERSION 3.25)
project(cod3_xenia_kernel_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(rexglue 0.10.0.5 EXACT REQUIRED CONFIG)

set(candidate "${CMAKE_CURRENT_LIST_DIR}/../../integration/xenia-kernel/candidate/src/kernel/xam/xam_ui.cpp")
file(READ "${candidate}" candidate_source)
string(REGEX MATCH "u32 XamShowMessageBoxUIEx_entry\\([^}]*\n}" candidate_adapter "${candidate_source}")
if(NOT candidate_adapter)
  message(FATAL_ERROR "Could not extract the actual candidate adapter")
endif()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/candidate_adapter.inl" "${candidate_adapter}\n")

# Compile the complete candidate translation unit against the installed SDK.
# It is not linked into either the active SDK or the game.
add_library(xenia_kernel_candidate_syntax OBJECT "${candidate}")
target_link_libraries(xenia_kernel_candidate_syntax PRIVATE rex::runtime)
rexglue_apply_target_settings(xenia_kernel_candidate_syntax)

add_executable(xenia_kernel_probe message_box_probe.cpp)
target_include_directories(xenia_kernel_probe PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(xenia_kernel_probe PRIVATE rex::runtime)
rexglue_apply_target_settings(xenia_kernel_probe)

enable_testing()
add_test(NAME message_box_ex_native_contract
  COMMAND xenia_kernel_probe "${CMAKE_CURRENT_LIST_DIR}/../../game/cod3")
set_tests_properties(message_box_ex_native_contract PROPERTIES TIMEOUT 20)

# Run-CombinedCandidate.ps1 stages the freshly built heap-fixed runtime DLL
# next to this executable before invoking this test. The test then resolves
# the real __imp__XamShowMessageBoxUIEx export instead of the isolated adapter.
add_test(NAME message_box_ex_combined_runtime_export
  COMMAND xenia_kernel_probe "${CMAKE_CURRENT_LIST_DIR}/../../game/cod3"
          --runtime-export)
set_tests_properties(message_box_ex_combined_runtime_export PROPERTIES TIMEOUT 20)
