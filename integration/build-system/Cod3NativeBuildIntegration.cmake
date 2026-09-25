# COD3 native build contract for the ReXGlue generated project.
#
# This file is intentionally an include, rather than a replacement for the
# generated SDK CMake.  Include it after rexglue_setup_target() and after the
# Xenon, coroutine, and timing subdirectories have been added:
#
#   include("${CMAKE_CURRENT_SOURCE_DIR}/../integration/build-system/Cod3NativeBuildIntegration.cmake")
#   cod3_native_integrate(HOST_TARGET cod3_pc REQUIRE_PATCHED_RUNTIME)
#
# The contract is deliberately Windows/Clang/x64-only.  It keeps the generated
# guest code and the native bridges under the same signed-arithmetic and strict
# floating-point rules, selects a configuration-matching runtime import pair,
# and verifies that the 15 address-overlay DLLs are present.  It does not link
# Xenia, start an emulator, or change the guest clock.

include_guard(GLOBAL)

set(_COD3_NATIVE_BUILD_SYSTEM_DIR "${CMAKE_CURRENT_LIST_DIR}")

set(COD3_NATIVE_DEFAULT_MODULES
    blkbrn
    chambois
    credits
    crssrds
    falaise
    forest
    fuelplnt
    hostage
    island
    laison
    mace2
    mayenne
    nightd
    saint_lo
    stbert
)

function(_cod3_native_error message_text)
    message(FATAL_ERROR "cod3_native_integrate: ${message_text}")
endfunction()

function(_cod3_native_strict_options out_var)
    # The active COD3 toolchain is Clang's GNU frontend.  Keep this list in one
    # place so generated main code, generated DLLs, and bridge objects cannot
    # silently drift apart.
    if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
        _cod3_native_error(
            "the native port requires Clang; got '${CMAKE_CXX_COMPILER_ID}'")
    endif()
    set(${out_var}
        -ffp-model=strict
        -fno-strict-aliasing
        -fwrapv
        PARENT_SCOPE)
endfunction()

function(_cod3_native_apply_strict target_name)
    if(NOT TARGET "${target_name}")
        _cod3_native_error("required target '${target_name}' does not exist")
    endif()

    get_target_property(_type "${target_name}" TYPE)
    if(_type STREQUAL "INTERFACE_LIBRARY" OR _type STREQUAL "UTILITY")
        return()
    endif()
    if(_type STREQUAL "UNKNOWN_LIBRARY")
        _cod3_native_error("target '${target_name}' has an unsupported type")
    endif()

    _cod3_native_strict_options(_options)
    target_compile_options("${target_name}" PRIVATE ${_options})
endfunction()

function(_cod3_native_reject_xenia target_name)
    if(NOT TARGET "${target_name}")
        return()
    endif()

    # Inspect target metadata rather than the whole workspace.  The project may
    # retain Xenia source and license files for provenance, but no executable,
    # JIT, Xenia runtime, or Xenia source target may enter the native link
    # graph.
    set(_properties
        SOURCES
        LINK_LIBRARIES
        INTERFACE_LINK_LIBRARIES
        INCLUDE_DIRECTORIES
        INTERFACE_INCLUDE_DIRECTORIES
        INTERFACE_SYSTEM_INCLUDE_DIRECTORIES
        IMPORTED_LOCATION
        IMPORTED_LOCATION_RELEASE
        IMPORTED_LOCATION_RELWITHDEBINFO
        IMPORTED_LOCATION_DEBUG
        IMPORTED_IMPLIB
        IMPORTED_IMPLIB_RELEASE
        IMPORTED_IMPLIB_RELWITHDEBINFO
        IMPORTED_IMPLIB_DEBUG
    )
    foreach(_property IN LISTS _properties)
        get_target_property(_values "${target_name}" "${_property}")
        if(_values STREQUAL "_values-NOTFOUND")
            continue()
        endif()
        foreach(_value IN LISTS _values)
            string(TOLOWER "${_value}" _lower_value)
            if(_lower_value MATCHES "xenia[^;]*(jit|\.exe|runtime)")
                _cod3_native_error(
                    "target '${target_name}' references an Xenia JIT/runtime executable: ${_value}")
            elseif(_lower_value MATCHES "xenia")
                _cod3_native_error(
                    "target '${target_name}' references Xenia through ${_property}: ${_value}")
            endif()
        endforeach()
    endforeach()

    string(TOLOWER "${target_name}" _lower_name)
    if(_lower_name MATCHES "xenia")
        _cod3_native_error("target '${target_name}' is an Xenia target")
    endif()
endfunction()

function(_cod3_native_config_contract configuration out_runtime out_gpu out_suffix)
    if(configuration STREQUAL "Release")
        set(_runtime "rexruntime.dll")
        set(_gpu "rexgpu-xenos.dll")
        set(_suffix "")
    elseif(configuration STREQUAL "RelWithDebInfo")
        set(_runtime "rexruntimerd.dll")
        set(_gpu "rexgpu-xenosrd.dll")
        set(_suffix "rd")
    elseif(configuration STREQUAL "Debug")
        set(_runtime "rexruntimed.dll")
        set(_gpu "rexgpu-xenosd.dll")
        set(_suffix "d")
    else()
        _cod3_native_error(
            "unsupported configuration '${configuration}'; use Release, RelWithDebInfo, or Debug")
    endif()
    set(${out_runtime} "${_runtime}" PARENT_SCOPE)
    set(${out_gpu} "${_gpu}" PARENT_SCOPE)
    set(${out_suffix} "${_suffix}" PARENT_SCOPE)
endfunction()

function(_cod3_native_imported_path target_name property_suffix out_var)
    if(NOT TARGET "${target_name}")
        set(${out_var} "" PARENT_SCOPE)
        return()
    endif()
    get_target_property(_path "${target_name}" "IMPORTED_LOCATION_${property_suffix}")
    if(_path STREQUAL "_path-NOTFOUND" OR NOT _path)
        get_target_property(_path "${target_name}" IMPORTED_LOCATION)
    endif()
    if(_path STREQUAL "_path-NOTFOUND")
        set(_path "")
    endif()
    set(${out_var} "${_path}" PARENT_SCOPE)
endfunction()

function(_cod3_native_validate_imported_runtime target_name configuration runtime_path
        runtime_implib expected_runtime)
    if(NOT TARGET "${target_name}")
        _cod3_native_error("runtime target '${target_name}' does not exist")
    endif()
    string(TOUPPER "${configuration}" _config_id)

    if(runtime_path)
        set_property(TARGET "${target_name}" APPEND PROPERTY
            IMPORTED_CONFIGURATIONS "${_config_id}")
        set_property(TARGET "${target_name}" PROPERTY
            "IMPORTED_LOCATION_${_config_id}" "${runtime_path}")
        set_property(TARGET "${target_name}" PROPERTY
            "IMPORTED_IMPLIB_${_config_id}" "${runtime_implib}")
    endif()

    _cod3_native_imported_path("${target_name}" "${_config_id}" _selected_dll)
    get_target_property(_selected_lib "${target_name}" "IMPORTED_IMPLIB_${_config_id}")
    if(_selected_lib STREQUAL "_selected_lib-NOTFOUND")
        set(_selected_lib "")
    endif()

    if(NOT _selected_dll OR NOT EXISTS "${_selected_dll}")
        _cod3_native_error(
            "${target_name} has no existing ${configuration} runtime DLL")
    endif()
    if(NOT _selected_lib OR NOT EXISTS "${_selected_lib}")
        _cod3_native_error(
            "${target_name} has no existing ${configuration} import library")
    endif()

    get_filename_component(_selected_dll_name "${_selected_dll}" NAME)
    get_filename_component(_selected_lib_name "${_selected_lib}" NAME)
    string(TOLOWER "${_selected_dll_name}" _selected_dll_lower)
    string(TOLOWER "${_selected_lib_name}" _selected_lib_lower)
    string(TOLOWER "${expected_runtime}" _expected_dll_lower)
    string(REGEX REPLACE "\\.dll$" ".lib" _expected_lib_lower "${_expected_dll_lower}")
    if(NOT _selected_dll_lower STREQUAL _expected_dll_lower)
        _cod3_native_error(
            "${configuration} runtime DLL is '${_selected_dll_name}', expected '${expected_runtime}'")
    endif()
    if(NOT _selected_lib_lower STREQUAL _expected_lib_lower)
        _cod3_native_error(
            "${configuration} import library is '${_selected_lib_name}', expected '${_expected_lib_lower}'")
    endif()

    set(COD3_NATIVE_SELECTED_RUNTIME_DLL "${_selected_dll}" PARENT_SCOPE)
    set(COD3_NATIVE_SELECTED_RUNTIME_IMPLIB "${_selected_lib}" PARENT_SCOPE)
endfunction()

function(_cod3_native_validate_gpu_target gpu_target configuration expected_gpu)
    if(NOT TARGET "${gpu_target}")
        _cod3_native_error("GPU plugin target '${gpu_target}' does not exist")
    endif()
    get_target_property(_imported "${gpu_target}" IMPORTED)
    if(_imported)
        string(TOUPPER "${configuration}" _config_id)
        _cod3_native_imported_path("${gpu_target}" "${_config_id}" _gpu_path)
        if(NOT _gpu_path OR NOT EXISTS "${_gpu_path}")
            _cod3_native_error(
                "GPU plugin '${gpu_target}' has no existing ${configuration} binary")
        endif()
        get_filename_component(_gpu_name "${_gpu_path}" NAME)
        string(TOLOWER "${_gpu_name}" _gpu_lower)
        string(TOLOWER "${expected_gpu}" _expected_lower)
        if(NOT _gpu_lower STREQUAL _expected_lower)
            _cod3_native_error(
                "${configuration} GPU plugin is '${_gpu_name}', expected '${expected_gpu}'")
        endif()
    endif()
endfunction()

function(_cod3_native_validate_codegen project_file adapter_path sdk_cmake_path
        generated_root modules module_cmake registry require_generated)
    if(adapter_path AND NOT EXISTS "${adapter_path}")
        _cod3_native_error("codegen adapter is missing: ${adapter_path}")
    endif()
    if(adapter_path)
        file(READ "${adapter_path}" _adapter_text)
        string(TOLOWER "${_adapter_text}" _adapter_lower)
        if(NOT _adapter_lower MATCHES "invoke-codegen\\.ps1")
            _cod3_native_error(
                "the codegen adapter does not invoke the isolated PowerShell helper")
        endif()
        if(_adapter_lower MATCHES "command[ \t\r\n]+\\$<target_file:rex::rexglue>[ \t\r\n]+codegen")
            _cod3_native_error(
                "the active codegen adapter still contains the stock all-modules command")
        endif()
    endif()

    if(project_file AND EXISTS "${project_file}")
        file(READ "${project_file}" _project_text)
        string(TOLOWER "${_project_text}" _project_lower)
        if(NOT _project_lower MATCHES "invoke-codegen\\.ps1")
            _cod3_native_error(
                "the configured ReXGlue CMake does not use Invoke-Codegen.ps1")
        endif()
        string(FIND "${_project_lower}"
            "command $<target_file:rex::rexglue> codegen" _direct_command)
        if(NOT _direct_command EQUAL -1)
            _cod3_native_error(
                "the configured ReXGlue CMake still contains the stock direct codegen command")
        endif()
    elseif(require_generated)
        _cod3_native_error("configured adapted ReXGlue CMake is missing: ${project_file}")
    endif()

    if(sdk_cmake_path AND EXISTS "${sdk_cmake_path}")
        file(READ "${sdk_cmake_path}" _sdk_text)
        string(TOLOWER "${_sdk_text}" _sdk_lower)
        if(_sdk_lower MATCHES "invoke-codegen\\.ps1")
            _cod3_native_error(
                "generated/rexglue.cmake appears edited; keep the SDK file stock and adapt it in the build directory")
        endif()
    elseif(require_generated)
        _cod3_native_error("stock SDK generated CMake is missing: ${sdk_cmake_path}")
    endif()

    if(NOT require_generated)
        return()
    endif()
    foreach(_required_file IN ITEMS
        "${generated_root}/default/sources.cmake"
        "${module_cmake}"
        "${registry}")
        if(NOT EXISTS "${_required_file}")
            _cod3_native_error("generated build input is missing: ${_required_file}")
        endif()
    endforeach()

    file(READ "${module_cmake}" _module_cmake_text)
    file(READ "${registry}" _registry_text)
    foreach(_module IN LISTS modules)
        set(_target "cod3_pc_${_module}")
        string(FIND "${_module_cmake_text}" "add_library(${_target} SHARED" _target_pos)
        if(_target_pos EQUAL -1)
            _cod3_native_error(
                "generated DLL CMake does not define the expected shared target '${_target}'")
        endif()
        string(FIND "${_registry_text}" "cod3_pc_${_module}" _registry_target_pos)
        string(FIND "${_registry_text}" "sp/${_module}/${_module}.dll" _registry_path_pos)
        if(_registry_target_pos EQUAL -1 OR _registry_path_pos EQUAL -1)
            _cod3_native_error(
                "module registry is incomplete for '${_module}'")
        endif()
    endforeach()
endfunction()

function(_cod3_native_validate_modules host_target codegen_target modules)
    set(_expected_targets)
    foreach(_module IN LISTS modules)
        set(_target "cod3_pc_${_module}")
        list(APPEND _expected_targets "${_target}")
        if(NOT TARGET "${_target}")
            _cod3_native_error("missing generated mission target '${_target}'")
        endif()
        get_target_property(_type "${_target}" TYPE)
        if(NOT _type STREQUAL "SHARED_LIBRARY")
            _cod3_native_error(
                "mission target '${_target}' must be SHARED_LIBRARY, got '${_type}'")
        endif()
        get_target_property(_links "${_target}" LINK_LIBRARIES)
        if(_links STREQUAL "_links-NOTFOUND" OR NOT _links MATCHES "(^|;)rex::runtime(;|$)")
            _cod3_native_error("mission target '${_target}' is not linked to rex::runtime")
        endif()
        if(TARGET "${codegen_target}")
            add_dependencies("${_target}" "${codegen_target}")
        endif()
    endforeach()

    # A generated project must expose exactly the 15 single-player overlays.
    # Ignore the host's object library and codegen utility when collecting the
    # cod3_pc_* names from this directory.
    get_property(_directory_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
    set(_actual_targets)
    foreach(_target IN LISTS _directory_targets)
        if(_target MATCHES "^cod3_pc_[A-Za-z0-9_]+$")
            if(NOT _target STREQUAL "${host_target}_recomp"
                AND NOT _target STREQUAL "${codegen_target}")
                list(APPEND _actual_targets "${_target}")
            endif()
        endif()
    endforeach()
    list(SORT _expected_targets)
    list(SORT _actual_targets)
    if(NOT _actual_targets STREQUAL _expected_targets)
        _cod3_native_error(
            "generated mission target set differs; expected '${_expected_targets}', got '${_actual_targets}'")
    endif()
endfunction()

function(_cod3_native_validate_integrations host_target entrypoint_target
        codegen_target extra_targets require_integrations)
    set(_known_integration_targets
        cod3_coroutines
        cod3_xenon_thunks
        cod3_timing_observer
        cod3_timing_hooks)
    if(extra_targets)
        list(APPEND _known_integration_targets ${extra_targets})
    endif()

    foreach(_target IN LISTS _known_integration_targets)
        if(TARGET "${_target}")
            _cod3_native_apply_strict("${_target}")
            _cod3_native_reject_xenia("${_target}")
            if(_target MATCHES "^(cod3_coroutines|cod3_timing_observer|cod3_xenon_thunks)$")
                add_dependencies("${host_target}" "${_target}")
            endif()
        elseif(require_integrations)
            _cod3_native_error("required native integration target '${_target}' is missing")
        endif()
    endforeach()

    # The bridge objects are expected to reach the host through the integration
    # helpers.  These dependencies are harmless when already present and make a
    # top-level host build deterministic.
    if(TARGET cod3_timing_hooks)
        add_dependencies("${host_target}" cod3_timing_hooks)
    endif()
    if(TARGET "${entrypoint_target}" AND TARGET cod3_coroutines)
        add_dependencies("${entrypoint_target}" cod3_coroutines)
    endif()
    if(TARGET "${codegen_target}")
        add_dependencies("${host_target}" "${codegen_target}")
    endif()
endfunction()

function(_cod3_native_stage_runtime host_target configuration runtime_dll runtime_pdb
        gpu_target)
    if(NOT WIN32)
        return()
    endif()
    if(runtime_dll)
        get_filename_component(_runtime_name "${runtime_dll}" NAME)
        add_custom_command(TARGET "${host_target}" POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${runtime_dll}"
                "$<TARGET_FILE_DIR:${host_target}>/${_runtime_name}"
            VERBATIM)
        if(runtime_pdb AND EXISTS "${runtime_pdb}")
            get_filename_component(_pdb_name "${runtime_pdb}" NAME)
            add_custom_command(TARGET "${host_target}" POST_BUILD
                COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "${runtime_pdb}"
                    "$<TARGET_FILE_DIR:${host_target}>/${_pdb_name}"
                VERBATIM)
        endif()
    endif()

    # rexglue_configure_target() also stages GPU plugins.  This explicit copy
    # keeps the contract self-contained when the include is reused by a small
    # host project and still resolves the selected configuration's imported
    # binary through TARGET_FILE.
    if(gpu_target AND TARGET "${gpu_target}")
        get_target_property(_gpu_imported "${gpu_target}" IMPORTED)
        if(NOT _gpu_imported)
            add_dependencies("${host_target}" "${gpu_target}")
        endif()
        add_custom_command(TARGET "${host_target}" POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "$<TARGET_FILE:${gpu_target}>"
                "$<TARGET_FILE_DIR:${host_target}>"
            VERBATIM)
    endif()
endfunction()

function(cod3_native_integrate)
    cmake_parse_arguments(ARG
        "REQUIRE_PATCHED_RUNTIME;SKIP_GENERATED_CHECK;SKIP_INTEGRATION_CHECK"
        "HOST_TARGET;ENTRYPOINT_OBJECT_TARGET;CODEGEN_TARGET;RUNTIME_CONFIGURATION;RUNTIME_DLL;RUNTIME_IMPLIB;RUNTIME_PDB;CODEGEN_PROJECT_FILE;CODEGEN_ADAPTER;SDK_GENERATED_CMAKE;GENERATED_ROOT;MODULE_CMAKE_FILE;MODULE_REGISTRY_FILE;GPU_TARGET;UPSCALING_TARGET"
        "MODULES;EXTRA_TARGETS"
        ${ARGN})

    if(ARG_UNPARSED_ARGUMENTS)
        _cod3_native_error("unparsed arguments: ${ARG_UNPARSED_ARGUMENTS}")
    endif()
    if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
        _cod3_native_error("the native COD3 port requires Windows x64")
    endif()
    _cod3_native_strict_options(_unused_options)

    if(NOT ARG_HOST_TARGET)
        set(ARG_HOST_TARGET cod3_pc)
    endif()
    if(NOT ARG_ENTRYPOINT_OBJECT_TARGET)
        set(ARG_ENTRYPOINT_OBJECT_TARGET "${ARG_HOST_TARGET}_recomp")
    endif()
    if(NOT ARG_CODEGEN_TARGET)
        set(ARG_CODEGEN_TARGET "${ARG_HOST_TARGET}_codegen")
    endif()
    if(NOT ARG_RUNTIME_CONFIGURATION)
        if(CMAKE_BUILD_TYPE)
            set(ARG_RUNTIME_CONFIGURATION "${CMAKE_BUILD_TYPE}")
        else()
            set(ARG_RUNTIME_CONFIGURATION RelWithDebInfo)
        endif()
    endif()
    if(NOT ARG_MODULES)
        set(ARG_MODULES ${COD3_NATIVE_DEFAULT_MODULES})
    endif()
    if(NOT ARG_GENERATED_ROOT)
        set(ARG_GENERATED_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/generated")
    endif()
    if(NOT ARG_MODULE_CMAKE_FILE)
        set(ARG_MODULE_CMAKE_FILE "${ARG_GENERATED_ROOT}/default/dll_targets.cmake")
    endif()
    if(NOT ARG_MODULE_REGISTRY_FILE)
        set(ARG_MODULE_REGISTRY_FILE "${ARG_GENERATED_ROOT}/default/module_registry.cpp")
    endif()
    if(NOT ARG_SDK_GENERATED_CMAKE)
        set(ARG_SDK_GENERATED_CMAKE "${CMAKE_CURRENT_SOURCE_DIR}/generated/rexglue.cmake")
    endif()
    if(NOT ARG_CODEGEN_ADAPTER)
        set(ARG_CODEGEN_ADAPTER "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Invoke-Codegen.ps1")
    endif()
    if(NOT ARG_CODEGEN_PROJECT_FILE)
        set(ARG_CODEGEN_PROJECT_FILE "${CMAKE_CURRENT_BINARY_DIR}/rexglue-project.cmake")
    endif()

    if(NOT TARGET "${ARG_HOST_TARGET}")
        _cod3_native_error("host target '${ARG_HOST_TARGET}' does not exist")
    endif()
    if(NOT TARGET "${ARG_ENTRYPOINT_OBJECT_TARGET}")
        _cod3_native_error(
            "entrypoint object target '${ARG_ENTRYPOINT_OBJECT_TARGET}' does not exist")
    endif()
    if(NOT TARGET "${ARG_CODEGEN_TARGET}")
        _cod3_native_error("codegen target '${ARG_CODEGEN_TARGET}' does not exist")
    endif()
    if(NOT TARGET rex::runtime)
        _cod3_native_error("ReXGlue target rex::runtime does not exist")
    endif()

    # A single-config build is required for this native contract.  This avoids
    # silently selecting a Debug or Release import library alongside a runtime
    # selected at configure time.
    if(CMAKE_CONFIGURATION_TYPES)
        _cod3_native_error(
            "the native COD3 contract requires a single-config generator; got '${CMAKE_CONFIGURATION_TYPES}'")
    endif()
    if(NOT CMAKE_BUILD_TYPE)
        _cod3_native_error(
            "set CMAKE_BUILD_TYPE to the runtime contract configuration")
    endif()
    if(CMAKE_BUILD_TYPE AND NOT CMAKE_BUILD_TYPE STREQUAL ARG_RUNTIME_CONFIGURATION)
        _cod3_native_error(
            "runtime contract selects ${ARG_RUNTIME_CONFIGURATION}, but CMAKE_BUILD_TYPE is '${CMAKE_BUILD_TYPE}'")
    endif()
    _cod3_native_config_contract("${ARG_RUNTIME_CONFIGURATION}"
        _expected_runtime _expected_gpu _config_suffix)

    set(_runtime_dll "${ARG_RUNTIME_DLL}")
    if(NOT _runtime_dll AND DEFINED COD3_RUNTIME_DLL AND COD3_RUNTIME_DLL)
        set(_runtime_dll "${COD3_RUNTIME_DLL}")
    endif()
    set(_runtime_implib "${ARG_RUNTIME_IMPLIB}")
    set(_runtime_pdb "${ARG_RUNTIME_PDB}")

    if(_runtime_dll)
        if(NOT EXISTS "${_runtime_dll}")
            _cod3_native_error("runtime override does not exist: ${_runtime_dll}")
        endif()
        if(NOT _runtime_implib)
            get_filename_component(_runtime_dir "${_runtime_dll}" DIRECTORY)
            get_filename_component(_runtime_root "${_runtime_dir}/.." ABSOLUTE)
            get_filename_component(_runtime_stem "${_runtime_dll}" NAME_WE)
            set(_runtime_implib "${_runtime_root}/lib/${_runtime_stem}.lib")
        endif()
        if(NOT EXISTS "${_runtime_implib}")
            _cod3_native_error("runtime import library does not exist: ${_runtime_implib}")
        endif()
        if(NOT _runtime_pdb)
            get_filename_component(_runtime_dir "${_runtime_dll}" DIRECTORY)
            get_filename_component(_runtime_stem "${_runtime_dll}" NAME_WE)
            set(_candidate_pdb "${_runtime_dir}/${_runtime_stem}.pdb")
            if(EXISTS "${_candidate_pdb}")
                set(_runtime_pdb "${_candidate_pdb}")
            endif()
        endif()
    elseif(ARG_REQUIRE_PATCHED_RUNTIME OR COD3_NATIVE_REQUIRE_PATCHED_RUNTIME)
        _cod3_native_error(
            "patched runtime required but RUNTIME_DLL/COD3_RUNTIME_DLL was not supplied")
    endif()

    _cod3_native_validate_imported_runtime(rex::runtime
        "${ARG_RUNTIME_CONFIGURATION}" "${_runtime_dll}" "${_runtime_implib}"
        "${_expected_runtime}")

    if(ARG_GPU_TARGET)
        set(_gpu_target "${ARG_GPU_TARGET}")
    elseif(TARGET rex::gpu-xenos)
        set(_gpu_target rex::gpu-xenos)
    elseif(TARGET rexgpu-xenos)
        set(_gpu_target rexgpu-xenos)
    else()
        _cod3_native_error("the xenos GPU plugin target is missing")
    endif()
    _cod3_native_validate_gpu_target("${_gpu_target}"
        "${ARG_RUNTIME_CONFIGURATION}" "${_expected_gpu}")
    _cod3_native_reject_xenia("${_gpu_target}")

    set(_require_generated TRUE)
    if(ARG_SKIP_GENERATED_CHECK)
        set(_require_generated FALSE)
    endif()
    _cod3_native_validate_codegen("${ARG_CODEGEN_PROJECT_FILE}"
        "${ARG_CODEGEN_ADAPTER}" "${ARG_SDK_GENERATED_CMAKE}"
        "${ARG_GENERATED_ROOT}" "${ARG_MODULES}"
        "${ARG_MODULE_CMAKE_FILE}" "${ARG_MODULE_REGISTRY_FILE}"
        "${_require_generated}")

    _cod3_native_apply_strict("${ARG_HOST_TARGET}")
    _cod3_native_apply_strict("${ARG_ENTRYPOINT_OBJECT_TARGET}")
    _cod3_native_reject_xenia("${ARG_HOST_TARGET}")
    _cod3_native_reject_xenia("${ARG_ENTRYPOINT_OBJECT_TARGET}")
    _cod3_native_validate_modules("${ARG_HOST_TARGET}" "${ARG_CODEGEN_TARGET}"
        "${ARG_MODULES}")

    set(_extra_targets ${ARG_EXTRA_TARGETS})
    if(ARG_UPSCALING_TARGET)
        if(NOT TARGET "${ARG_UPSCALING_TARGET}")
            _cod3_native_error(
                "requested upscaling target '${ARG_UPSCALING_TARGET}' does not exist")
        endif()
        list(APPEND _extra_targets "${ARG_UPSCALING_TARGET}")
    endif()

    set(_require_integrations TRUE)
    if(ARG_SKIP_INTEGRATION_CHECK)
        set(_require_integrations FALSE)
    endif()
    _cod3_native_validate_integrations("${ARG_HOST_TARGET}"
        "${ARG_ENTRYPOINT_OBJECT_TARGET}" "${ARG_CODEGEN_TARGET}"
        "${_extra_targets}" "${_require_integrations}")

    # Keep the generated module outputs and host in one dependency graph.
    foreach(_module IN LISTS ARG_MODULES)
        add_dependencies("${ARG_HOST_TARGET}" "cod3_pc_${_module}")
        _cod3_native_apply_strict("cod3_pc_${_module}")
        _cod3_native_reject_xenia("cod3_pc_${_module}")
    endforeach()

    # `cod3_enable_*` already provides the live hooks.  This loop only makes
    # the final target graph auditable and protects against an integration
    # target being created after its helper was called.
    foreach(_target IN LISTS _extra_targets)
        if(TARGET "${_target}")
            _cod3_native_apply_strict("${_target}")
            _cod3_native_reject_xenia("${_target}")
        endif()
    endforeach()

    _cod3_native_stage_runtime("${ARG_HOST_TARGET}"
        "${ARG_RUNTIME_CONFIGURATION}" "${COD3_NATIVE_SELECTED_RUNTIME_DLL}"
        "${_runtime_pdb}" "${_gpu_target}")

    if(ARG_UPSCALING_TARGET)
        message(STATUS
            "COD3 native upscaling target '${ARG_UPSCALING_TARGET}' is included; host presentation remains a separate contract")
    else()
        message(STATUS
            "COD3 native upscaling: no live target requested; integration/upscaling remains probe-only")
    endif()
    message(STATUS
        "COD3 native build contract: ${ARG_HOST_TARGET}, ${ARG_RUNTIME_CONFIGURATION}, 15 mission DLLs, strict FP, no Xenia runtime")
endfunction()
