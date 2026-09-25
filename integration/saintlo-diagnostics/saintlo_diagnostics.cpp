// Observational wrappers only. Every wrapper executes the original generated body
// with the original PPCContext. No register, memory, return value, or timing repair.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <atomic>
#include <array>
#include <cstdint>

#include <rex/hook.h>

extern "C" REX_FUNC(__imp__sub_89132580);
extern "C" REX_FUNC(__imp__sub_89099818);
extern "C" REX_FUNC(__imp__sub_891BE760);
extern "C" REX_FUNC(__imp__sub_891A1B88);
extern "C" REX_FUNC(__imp__sub_89191FD0);
extern "C" REX_FUNC(__imp__sub_89191880);

namespace {
struct Read64 {
  bool valid{};
  uint64_t value{};
};

Read64 ReadGuest64(uint8_t* base, uint32_t address) {
  // ReadProcessMemory makes invalid stack addresses diagnostic data rather than
  // causing an extra fault in the observer. This reads this process exclusively.
  uint8_t bytes[8]{};
  SIZE_T count{};
  Read64 result{};
  if (ReadProcessMemory(GetCurrentProcess(), base + address, bytes, sizeof(bytes), &count) &&
      count == sizeof(bytes)) {
    result.valid = true;
    for (auto byte : bytes) result.value = (result.value << 8) | byte;
  }
  return result;
}

uint32_t ReadGuest32(uint8_t* base, uint32_t address) {
  const auto data = ReadGuest64(base, address);
  return data.valid ? uint32_t(data.value >> 32) : 0;
}

std::array<char, 193> ReadAscii(uint8_t* base, uint32_t address) {
  std::array<char, 193> text{};
  SIZE_T count{};
  if (ReadProcessMemory(GetCurrentProcess(), base + address, text.data(),
                        text.size() - 1, &count)) {
    for (auto& c : text) {
      if (!c) break;
      if (static_cast<unsigned char>(c) < 32 || static_cast<unsigned char>(c) > 126) c = '?';
    }
  } else {
    text[0] = '\0';
  }
  return text;
}

struct Snapshot {
  uint64_t sp, lr, r29, r30, r31;
};

Snapshot TakeSnapshot(const PPCContext& ctx) {
  return {ctx.r1.u64, ctx.lr, ctx.r29.u64, ctx.r30.u64, ctx.r31.u64};
}

template <PPCFunc* Original>
void Observe(PPCContext& ctx, uint8_t* base, uint32_t address,
             std::atomic<uint32_t>& invocation_counter,
             std::atomic<uint32_t>& failure_counter) {
  const auto entry_last_error = GetLastError();
  const auto ordinal = invocation_counter.fetch_add(1, std::memory_order_relaxed) + 1;
  const auto before = TakeSnapshot(ctx);
  if (ordinal <= 4) {
    REXLOG_INFO("[saintlo-diag] enter fn={:08X} n={} tid={} lr={:08X} sp={:08X} "
                "r3={:08X} r4={:08X} r29={:016X} r30={:016X} r31={:016X}",
                address, ordinal, GetCurrentThreadId(), uint32_t(before.lr),
                uint32_t(before.sp), ctx.r3.u32, ctx.r4.u32,
                before.r29, before.r30, before.r31);
    if (address == 0x89099818) {
      const auto file = ReadAscii(base, ctx.r4.u32);
      const auto symbol = ReadAscii(base, ctx.r6.u32);
      const auto closure = ctx.r7.u32;
      const auto vtable = ReadGuest32(base, closure);
      REXLOG_INFO("[saintlo-diag] script-dispatch file='{}' line={} symbol='{}' "
                  "r3={:08X} r6={:08X} closure={:08X} closure_vtable={:08X} "
                  "closure_function={:08X} closure_context={:08X} "
                  "getter={:08X} api56={:08X} api68={:08X} api72={:08X} "
                  "api76={:08X} api80={:08X} api84={:08X} api92={:08X} api4320={:08X}",
                  file.data(), ctx.r5.u32, symbol.data(), ctx.r3.u32, ctx.r6.u32,
                  closure, vtable, ReadGuest32(base, closure + 4),
                  ReadGuest32(base, closure + 8), ReadGuest32(base, vtable + 4),
                  ReadGuest32(base, 0x89255310 + 56),
                  ReadGuest32(base, 0x89255310 + 68),
                  ReadGuest32(base, 0x89255310 + 72),
                  ReadGuest32(base, 0x89255310 + 76),
                  ReadGuest32(base, 0x89255310 + 80),
                  ReadGuest32(base, 0x89255310 + 84),
                  ReadGuest32(base, 0x89255310 + 92),
                  ReadGuest32(base, 0x89255310 + 4320));
    }
  }
  SetLastError(entry_last_error);
  Original(ctx, base);
  const auto return_last_error = GetLastError();
  const auto after = TakeSnapshot(ctx);
  const bool changed = before.sp != after.sp || before.r29 != after.r29 ||
                       before.r30 != after.r30 || before.r31 != after.r31;
  const auto failure = changed ? failure_counter.fetch_add(1, std::memory_order_relaxed) + 1 : 0;
  if (ordinal <= 4 || (changed && failure <= 16)) {
    const auto saved_r30 = ReadGuest64(base, uint32_t(before.sp) - 24);
    const auto saved_r31 = ReadGuest64(base, uint32_t(before.sp) - 16);
    const auto parent_r30 = ReadGuest64(base, uint32_t(before.sp) + 112 - 24);
    REXLOG_INFO("[saintlo-diag] leave fn={:08X} n={} tid={} nonvolatile_changed={} "
                "sp={:08X}->{:08X} r29={:016X}->{:016X} r30={:016X}->{:016X} "
                "r31={:016X}->{:016X} saved_r30_addr={:08X} readable={} value={:016X} "
                "saved_r31_readable={} value={:016X} parent112_r30_readable={} value={:016X}",
                address, ordinal, GetCurrentThreadId(), changed,
                uint32_t(before.sp), uint32_t(after.sp), before.r29, after.r29,
                before.r30, after.r30, before.r31, after.r31,
                uint32_t(before.sp) - 24, saved_r30.valid, saved_r30.value,
                saved_r31.valid, saved_r31.value, parent_r30.valid, parent_r30.value);
  }
  SetLastError(return_last_error);
}
}  // namespace

#define COD3_OBSERVE(name, address)                                     \
  REX_HOOK_RAW(name) {                                                 \
    static std::atomic<uint32_t> calls{0};                              \
    static std::atomic<uint32_t> failures{0};                           \
    Observe<__imp__##name>(ctx, base, address, calls, failures);         \
  }

COD3_OBSERVE(sub_89132580, 0x89132580)
COD3_OBSERVE(sub_89099818, 0x89099818)
COD3_OBSERVE(sub_891BE760, 0x891BE760)
COD3_OBSERVE(sub_891A1B88, 0x891A1B88)
COD3_OBSERVE(sub_89191FD0, 0x89191FD0)
COD3_OBSERVE(sub_89191880, 0x89191880)
