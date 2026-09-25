#pragma once
#include <cstdint>
#include <cod3_coroutines.h>
#include "register_access.h"
#include "vectors.hpp"

namespace cod3::coroutine_tests {
struct Node {
  uint32_t key = 0;
  size_t vector = 0;
  int saves = 0, resumes = 0, capture_cleanup = 0, script_cleanup = 0;
  int fallthrough = 0, done = 0, completion_callbacks = 0;
  bool exit_instead = false, bad_cross_fiber_jump = false;
  bool state_ok = true, identity_ok = true, fp_ok = true, native_locals_ok = true;
  bool host_fp_ok = true;
  PPCContext* original_context = nullptr;
  uint8_t frame[400]{};
};
void PutState(PPCContext& ctx, const coroutine_reference_vectors::RegisterState& state);
bool SameState(PPCContext& ctx, const coroutine_reference_vectors::RegisterState& state);
using Transfer = void(uint32_t, int);
extern "C" __declspec(dllexport) void FixtureClosure(PPCContext&, uint8_t*);
extern "C" __declspec(dllexport) void FixtureSetTransfer(Transfer* transfer);
}
