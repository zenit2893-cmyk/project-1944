#include "cod3_pc_pch.h"
#include "cod3_coroutines.h"
#include <rex/hook.h>
#include <rex/logging.h>
#include <rex/system/user_module.h>
#include <rex/system/xex_module.h>
#include <rex/system/xthread.h>
#include <windows.h>

REX_EXTERN(__imp__sub_824A6150);
REX_EXTERN(__imp__sub_823C0B98);
REX_EXTERN(__imp__sub_824A5D70);
REX_EXTERN(sub_820A4028);

namespace {
void SchedulerJump(uint32_t buffer, int value) {
  // This definition must be compiled in the MAIN image so its inline map is
  // exactly the one used by the generated scheduler's native setjmp.
  ppc_longjmp(buffer, value);
}
void CompleteReturnedClosure(uint32_t node, PPCContext& ctx, uint8_t* base) {
  // Original initial-call continuation 824A62AC..824A62B8 marks bit3 via this
  // guest helper. A resumed closure returning to that old native frame needs
  // the same persistent effect before the CURRENT scheduler landing.
  ctx.r3.u64 = node + 16;
  ctx.r4.u64 = 3;
  sub_820A4028(ctx, base);
}
PPCFunc* OriginalUnload() {
  for (const auto* name : {L"rexruntimerd.dll", L"rexruntime.dll", L"rexruntimed.dll"}) {
    if (auto library = GetModuleHandleW(name)) {
      if (auto symbol = GetProcAddress(library, "__imp__XexUnloadImage")) {
        return reinterpret_cast<PPCFunc*>(symbol);
      }
    }
  }
  throw std::runtime_error("Original ReXGlue XexUnloadImage export is unavailable");
}
rex::thread::Fiber* SchedulerRoot() {
  // XThread::Execute converts the host thread once and owns this root for the
  // lifetime of the guest thread. Passing the owner handle lets the bridge
  // use the SDK Fiber::SwitchTo path, which updates ReXGlue's TLS marker.
  if (rex::system::XThread::IsInThread()) {
    auto* thread = rex::system::XThread::GetCurrentThread();
    return thread->main_fiber();
  }
  return nullptr;
}
}

REX_HOOK_RAW(sub_824A6150) {
  cod3::coroutines::ResumeScope scope(ctx, base, ctx.r3.u32, SchedulerJump,
                                     CompleteReturnedClosure, SchedulerRoot());
  __imp__sub_824A6150(ctx, base);
}
REX_HOOK_RAW(sub_823C0B98) {
  if (uint32_t(ctx.lr) != 0x824A62A8) {
    __imp__sub_823C0B98(ctx, base);
    return;
  }
  cod3::coroutines::StartClosure(ctx, base, __imp__sub_823C0B98);
}
REX_HOOK_RAW(sub_824A5D70) {
  cod3::coroutines::Destroy(ctx.r4.u32);
  __imp__sub_824A5D70(ctx, base);
}
REX_HOOK_RAW(__imp__XexUnloadImage) {
  uint32_t module_base = 0;
  {
    auto module = rex::system::XModule::GetFromHModule(
        REX_KERNEL_STATE(), REX_KERNEL_MEMORY()->TranslateVirtual(ctx.r3.u32));
    if (module && module->module_type() == rex::system::XModule::ModuleType::kUserModule) {
      auto* user = static_cast<rex::system::UserModule*>(module.get());
      if (user->is_dll_module()) module_base = user->xex_module()->base_address();
    }
  }
  if (module_base) {
    // A refusal here used to propagate out of guest code and silently end the
    // guest thread, which looked like the game quitting during the end-of-level
    // save. Report it and still run the original unload.
    try {
      cod3::coroutines::BeforeModuleUnload(module_base);
    } catch (const std::exception& error) {
      REXLOG_ERROR("[cod3-coroutines] module 0x{:08X} unload cleanup failed: {}", module_base,
                   error.what());
    }
  }
  static auto* original = OriginalUnload();
  original(ctx, base);
}

// The no-argument mid-ASM hook gets the exact current context from ResumeScope.
// The game has already performed its asymmetric 400-byte restore at this site.
void Cod3CoroutineResumeRestored() {
  cod3::coroutines::ResumeRestored();
}
