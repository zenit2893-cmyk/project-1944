cmake_minimum_required(VERSION 3.25)
project(CoD3XeniaGraphicsPatchCompile LANGUAGES CXX)

# Compile the real patched translation unit only. No GPU runtime is linked or
# launched, and this does not replace the active SDK/plugin.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
get_filename_component(WORKSPACE "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
list(PREPEND CMAKE_PREFIX_PATH "${WORKSPACE}/win-amd64")
find_package(rexglue CONFIG REQUIRED)

add_library(graphics_patch_compile OBJECT
    overlay/src/graphics/d3d12/texture_cache.cpp)
target_include_directories(graphics_patch_compile BEFORE PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/overlay/include"
    "${WORKSPACE}/tools/rexglue-source/include"
    "${WORKSPACE}/tools/rexglue-source/src/graphics/d3d12")
target_link_libraries(graphics_patch_compile PRIVATE rex::runtime)
target_compile_definitions(graphics_patch_compile PRIVATE
    REX_PLATFORM_WINDOWS=1 REX_HAS_D3D12=1 REX_HAS_VULKAN=0
    REXGLUE_BUILD_CONFIG="Release")
target_compile_options(graphics_patch_compile PRIVATE
    -march=x86-64-v2 -fno-strict-aliasing -ffp-model=strict -fno-char8_t
    -Wno-unused-variable)
