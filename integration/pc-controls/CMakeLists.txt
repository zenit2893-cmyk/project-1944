cmake_minimum_required(VERSION 3.25)

if(NOT TARGET rex::runtime)
    message(FATAL_ERROR "Find the pinned ReXGlue SDK before adding integration/pc-controls")
endif()

# Keyboard/mouse mapping and direct mouse look. The logic lives in a static
# library; the two guest hooks are an object library so their strong symbols
# are linked into the host whether or not anything references them.
add_library(cod3_pc_controls STATIC pc_controls.cpp game_cursor.cpp menu_mouse.cpp)
add_library(cod3::pc_controls ALIAS cod3_pc_controls)
target_compile_features(cod3_pc_controls PUBLIC cxx_std_23)
target_include_directories(cod3_pc_controls PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
# comctl32: SetWindowSubclass for the game-window pointer.
# shell32: CommandLineToArgvW for the relaunch between levels.
target_link_libraries(cod3_pc_controls PUBLIC rex::runtime PRIVATE comctl32 shell32)

# game_console.cpp: the retail print stubs, copied into the log on request.
# sdl_hints.cpp: SDL joystick settings applied before SDL starts.
# title_relaunch.cpp: the game's reboot into itself between levels.
# movies.cpp: any button skips a movie.
add_library(cod3_pc_controls_hooks OBJECT pc_controls_hooks.cpp game_console.cpp sdl_hints.cpp title_relaunch.cpp
            movies.cpp)
target_link_libraries(cod3_pc_controls_hooks PUBLIC cod3::pc_controls)

function(cod3_enable_pc_controls target_name)
    if(NOT TARGET "${target_name}")
        message(FATAL_ERROR "Unknown PC controls host target ${target_name}")
    endif()
    target_sources("${target_name}" PRIVATE $<TARGET_OBJECTS:cod3_pc_controls_hooks>)
    # WHOLE_ARCHIVE keeps the REXCVAR registrations even though only a few of
    # the library's symbols are referenced from the host.
    target_link_libraries("${target_name}" PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,cod3::pc_controls>")
endfunction()
