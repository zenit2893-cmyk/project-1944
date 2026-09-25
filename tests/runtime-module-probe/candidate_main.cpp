#include <array>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <rex/kernel/init.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/xex_module.h>
#include <rex/system/xmemory.h>
#include "crypto/rijndael-alg-fst.h"

namespace {
std::vector<std::pair<std::string, bool>> results;
std::filesystem::path report_path;
bool Check(bool value, const std::string& name) {
  results.emplace_back(name, value);
  std::cout << (value ? "PASS " : "FAIL ") << name << '\n';
  return value;
}
[[noreturn]] void Finish(int code) {
  std::ofstream out(report_path, std::ios::binary);
  out << "{\n  \"schema\":1,\n  \"guest_entry_executed\":false,\n"
      << "  \"loader_implementation\":\"patched XexModule object linked locally against original runtime heap\",\n"
      << "  \"fixture_mutation\":\"devkit AES wrapper in a temporary memory buffer only\",\n"
      << "  \"checks\":[\n";
  for (size_t i = 0; i < results.size(); ++i) {
    out << "    {\"name\":\"" << results[i].first << "\",\"passed\":"
        << (results[i].second ? "true" : "false") << "}";
    if (i + 1 != results.size()) out << ',';
    out << '\n';
  }
  out << "  ],\n  \"all_passed\":" << (code == 0 ? "true" : "false") << "\n}\n";
  out.flush();
  if (!out.good()) code = 70;
  out.close();
  rex::FlushLogging();
  std::cout.flush();
  std::_Exit(code);
}
std::vector<uint8_t> Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    Check(false, "input file opens");
    Finish(1);
  }
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
std::unique_ptr<rex::runtime::XexModule> Load(rex::Runtime& runtime,
                                            const std::vector<uint8_t>& bytes,
                                            const char* name) {
  auto module = std::make_unique<rex::runtime::XexModule>(runtime.function_dispatcher(),
                                                        runtime.kernel_state());
  if (!module->Load(name, name, bytes.data(), bytes.size()) || !module->LoadContinue()) {
    return nullptr;
  }
  return module;
}
uint32_t State(rex::Runtime& runtime, uint32_t address) {
  rex::memory::HeapAllocationInfo info{};
  runtime.memory()->LookupHeap(address)->QueryRegionInfo(address, &info);
  return info.state;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 64;
  report_path = argv[2];
  const std::filesystem::path root(argv[1]);
  auto main_bytes = Read(root / "default.xex");
  auto level_bytes = Read(root / "sp" / "saint_lo" / "saint_lo.dll");
  rex::InitLogging(nullptr, spdlog::level::warn);
  auto runtime = std::make_unique<rex::Runtime>(root);
  rex::RuntimeConfig config;
  config.kernel_init = rex::kernel::InitializeKernel;
  config.tool_mode = true;
  if (!Check(runtime->Setup(std::move(config)) == 0, "tool runtime setup")) Finish(1);

  constexpr uint32_t sentinel = 0x83000000;
  auto* heap = runtime->memory()->LookupHeap(sentinel);
  if (!Check(heap->AllocFixed(sentinel, 0x10000, 0x10000, 3, 3),
             "independent reservation before main load")) Finish(1);
  auto main = Load(*runtime, main_bytes, "default.xex");
  if (!Check(main != nullptr, "retail main loads")) Finish(1);
  if (!Check(State(*runtime, sentinel) == 3, "main load preserves independent reservation")) Finish(1);
  const uint32_t main_base = main->base_address();
  auto level = Load(*runtime, level_bytes, "saint_lo.dll");
  if (!Check(level != nullptr, "retail level loads")) Finish(1);
  const uint32_t level_base = level->base_address();
  if (!Check(State(*runtime, main_base) == 3 && State(*runtime, sentinel) == 3,
             "level load preserves main and independent reservations")) Finish(1);
  if (!Check(!heap->AllocFixed(main_base, 0x10000, 0x10000,
                              rex::memory::kMemoryAllocationReserve, 1),
             "overlap reservation remains rejected")) Finish(1);

  auto duplicate = Load(*runtime, level_bytes, "duplicate-saint_lo.dll");
  if (!Check(duplicate == nullptr, "overlapping second image fails without overwrite")) Finish(1);
  if (!Check(State(*runtime, main_base) == 3 && State(*runtime, level_base) == 3,
             "failed conflicting load preserves existing images")) Finish(1);
  if (!Check(level->Unload() && State(*runtime, level_base) == 0,
             "owned level image releases on unload")) Finish(1);

  // Preserve the encrypted payload and rewrap only the image's 16-byte AES key
  // under the standard devkit wrapper. A retail attempt must fail PE validation,
  // release its own allocation and allow the devkit attempt to allocate again.
  auto* header = reinterpret_cast<rex::xex2_header*>(level_bytes.data());
  auto* security = reinterpret_cast<rex::xex2_security_info*>(
      level_bytes.data() + uint32_t(header->security_offset));
  constexpr uint8_t retail_key[16] = {0x20,0xB1,0x85,0xA5,0x9D,0x28,0xFD,0xC3,
                                    0x40,0x58,0x3F,0xBB,0x08,0x96,0xBF,0x91};
  constexpr uint8_t devkit_key[16] = {};
  uint32_t schedule[4 * (MAXNR + 1)];
  uint8_t image_key[16];
  int rounds = rijndaelKeySetupDec(schedule, retail_key, 128);
  rijndaelDecrypt(schedule, rounds, reinterpret_cast<uint8_t*>(security->aes_key), image_key);
  rounds = rijndaelKeySetupEnc(schedule, devkit_key, 128);
  rijndaelEncrypt(schedule, rounds, image_key, reinterpret_cast<uint8_t*>(security->aes_key));
  std::memset(image_key, 0, sizeof(image_key));
  std::memset(schedule, 0, sizeof(schedule));
  auto devkit = Load(*runtime, level_bytes, "in-memory-devkit-saint_lo.dll");
  if (!Check(devkit && devkit->is_dev_kit(), "failed retail attempt retries successfully with devkit key")) Finish(1);
  if (!Check(State(*runtime, main_base) == 3 && State(*runtime, sentinel) == 3,
             "devkit retry preserves unrelated reservations")) Finish(1);
  if (!Check(devkit->Unload() && main->Unload() && heap->Release(sentinel),
             "all owned reservations unload successfully")) Finish(1);
  Finish(0);
}
