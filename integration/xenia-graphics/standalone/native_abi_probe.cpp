// Read-only native load probe for a staged rexgpu-xenos DLL.
// It checks only the exported ABI symbols; it does not create a GPU device,
// construct a graphics system, attach to a host, or launch a game.

#include <Windows.h>

#include <cstdint>
#include <cstdio>

namespace {

using AbiVersionFn = std::uint32_t (*)();

int Fail(const char* message, unsigned long error = ERROR_SUCCESS) {
  if (error == ERROR_SUCCESS) {
    std::fprintf(stderr, "xenia-graphics-abi-probe: FAIL: %s\n", message);
  } else {
    std::fprintf(stderr, "xenia-graphics-abi-probe: FAIL: %s (Win32=%lu)\n", message,
                 error);
  }
  return 1;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) {
    return Fail("usage: xenia_graphics_abi_probe.exe <staged-plugin.dll>");
  }

  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR);
  HMODULE module = LoadLibraryExW(argv[1], nullptr,
                                  LOAD_LIBRARY_SEARCH_DEFAULT_DIRS |
                                      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR);
  if (!module) {
    return Fail("LoadLibraryExW failed", GetLastError());
  }

  auto abi_version = reinterpret_cast<AbiVersionFn>(GetProcAddress(module, "rex_gpu_abi_version"));
  auto create = GetProcAddress(module, "rex_gpu_create");
  if (!abi_version || !create) {
    unsigned long error = GetLastError();
    FreeLibrary(module);
    return Fail("required rexglue GPU exports are missing", error);
  }

  const std::uint32_t observed = abi_version();
  if (observed != 1) {
    FreeLibrary(module);
    return Fail("unexpected GPU plugin ABI version");
  }

  wprintf(L"xenia-graphics-abi-probe: PASS: loaded %ls; ABI=%u; exports=2\n", argv[1],
          observed);
  FreeLibrary(module);
  return 0;
}
