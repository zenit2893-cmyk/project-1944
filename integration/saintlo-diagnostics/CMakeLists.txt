# Optional, observational hooks for the exact Saint-Lo build from the supplied disc.
function(cod3_enable_saintlo_diagnostics target_name)
    if(NOT WIN32 OR NOT TARGET "${target_name}")
        message(FATAL_ERROR "Saint-Lo diagnostics require an existing Windows mission DLL target")
    endif()
    target_sources("${target_name}" PRIVATE
        "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/saintlo_diagnostics.cpp")
endfunction()
