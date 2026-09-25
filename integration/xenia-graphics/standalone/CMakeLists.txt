cmake_minimum_required(VERSION 3.25)
project(CoD3XeniaPatchedGpuPlugin LANGUAGES CXX)

# This project builds only a replacement GPU plugin. The runtime and all
# third-party libraries are imported from the verified SDK prefix; the full
# ReXGlue SDK is not added as a subdirectory and is not rebuilt here.
if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The standalone plugin build requires Windows x64")
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_DEBUG_POSTFIX d)
set(CMAKE_RELWITHDEBINFO_POSTFIX rd)

get_filename_component(WORKSPACE "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(REX_SOURCE "${WORKSPACE}/tools/rexglue-source")
set(SDK_ROOT "${WORKSPACE}/win-amd64")
set(OVERLAY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../overlay")
list(PREPEND CMAKE_PREFIX_PATH "${SDK_ROOT}")
find_package(rexglue CONFIG REQUIRED)

set(REX_GRAPHICS_ROOT "${REX_SOURCE}/src/graphics")

# Keep this list synchronized with tools/rexglue-source/src/graphics/CMakeLists.txt.
# The one source replaced by the overlay is listed explicitly below so an
# accidental source-tree edit cannot silently change the patch boundary.
set(REXGPU_XENOS_SOURCES
  "${REX_GRAPHICS_ROOT}/plugin_main.cpp"
  "${REX_GRAPHICS_ROOT}/flags.cpp"
  "${REX_GRAPHICS_ROOT}/register_file.cpp"
  "${REX_GRAPHICS_ROOT}/registers.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/shader.cpp"
  "${REX_GRAPHICS_ROOT}/format/ucode.cpp"
  "${REX_GRAPHICS_ROOT}/sampler_info.cpp"
  "${REX_GRAPHICS_ROOT}/graphics_system.cpp"
  "${REX_GRAPHICS_ROOT}/command_processor.cpp"
  "${REX_GRAPHICS_ROOT}/util/draw_extent_estimator.cpp"
  "${REX_GRAPHICS_ROOT}/util/draw.cpp"
  "${REX_GRAPHICS_ROOT}/packet_disassembler.cpp"
  "${REX_GRAPHICS_ROOT}/primitive_processor.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/render_target/cache.cpp"
  "${REX_GRAPHICS_ROOT}/shared_memory.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/texture/cache.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/interpreter.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/translator.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/translator_disasm.cpp"
  "${REX_SOURCE}/thirdparty/dxbc/DXBCChecksum.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/dxbc.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/dxbc_translator.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/dxbc_translator_alu.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/dxbc_translator_fetch.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/dxbc_translator_memexport.cpp"
  "${REX_GRAPHICS_ROOT}/pipeline/shader/dxbc_translator_om.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/graphics_system.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/command_processor.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/primitive_processor.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/render_target_cache.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/shader.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/shared_memory.cpp"
  "${OVERLAY_ROOT}/src/graphics/d3d12/texture_cache.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/deferred_command_list.cpp"
  "${REX_GRAPHICS_ROOT}/d3d12/pipeline_cache.cpp"
)

add_library(rexgpu-xenos-patched SHARED ${REXGPU_XENOS_SOURCES})
set_target_properties(rexgpu-xenos-patched PROPERTIES
  OUTPUT_NAME "rexgpu-xenos"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)
target_include_directories(rexgpu-xenos-patched BEFORE PRIVATE
  "${OVERLAY_ROOT}/include"
  "${REX_SOURCE}/include"
  "${REX_GRAPHICS_ROOT}/d3d12"
  "${REX_SOURCE}/thirdparty/renderdoc"
  "${REX_SOURCE}"
)
target_compile_definitions(rexgpu-xenos-patched PRIVATE
  REX_PLATFORM_WINDOWS=1
  REX_HAS_D3D12=1
  REX_HAS_VULKAN=0
  REXGLUE_BUILD_CONFIG="$<CONFIG>"
)
target_compile_options(rexgpu-xenos-patched PRIVATE
  -march=x86-64-v2
  -fno-strict-aliasing
  -ffp-model=strict
  -fno-char8_t
  -Wno-unused-variable
)
target_link_libraries(rexgpu-xenos-patched PRIVATE
  rex::runtime
  rex::xxhash
  d3d12
  dxgi
  dxguid
)

add_executable(xenia_graphics_abi_probe native_abi_probe.cpp)
set_target_properties(xenia_graphics_abi_probe PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
target_compile_options(xenia_graphics_abi_probe PRIVATE
  -fno-char8_t
)
target_link_libraries(xenia_graphics_abi_probe PRIVATE kernel32)
