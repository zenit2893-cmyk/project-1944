#pragma once
#include <cstddef>
#include <cstdint>
#include <rex/ppc/context.h>

namespace rex::thread {
struct Fiber;
}

#if defined(COD3_COROUTINES_BUILD)
#define COD3_CORO_API __declspec(dllexport)
#else
#define COD3_CORO_API __declspec(dllimport)
#endif

namespace cod3::coroutines {
using GuestFunction = void(PPCContext&, uint8_t*);
using SchedulerJump = void(uint32_t, int);
using ReturnedClosure = void(uint32_t, PPCContext&, uint8_t*);
inline constexpr uint32_t kSchedulerBuffer = 0x829EB1C0;

// One active scheduler invocation on one host thread. A node is identified by
// its real guest address; its original memory and flag updates remain in guest code.
class COD3_CORO_API ResumeScope {
 public:
  ResumeScope(PPCContext& ctx, uint8_t* base, uint32_t node, SchedulerJump* jump,
              ReturnedClosure* complete_returned_closure = nullptr,
              rex::thread::Fiber* scheduler_root = nullptr);
  ~ResumeScope();
  ResumeScope(const ResumeScope&) = delete;
  ResumeScope& operator=(const ResumeScope&) = delete;
 private:
  void* frame_ = nullptr;
};

COD3_CORO_API void NoteSetjmp(uint32_t buffer);
// Returns false when the generated native longjmp is valid on the current fiber.
// The supported scheduler transfer does not return on its original call stack.
COD3_CORO_API bool InterceptLongjmp(uint32_t buffer, int value);
COD3_CORO_API void StartClosure(PPCContext& ctx, uint8_t* base, GuestFunction* original);
// Called AFTER the original 400-byte guest restore and SP += 400, at its blr.
[[noreturn]] COD3_CORO_API void ResumeRestored();
// Calls the original capture/save/guest-copy/wait implementation. A scheduler
// transfer unwinds back here inside the same child fiber before it is parked.
COD3_CORO_API void Capture(PPCContext& ctx, uint8_t* base, GuestFunction* original,
                           uint32_t guest_module_base);
COD3_CORO_API void Destroy(uint32_t node);
COD3_CORO_API void BeforeModuleUnload(uint32_t guest_module_base);
COD3_CORO_API std::size_t ParkedCount();
COD3_CORO_API void ReleaseThread();
}  // namespace cod3::coroutines
