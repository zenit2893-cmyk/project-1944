cmake_minimum_required(VERSION 3.25)
project(CoD3SpatialPresenterProbe LANGUAGES CXX)

option(REXGLUE_ENABLE_SPATIAL_UPSCALING
    "Compile the checked-in ReXGlue CAS/FSR1 presenter path" ON)

get_filename_component(WORKSPACE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(SOURCE_ROOT "${WORKSPACE_ROOT}/tools/rexglue-source")
set(SDK_ROOT "${WORKSPACE_ROOT}/win-amd64")
set(OVERLAY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/overlay")
list(PREPEND CMAKE_PREFIX_PATH "${SDK_ROOT}")
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
find_package(fmt CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(SDL3 CONFIG REQUIRED)

add_compile_definitions(NDEBUG REX_PLATFORM_WINDOWS=1 REX_HAS_D3D12=1
    REX_HAS_FIDELITYFX_SPATIAL=1 NOMINMAX WIN32_LEAN_AND_MEAN)
add_compile_options(-march=x86-64-v2 -fno-strict-aliasing -ffp-model=strict -fno-char8_t)
include_directories("${OVERLAY_ROOT}/include" "${SDK_ROOT}/include"
    "${SOURCE_ROOT}/include" "${SOURCE_ROOT}/src" "${SDK_ROOT}/include/dxc"
    "${SDK_ROOT}/include/renderdoc" "${SOURCE_ROOT}/thirdparty/imgui")

# Compile the real presenter translation units with the spatial-only feature
# definition. This target does not link a runtime, open a window, or create a GPU.
add_library(spatial_presenter_compile_check OBJECT
    "${OVERLAY_ROOT}/src/ui/presenter.cpp"
    "${OVERLAY_ROOT}/src/ui/d3d12/d3d12_presenter.cpp")
target_link_libraries(spatial_presenter_compile_check PRIVATE fmt::fmt spdlog::spdlog SDL3::SDL3)

add_executable(spatial_probe
    "${WORKSPACE_ROOT}/tests/upscaling/native_presenter_test.cpp")
target_compile_options(spatial_probe PRIVATE -UNDEBUG)
target_compile_definitions(spatial_probe PRIVATE REX_HAS_FIDELITYFX_SPATIAL=1)
enable_testing()
add_test(NAME spatial_flow_and_shader_reflection COMMAND spatial_probe)
