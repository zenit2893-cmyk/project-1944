cmake_minimum_required(VERSION 3.25)
project(cod3_native_build_contract_fixture LANGUAGES CXX)

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "The build-contract fixture requires Windows x64")
endif()
get_filename_component(WORKSPACE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(PATCHED_SDK "${WORKSPACE_ROOT}/tools/rexglue-patched-sdk")
set(COD3_GENERATED "${WORKSPACE_ROOT}/cod3-pc/generated")

# The fixture provides imported targets with the same configuration-specific
# paths as the installed SDK.  No SDK project is built or modified here.
add_library(rex::runtime SHARED IMPORTED GLOBAL)
set_target_properties(rex::runtime PROPERTIES
    IMPORTED_CONFIGURATIONS RELWITHDEBINFO
    IMPORTED_LOCATION_RELWITHDEBINFO "${PATCHED_SDK}/bin/rexruntimerd.dll"
    IMPORTED_IMPLIB_RELWITHDEBINFO "${PATCHED_SDK}/lib/rexruntimerd.lib")

add_library(rex::gpu-xenos SHARED IMPORTED GLOBAL)
set_target_properties(rex::gpu-xenos PROPERTIES
    IMPORTED_CONFIGURATIONS RELWITHDEBINFO
    IMPORTED_LOCATION_RELWITHDEBINFO "${PATCHED_SDK}/bin/rexgpu-xenosrd.dll"
    IMPORTED_IMPLIB_RELWITHDEBINFO "${PATCHED_SDK}/lib/rexgpu-xenosrd.lib")

add_executable(cod3_pc host_stub.cpp)
add_library(cod3_pc_recomp OBJECT EXCLUDE_FROM_ALL object_stub.cpp)
add_custom_target(cod3_pc_codegen)
target_link_libraries(cod3_pc PRIVATE rex::runtime)
target_link_libraries(cod3_pc_recomp PRIVATE rex::runtime)

foreach(_module IN ITEMS
    blkbrn chambois credits crssrds falaise forest fuelplnt hostage island
    laison mace2 mayenne nightd saint_lo stbert)
    add_library(cod3_pc_${_module} SHARED EXCLUDE_FROM_ALL module_stub.cpp)
    target_link_libraries(cod3_pc_${_module} PRIVATE rex::runtime)
endforeach()

# These targets model the live native integrations attached by the project.
# Their source files are deliberately the same inert fixture and do not execute
# any guest code.
add_library(cod3_coroutines STATIC EXCLUDE_FROM_ALL integration_stub.cpp)
add_library(cod3_xenon_thunks OBJECT EXCLUDE_FROM_ALL integration_stub.cpp)
add_library(cod3_timing_observer STATIC EXCLUDE_FROM_ALL integration_stub.cpp)
add_library(cod3_timing_hooks OBJECT EXCLUDE_FROM_ALL integration_stub.cpp)
target_link_libraries(cod3_coroutines PRIVATE rex::runtime)
target_link_libraries(cod3_timing_observer PRIVATE rex::runtime)
target_link_libraries(cod3_pc PRIVATE cod3_coroutines cod3_timing_observer cod3_xenon_thunks)
target_sources(cod3_pc PRIVATE $<TARGET_OBJECTS:cod3_timing_hooks>)

set(_extra_contract_targets)
if(COD3_CONTRACT_ADD_XENIA)
    add_library(xenia_jit STATIC EXCLUDE_FROM_ALL integration_stub.cpp)
    list(APPEND _extra_contract_targets xenia_jit)
endif()

set(_adapted_cmake "${CMAKE_CURRENT_BINARY_DIR}/rexglue-project.cmake")
file(WRITE "${_adapted_cmake}"
    "# fixture adapted SDK CMake\\n"
    "COMMAND pwsh -File cmake/Invoke-Codegen.ps1\\n")

include("${WORKSPACE_ROOT}/integration/build-system/Cod3NativeBuildIntegration.cmake")
cod3_native_integrate(
    HOST_TARGET cod3_pc
    ENTRYPOINT_OBJECT_TARGET cod3_pc_recomp
    CODEGEN_TARGET cod3_pc_codegen
    RUNTIME_CONFIGURATION RelWithDebInfo
    RUNTIME_DLL "${PATCHED_SDK}/bin/rexruntimerd.dll"
    RUNTIME_IMPLIB "${PATCHED_SDK}/lib/rexruntimerd.lib"
    RUNTIME_PDB "${PATCHED_SDK}/bin/rexruntimerd.pdb"
    CODEGEN_PROJECT_FILE "${_adapted_cmake}"
    CODEGEN_ADAPTER "${WORKSPACE_ROOT}/cod3-pc/cmake/Invoke-Codegen.ps1"
    SDK_GENERATED_CMAKE "${WORKSPACE_ROOT}/cod3-pc/generated/rexglue.cmake"
    GENERATED_ROOT "${COD3_GENERATED}"
    MODULE_CMAKE_FILE "${COD3_GENERATED}/default/dll_targets.cmake"
    MODULE_REGISTRY_FILE "${COD3_GENERATED}/default/module_registry.cpp"
    GPU_TARGET rex::gpu-xenos
    EXTRA_TARGETS ${_extra_contract_targets}
    REQUIRE_PATCHED_RUNTIME
)

add_executable(contract_smoke stub.cpp)
enable_testing()
add_test(NAME build_contract_smoke COMMAND contract_smoke)
