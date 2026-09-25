# Keep the SDK-generated integration intact while replacing its codegen command.
# COD3 mission DLLs are overlays sharing guest base 0x89000000. SDK 0.10.0.5
# cannot analyze them in a single Runtime; each --target needs its own process.
find_program(REXGLUE_POWERSHELL NAMES pwsh REQUIRED)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/generated/rexglue.cmake" _cod3_sdk_cmake)
set(_cod3_sdk_command
    "COMMAND $<TARGET_FILE:rex::rexglue> codegen \${CMAKE_CURRENT_SOURCE_DIR}/cod3_pc_manifest.toml")
set(_cod3_isolated_command
    "COMMAND \"${REXGLUE_POWERSHELL}\" -NoProfile -File \"\${CMAKE_CURRENT_SOURCE_DIR}/cmake/Invoke-Codegen.ps1\" -ReXGlue \"$<TARGET_FILE:rex::rexglue>\"")
string(FIND "${_cod3_sdk_cmake}" "${_cod3_sdk_command}" _cod3_command_position)
if(_cod3_command_position EQUAL -1)
    message(FATAL_ERROR "Unexpected ReXGlue codegen command; review the overlay-isolation adapter for this SDK version.")
endif()
string(REPLACE "${_cod3_sdk_command}" "${_cod3_isolated_command}"
    _cod3_sdk_cmake "${_cod3_sdk_cmake}")
string(REPLACE
    "    DEPFILE \"\${CMAKE_CURRENT_SOURCE_DIR}/generated/default/codegen.d\""
    "    DEPFILE \"\${CMAKE_CURRENT_SOURCE_DIR}/generated/default/codegen.d\"\n    DEPENDS \"\${CMAKE_CURRENT_SOURCE_DIR}/cmake/Invoke-Codegen.ps1\""
    _cod3_sdk_cmake "${_cod3_sdk_cmake}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/rexglue-project.cmake" "${_cod3_sdk_cmake}")
include("${CMAKE_CURRENT_BINARY_DIR}/rexglue-project.cmake")

# The release packages ship the ReXGlue SDK without bin/rexglue.exe: it
# statically links the GNU binutils PowerPC disassembler, which is GPL, so
# redistributing it would require the corresponding source of the whole
# executable. The codegen commands above reference $<TARGET_FILE:rex::rexglue>,
# which would otherwise fail at generate time with no explanation.
set(REXGLUE_EXECUTABLE "" CACHE FILEPATH "ReXGlue code-generation executable; found automatically when left empty.")

set(_cod3_rexglue_location "")
if(REXGLUE_EXECUTABLE AND EXISTS "${REXGLUE_EXECUTABLE}")
    set(_cod3_rexglue_location "${REXGLUE_EXECUTABLE}")
endif()
if(NOT _cod3_rexglue_location AND TARGET rex::rexglue)
    get_target_property(_cod3_rexglue_configs rex::rexglue IMPORTED_CONFIGURATIONS)
    if(_cod3_rexglue_configs)
        foreach(_cod3_cfg IN LISTS _cod3_rexglue_configs)
            get_target_property(_cod3_candidate rex::rexglue IMPORTED_LOCATION_${_cod3_cfg})
            if(_cod3_candidate AND EXISTS "${_cod3_candidate}")
                set(_cod3_rexglue_location "${_cod3_candidate}")
                break()
            endif()
        endforeach()
    endif()
endif()
if(NOT _cod3_rexglue_location)
    # A package ships the SDK without its Release configuration, so the export
    # that carries the executable's location is absent even when the user has
    # supplied the file itself. Pick it up from the SDK's bin directory and
    # give the imported target a location, so $<TARGET_FILE:rex::rexglue>
    # resolves exactly as it does against a complete SDK.
    get_filename_component(_cod3_sdk_prefix "${rexglue_DIR}/../../.." ABSOLUTE)
    foreach(_cod3_candidate
            "${_cod3_sdk_prefix}/bin/rexglue.exe"
            "${CMAKE_CURRENT_SOURCE_DIR}/../win-amd64/bin/rexglue.exe")
        if(EXISTS "${_cod3_candidate}")
            set(_cod3_rexglue_location "${_cod3_candidate}")
            break()
        endif()
    endforeach()
    if(_cod3_rexglue_location)
        if(NOT TARGET rex::rexglue)
            add_executable(rex::rexglue IMPORTED)
        endif()
        set_target_properties(rex::rexglue PROPERTIES IMPORTED_LOCATION "${_cod3_rexglue_location}")
    endif()
endif()
if(NOT _cod3_rexglue_location)
    message(FATAL_ERROR
        "The ReXGlue code-generation executable is missing. Build it with "
        "tools/rexglue-cli/Build-RexGlueCli.ps1, or copy rexglue.exe from your "
        "own ReXGlue SDK 0.10.0.5 installation into win-amd64/bin/, then "
        "configure again. It is not redistributed with this project; see "
        "win-amd64/SDK-PRUNING.txt and docs/legal.md for the reason.")
endif()
message(STATUS "ReXGlue codegen tool: ${_cod3_rexglue_location}")
