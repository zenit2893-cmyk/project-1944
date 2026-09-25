# Inject the build contract at the end of cod3-pc's top-level directory for a
# read-only configure probe.  This file is passed through CMAKE_PROJECT_INCLUDE;
# the active project itself remains untouched.
if(CMAKE_PROJECT_NAME STREQUAL "cod3_pc" AND PROJECT_NAME STREQUAL "cod3_pc")
    set(_cod3_contract_workspace "<workspace>")
    set(_cod3_contract_include
        "${_cod3_contract_workspace}/integration/build-system/Cod3NativeBuildIntegration.cmake")
    cmake_language(DEFER CALL include "${_cod3_contract_include}")
    cmake_language(DEFER CALL cod3_native_integrate
        HOST_TARGET cod3_pc
        ENTRYPOINT_OBJECT_TARGET cod3_pc_recomp
        CODEGEN_TARGET cod3_pc_codegen
        RUNTIME_CONFIGURATION RelWithDebInfo
        RUNTIME_DLL "${_cod3_contract_workspace}/tools/rexglue-patched-sdk/bin/rexruntimerd.dll"
        RUNTIME_IMPLIB "${_cod3_contract_workspace}/tools/rexglue-patched-sdk/lib/rexruntimerd.lib"
        RUNTIME_PDB "${_cod3_contract_workspace}/tools/rexglue-patched-sdk/bin/rexruntimerd.pdb"
        REQUIRE_PATCHED_RUNTIME)
endif()
