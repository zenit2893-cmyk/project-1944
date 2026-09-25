#include "fixture.h"
#include <cstring>
#include <stdexcept>

namespace cod3::coroutine_tests {
namespace {
Transfer* transfer = nullptr;
thread_local uint32_t tls_marker = 0xC03F1B3;
void SaveAndWait(PPCContext&, uint8_t* base) {
  auto& node = *reinterpret_cast<Node*>(base);
  struct CaptureCleanup { Node& node; ~CaptureCleanup() { ++node.capture_cleanup; } } cleanup{node};
  // Synthetic ORIGINAL guest-body stand-in: all persistent effects happen
  // before the transfer; the bridge must call this body and not fake its result.
  std::memcpy(node.frame, coroutine_reference_vectors::kVectors[node.vector].frame, 400);
  ++node.saves;
  transfer(node.bad_cross_fiber_jump ? 0x12345678 : coroutines::kSchedulerBuffer, 0);
  ++node.fallthrough;
}
}
void PutState(PPCContext& ctx, const coroutine_reference_vectors::RegisterState& state) {
  for (size_t i=0; i<32; ++i) {
    (ctx.*r_members[i]).u64 = state.gpr[i];
    (ctx.*f_members[i]).u64 = state.fpr_bits[i];
  }
  for (size_t i=0; i<128; ++i) std::memcpy(&(ctx.*v_members[i]), state.vr_bits[i], 16);
  for (size_t i=0; i<8; ++i) (ctx.*cr_members[i]).set_raw((state.cr >> ((7-i)*4)) & 15);
  ctx.lr = state.lr;
  ctx.ctr.u64 = state.ctr;
  ctx.xer.so = (state.xer >> 31) & 1;
  ctx.xer.ov = (state.xer >> 30) & 1;
  ctx.xer.ca = (state.xer >> 29) & 1;
  // The original generated lfd resume stream disables flushing. Keep host
  // exception policy and use the vector's rounding bits as an independent input.
  ctx.fpscr.csr = (ctx.fpscr.getcsr() & ~PPCFPSCRRegister::GuestMask) |
                  (state.fpscr & PPCFPSCRRegister::RoundMaskVal);
}
bool SameState(PPCContext& ctx, const coroutine_reference_vectors::RegisterState& state) {
  for (size_t i=0; i<32; ++i) {
    if ((ctx.*r_members[i]).u64 != state.gpr[i] || (ctx.*f_members[i]).u64 != state.fpr_bits[i]) return false;
  }
  for (size_t i=0; i<128; ++i) if (std::memcmp(&(ctx.*v_members[i]), state.vr_bits[i], 16)) return false;
  for (size_t i=0; i<8; ++i) if ((ctx.*cr_members[i]).raw() != ((state.cr >> ((7-i)*4)) & 15)) return false;
  return ctx.lr == state.lr && ctx.ctr.u64 == state.ctr &&
         ctx.xer.so == ((state.xer >> 31)&1) && ctx.xer.ov == ((state.xer >> 30)&1) &&
         ctx.xer.ca == ((state.xer >> 29)&1) &&
         (ctx.fpscr.csr & PPCFPSCRRegister::GuestMask) == (state.fpscr & PPCFPSCRRegister::RoundMaskVal);
}
extern "C" __declspec(dllexport) void FixtureSetTransfer(Transfer* value) { transfer = value; }
extern "C" __declspec(dllexport) void FixtureClosure(PPCContext& ctx, uint8_t* base) {
  auto& node = *reinterpret_cast<Node*>(base);
  struct ScriptCleanup { Node& node; ~ScriptCleanup() { ++node.script_cleanup; } } cleanup{node};
  volatile uint64_t native_local = 0xABCDEF1234567890ull + node.vector;
  for (int iteration = 0; iteration < 2; ++iteration) {
    ctx.fpscr.enableFlushModeUnconditional();
    // A sticky MXCSR status bit belongs to the host execution context, not to
    // the guest FPSCR payload. The production bridge must restore the root's
    // host policy after a child yield while preserving guest-owned bits.
    ctx.fpscr.setcsr(ctx.fpscr.getcsr() ^ 0x20u);
    coroutines::Capture(ctx, base, SaveAndWait, 0x89000000);
    ++node.resumes;
    node.identity_ok &= &ctx == node.original_context && tls_marker == 0xC03F1B3;
    node.native_locals_ok &= native_local == 0xABCDEF1234567890ull + node.vector;
    node.state_ok &= SameState(ctx, coroutine_reference_vectors::kVectors[node.vector].restore_expected);
    node.fp_ok &= (ctx.fpscr.getcsr() & PPCFPSCRRegister::GuestMask) ==
                  (ctx.fpscr.csr & PPCFPSCRRegister::GuestMask);
  }
  if (node.exit_instead) {
    node.done = 1; // Synthetic original guest completion effect before nonlocal exit.
    transfer(coroutines::kSchedulerBuffer, 0);
    ++node.fallthrough;
  }
}
}
