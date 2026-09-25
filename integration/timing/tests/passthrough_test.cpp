#include "candidate_observer.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <immintrin.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <cfenv>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#include <rex/ppc/context.h>

REX_EXTERN(sub_825298D8);
REX_EXTERN(sub_82536DD0);
REX_EXTERN(__imp__sub_825298D8);
REX_EXTERN(__imp__sub_82536DD0);

// Match the generated Windows ReXGlue alias arrangement. The independent
// override_hooks.cpp object must override these weak names while __imp__ stays
// callable as the original. Admission counts below prove hooks were reached.
__attribute__((alias("__imp__sub_825298D8")))
__attribute__((weak, noinline)) extern "C" REX_FUNC(sub_825298D8);
__attribute__((alias("__imp__sub_82536DD0")))
__attribute__((weak, noinline)) extern "C" REX_FUNC(sub_82536DD0);

namespace {
std::atomic<unsigned> original_calls{};
thread_local PPCContext* expected_context{};
thread_local uint8_t* expected_base{};
thread_local unsigned expected_mxcsr{};
thread_local int expected_errno{};
thread_local DWORD expected_win_error{};
thread_local bool reference_mode{}, nested_mode{}, throw_mode{};
std::vector<std::filesystem::path> trace_files;

void Check(bool result, const char* expression, int line) {
  if (!result) {
    std::fprintf(stderr, "FAILED line %d: %s\n", line, expression);
    std::abort();
  }
}
#define CHECK(expression) Check(bool(expression), #expression, __LINE__)

struct Raised { unsigned code; };
struct HostSnapshot { unsigned mxcsr; int round; int exception_flags; int error; DWORD win_error; };

void ExpectedHost() {
  expected_win_error = GetLastError();
  expected_errno = errno;
  expected_mxcsr = _mm_getcsr();
}

void ResetHost() {
  std::fesetenv(FE_DFL_ENV);
  std::fesetround(FE_DOWNWARD);
  _mm_setcsr(0x1F80u | 0x2000u | 0x10u | 0x40u);
  errno = EDOM;
  SetLastError(0x13426789);
  ExpectedHost();
}

HostSnapshot Host() {
  const DWORD error = GetLastError();
  const int crt = errno;
  const auto mxcsr = _mm_getcsr();
  const auto round = std::fegetround();
  const auto exception_flags = std::fetestexcept(FE_ALL_EXCEPT);
  return {mxcsr, round, exception_flags, crt, error};
}

void Mutate(PPCContext& ctx, uint8_t* base, uint8_t salt) {
  const DWORD win_error = GetLastError();
  CHECK(&ctx == expected_context);
  CHECK(base == expected_base);
  CHECK(_mm_getcsr() == expected_mxcsr);
  CHECK(errno == expected_errno);
  CHECK(win_error == expected_win_error);
  ++original_calls;
  auto* bytes = reinterpret_cast<unsigned char*>(&ctx);
  for (size_t i = 0; i < sizeof(ctx); ++i) bytes[i] ^= uint8_t(i * 17 + salt);
  for (size_t i = 0; i < 512; ++i) base[i] ^= uint8_t(i * 13 + salt);
  std::fesetround(FE_TOWARDZERO);
  _mm_setcsr(0x1F80u | 0x6000u | 0x20u | 0x8000u);
  errno = ERANGE;
  SetLastError(0xABCDEF12);
  ExpectedHost();
}

void CompareOne(PPCFunc& original, PPCFunc& hook, unsigned seed, bool nested = false, bool throwing = false) {
  static_assert(std::is_trivially_copyable_v<PPCContext>);
  PPCContext initial{}, reference{}, observed{};
  alignas(32) std::array<uint8_t, 512> initial_memory{}, memory{}, expected_memory{};
  auto* bytes = reinterpret_cast<unsigned char*>(&initial);
  for (size_t i = 0; i < sizeof(initial); ++i) bytes[i] = uint8_t(seed + i * 7);
  for (size_t i = 0; i < memory.size(); ++i) initial_memory[i] = uint8_t(seed + i * 3);
  std::memcpy(&reference, &initial, sizeof(initial));
  std::memcpy(&observed, &initial, sizeof(initial));
  nested_mode = nested;
  throw_mode = throwing;
  reference_mode = true;
  memory = initial_memory;
  expected_context = &reference;
  expected_base = memory.data();
  ResetHost();
  bool reference_threw = false;
  try { original(reference, memory.data()); }
  catch (const Raised& raised) { CHECK(raised.code == 0xFACE); reference_threw = true; }
  const auto reference_host = Host();
  expected_memory = memory;

  reference_mode = false;
  memory = initial_memory;
  expected_context = &observed;
  expected_base = memory.data();
  ResetHost();
  bool observed_threw = false;
  try { hook(observed, memory.data()); }
  catch (const Raised& raised) { CHECK(raised.code == 0xFACE); observed_threw = true; }
  const auto observed_host = Host();
  CHECK(reference_threw == observed_threw);
  CHECK(reference_threw == throwing);
  CHECK(std::memcmp(&reference, &observed, sizeof(PPCContext)) == 0);
  CHECK(expected_memory == memory);
  CHECK(reference_host.mxcsr == observed_host.mxcsr);
  CHECK(reference_host.round == observed_host.round);
  CHECK(reference_host.exception_flags == observed_host.exception_flags);
  CHECK(reference_host.error == observed_host.error);
  CHECK(reference_host.win_error == observed_host.win_error);
  nested_mode = throw_mode = false;
}

void Enable(const std::filesystem::path& root, const std::filesystem::path& output, const wchar_t* cap) {
  _wputenv_s(L"COD3_TIMING_TRACE", L"1");
  _wputenv_s(L"COD3_TIMING_OUTPUT_DIR", output.c_str());
  _wputenv_s(L"COD3_TIMING_MAX_CALLS", cap);
  CHECK(cod3::timing::ConfigureFromEnvironment(root) == cod3::timing::StartResult::Recording);
}

void CloseAndRemember() {
  cod3::timing::Shutdown();
  CHECK(!cod3::timing::GetSnapshot().recording);
  CHECK(!cod3::timing::GetSnapshot().io_error);
  const auto file = cod3::timing::OutputPath();
  CHECK(std::filesystem::exists(file));
  CHECK(std::filesystem::file_size(file) < 64u * 1024 * 1024);
  trace_files.push_back(file);
}

std::string QuotePath(const std::filesystem::path& value) {
  const auto utf8 = value.generic_u8string();
  std::string result = "\"";
  for (const auto byte : utf8) {
    const char c = static_cast<char>(byte);
    if (c == '\\' || c == '"') result += '\\';
    result += c;
  }
  return result + '"';
}
}  // namespace

REX_EXTERN(__imp__sub_825298D8) {
  Mutate(ctx, base, 0x35);
  if (throw_mode) throw Raised{0xFACE};
}

REX_EXTERN(__imp__sub_82536DD0) {
  Mutate(ctx, base, 0xA7);
  if (nested_mode) {
    if (reference_mode) __imp__sub_825298D8(ctx, base);
    else sub_825298D8(ctx, base);
  }
  if (throw_mode) throw Raised{0xFACE};
}

int wmain(int argc, wchar_t** argv) {
  CHECK(argc == 3);
  const std::filesystem::path workspace = std::filesystem::canonical(argv[1]);
  const auto test_root = std::filesystem::path(argv[2]) /
                         (L"native-stubs-" + std::to_wstring(GetCurrentProcessId()));
  std::filesystem::create_directories(test_root);
  const auto output = test_root / "traces";
  // Tests run in their own process; no user/system env is changed.
  _wputenv_s(L"COD3_TIMING_TRACE", L"");
  _wputenv_s(L"COD3_TIMING_OUTPUT_DIR", L"");
  CHECK(cod3::timing::ConfigureFromEnvironment(workspace) == cod3::timing::StartResult::Disabled);
  for (unsigned i = 0; i < 32; ++i) {
    CompareOne(__imp__sub_825298D8, sub_825298D8, i);
    CompareOne(__imp__sub_82536DD0, sub_82536DD0, i);
  }
  CHECK(!std::filesystem::exists(output));

  Enable(workspace, output, L"65536");
  for (unsigned i = 0; i < 64; ++i) {
    CompareOne(__imp__sub_825298D8, sub_825298D8, i + 33);
    CompareOne(__imp__sub_82536DD0, sub_82536DD0, i + 33);
  }
  CompareOne(__imp__sub_82536DD0, sub_82536DD0, 201, true);
  CompareOne(__imp__sub_825298D8, sub_825298D8, 203, false, true);
  CompareOne(__imp__sub_82536DD0, sub_82536DD0, 205, true, true);
  CloseAndRemember();
  CHECK(cod3::timing::GetSnapshot().admitted_calls == 133);
  CHECK(cod3::timing::GetSnapshot().pending_calls == 0);

  Enable(workspace, output, L"65536");
  std::vector<std::thread> threads;
  for (unsigned thread = 0; thread < 8; ++thread) {
    threads.emplace_back([thread] {
      for (unsigned i = 0; i < 100; ++i) {
        CompareOne(__imp__sub_825298D8, sub_825298D8, thread * 13 + i);
        CompareOne(__imp__sub_82536DD0, sub_82536DD0, thread * 17 + i);
      }
    });
  }
  for (auto& thread : threads) thread.join();
  CloseAndRemember();
  CHECK(cod3::timing::GetSnapshot().admitted_calls == 1600);
  CHECK(cod3::timing::GetSnapshot().pending_calls == 0);

  Enable(workspace, output, L"3");
  for (unsigned i = 0; i < 20; ++i) CompareOne(__imp__sub_825298D8, sub_825298D8, i);
  CloseAndRemember();
  CHECK(cod3::timing::GetSnapshot().limit_reached);
  CHECK(cod3::timing::GetSnapshot().admitted_calls == 3);
  CHECK(cod3::timing::GetSnapshot().written_records <= 6);

  _wputenv_s(L"COD3_TIMING_OUTPUT_DIR", workspace.parent_path().c_str());
  CHECK(cod3::timing::ConfigureFromEnvironment(workspace) == cod3::timing::StartResult::InvalidConfiguration);
  CompareOne(__imp__sub_825298D8, sub_825298D8, 44);
  _wputenv_s(L"COD3_TIMING_OUTPUT_DIR", output.c_str());
  _wputenv_s(L"COD3_TIMING_MAX_CALLS", L"999999999999999999999999");
  CHECK(cod3::timing::ConfigureFromEnvironment(workspace) == cod3::timing::StartResult::InvalidConfiguration);
  CompareOne(__imp__sub_82536DD0, sub_82536DD0, 47);

  std::ofstream receipt(test_root / "native-test-result.json", std::ios::binary);
  receipt << "{\n  \"state\":\"NATIVE_STUB_TESTS_PASSED\",\n"
             "  \"gameplay_120fps_verified\":false,\n"
             "  \"test_scope\":\"Whole-context and memory passthrough against reference stubs; not game functions\",\n"
             "  \"cases\":[\"disabled_passthrough\",\"enabled_passthrough\",\"nested_calls\","
             "\"exception_propagation\",\"eight_threads\",\"record_cap\",\"invalid_configuration_passthrough\"],\n"
             "  \"original_stub_calls\":" << original_calls.load() << ",\n  \"trace_files\":[\n";
  for (size_t i = 0; i < trace_files.size(); ++i) {
    receipt << "    " << QuotePath(trace_files[i]) << (i + 1 < trace_files.size() ? ",\n" : "\n");
  }
  receipt << "  ]\n}\n";
  receipt.close();
  CHECK(receipt.good());
  std::puts("PASS: 7 native stub cases; whole PPCContext, memory, FP state, errno and LastError preserved.");
  std::puts("NOT A GAMEPLAY OR 120 FPS TEST. Inspect native-test-result.json and the trace schema.");
  return 0;
}
