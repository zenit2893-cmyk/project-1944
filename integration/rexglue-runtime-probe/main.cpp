#include <array>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>

#include <rex/kernel/init.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/user_module.h>
#include <rex/system/xex_module.h>
#include <rex/system/xmemory.h>

using rex::X_STATUS;

namespace {
void WriteRegion(std::ostream& out, const rex::memory::HeapAllocationInfo& region) {
  out << "{\"base\":" << region.base_address
      << ",\"allocation_base\":" << region.allocation_base
      << ",\"allocation_size\":" << region.allocation_size
      << ",\"region_size\":" << region.region_size
      << ",\"state\":" << region.state
      << ",\"protect\":" << region.protect << "}";
}

[[noreturn]] void Finish(int code) {
  // The regression deliberately leaves allocation bookkeeping inconsistent.
  // Avoid running destructors against that corrupted bookkeeping. The process
  // owns this arena and its kernel worker; the OS reclaims them on exit.
  rex::FlushLogging();
  std::cout.flush();
  std::cerr.flush();
  std::_Exit(code);
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) {
    std::cerr << "Usage: rexglue_runtime_module_probe <game-root> <result.json>\n";
    return 64;
  }
  rex::InitLogging(nullptr, spdlog::level::warn);
  auto runtime = std::make_unique<rex::Runtime>(std::filesystem::path(argv[1]));
  rex::RuntimeConfig config;
  config.kernel_init = rex::kernel::InitializeKernel;
  config.tool_mode = true;
  if (runtime->Setup(std::move(config)) != X_STATUS_SUCCESS) {
    std::cerr << "Runtime setup failed\n";
    Finish(65);
  }
  if (runtime->LoadXexImage("game:\\default.xex") != X_STATUS_SUCCESS) {
    std::cerr << "Main XEX load failed\n";
    Finish(66);
  }
  auto main_module = runtime->kernel_state()->GetExecutableModule();
  const uint32_t main_base = main_module->xex_module()->base_address();
  auto* heap = runtime->memory()->LookupHeap(main_base);
  rex::memory::HeapAllocationInfo before{};
  if (!heap->QueryRegionInfo(main_base, &before) || before.state == 0) {
    std::cerr << "Main XEX was not tracked immediately after load\n";
    Finish(67);
  }
  std::array<uint8_t, 64> main_bytes{};
  std::memcpy(main_bytes.data(), runtime->memory()->TranslateVirtual(main_base), main_bytes.size());
  const bool overlap_before = heap->AllocFixed(
      main_base, heap->page_size(), heap->page_size(),
      rex::memory::kMemoryAllocationReserve, rex::memory::kMemoryProtectRead);
  if (overlap_before) {
    std::cerr << "Baseline rejected: main was already available for overlap before level load\n";
    Finish(68);
  }

  // Load the level's data/imports only. Passing false prevents DllMain, and this
  // probe never prepares or launches a guest game thread or a GPU/audio system.
  auto level = runtime->kernel_state()->LoadUserModule("game:\\sp\\saint_lo\\saint_lo.dll", false);
  if (!level) {
    std::cerr << "Saint-Lo XEX module load failed\n";
    Finish(69);
  }
  const uint32_t level_base = level->xex_module()->base_address();
  rex::memory::HeapAllocationInfo after{};
  rex::memory::HeapAllocationInfo level_region{};
  heap->QueryRegionInfo(main_base, &after);
  runtime->memory()->LookupHeap(level_base)->QueryRegionInfo(level_base, &level_region);
  const bool main_bytes_unchanged = std::memcmp(
      main_bytes.data(), runtime->memory()->TranslateVirtual(main_base), main_bytes.size()) == 0;
  const bool overlap_after = heap->AllocFixed(
      main_base, heap->page_size(), heap->page_size(),
      rex::memory::kMemoryAllocationReserve, rex::memory::kMemoryProtectRead);
  const bool regression = before.state != 0 && after.state == 0 && overlap_after;

  std::ofstream out(std::filesystem::path(argv[2]), std::ios::binary);
  out << std::boolalpha
      << "{\n  \"schema\":1,\n  \"guest_entry_executed\":false,\n"
      << "  \"same_heap\":" << (heap == runtime->memory()->LookupHeap(level_base)) << ",\n"
      << "  \"main_base\":" << main_base << ",\n"
      << "  \"level_base\":" << level_base << ",\n"
      << "  \"main_before\":";
  WriteRegion(out, before);
  out << ",\n  \"main_after_level_load\":";
  WriteRegion(out, after);
  out << ",\n  \"level_region\":";
  WriteRegion(out, level_region);
  out << ",\n  \"main_first_64_bytes_unchanged\":" << main_bytes_unchanged
      << ",\n  \"overlap_reservation_before\":" << overlap_before
      << ",\n  \"overlap_reservation_after\":" << overlap_after
      << ",\n  \"regression_reproduced\":" << regression << "\n}\n";
  out.flush();
  const bool output_ok = out.good();
  out.close();
  if (!output_ok) {
    std::cerr << "Writing probe receipt failed\n";
    Finish(70);
  }
  std::cout << "Main state " << before.state << " -> " << after.state
            << "; overlapping reserve " << overlap_before << " -> " << overlap_after
            << "; regression " << regression << '\n';
  Finish(regression ? 2 : 0);
}
