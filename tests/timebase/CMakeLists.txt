cmake_minimum_required(VERSION 3.25)
project(cod3_timebase_contract_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

get_filename_component(WORKSPACE "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
list(PREPEND CMAKE_PREFIX_PATH "${WORKSPACE}/win-amd64")
find_package(rexglue 0.10.0.5 EXACT REQUIRED CONFIG)

add_subdirectory("${WORKSPACE}/integration/timebase" timebase_adapter)

add_executable(cod3_timebase_contract_test
  timebase_contract_test.cpp)
target_include_directories(cod3_timebase_contract_test PRIVATE
  "${WORKSPACE}/integration/timebase")
target_link_libraries(cod3_timebase_contract_test PRIVATE
  cod3::xenon_timebase)
target_compile_options(cod3_timebase_contract_test PRIVATE
  -ffp-model=strict -fno-strict-aliasing -fwrapv)

if(WIN32)
  add_custom_command(TARGET cod3_timebase_contract_test POST_BUILD
    COMMAND
      "$<$<BOOL:$<TARGET_RUNTIME_DLLS:cod3_timebase_contract_test>>:${CMAKE_COMMAND};-E;copy_if_different;$<TARGET_RUNTIME_DLLS:cod3_timebase_contract_test>;$<TARGET_FILE_DIR:cod3_timebase_contract_test>>"
    COMMAND_EXPAND_LISTS VERBATIM)
endif()

enable_testing()
add_test(NAME timebase_native_contract
  COMMAND cod3_timebase_contract_test)

find_program(COD3_POWERSHELL NAMES pwsh powershell REQUIRED)
add_test(NAME timebase_adapter_source_no_host_tsc
  COMMAND "${COD3_POWERSHELL}" -NoProfile -File
    "${CMAKE_CURRENT_SOURCE_DIR}/check_no_host_tsc.ps1"
    -AdapterDirectory "${WORKSPACE}/integration/timebase")
