#include "cod3_pc_pch.h"

using JumpCallback = void (*)(PPCContext&, int);

extern "C" __declspec(dllexport) const void* DllJumpMapAddress() {
  return &get_jmp_buf_map();
}

extern "C" __declspec(dllexport) void DllFrame(PPCContext& ctx, int value,
                                                volatile int* return_marker,
                                                volatile int* destructors,
                                                JumpCallback callback) {
  struct Cleanup {
    volatile int* count;
    ~Cleanup() { *count = *count + 1; }
  } cleanup{destructors};
  ctx.r1.u64 = 0x7016D490;
  ctx.r30.u64 = 0xFFFFFFFF89250000ull;
  ctx.r31.u64 = 0xFFFFFFFF89255310ull;
  callback(ctx, value);
  *return_marker = *return_marker + 1;
}

