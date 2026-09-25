#include "cod3_pc_pch.h"
#include <iostream>

using JumpCallback = void (*)(PPCContext&, int);
extern "C" __declspec(dllimport) const void* DllJumpMapAddress();
extern "C" __declspec(dllimport) void DllFrame(PPCContext&, int, volatile int*,
                                               volatile int*, JumpCallback);

namespace {
constexpr uint32_t kGuestBuffer = 0x12340000;
volatile int return_marker = 0;
volatile int destructors = 0;
PPCContext context{};

void MainImageLongjmp(PPCContext&, int value) {
  // Both lookup and landing storage belong to the main native image, matching
  // all currently observed direct CRT call sites in the game.
  ppc_longjmp(kGuestBuffer, value);
}

bool CheckCase(int value) {
  return_marker = 0;
  destructors = 0;
  context = {};
  context.r1.u64 = 0x7016F7F0;
  context.r3.u32 = kGuestBuffer;
  context.r30.u64 = 0x30;
  context.r31.u64 = 0x31;

  // This is the exact sequence emitted by the installed ReXGlue code generator
  // when setjmp_address is configured. The native call site stays alive.
  PPCContext env{};
  PPCRegister temp{};
  env = context;
  temp.s64 = ppc_setjmp(context.r3.u32);
  if (temp.s64 != 0) context = env;
  context.r3 = temp;
  if (context.r3.u32 == 0) {
    DllFrame(context, value, &return_marker, &destructors, MainImageLongjmp);
    return_marker = return_marker + 1;
    return false;
  }
  const int expected = value == 0 ? 1 : value;
  const bool ok = context.r3.s32 == expected && context.r1.u64 == 0x7016F7F0 &&
                  context.r30.u64 == 0x30 && context.r31.u64 == 0x31 &&
                  return_marker == 0 && destructors == 1;
  std::cout << "{\"value\":" << value << ",\"returned\":" << context.r3.s32
            << ",\"guest_sp_restored\":" << (context.r1.u64 == 0x7016F7F0)
            << ",\"guest_nonvolatiles_restored\":"
            << (context.r30.u64 == 0x30 && context.r31.u64 == 0x31)
            << ",\"skipped_intermediate_returns\":" << (return_marker == 0)
            << ",\"dll_cleanup_count\":" << destructors
            << ",\"passed\":" << ok << "}\n";
  return ok;
}
}  // namespace

int main() {
  std::cout << std::boolalpha;
  const bool maps_are_separate = DllJumpMapAddress() != &get_jmp_buf_map();
  std::cout << "{\"main_and_dll_jump_maps_are_separate\":" << maps_are_separate << "}\n";
  const bool zero = CheckCase(0);
  const bool one = CheckCase(1);
  const bool seven = CheckCase(7);
  return maps_are_separate && zero && one && seven ? 0 : 1;
}
