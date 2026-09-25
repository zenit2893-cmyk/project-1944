#pragma once

#include <cstdint>
#include <filesystem>

#include <rex/ppc/func.h>

namespace cod3::timing {

enum class Probe : uint8_t { MsNormalization, OuterFrame };
enum class StartResult { Disabled, Recording, InvalidConfiguration, OpenFailed, StartFailed };

struct Snapshot {
  bool recording;
  bool limit_reached;
  bool io_error;
  uint64_t admitted_calls;
  uint64_t pending_calls;
  uint64_t queued_records;
  uint64_t written_records;
  uint64_t dropped_records;
  uint64_t qpc_failures;
};

// Call before starting guest threads. Both env variables are required:
// COD3_TIMING_TRACE=1 and COD3_TIMING_OUTPUT_DIR=<directory inside workspace>.
// Optional COD3_TIMING_MAX_CALLS is an integer in [1, 65536], default 32768.
// Opening failures leave the hooks in passthrough mode. No console logging.
StartResult ConfigureFromEnvironment(const std::filesystem::path& workspace_root) noexcept;

// Call after guest threads have joined. Flushes queued records and writes a
// footer. Calling while a hooked function is pending is safe but marks the
// capture incomplete; it does not wait for or interrupt the guest function.
void Shutdown() noexcept;
Snapshot GetSnapshot() noexcept;
std::filesystem::path OutputPath();

// Exact raw PPC ABI. Reads r3 and lr only, forwards ctx and base unmodified to
// original exactly once, and retains all of the original function's effects.
void Observe(Probe probe, PPCFunc& original, PPCContext& ctx, uint8_t* base);

}  // namespace cod3::timing
