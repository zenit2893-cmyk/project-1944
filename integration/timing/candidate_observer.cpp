#include "candidate_observer.h"

#ifndef _WIN32
#error The current timing observer is intentionally Windows-only (QPC).
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <immintrin.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cfenv>
#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

#include <rex/ppc/context.h>

namespace cod3::timing {
namespace {

constexpr size_t kQueueCapacity = 4096;
constexpr size_t kBatchRecords = 128;
constexpr uint64_t kMaxBytes = 64ull * 1024 * 1024;
constexpr uint64_t kFooterReserve = 2048;
constexpr uint64_t kDefaultMaxCalls = 32768;
constexpr uint64_t kHardMaxCalls = 65536;

// Logging must not overwrite original host-side FP control/status, errno or
// Win32 LastError. Keep this guard around observation only, never across the
// original guest function, whose own FP changes must survive the hook.
class HostStateGuard {
 public:
  HostStateGuard() noexcept
      : win_error_(GetLastError()), crt_error_(errno), mxcsr_(_mm_getcsr()),
        fenv_valid_(std::fegetenv(&fenv_) == 0) {}
  ~HostStateGuard() noexcept {
    if (fenv_valid_) std::fesetenv(&fenv_);
    _mm_setcsr(mxcsr_);
    errno = crt_error_;
    SetLastError(win_error_);
  }
 private:
  DWORD win_error_;
  int crt_error_;
  unsigned mxcsr_;
  std::fenv_t fenv_{};
  bool fenv_valid_;
};

struct Record {
  uint64_t call_id;
  uint64_t outer_call_id;
  uint64_t qpc;
  uint64_t r3;
  uint64_t lr;
  uint32_t thread_id;
  Probe probe;
  bool begin;
  bool unwinding;
};

struct Ticket {
  Record entry{};
  uint64_t previous_outer{};
  bool valid{};
};

thread_local uint64_t current_outer_call = 0;

// Fixed-size JSON encoder: no allocation or FP formatting per record. All
// dynamic values are integers; strings are fixed literals, so no escaping is
// required. File metadata deliberately does not attest the loaded XEX.
struct Line {
  std::array<char, 1536> bytes{};
  size_t used{};
  bool valid{true};
  void Add(std::string_view value) noexcept {
    if (value.size() > bytes.size() - used) { valid = false; return; }
    std::memcpy(bytes.data() + used, value.data(), value.size());
    used += value.size();
  }
  template <typename Integer> void Number(Integer value) noexcept {
    const auto result = std::to_chars(bytes.data() + used, bytes.data() + bytes.size(), value);
    if (result.ec != std::errc{}) { valid = false; return; }
    used = static_cast<size_t>(result.ptr - bytes.data());
  }
};

class TraceState {
 public:
  std::atomic<bool> recording{false};
  std::atomic<bool> writer_active{false};
  std::atomic<bool> stopping{false};
  std::atomic<bool> limit_reached{false};
  std::atomic<bool> io_error{false};
  std::atomic<uint64_t> attempts{0}, admitted{0}, pending{0};
  std::atomic<uint64_t> queued{0}, written{0}, dropped{0}, qpc_failures{0};
  uint64_t max_calls{kDefaultMaxCalls}, frequency{}, start_qpc{}, bytes_written{};
  HANDLE file{INVALID_HANDLE_VALUE};
  std::filesystem::path path;
  std::mutex control_mutex, queue_mutex;
  std::condition_variable wake;
  std::array<Record, kQueueCapacity> queue{};
  size_t head{}, count{};
  std::thread writer;

  ~TraceState() { Stop(); }

  void Stop() noexcept {
    HostStateGuard preserve;
    try {
      std::lock_guard control(control_mutex);
      recording.store(false, std::memory_order_release);
      stopping.store(true, std::memory_order_release);
      wake.notify_one();
      if (writer.joinable()) writer.join();
      writer_active.store(false, std::memory_order_release);
      if (file != INVALID_HANDLE_VALUE) {
        if (!FlushFileBuffers(file)) io_error.store(true);
        CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
      }
    } catch (...) {
      io_error.store(true);
      // The observer never throws into guest execution. Normal caller contract
      // excludes concurrent Configure/Shutdown or guest use at process teardown.
    }
  }

  uint64_t Qpc() noexcept {
    LARGE_INTEGER stamp{};
    if (!QueryPerformanceCounter(&stamp) || stamp.QuadPart < 0) {
      qpc_failures.fetch_add(1, std::memory_order_relaxed);
      return 0;
    }
    return static_cast<uint64_t>(stamp.QuadPart);
  }

  bool Write(const char* bytes, size_t size, bool footer = false) noexcept {
    if (io_error.load(std::memory_order_relaxed)) return false;
    if (bytes_written + size > kMaxBytes - (footer ? 0 : kFooterReserve)) {
      limit_reached.store(true);
      recording.store(false, std::memory_order_release);
      return false;
    }
    size_t offset = 0;
    while (offset < size) {
      DWORD completed = 0;
      if (!WriteFile(file, bytes + offset, static_cast<DWORD>(size - offset), &completed, nullptr)
          || completed == 0) {
        io_error.store(true);
        recording.store(false, std::memory_order_release);
        return false;
      }
      offset += completed;
      bytes_written += completed;
    }
    return true;
  }

  void Emit(const Record& record) noexcept {
    try {
      if (!writer_active.load(std::memory_order_acquire) || stopping.load(std::memory_order_acquire)) {
        dropped.fetch_add(1, std::memory_order_relaxed);
        return;
      }
      std::unique_lock lock(queue_mutex, std::try_to_lock);
      if (!lock || count == kQueueCapacity) {
        dropped.fetch_add(1, std::memory_order_relaxed);
        return;
      }
      queue[(head + count) % kQueueCapacity] = record;
      ++count;
      queued.fetch_add(1, std::memory_order_relaxed);
      const bool notify = count == kBatchRecords;
      lock.unlock();
      if (notify) wake.notify_one();
    } catch (...) {
      dropped.fetch_add(1, std::memory_order_relaxed);
    }
  }

  static Line Encode(const Record& record) noexcept {
    Line line;
    line.Add(record.begin ? "{\"kind\":\"call_begin\",\"event\":\"" :
                           "{\"kind\":\"call_end\",\"event\":\"");
    line.Add(record.probe == Probe::MsNormalization ? "candidate_ms_normalization" : "candidate_outer_frame");
    line.Add("\",\"guest_address\":\"");
    line.Add(record.probe == Probe::MsNormalization ? "0x825298D8" : "0x82536DD0");
    line.Add("\",\"call_id\":"); line.Number(record.call_id);
    line.Add(",\"outer_call_id\":"); line.Number(record.outer_call_id);
    line.Add(",\"host_thread_id\":"); line.Number(record.thread_id);
    line.Add(",\"host_qpc\":"); line.Number(record.qpc);
    line.Add(",\"r3_u64\":"); line.Number(record.r3);
    line.Add(",\"r3_s32\":"); line.Number(static_cast<int32_t>(static_cast<uint32_t>(record.r3)));
    line.Add(",\"guest_lr_u64\":"); line.Number(record.lr);
    line.Add(",\"outcome\":\"");
    line.Add(record.begin ? "entered" : (record.unwinding ? "exception_unwind" : "returned"));
    line.Add("\"}\n");
    return line;
  }

  void Worker() noexcept {
    try {
      std::array<Record, kBatchRecords> batch{};
      std::array<char, kBatchRecords * 512> output{};
      for (;;) {
        size_t amount = 0;
        {
          std::unique_lock lock(queue_mutex);
          wake.wait_for(lock, std::chrono::milliseconds(100), [&] {
            return count >= kBatchRecords || stopping.load(std::memory_order_acquire);
          });
          amount = (std::min)(count, batch.size());
          for (size_t i = 0; i < amount; ++i) batch[i] = queue[(head + i) % kQueueCapacity];
          head = (head + amount) % kQueueCapacity;
          count -= amount;
          if (amount == 0 && stopping.load(std::memory_order_acquire)) break;
        }
        size_t used = 0;
        bool encoded = true;
        for (size_t i = 0; i < amount; ++i) {
          const auto line = Encode(batch[i]);
          if (!line.valid || line.used > output.size() - used) { encoded = false; break; }
          std::memcpy(output.data() + used, line.bytes.data(), line.used);
          used += line.used;
        }
        if (!encoded) {
          io_error.store(true);
          recording.store(false, std::memory_order_release);
        }
        if (encoded && Write(output.data(), used)) written.fetch_add(amount);
        else dropped.fetch_add(amount);
      }
      Line footer;
      const uint64_t end_qpc = Qpc();
      const bool complete = pending.load() == 0 && dropped.load() == 0 &&
                            qpc_failures.load() == 0 && !io_error.load() && !limit_reached.load();
      footer.Add("{\"kind\":\"end\",\"capture_complete\":"); footer.Add(complete ? "true" : "false");
      footer.Add(",\"gameplay_120fps_verified\":false,\"host_qpc\":"); footer.Number(end_qpc);
      footer.Add(",\"admitted_calls\":"); footer.Number(admitted.load());
      footer.Add(",\"pending_calls\":"); footer.Number(pending.load());
      footer.Add(",\"queued_records\":"); footer.Number(queued.load());
      footer.Add(",\"written_records\":"); footer.Number(written.load());
      footer.Add(",\"dropped_records\":"); footer.Number(dropped.load());
      footer.Add(",\"qpc_failures\":"); footer.Number(qpc_failures.load());
      footer.Add(",\"limit_reached\":"); footer.Add(limit_reached.load() ? "true" : "false");
      footer.Add(",\"io_error\":"); footer.Add(io_error.load() ? "true" : "false");
      footer.Add("}\n");
      if (footer.valid) Write(footer.bytes.data(), footer.used, true);
    } catch (...) {
      io_error.store(true);
      recording.store(false, std::memory_order_release);
    }
    writer_active.store(false, std::memory_order_release);
  }
};

TraceState trace;

std::wstring Environment(const wchar_t* name) {
  const DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
  if (!length) return {};
  std::wstring result(length, L'\0');
  const DWORD copied = GetEnvironmentVariableW(name, result.data(), length);
  if (!copied || copied >= length) return {};
  result.resize(copied);
  return result;
}

bool Inside(const std::filesystem::path& child, const std::filesystem::path& root) {
  auto cursor = child.begin();
  for (const auto& component : root) {
    if (cursor == child.end() || _wcsicmp(cursor->c_str(), component.c_str()) != 0) return false;
    ++cursor;
  }
  return true;
}

Ticket Begin(Probe probe, uint64_t input_r3, uint64_t input_lr) noexcept {
  HostStateGuard preserve;
  Ticket ticket;
  if (!trace.recording.load(std::memory_order_acquire)) return ticket;
  const uint64_t call_id = trace.attempts.fetch_add(1, std::memory_order_relaxed) + 1;
  if (call_id > trace.max_calls) {
    trace.limit_reached.store(true);
    trace.recording.store(false, std::memory_order_release);
    return ticket;
  }
  trace.admitted.fetch_add(1, std::memory_order_relaxed);
  trace.pending.fetch_add(1, std::memory_order_relaxed);
  ticket.previous_outer = current_outer_call;
  if (probe == Probe::OuterFrame) current_outer_call = call_id;
  ticket.entry = {call_id, current_outer_call, trace.Qpc(), input_r3, input_lr,
                  GetCurrentThreadId(), probe, true, false};
  ticket.valid = true;
  trace.Emit(ticket.entry);
  return ticket;
}

void Finish(const Ticket& ticket, uint64_t output_r3, uint64_t output_lr, bool unwinding) noexcept {
  if (!ticket.valid) return;
  HostStateGuard preserve;
  Record end = ticket.entry;
  end.qpc = trace.Qpc();
  end.r3 = output_r3;
  end.lr = output_lr;
  end.begin = false;
  end.unwinding = unwinding;
  trace.Emit(end);
  if (end.probe == Probe::OuterFrame) current_outer_call = ticket.previous_outer;
  trace.pending.fetch_sub(1, std::memory_order_relaxed);
}

}  // namespace

StartResult ConfigureFromEnvironment(const std::filesystem::path& workspace_root) noexcept {
  HostStateGuard preserve;
  try {
    std::lock_guard control(trace.control_mutex);
    if (trace.writer.joinable() || trace.pending.load() != 0) return StartResult::InvalidConfiguration;
    if (Environment(L"COD3_TIMING_TRACE") != L"1") return StartResult::Disabled;
    const auto raw_directory = Environment(L"COD3_TIMING_OUTPUT_DIR");
    if (raw_directory.empty()) return StartResult::InvalidConfiguration;
    const auto workspace = std::filesystem::canonical(workspace_root);
    auto directory = std::filesystem::path(raw_directory);
    if (directory.is_relative()) directory = workspace / directory;
    directory = std::filesystem::weakly_canonical(directory);
    if (!Inside(directory, workspace)) return StartResult::InvalidConfiguration;
    uint64_t max_calls = kDefaultMaxCalls;
    const auto raw_limit = Environment(L"COD3_TIMING_MAX_CALLS");
    if (!raw_limit.empty()) {
      max_calls = 0;
      for (wchar_t digit : raw_limit) {
        if (digit < L'0' || digit > L'9' || max_calls > kHardMaxCalls) return StartResult::InvalidConfiguration;
        max_calls = max_calls * 10 + static_cast<unsigned>(digit - L'0');
      }
      if (!max_calls || max_calls > kHardMaxCalls) return StartResult::InvalidConfiguration;
    }
    std::filesystem::create_directories(directory);
    directory = std::filesystem::canonical(directory);
    if (!Inside(directory, workspace)) return StartResult::InvalidConfiguration;
    LARGE_INTEGER frequency{}, start{};
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0 ||
        !QueryPerformanceCounter(&start) || start.QuadPart < 0) return StartResult::StartFailed;
    const auto stem = L"cod3-candidate-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
                      std::to_wstring(start.QuadPart);
    HANDLE file = INVALID_HANDLE_VALUE;
    std::filesystem::path output_path;
    for (unsigned suffix = 0; suffix < 16; ++suffix) {
      output_path = directory / (stem + L"-" + std::to_wstring(suffix) + L".ndjson");
      file = CreateFileW(output_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_NEW,
                         FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
      if (file != INVALID_HANDLE_VALUE || GetLastError() != ERROR_FILE_EXISTS) break;
    }
    if (file == INVALID_HANDLE_VALUE) return StartResult::OpenFailed;
    trace.file = file;
    trace.path = output_path;
    trace.max_calls = max_calls;
    trace.frequency = static_cast<uint64_t>(frequency.QuadPart);
    trace.start_qpc = static_cast<uint64_t>(start.QuadPart);
    trace.bytes_written = trace.head = trace.count = 0;
    trace.attempts = 0; trace.admitted = 0; trace.pending = 0;
    trace.queued = 0; trace.written = 0; trace.dropped = 0; trace.qpc_failures = 0;
    trace.limit_reached = false; trace.io_error = false; trace.stopping = false;
    Line metadata;
    metadata.Add("{\"kind\":\"metadata\",\"schema\":\"cod3-candidate-observation-v1\","
                 "\"capture_source\":\"native_hook_observation\",\"execution_kind_attested\":false,"
                 "\"gameplay_120fps_verified\":false,\"probe_semantics\":\"candidate_functions_only\","
                 "\"loaded_executable_verified_by_logger\":false,"
                 "\"expected_executable_sha256\":\"2944eec7d1231ad6798b5f9f8adf8855f5e489296b22eab45b27a577cee23692\","
                 "\"sdk_commit\":\"0c7b01a0ac0479801757507d80533f662fa0815d\","
                 "\"host_clock\":\"QueryPerformanceCounter\",\"host_qpc_frequency_hz\":");
    metadata.Number(trace.frequency);
    metadata.Add(",\"start_host_qpc\":"); metadata.Number(trace.start_qpc);
    metadata.Add(",\"max_calls\":"); metadata.Number(max_calls);
    metadata.Add(",\"queue_capacity_records\":"); metadata.Number(kQueueCapacity);
    metadata.Add(",\"max_file_bytes\":"); metadata.Number(kMaxBytes);
    metadata.Add(",\"r3_semantics\":\"raw_entry_or_exit_register; outer_frame_return_is_untyped\"}\n");
    if (!metadata.valid || !trace.Write(metadata.bytes.data(), metadata.used)) {
      CloseHandle(trace.file); trace.file = INVALID_HANDLE_VALUE;
      return StartResult::OpenFailed;
    }
    try {
      trace.writer_active.store(true, std::memory_order_release);
      trace.writer = std::thread([] { trace.Worker(); });
      trace.recording.store(true, std::memory_order_release);
    } catch (...) {
      trace.writer_active.store(false, std::memory_order_release);
      CloseHandle(trace.file); trace.file = INVALID_HANDLE_VALUE;
      return StartResult::StartFailed;
    }
    return StartResult::Recording;
  } catch (...) {
    return StartResult::InvalidConfiguration;
  }
}

void Shutdown() noexcept { trace.Stop(); }

Snapshot GetSnapshot() noexcept {
  return {trace.recording.load(), trace.limit_reached.load(), trace.io_error.load(),
          trace.admitted.load(), trace.pending.load(), trace.queued.load(), trace.written.load(),
          trace.dropped.load(), trace.qpc_failures.load()};
}

std::filesystem::path OutputPath() {
  std::lock_guard control(trace.control_mutex);
  return trace.path;
}

void Observe(Probe probe, PPCFunc& original, PPCContext& ctx, uint8_t* base) {
  if (!trace.recording.load(std::memory_order_acquire)) {
    original(ctx, base);
    return;
  }
  const Ticket ticket = Begin(probe, ctx.r3.u64, ctx.lr);
  try {
    original(ctx, base);
  } catch (...) {
    Finish(ticket, ctx.r3.u64, ctx.lr, true);
    throw;
  }
  Finish(ticket, ctx.r3.u64, ctx.lr, false);
}

}  // namespace cod3::timing
