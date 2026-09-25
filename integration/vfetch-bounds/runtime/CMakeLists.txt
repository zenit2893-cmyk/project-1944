cmake_minimum_required(VERSION 3.25)
project(ReXGlueGpuPluginVFetchBounds LANGUAGES C CXX)

# Isolated build of the Xenos GPU plugin (rexgpu-xenos) from a staged ReXGlue
# source tree carrying the vertex-fetch bounds fix. It links against the
# installed runtime's import library, exactly like the SDK's own plugin build:
# the plugin never links the core object libraries.

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "This isolated GPU plugin build is for Windows x64.")
endif()

get_filename_component(REXGLUE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../source" ABSOLUTE)
get_filename_component(BASE_SDK "${CMAKE_CURRENT_LIST_DIR}/../../../win-amd64" ABSOLUTE)
set(PROJECT_SOURCE_DIR "${REXGLUE_ROOT}")
list(PREPEND CMAKE_PREFIX_PATH "${BASE_SDK}")

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_DEBUG_POSTFIX d)
set(CMAKE_RELWITHDEBINFO_POSTFIX rd)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_INSTALL_INCLUDEDIR include)

set(REXGLUE_USE_D3D12 ON)
set(REXGLUE_USE_VULKAN OFF)
set(REXGLUE_ENABLE_FIDELITYFX OFF)
set(REXGLUE_ENABLE_TRACY ON)
set(REXGLUE_ENABLE_PERF_COUNTERS ON)
set(REX_PLATFORM win-amd64)

# Same definitions and codegen options as the shipped RelWithDebInfo plugin.
add_compile_definitions(
    REX_PLATFORM_WINDOWS=1
    # Normally PUBLIC from rexcore/rexruntime; the imported runtime cannot carry it.
    REX_HAS_D3D12=1
    REXGLUE_BUILD_CONFIG="$<CONFIG>"
    $<$<NOT:$<CONFIG:Release>>:REXGLUE_ENABLE_PROFILING>
    $<$<NOT:$<CONFIG:Release>>:REXGLUE_ENABLE_PERF_COUNTERS>)
add_compile_options(-march=x86-64-v2 -fno-strict-aliasing -ffp-model=strict -fno-char8_t)

include("${REXGLUE_ROOT}/cmake/rex_pch.cmake")
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/include/rex")
configure_file("${BASE_SDK}/include/rex/version.h" "${CMAKE_BINARY_DIR}/include/rex/version.h"
               COPYONLY)
include_directories("${REXGLUE_ROOT}/include" "${CMAKE_BINARY_DIR}/include" "${BASE_SDK}/include")

find_package(fmt CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(SDL3 CONFIG REQUIRED)
find_package(utf8cpp CONFIG REQUIRED)
add_library(utf8cpp ALIAS utf8cpp::utf8cpp)
find_package(Threads REQUIRED)

function(import_sdk_static name basename)
    add_library(${name} STATIC IMPORTED GLOBAL)
    set_target_properties(${name} PROPERTIES
        IMPORTED_CONFIGURATIONS "Release;RelWithDebInfo;Debug"
        IMPORTED_LOCATION_RELEASE "${BASE_SDK}/lib/${basename}.lib"
        IMPORTED_LOCATION_RELWITHDEBINFO "${BASE_SDK}/lib/${basename}rd.lib"
        IMPORTED_LOCATION_DEBUG "${BASE_SDK}/lib/${basename}d.lib"
        INTERFACE_INCLUDE_DIRECTORIES "${BASE_SDK}/include")
endfunction()

import_sdk_static(xxhash xxhash)
add_library(xxHash::xxhash ALIAS xxhash)

# The runtime the plugin resolves its symbols from. The DLL used at run time is
# selected by the game launcher; only the import library matters when linking.
set(COD3_RUNTIME_DLL "${BASE_SDK}/bin/rexruntimerd.dll" CACHE FILEPATH
    "Runtime DLL the plugin is validated against")
add_library(rexruntime SHARED IMPORTED GLOBAL)
set_target_properties(rexruntime PROPERTIES
    IMPORTED_CONFIGURATIONS "Release;RelWithDebInfo;Debug"
    IMPORTED_LOCATION_RELEASE "${BASE_SDK}/bin/rexruntime.dll"
    IMPORTED_IMPLIB_RELEASE "${BASE_SDK}/lib/rexruntime.lib"
    IMPORTED_LOCATION_RELWITHDEBINFO "${COD3_RUNTIME_DLL}"
    IMPORTED_IMPLIB_RELWITHDEBINFO "${BASE_SDK}/lib/rexruntimerd.lib"
    IMPORTED_LOCATION_DEBUG "${BASE_SDK}/bin/rexruntimed.dll"
    IMPORTED_IMPLIB_DEBUG "${BASE_SDK}/lib/rexruntimed.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${BASE_SDK}/include")

foreach(name simde tomlplusplus disruptorplus renderdoc dxc-headers)

    add_library(${name} INTERFACE)
endforeach()
target_include_directories(simde INTERFACE "${BASE_SDK}/include")
target_include_directories(tomlplusplus SYSTEM INTERFACE "${BASE_SDK}/include")
target_include_directories(disruptorplus INTERFACE "${BASE_SDK}/include/disruptorplus")
target_include_directories(renderdoc INTERFACE "${BASE_SDK}/include/renderdoc")
target_include_directories(dxc-headers INTERFACE "${BASE_SDK}/include/dxc")

add_library(TracyClient SHARED IMPORTED GLOBAL)
set_target_properties(TracyClient PROPERTIES
    IMPORTED_CONFIGURATIONS "Release;RelWithDebInfo;Debug"
    IMPORTED_LOCATION_RELEASE "${BASE_SDK}/bin/TracyClient.dll"
    IMPORTED_IMPLIB_RELEASE "${BASE_SDK}/lib/TracyClient.lib"
    IMPORTED_LOCATION_RELWITHDEBINFO "${BASE_SDK}/bin/TracyClientrd.dll"
    IMPORTED_IMPLIB_RELWITHDEBINFO "${BASE_SDK}/lib/TracyClientrd.lib"
    IMPORTED_LOCATION_DEBUG "${BASE_SDK}/bin/TracyClientd.dll"
    IMPORTED_IMPLIB_DEBUG "${BASE_SDK}/lib/TracyClientd.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${BASE_SDK}/include/tracy"
    INTERFACE_SYSTEM_INCLUDE_DIRECTORIES "${BASE_SDK}/include/tracy"
    INTERFACE_COMPILE_DEFINITIONS
        "TRACY_IMPORTS;TRACY_ENABLE;TRACY_ON_DEMAND;TRACY_DELAYED_INIT;TRACY_MANUAL_LIFETIME;TRACY_FIBERS"
    INTERFACE_LINK_LIBRARIES "Threads::Threads;ws2_32;dbghelp")

# In the SDK's own build rexruntime is a real target that carries these
# interfaces; the imported one has to re-declare them for the plugin.
set_property(TARGET rexruntime APPEND PROPERTY INTERFACE_LINK_LIBRARIES
    spdlog::spdlog fmt::fmt TracyClient simde tomlplusplus disruptorplus dxc-headers)

set(IMGUI_DIR "${REXGLUE_ROOT}/thirdparty/imgui")
add_library(imgui OBJECT
    "${IMGUI_DIR}/imgui.cpp" "${IMGUI_DIR}/imgui_demo.cpp" "${IMGUI_DIR}/imgui_draw.cpp"
    "${IMGUI_DIR}/imgui_tables.cpp" "${IMGUI_DIR}/imgui_widgets.cpp")
add_library(imgui::imgui ALIAS imgui)
target_include_directories(imgui PUBLIC "${IMGUI_DIR}")
target_compile_options(imgui PRIVATE -w)

add_subdirectory("${REXGLUE_ROOT}/src/graphics" "components/graphics")
