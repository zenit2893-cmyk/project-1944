# cod3_pc - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(cod3_pc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(REXSDK_VERSION "0.10.0.5" CACHE STRING "ReXGlue SDK package version")
include(cmake/ReXGlueProject.cmake)

# Sources
set(COD3PC_SOURCES
    src/main.cpp
)

if(WIN32)
    add_executable(cod3_pc WIN32 ${COD3PC_SOURCES})
else()
    add_executable(cod3_pc ${COD3PC_SOURCES})
endif()

rexglue_setup_target(cod3_pc GPU_PLUGINS xenos)

# timeBeginPeriod for the 1 ms host timer used by guest vblank/sleep pacing.
if(WIN32)
    target_link_libraries(cod3_pc PRIVATE winmm)
endif()

# Only these two opcode-verified XenonRecomp thunks share the SDK ABI through
# an explicitly tested adapter. Remaining guest functions use ReXGlue codegen.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/xenon" xenon)
cod3_enable_xenon_thunk_overrides(cod3_pc)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/timing" timing)
cod3_enable_timing_hooks(cod3_pc)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/coroutines" coroutines)
cod3_enable_coroutines(cod3_pc "${CMAKE_CURRENT_SOURCE_DIR}/generated/default")

# Keyboard/mouse layer: shooter key mapping merged into the pad state, and
# mouse look written straight into the view angles (PC Call of Duty feel).
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/pc-controls" pc-controls)
cod3_enable_pc_controls(cod3_pc)

option(COD3_SAINTLO_DIAGNOSTICS "Observe the Saint-Lo register restoration failure" OFF)
if(COD3_SAINTLO_DIAGNOSTICS)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/saintlo-diagnostics" saintlo-diagnostics)
    cod3_enable_saintlo_diagnostics(cod3_pc_saint_lo)
endif()

# Replacement Xenos GPU plugin (integration/vfetch-bounds). rexglue_setup_target
# stages the stock plugin next to the executable, so this copy must run after it.
set(COD3_GPU_PLUGIN "" CACHE FILEPATH "Replacement rexgpu-xenos plugin built from patched SDK source")
if(COD3_GPU_PLUGIN)
    if(NOT EXISTS "${COD3_GPU_PLUGIN}")
        message(FATAL_ERROR "COD3_GPU_PLUGIN does not exist: ${COD3_GPU_PLUGIN}")
    endif()
    add_custom_command(TARGET cod3_pc POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${COD3_GPU_PLUGIN}" "$<TARGET_FILE_DIR:cod3_pc>/rexgpu-xenosrd.dll"
        COMMENT "Staging patched Xenos GPU plugin")
endif()

set(COD3_RUNTIME_DLL "" CACHE FILEPATH "Verified replacement ReXGlue runtime, ABI-compatible with the installed SDK")
if(COD3_RUNTIME_DLL)
    if(NOT CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo" OR NOT EXISTS "${COD3_RUNTIME_DLL}")
        message(FATAL_ERROR "The replacement runtime must exist and match RelWithDebInfo")
    endif()
    set_property(TARGET rex::runtime PROPERTY IMPORTED_LOCATION_RELWITHDEBINFO "${COD3_RUNTIME_DLL}")
    set_property(TARGET cod3_pc APPEND PROPERTY LINK_DEPENDS "${COD3_RUNTIME_DLL}")
endif()

# The prebuilt SDK's exported targets do not carry its source-tree global FP
# and aliasing flags. Generated guest code relies on dynamic FP modes and
# modulo signed-register arithmetic, so make this contract explicit here.
get_property(_cod3_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
foreach(_cod3_target IN LISTS _cod3_targets)
    get_target_property(_cod3_type "${_cod3_target}" TYPE)
    if(_cod3_target MATCHES "^cod3_pc($|_)" AND NOT _cod3_type STREQUAL "UTILITY")
        target_compile_options("${_cod3_target}" PRIVATE
            -ffp-model=strict -fno-strict-aliasing -fwrapv)
    endif()
endforeach()
