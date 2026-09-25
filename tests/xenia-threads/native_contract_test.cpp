// Bounded native contract checks for the ReXGlue primitives used by the
// Xenia-derived Xbox 360 kernel layer. This test intentionally does not load
// an XEX, enter guest code, or link any Xenia emulator/JIT component.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <rex/thread.h>
#include <rex/thread/fiber.h>

namespace {

using namespace std::chrono_literals;
using rex::thread::Event;
using rex::thread::Fiber;
using rex::thread::HighResolutionTimer;
using rex::thread::Semaphore;
using rex::thread::Thread;
using rex::thread::Timer;
using rex::thread::Wait;
using rex::thread::WaitAll;
using rex::thread::WaitAny;
using rex::thread::WaitResult;

struct TestState {
  uint32_t passed = 0;
  uint32_t failed = 0;
};

bool Check(TestState& state, bool condition, const char* name) {
  if (condition) {
    ++state.passed;
    std::cout << "PASS " << name << '\n';
    return true;
  }
  ++state.failed;
  std::cout << "FAIL " << name << '\n';
  return false;
}

template <typename Predicate>
bool WaitUntil(Predicate&& predicate, std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!predicate()) {
    if (std::chrono::steady_clock::now() >= deadline) {
      return false;
    }
    std::this_thread::yield();
  }
  return true;
}

bool TestSuspendedThread(TestState& state) {
  Thread::CreationParameters params;
  params.create_suspended = true;
  std::atomic<uint32_t> entered{0};
  auto thread = Thread::Create(params, [&] { entered.store(1, std::memory_order_release); });
  if (!Check(state, thread != nullptr, "thread creation with suspended flag")) {
    return false;
  }

  const bool held = Wait(thread.get(), false, 40ms) == WaitResult::kTimeout &&
                    entered.load(std::memory_order_acquire) == 0;
  Check(state, held, "suspended thread stays stopped before Resume");

  const bool resumed = thread->Resume();
  Check(state, resumed, "Resume accepts the suspended thread");
  const bool exited = Wait(thread.get(), false, 1000ms) == WaitResult::kSuccess;
  Check(state, exited && entered.load(std::memory_order_acquire) == 1,
        "resumed thread runs and becomes a signaled wait object");
  return held && resumed && exited;
}

bool TestManualAndAutoEvents(TestState& state) {
  auto manual = Event::CreateManualResetEvent(false);
  auto automatic = Event::CreateAutoResetEvent(false);
  if (!Check(state, manual != nullptr && automatic != nullptr, "event creation")) {
    return false;
  }

  std::atomic<uint32_t> manual_started{0};
  std::atomic<uint32_t> manual_woke{0};
  std::vector<std::unique_ptr<Thread>> manual_threads;
  for (uint32_t i = 0; i < 3; ++i) {
    manual_threads.emplace_back(Thread::Create({}, [&] {
      manual_started.fetch_add(1, std::memory_order_release);
      if (Wait(manual.get(), false, 1500ms) == WaitResult::kSuccess) {
        manual_woke.fetch_add(1, std::memory_order_release);
      }
    }));
  }
  bool manual_created = manual_threads.size() == 3;
  Check(state, manual_created, "three manual-reset waiter threads created");
  const bool manual_ready = WaitUntil(
      [&] { return manual_started.load(std::memory_order_acquire) == 3; }, 1000ms);
  Check(state, manual_ready, "manual-reset waiters reached their waits");

  manual->Set();
  std::vector<rex::thread::WaitHandle*> manual_handles;
  for (auto& thread : manual_threads) manual_handles.push_back(thread.get());
  const bool all_woke = WaitAll(manual_handles, false, 2000ms) == WaitResult::kSuccess &&
                        manual_woke.load(std::memory_order_acquire) == 3;
  Check(state, all_woke, "manual-reset event releases all waiters");
  const bool remains_set = Wait(manual.get(), false, 0ms) == WaitResult::kSuccess;
  Check(state, remains_set, "manual-reset event remains signaled until Reset");
  manual->Reset();
  Check(state, Wait(manual.get(), false, 0ms) == WaitResult::kTimeout,
        "manual-reset event Reset clears its state");

  std::atomic<uint32_t> auto_started{0};
  std::atomic<uint32_t> auto_woke{0};
  std::vector<std::unique_ptr<Thread>> auto_threads;
  for (uint32_t i = 0; i < 2; ++i) {
    auto_threads.emplace_back(Thread::Create({}, [&] {
      auto_started.fetch_add(1, std::memory_order_release);
      if (Wait(automatic.get(), false, 1500ms) == WaitResult::kSuccess) {
        auto_woke.fetch_add(1, std::memory_order_release);
      }
    }));
  }
  const bool auto_created = auto_threads.size() == 2;
  Check(state, auto_created, "two auto-reset waiter threads created");
  const bool auto_ready = WaitUntil(
      [&] { return auto_started.load(std::memory_order_acquire) == 2; }, 1000ms);
  Check(state, auto_ready, "auto-reset waiters reached their waits");

  automatic->Set();
  const bool one_woke = WaitUntil(
      [&] { return auto_woke.load(std::memory_order_acquire) == 1; }, 1000ms);
  Check(state, one_woke, "one auto-reset Set releases exactly one waiter");
  const bool no_extra_wake = auto_woke.load(std::memory_order_acquire) == 1;
  Check(state, no_extra_wake, "auto-reset signal is consumed by one waiter");

  automatic->Set();
  std::vector<rex::thread::WaitHandle*> auto_handles;
  for (auto& thread : auto_threads) auto_handles.push_back(thread.get());
  const bool both_exited = WaitAll(auto_handles, false, 2000ms) == WaitResult::kSuccess &&
                           auto_woke.load(std::memory_order_acquire) == 2;
  Check(state, both_exited, "second auto-reset Set releases the remaining waiter");
  return manual_created && manual_ready && all_woke && remains_set && auto_created &&
         auto_ready && one_woke && no_extra_wake && both_exited;
}

bool TestWaitMultipleAndSemaphore(TestState& state) {
  auto first = Event::CreateManualResetEvent(false);
  auto second = Event::CreateManualResetEvent(false);
  auto third = Event::CreateManualResetEvent(false);
  if (!Check(state, first != nullptr && second != nullptr && third != nullptr,
             "manual events for multi-wait")) {
    return false;
  }

  second->Set();
  std::vector<rex::thread::WaitHandle*> handles = {first.get(), second.get(), third.get()};
  const auto any = WaitAny(handles, false, 100ms);
  const bool any_ok = any.first == WaitResult::kSuccess && any.second == 1;
  Check(state, any_ok, "WaitAny reports the signaled event index");

  second->Reset();
  first->Set();
  second->Set();
  third->Set();
  const bool all_ok = WaitAll(handles, false, 100ms) == WaitResult::kSuccess;
  Check(state, all_ok, "WaitAll waits for every event");

  auto semaphore = Semaphore::Create(0, 3);
  if (!Check(state, semaphore != nullptr, "semaphore creation")) {
    return false;
  }
  const bool empty = Wait(semaphore.get(), false, 0ms) == WaitResult::kTimeout;
  Check(state, empty, "empty semaphore is nonsignaled");

  int previous = -1;
  const bool released = semaphore->Release(2, &previous) && previous == 0;
  Check(state, released, "semaphore Release reports previous count");
  const bool consumed = Wait(semaphore.get(), false, 0ms) == WaitResult::kSuccess &&
                        Wait(semaphore.get(), false, 0ms) == WaitResult::kSuccess &&
                        Wait(semaphore.get(), false, 0ms) == WaitResult::kTimeout;
  Check(state, consumed, "semaphore waits consume exactly the released permits");

  previous = -1;
  const bool refilled = semaphore->Release(3, &previous) && previous == 0;
  Check(state, refilled, "semaphore can be refilled to its limit");
  previous = -7;
  const bool over_limit = !semaphore->Release(1, &previous) && previous == -7;
  Check(state, over_limit, "semaphore rejects an over-limit release");
  return any_ok && all_ok && empty && released && consumed && refilled && over_limit;
}

bool TestAlertableApc(TestState& state) {
  auto ready = Event::CreateManualResetEvent(false);
  auto nonalertable_done = Event::CreateManualResetEvent(false);
  auto proceed = Event::CreateManualResetEvent(false);
  auto done = Event::CreateManualResetEvent(false);
  auto blocked = Event::CreateManualResetEvent(false);
  if (!Check(state, ready != nullptr && nonalertable_done != nullptr && proceed != nullptr &&
                 done != nullptr && blocked != nullptr,
             "APC contract events created")) {
    return false;
  }

  std::atomic<uint32_t> callback_count{0};
  std::atomic<uint32_t> callback_thread_id{0};
  std::atomic<int32_t> alert_result{-1};
  auto worker = Thread::Create({}, [&] {
    ready->Set();
    const auto nonalertable = Wait(blocked.get(), false, 120ms);
    if (nonalertable != WaitResult::kTimeout) {
      done->Set();
      return;
    }
    nonalertable_done->Set();
    if (Wait(proceed.get(), false, 1000ms) != WaitResult::kSuccess) {
      done->Set();
      return;
    }
    alert_result.store(static_cast<int32_t>(rex::thread::AlertableSleep(1500ms)),
                      std::memory_order_release);
    done->Set();
  });
  if (!Check(state, worker != nullptr, "APC worker created")) {
    return false;
  }
  const bool worker_ready = Wait(ready.get(), false, 1000ms) == WaitResult::kSuccess;
  Check(state, worker_ready, "APC worker entered the nonalertable wait phase");

  worker->QueueUserCallback([&] {
    callback_thread_id.store(rex::thread::current_thread_system_id(), std::memory_order_release);
    callback_count.fetch_add(1, std::memory_order_release);
  });
  const bool nonalertable_finished =
      Wait(nonalertable_done.get(), false, 1000ms) == WaitResult::kSuccess;
  Check(state, nonalertable_finished, "nonalertable wait returns without dispatching APC");
  const bool held_back = callback_count.load(std::memory_order_acquire) == 0;
  Check(state, held_back, "queued APC stays pending during nonalertable wait");

  proceed->Set();
  const bool worker_done = Wait(done.get(), false, 2000ms) == WaitResult::kSuccess;
  const bool worker_exited = Wait(worker.get(), false, 1000ms) == WaitResult::kSuccess;
  const bool delivered = callback_count.load(std::memory_order_acquire) == 1 &&
                         alert_result.load(std::memory_order_acquire) ==
                             static_cast<int32_t>(rex::thread::SleepResult::kAlerted);
  const bool same_thread = callback_thread_id.load(std::memory_order_acquire) == worker->system_id();
  Check(state, worker_done && worker_exited, "APC worker reaches completion");
  Check(state, delivered, "alertable sleep dispatches the queued APC and reports alerted");
  Check(state, same_thread, "APC callback executes on its target thread");
  return worker_ready && nonalertable_finished && held_back && worker_done && worker_exited &&
         delivered && same_thread;
}

bool TestWaitableTimer(TestState& state) {
  auto timer = Timer::CreateSynchronizationTimer();
  if (!Check(state, timer != nullptr, "waitable timer creation")) {
    return false;
  }

  std::atomic<uint32_t> callback_count{0};
  std::atomic<uint32_t> callback_thread_id{0};
  const auto owner_id = rex::thread::current_thread_system_id();
  const bool set_ok = timer->SetOnceAt(std::chrono::steady_clock::now() + 35ms, [&] {
    callback_thread_id.store(rex::thread::current_thread_system_id(), std::memory_order_release);
    callback_count.fetch_add(1, std::memory_order_release);
  });
  Check(state, set_ok, "one-shot waitable timer accepts a due time");
  const auto alert_result = rex::thread::AlertableSleep(1000ms);
  const bool fired = alert_result == rex::thread::SleepResult::kAlerted &&
                     callback_count.load(std::memory_order_acquire) == 1;
  Check(state, fired, "one-shot timer callback wakes an alertable owner");
  Check(state, callback_thread_id.load(std::memory_order_acquire) == owner_id,
        "waitable timer callback runs on the setting thread");
  Check(state, Wait(timer.get(), false, 0ms) == WaitResult::kSuccess,
        "waitable timer becomes a signaled wait object");

  std::atomic<uint32_t> canceled_callback{0};
  const bool set_cancel = timer->SetOnceAt(std::chrono::steady_clock::now() + 250ms, [&] {
    canceled_callback.fetch_add(1, std::memory_order_release);
  });
  const bool canceled = timer->Cancel();
  Check(state, set_cancel && canceled, "timer cancellation succeeds before its due time");
  const auto after_cancel = rex::thread::AlertableSleep(100ms);
  const bool suppressed = after_cancel == rex::thread::SleepResult::kSuccess &&
                          canceled_callback.load(std::memory_order_acquire) == 0 &&
                          Wait(timer.get(), false, 0ms) == WaitResult::kTimeout;
  Check(state, suppressed, "canceled timer does not signal or callback");
  return set_ok && fired && set_cancel && canceled && suppressed;
}

bool TestTimerQueueDisarm(TestState& state) {
  std::atomic<uint32_t> entered{0};
  std::atomic<uint32_t> in_callback{0};
  std::atomic<uint32_t> callback_count{0};
  std::atomic<uint32_t> callback_thread_id{0};
  {
    auto timer = HighResolutionTimer::CreateRepeating(5ms, [&] {
      in_callback.store(1, std::memory_order_release);
      entered.store(1, std::memory_order_release);
      callback_thread_id.store(rex::thread::current_thread_system_id(),
                               std::memory_order_release);
      callback_count.fetch_add(1, std::memory_order_release);
      std::this_thread::sleep_for(12ms);
      in_callback.store(0, std::memory_order_release);
    });
    const bool entered_ok = timer != nullptr && WaitUntil(
        [&] { return entered.load(std::memory_order_acquire) == 1; }, 1000ms);
    Check(state, entered_ok, "timer queue dispatches a repeating callback");
    const auto count_before_disarm = callback_count.load(std::memory_order_acquire);
    timer.reset();
    const bool drained = in_callback.load(std::memory_order_acquire) == 0;
    Check(state, drained, "timer disarm waits for an in-flight callback");
    std::this_thread::sleep_for(40ms);
    const bool quiet = callback_count.load(std::memory_order_acquire) == count_before_disarm ||
                       callback_count.load(std::memory_order_acquire) == count_before_disarm + 1;
    // A callback already executing at reset is allowed to finish. No later
    // callback may be admitted after Disarm returns.
    Check(state, quiet, "timer disarm prevents later callbacks");
  }
  Check(state, callback_thread_id.load(std::memory_order_acquire) != 0,
        "timer queue callback has a stable dispatch thread");
  return entered.load(std::memory_order_acquire) == 1 &&
         in_callback.load(std::memory_order_acquire) == 0 &&
         callback_thread_id.load(std::memory_order_acquire) != 0;
}

struct FiberState {
  Fiber* root = nullptr;
  Fiber* child = nullptr;
  uint32_t stage = 0;
};

void FiberEntry(void* opaque) {
  auto* state = static_cast<FiberState*>(opaque);
  state->stage = 1;
  Fiber::SwitchTo(state->root);
  if (state->stage == 1) {
    state->stage = 2;
  }
  Fiber::SwitchTo(state->root);
}

bool TestFiberRootOwnership(TestState& state) {
  FiberState fiber_state;
  fiber_state.root = Fiber::ConvertCurrentThread();
  if (!Check(state, fiber_state.root != nullptr, "current thread converts to one root fiber")) {
    return false;
  }
  fiber_state.child = Fiber::Create(256 * 1024, FiberEntry, &fiber_state);
  if (!Check(state, fiber_state.child != nullptr, "child fiber creation")) {
    fiber_state.root->Destroy();
    return false;
  }

  Fiber::SwitchTo(fiber_state.child);
  const bool first_resume = fiber_state.stage == 1;
  Check(state, first_resume, "child fiber yields back to its owning root");
  Fiber::SwitchTo(fiber_state.child);
  const bool second_resume = fiber_state.stage == 2;
  Check(state, second_resume, "child fiber resumes with its continuation intact");

  fiber_state.child->Destroy();
  // A second conversion must fail while the original root still owns this
  // host thread. This avoids depending on Fiber::Current(), whose TLS storage
  // is intentionally private to the runtime implementation.
  auto* second_root = Fiber::ConvertCurrentThread();
  const bool root_still_current = second_root == nullptr;
  if (second_root) {
    second_root->Destroy();
  }
  Check(state, root_still_current, "destroying a parked child preserves the root owner");
  fiber_state.root->Destroy();
  return first_resume && second_resume && root_still_current;
}

}  // namespace

int main() {
  TestState state;
  TestSuspendedThread(state);
  TestManualAndAutoEvents(state);
  TestWaitMultipleAndSemaphore(state);
  TestAlertableApc(state);
  TestWaitableTimer(state);
  TestTimerQueueDisarm(state);
  TestFiberRootOwnership(state);
  std::cout << "RESULT " << state.passed << "/" << (state.passed + state.failed)
            << " passed\n";
  std::cout << "SCOPE native ReXGlue primitives only; no XEX, game entry, emulator, JIT, "
               "simulation time, physics or FPS path\n";
  return state.failed == 0 ? 0 : 1;
}
