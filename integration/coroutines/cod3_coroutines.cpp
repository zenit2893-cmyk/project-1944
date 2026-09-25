#include "cod3_coroutines.h"
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <csetjmp>
#include <atomic>
#include <exception>
#include <map>
#include <memory>
#include <mutex>
#include <rex/logging.h>
#include <rex/thread/fiber.h>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace cod3::coroutines {
namespace {
enum class Phase { Created, Running, Parked, Returned, Exited, Cancelled, Failed };
struct State;
struct Coroutine;
struct Frame {
  State* state;
  PPCContext* ctx;
  uint8_t* base;
  uint32_t node;
  SchedulerJump* jump;
  ReturnedClosure* returned;
};
struct Coroutine {
  State* state = nullptr;
  uint32_t node = 0;
  rex::thread::Fiber* fiber = nullptr;
  GuestFunction* original = nullptr;
  PPCContext* ctx = nullptr;
  uint8_t* base = nullptr;
  std::atomic<Phase> phase{Phase::Created};
  std::jmp_buf terminal;
  std::jmp_buf* capture = nullptr;
  std::set<uint32_t> guest_modules;
  PPCContext parked_context{};
  int jump_value = 0;
  bool cancel = false;
  // The guest FPSCR guest bits live in PPCContext, while the host exception
  // masks/status are per native execution context. Capture the scheduler's
  // host policy before every switch so returning to a plain SDK root cannot
  // inherit child status bits. Guest bits are re-applied from ctx after the
  // switch and remain observable to generated code.
  uint32_t scheduler_host_fpscr = 0;
  bool scheduler_host_fpscr_valid = false;
  std::exception_ptr failure;
};
struct State {
  ~State();
  DWORD thread_id = GetCurrentThreadId();
  rex::thread::Fiber* scheduler = nullptr;
  rex::thread::Fiber* scheduler_hint = nullptr;
  bool converted = false;
  bool scheduler_current = false;
  Coroutine* active = nullptr;
  Frame* frame = nullptr;
  std::map<uint32_t, std::unique_ptr<Coroutine>> nodes;
  std::map<uint32_t, Coroutine*> buffer_owners;
};
std::mutex registry_mutex;
std::set<State*> registry;
thread_local std::unique_ptr<State> local;
State::~State() {
  std::lock_guard lock(registry_mutex);
  registry.erase(this);
  for (auto& [node, c] : nodes) {
    if (c->fiber && active != c.get()) c->fiber->Destroy();
  }
  if (converted && scheduler) {
    scheduler->Destroy();
  }
}

[[noreturn]] void Fail(const char* what) {
  // The bridge refuses unsupported transfers instead of jumping into a foreign
  // stack. Record the reason: the guest thread dies quietly otherwise, which
  // looks like the game exiting on its own.
  REXLOG_ERROR("[cod3-coroutines] refused: {}", what);
  throw std::runtime_error(std::string("CoD3 coroutine bridge: ") + what);
}
State& Current() {
  if (!local) {
    local = std::make_unique<State>();
    std::lock_guard lock(registry_mutex);
    registry.insert(local.get());
  }
  return *local;
}
void SyncGuestFP(PPCContext& ctx) {
  // The shared context carries guest rounding/flush bits. Keep the current
  // native policy (exception masks/status) when no scheduler snapshot exists.
  ctx.fpscr.restoreGuestBits(ctx.fpscr.csr);
}
void SyncGuestFP(PPCContext& ctx, uint32_t host_csr) {
  // Re-apply the scheduler's complete native policy while retaining the
  // guest-owned bits currently present in the shared PPCContext.
  ctx.fpscr.csr = (host_csr & ~PPCFPSCRRegister::GuestMask) |
                  (ctx.fpscr.csr & PPCFPSCRRegister::GuestMask);
  ctx.fpscr.setcsr(ctx.fpscr.csr);
}
void EnsureScheduler(State& s) {
  if (s.scheduler) {
    if (s.scheduler_hint && s.scheduler_hint != s.scheduler) {
      Fail("scheduler root changed during a live bridge");
    }
    // Fiber::SwitchTo updates the SDK's current-fiber marker. The bridge
    // reaches this function only on the scheduler side; a raw native fiber
    // supplied by an external caller cannot satisfy the SDK contract.
    if (!IsThreadAFiber()) {
      Fail("scheduler called from an unexpected fiber");
    }
    return;
  }
  if (s.scheduler_hint) {
    if (!IsThreadAFiber()) {
      Fail("SDK scheduler root was supplied before thread fiber conversion");
    }
    // ReXGlue's XThread owns this root. Borrow it and leave its lifetime and
    // TLS current-fiber marker untouched when this bridge is released.
    s.scheduler = s.scheduler_hint;
    s.converted = false;
  } else {
    if (IsThreadAFiber()) {
      Fail("an existing SDK root fiber must be passed to ResumeScope");
    }
    s.scheduler = rex::thread::Fiber::ConvertCurrentThread();
    s.converted = s.scheduler != nullptr;
  }
  if (!s.scheduler) Fail("rex::thread::Fiber::ConvertCurrentThread failed");
  s.scheduler_current = true;
}
void SwitchToScheduler(Coroutine& c) {
  auto& s = *c.state;
  if (s.scheduler_current) Fail("scheduler transfer attempted from the scheduler fiber");
  c.parked_context = *c.ctx;
  s.active = nullptr;
  rex::thread::Fiber::SwitchTo(s.scheduler);
  // This activation sees guest registers restored by the original game stream.
  if (s.active != &c) Fail("resumed without the owning coroutine active");
  if (c.scheduler_host_fpscr_valid) {
    SyncGuestFP(*c.ctx, c.scheduler_host_fpscr);
  } else {
    SyncGuestFP(*c.ctx);
  }
}
void WINAPI FiberMain(void* parameter) {
  auto& c = *static_cast<Coroutine*>(parameter);
  try {
    if (c.scheduler_host_fpscr_valid) {
      SyncGuestFP(*c.ctx, c.scheduler_host_fpscr);
    } else {
      SyncGuestFP(*c.ctx);
    }
    const int terminal_reason = setjmp(c.terminal);
    if (terminal_reason == 0) {
      c.original(*c.ctx, c.base);
      c.phase = Phase::Returned;
    } else {
      c.phase = terminal_reason == 2 ? Phase::Cancelled : Phase::Exited;
    }
  } catch (...) {
    c.failure = std::current_exception();
    c.phase = Phase::Failed;
  }
  SwitchToScheduler(c);
  // Only parked capture frames may ever be resumed.
  std::terminate();
}
void DeleteNativeFiber(Coroutine& c) {
  if (c.fiber) {
    if (c.state->active == &c) Fail("attempt to delete the running fiber");
    c.fiber->Destroy();
    c.fiber = nullptr;
  }
}
void Activate(Coroutine& c) {
  auto& s = *c.state;
  if (s.active || !s.scheduler || !IsThreadAFiber() || !s.scheduler_current) {
    Fail("cross-thread or nested coroutine activation is unsupported");
  }
  if (c.phase != Phase::Created && c.phase != Phase::Parked) Fail("resuming a completed task");
  c.scheduler_host_fpscr = c.ctx->fpscr.getcsr();
  c.scheduler_host_fpscr_valid = true;
  c.phase = Phase::Running;
  s.active = &c;
  s.scheduler_current = false;
  rex::thread::Fiber::SwitchTo(c.fiber);
  s.scheduler_current = true;
  // Fiber::SwitchTo updates the SDK TLS marker as well as the native fiber.
  // Use the saved root policy and the child-produced guest bits. This keeps
  // both a ReXGlue-owned plain root and a bridge-owned root deterministic.
  SyncGuestFP(*c.ctx, c.scheduler_host_fpscr);
  if (c.phase == Phase::Failed) {
    DeleteNativeFiber(c);
    std::rethrow_exception(c.failure);
  }
}
[[noreturn]] void SchedulerTransfer(State& s, Coroutine& c) {
  if (!s.frame || s.frame->node != c.node || !s.frame->jump) {
    Fail("no matching live scheduler landing for transfer");
  }
  if (c.phase == Phase::Exited || c.phase == Phase::Cancelled) DeleteNativeFiber(c);
  s.frame->jump(kSchedulerBuffer, c.jump_value);
  Fail("scheduler longjmp callback returned");
}
void CancelAndErase(State& s, uint32_t node) {
  const auto found = s.nodes.find(node);
  if (found == s.nodes.end()) return;
  auto& c = *found->second;
  if (s.active == &c || c.phase == Phase::Running) Fail("destruction of a running task");
  if (c.phase == Phase::Parked) {
    EnsureScheduler(s);
    const PPCContext scheduler_context = *c.ctx;
    *c.ctx = c.parked_context;
    c.cancel = true;
    Activate(c);
    *c.ctx = scheduler_context;
    SyncGuestFP(*c.ctx);
    if (c.phase != Phase::Cancelled) Fail("parked task failed to cancel cooperatively");
  }
  DeleteNativeFiber(c);
  for (auto it = s.buffer_owners.begin(); it != s.buffer_owners.end();) {
    if (it->second == &c) it = s.buffer_owners.erase(it);
    else ++it;
  }
  {
    std::lock_guard lock(registry_mutex);
    s.nodes.erase(found);
  }
}
}  // namespace

ResumeScope::ResumeScope(PPCContext& ctx, uint8_t* base, uint32_t node, SchedulerJump* jump,
                         ReturnedClosure* returned, rex::thread::Fiber* scheduler_root) {
  auto& s = Current();
  if (s.active || s.frame) Fail("nested guest scheduler invocation is unsupported");
  if (!node || !jump) Fail("invalid scheduler node or callback");
  if (scheduler_root) {
    if (s.scheduler && s.scheduler != scheduler_root) {
      Fail("scheduler root changed during a live bridge");
    }
    s.scheduler_hint = scheduler_root;
  }
  auto* frame = new Frame{&s, &ctx, base, node, jump, returned};
  s.frame = frame;
  frame_ = frame;
}
ResumeScope::~ResumeScope() {
  auto* frame = static_cast<Frame*>(frame_);
  if (frame) {
    frame->state->frame = nullptr;
    delete frame;
  }
}
void NoteSetjmp(uint32_t buffer) {
  auto& s = Current();
  s.buffer_owners[buffer] = s.active;
}
bool InterceptLongjmp(uint32_t buffer, int value) {
  auto& s = Current();
  const auto owner = s.buffer_owners.find(buffer);
  if (owner == s.buffer_owners.end()) {
    if (s.active) Fail("longjmp to an untracked buffer from a coroutine");
    return false;
  }
  if (owner->second == s.active) return false;
  if (!s.active || owner->second || buffer != kSchedulerBuffer || !s.frame) {
    Fail("unsupported cross-fiber longjmp target");
  }
  auto& c = *s.active;
  c.jump_value = value;
  if (c.capture) longjmp(*c.capture, 1);
  longjmp(c.terminal, 1);
}
void StartClosure(PPCContext& ctx, uint8_t* base, GuestFunction* original) {
  auto& s = Current();
  if (!s.frame) { original(ctx, base); return; }
  if (s.frame->ctx != &ctx || s.frame->base != base) Fail("PPCContext identity changed");
  EnsureScheduler(s);
  if (s.nodes.contains(s.frame->node)) Fail("duplicate initial closure for an existing node");
  auto c = std::make_unique<Coroutine>();
  c->state = &s;
  c->node = s.frame->node;
  c->ctx = &ctx;
  c->base = base;
  c->original = original;
  c->fiber = rex::thread::Fiber::Create(8 * 1024 * 1024, FiberMain, c.get());
  if (!c->fiber) Fail("CreateFiberEx failed");
  auto* raw = c.get();
  {
    std::lock_guard lock(registry_mutex);
    s.nodes.emplace(c->node, std::move(c));
  }
  Activate(*raw);
  if (raw->phase == Phase::Returned) { DeleteNativeFiber(*raw); return; }
  SchedulerTransfer(s, *raw);
}
[[noreturn]] void ResumeRestored() {
  auto& s = Current();
  if (!s.frame) Fail("custom guest blr has no scheduler frame");
  const auto found = s.nodes.find(s.frame->node);
  if (found == s.nodes.end()) Fail("custom guest blr has no parked native continuation");
  auto& c = *found->second;
  if (c.ctx != s.frame->ctx || c.base != s.frame->base) Fail("PPCContext identity changed at resume");
  EnsureScheduler(s);
  Activate(c);
  if (c.phase == Phase::Returned) {
    // A resumed closure eventually returns to its original INITIAL call site.
    // Its original persistent completion effect (bit 3 via the guest setter)
    // must occur before transferring to the current scheduler landing.
    if (!s.frame->returned) Fail("no original completion adapter for a returned closure");
    s.frame->returned(c.node, *c.ctx, c.base);
    DeleteNativeFiber(c);
  }
  SchedulerTransfer(s, c);
}
void Capture(PPCContext& ctx, uint8_t* base, GuestFunction* original, uint32_t module) {
  auto& s = Current();
  auto* c = s.active;
  if (!c) Fail("guest capture called outside a native coroutine");
  if (&ctx != c->ctx || base != c->base) Fail("capture changed shared context identity");
  if (c->capture) Fail("nested guest capture is unsupported");
  {
    std::lock_guard lock(registry_mutex);
    c->guest_modules.insert(module);
  }
  std::jmp_buf capture_landing;
  c->capture = &capture_landing;
  const int transferred = setjmp(capture_landing);
  if (transferred == 0) {
    try { original(ctx, base); }
    catch (...) { c->capture = nullptr; throw; }
    c->capture = nullptr;
    Fail("original capture returned without a scheduler transfer");
  }
  c->capture = nullptr;
  c->phase = Phase::Parked;
  SwitchToScheduler(*c);
  if (c->cancel) longjmp(c->terminal, 2);
  // ORIGINAL resume code has already restored the exact guest state. In
  // particular, do not restore a guessed full context, CR, VMX or old FPSCR.
}
void Destroy(uint32_t node) { CancelAndErase(Current(), node); }
void BeforeModuleUnload(uint32_t module) {
  auto& s = Current();
  REXLOG_INFO("[cod3-coroutines] module 0x{:08X} unloading: {} live tasks, {} parked", module,
              s.nodes.size(), ParkedCount());
  std::vector<uint32_t> own;
  {
    std::lock_guard lock(registry_mutex);
    for (const auto* state : registry) {
      for (const auto& [node, coroutine] : state->nodes) {
        if (!coroutine->guest_modules.contains(module)) continue;
        if (state != &s) Fail("mission unload has continuations owned by another thread");
        if (coroutine->phase == Phase::Running) Fail("mission unload contains running code");
        own.push_back(node);
      }
    }
  }
  for (const auto node : own) CancelAndErase(s, node);
}
std::size_t ParkedCount() {
  std::size_t count = 0;
  for (const auto& [node, c] : Current().nodes) if (c->phase == Phase::Parked) ++count;
  return count;
}
void ReleaseThread() {
  if (!local) return;
  auto& s = *local;
  if (s.active || s.frame || (s.scheduler && !s.scheduler_current)) {
    Fail("thread release during coroutine execution");
  }
  std::vector<uint32_t> nodes;
  for (const auto& [node, c] : s.nodes) nodes.push_back(node);
  for (auto node : nodes) CancelAndErase(s, node);
  if (s.converted) {
    if (!s.scheduler || !s.scheduler_current) {
      Fail("bridge-owned scheduler fiber is not current at release");
    }
    s.scheduler->Destroy();
    s.scheduler = nullptr;
  }
  {
    std::lock_guard lock(registry_mutex);
    registry.erase(&s);
  }
  local.reset();
}
}  // namespace cod3::coroutines
