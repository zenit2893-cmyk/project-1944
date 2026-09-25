if(NOT TARGET rex::runtime)
    message(FATAL_ERROR "Find the pinned ReXGlue SDK before adding integration/xenon")
endif()
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    message(FATAL_ERROR "The bounded Xenon bridge requires the verified Clang toolchain")
endif()
if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/generated/thunks.generated.inl")
    message(FATAL_ERROR "Run extract-generated-thunks.ps1 on real Xenon output first")
endif()

add_library(cod3_xenon_thunks OBJECT xenon_thunks.cpp)
add_library(cod3::xenon_thunks ALIAS cod3_xenon_thunks)
target_compile_features(cod3_xenon_thunks PUBLIC cxx_std_23)
target_include_directories(cod3_xenon_thunks PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(cod3_xenon_thunks PUBLIC rex::runtime)
# Xenon emits ADDI via signed 64-bit arithmetic. Explicitly define wrap semantics
# for this object alone; the source text remains exactly as Xenon generated it.
target_compile_options(cod3_xenon_thunks PRIVATE
    -fwrapv -fno-strict-aliasing -ffp-model=strict)

function(cod3_enable_xenon_thunk_overrides target_name)
    if(NOT TARGET "${target_name}")
        message(FATAL_ERROR "Unknown Xenon bridge host target ${target_name}")
    endif()
    target_sources("${target_name}" PRIVATE
        "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/override_hooks.cpp")
    target_link_libraries("${target_name}" PRIVATE cod3::xenon_thunks)
endfunction()

