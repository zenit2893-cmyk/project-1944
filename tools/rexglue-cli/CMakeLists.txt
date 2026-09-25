# Standalone build of the ReXGlue code-generation CLI.
#
# The SDK's own build compiles the whole SDK; this project compiles only the
# codegen library and the CLI front end, and links them against the already
# installed SDK package (rex::runtime and friends). That keeps the build to a
# couple of minutes and needs nothing beyond the two header-only dependencies
# fetched by Get-Dependencies.ps1.
#
# The result is exactly the tool the project's packages leave out: rexglue.exe
# contains the GNU binutils PowerPC disassembler (GPL-2.0-or-later), so it is
# built on the user's own machine instead of being redistributed.

cmake_minimum_required(VERSION 3.25)
project(rexglue_cli LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT REXGLUE_SOURCE_ROOT)
    message(FATAL_ERROR "Pass -DREXGLUE_SOURCE_ROOT=<path to the ReXGlue SDK source tree>.")
endif()
get_filename_component(REXGLUE_SOURCE_ROOT "${REXGLUE_SOURCE_ROOT}" ABSOLUTE)
if(NOT EXISTS "${REXGLUE_SOURCE_ROOT}/src/codegen/codegen.cpp")
    message(FATAL_ERROR "REXGLUE_SOURCE_ROOT does not look like the SDK source tree: ${REXGLUE_SOURCE_ROOT}")
endif()

foreach(_dep
        "${REXGLUE_SOURCE_ROOT}/thirdparty/cli11/include/CLI/CLI.hpp"
        "${REXGLUE_SOURCE_ROOT}/thirdparty/inja/single_include/inja/inja.hpp"
        "${REXGLUE_SOURCE_ROOT}/thirdparty/inja/third_party/include/nlohmann/json.hpp")
    if(NOT EXISTS "${_dep}")
        message(FATAL_ERROR "Missing header-only dependency: ${_dep}\nRun tools/rexglue-cli/Get-Dependencies.ps1 first.")
    endif()
endforeach()

find_package(rexglue CONFIG REQUIRED)

# ---------------------------------------------------------------------------
# Embedded inja templates, reproduced from the SDK's own codegen build.
# ---------------------------------------------------------------------------
set(TEMPLATE_SOURCE_DIR "${REXGLUE_SOURCE_ROOT}/resources/templates")
set(TEMPLATE_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated/templates")

file(GLOB_RECURSE INJA_TEMPLATE_FILES CONFIGURE_DEPENDS "${TEMPLATE_SOURCE_DIR}/*.inja")
if(NOT INJA_TEMPLATE_FILES)
    message(FATAL_ERROR "No .inja templates found under ${TEMPLATE_SOURCE_DIR}")
endif()

set(EMBEDDED_HEADERS "")
foreach(TEMPLATE_FILE ${INJA_TEMPLATE_FILES})
    file(RELATIVE_PATH REL_PATH "${TEMPLATE_SOURCE_DIR}" "${TEMPLATE_FILE}")
    string(REGEX REPLACE "\\.inja$" "" CANONICAL_ID "${REL_PATH}")
    string(REPLACE "/" "_" VAR_NAME "${CANONICAL_ID}")
    string(REPLACE "-" "_" VAR_NAME "${VAR_NAME}")
    list(APPEND EMBEDDED_HEADERS "${TEMPLATE_OUTPUT_DIR}/${VAR_NAME}.inja.h")
endforeach()
list(APPEND EMBEDDED_HEADERS "${TEMPLATE_OUTPUT_DIR}/embedded_templates.h")

add_custom_command(
    OUTPUT ${EMBEDDED_HEADERS}
    COMMAND ${CMAKE_COMMAND}
        -DTEMPLATE_SOURCE_DIR=${TEMPLATE_SOURCE_DIR}
        -DTEMPLATE_OUTPUT_DIR=${TEMPLATE_OUTPUT_DIR}
        -P ${REXGLUE_SOURCE_ROOT}/cmake/embed_templates.cmake
    DEPENDS ${INJA_TEMPLATE_FILES} ${REXGLUE_SOURCE_ROOT}/cmake/embed_templates.cmake
    COMMENT "Embedding inja templates"
    VERBATIM
)
add_custom_target(embed_templates DEPENDS ${EMBEDDED_HEADERS})

# ---------------------------------------------------------------------------
# Sources, mirroring src/codegen/CMakeLists.txt and src/rexglue/CMakeLists.txt.
# ---------------------------------------------------------------------------
set(_codegen_dir "${REXGLUE_SOURCE_ROOT}/src/codegen")
set(CODEGEN_SOURCES
    codegen.cpp codegen_flags.cpp analyze.cpp code_emitter.cpp decoded_binary.cpp
    codegen_writer.cpp output_partition.cpp output_stamp.cpp config.cpp
    function_graph.cpp function_scanner.cpp sig_scanner.cpp vtable_scanner.cpp
    binary_view.cpp instruction_dispatch.cpp test_support.cpp codegen_context.cpp
    phase_register.cpp phase_scan.cpp phase_discover.cpp phase_gapfill.cpp
    phase_merge.cpp phase_validate.cpp template_registry.cpp manifest.cpp
    project_recompiler.cpp
    ppc/opcode.cpp ppc/instruction.cpp ppc/disasm.cpp
    builders/context.cpp builders/comparison.cpp builders/arithmetic.cpp
    builders/logical.cpp builders/control_flow.cpp builders/floating_point.cpp
    builders/memory.cpp builders/system.cpp builders/vector.cpp
)
list(TRANSFORM CODEGEN_SOURCES PREPEND "${_codegen_dir}/")

set(_cli_dir "${REXGLUE_SOURCE_ROOT}/src/rexglue")
set(CLI_SOURCES
    main.cpp ui/ui.cpp ui/progress.cpp
    commands/codegen_command.cpp commands/init_command.cpp
    commands/test_recompiler.cpp commands/project_scan.cpp
)
list(TRANSFORM CLI_SOURCES PREPEND "${_cli_dir}/")

foreach(_src ${CODEGEN_SOURCES} ${CLI_SOURCES})
    if(NOT EXISTS "${_src}")
        message(FATAL_ERROR "Source file is missing from the SDK tree: ${_src}\nThis build harness targets SDK 0.10.0.5; a different revision needs its source list refreshed.")
    endif()
endforeach()

add_executable(rexglue ${CODEGEN_SOURCES} ${CLI_SOURCES})
add_dependencies(rexglue embed_templates)
set_target_properties(rexglue PROPERTIES OUTPUT_NAME "rexglue")

target_include_directories(rexglue
    PRIVATE
        "${REXGLUE_SOURCE_ROOT}/include"
        "${REXGLUE_SOURCE_ROOT}/src"
        "${_codegen_dir}"
        "${_codegen_dir}/builders"
        "${_cli_dir}"
        "${REXGLUE_SOURCE_ROOT}/thirdparty/disasm"
        "${REXGLUE_SOURCE_ROOT}/thirdparty/cli11/include"
        "${REXGLUE_SOURCE_ROOT}/thirdparty/inja/single_include"
        "${REXGLUE_SOURCE_ROOT}/thirdparty/inja/third_party/include"
        "${TEMPLATE_OUTPUT_DIR}"
)

# rex::runtime carries the SDK's own compile definitions and include tree, so
# the codegen sources see exactly what they see in the SDK build.
target_link_libraries(rexglue
    PRIVATE
        rex::runtime
        fmt::fmt
        spdlog::spdlog
        rex::tomlplusplus
        rex::disasm
        rex::xxhash
        rex::simde
)

if(MSVC)
    target_compile_options(rexglue PRIVATE /bigobj /EHsc /utf-8 /wd4267 /wd4244)
    target_compile_definitions(rexglue PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

install(TARGETS rexglue RUNTIME DESTINATION bin)
