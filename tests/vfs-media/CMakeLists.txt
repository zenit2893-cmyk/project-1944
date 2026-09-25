cmake_minimum_required(VERSION 3.25)
project(cod3_vfs_media_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

get_filename_component(WORKSPACE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

add_executable(cod3_vfs_media_tests
    main.cpp
    "${WORKSPACE_ROOT}/integration/vfs-media/cod3_vfs_media_map.cpp")
target_include_directories(cod3_vfs_media_tests PRIVATE
    "${WORKSPACE_ROOT}/integration/vfs-media")

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(cod3_vfs_media_tests PRIVATE -Wall -Wextra -Wpedantic)
endif()

enable_testing()
add_test(NAME cod3_vfs_media_inventory
    COMMAND cod3_vfs_media_tests "${WORKSPACE_ROOT}/game/cod3")
