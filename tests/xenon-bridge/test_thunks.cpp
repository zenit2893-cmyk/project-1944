#include "xenon_thunks.h"

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <type_traits>

REX_EXTERN(sub_822D0498);
REX_EXTERN(sub_822D2140);

namespace {
static_assert(std::is_trivially_copyable_v<PPCContext>);
static_assert(std::is_same_v<decltype(&cod3_xenon_thunk_822D0498), PPCFunc*>);
static_assert(std::is_same_v<decltype(&cod3_xenon_thunk_822D2140), PPCFunc*>);

PPCContext* active_context;
uint8_t* active_base;
PPCContext expected_at_branch;
PPCContext expected_after_callee;
uint32_t expected_target;
unsigned callee_calls;
unsigned cases;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

// Independent decoder for the reviewed original PowerPC opcodes. ADDI computes
// a modulo-2^64 register result. Relative B leaves the guest LR unchanged.
uint32_t ExecuteReference(PPCContext& ctx, uint32_t pc,
                          const uint32_t* code, size_t count) {
  for (size_t i = 0; i < count; ++i, pc += 4) {
    const uint32_t instruction = code[i];
    const unsigned opcode = instruction >> 26;
    if (opcode == 14) {
      Require(((instruction >> 21) & 31) == 3 &&
                  ((instruction >> 16) & 31) == 3,
              "Unexpected ADDI register in reference input");
      const auto immediate = static_cast<int64_t>(static_cast<int16_t>(instruction));
      ctx.r3.u64 += static_cast<uint64_t>(immediate);
    } else if (opcode == 18) {
      Require((instruction & 3) == 0, "Reference branch must be relative and preserve LR");
      uint32_t displacement = instruction & 0x03FFFFFC;
      if (displacement & 0x02000000) displacement |= 0xFC000000;
      return pc + displacement;
    } else {
      throw std::runtime_error("Unsupported original opcode in bounded reference");
    }
  }
  throw std::runtime_error("Reference thunk did not tail-call");
}

void ObserveCallee(uint32_t target, PPCContext& ctx, uint8_t* base) {
  Require(&ctx == active_context, "Bridge copied or substituted PPCContext");
  Require(base == active_base, "Bridge changed guest memory base");
  Require(target == expected_target, "Bridge called the wrong guest target");
  Require(++callee_calls == 1, "Bridge called the guest target more than once");
  Require(std::memcmp(&ctx, &expected_at_branch, sizeof(ctx)) == 0,
          "Context differs from original instruction semantics at guest target");
  // A tail callee owns its outputs. Verify the bridge does not restore a stale
  // copy when control returns through the host hook.
  ctx.r3.u64 = 0xBAD0C0DE822D0000ULL | (target & 0xFFFF);
  ctx.r7.u64 ^= 0xA533CAFE12345678ULL;
  ctx.f14.u64 ^= 0x00123456789ABCDEULL;
  ctx.v127.u64[1] ^= 0xFEDCBA9876543210ULL;
  ctx.last_indirect_target ^= 0x01020304;
  std::memcpy(&expected_after_callee, &ctx, sizeof(ctx));
}

uint64_t Next(uint64_t& state) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

void RunCase(PPCFunc* entry, uint32_t address, const uint32_t* code,
             size_t count, uint64_t r3, uint64_t& random) {
  PPCContext ctx;
  auto* raw = reinterpret_cast<uint8_t*>(&ctx);
  for (size_t i = 0; i < sizeof(ctx); ++i) raw[i] = static_cast<uint8_t>(Next(random));
  ctx.r3.u64 = r3;
  alignas(64) std::array<uint8_t, 256> memory;
  for (auto& byte : memory) byte = static_cast<uint8_t>(Next(random));
  const auto original_memory = memory;
  std::memcpy(&expected_at_branch, &ctx, sizeof(ctx));
  expected_target = ExecuteReference(expected_at_branch, address, code, count);
  active_context = &ctx;
  active_base = memory.data();
  callee_calls = 0;
  entry(ctx, memory.data());
  Require(callee_calls == 1, "Bridge did not invoke guest target");
  Require(std::memcmp(&ctx, &expected_after_callee, sizeof(ctx)) == 0,
          "Bridge lost guest callee output");
  Require(memory == original_memory, "A branch-only thunk modified guest memory");
  ++cases;
}
}  // namespace

REX_EXTERN(sub_822D0118) { ObserveCallee(0x822D0118, ctx, base); }
REX_EXTERN(sub_822CBA28) { ObserveCallee(0x822CBA28, ctx, base); }

int main() {
  try {
    constexpr std::array<uint32_t, 1> branch = {0x4BFFFC80};
    constexpr std::array<uint32_t, 2> adjust_branch = {0x38630004, 0x4BFF98E4};
    constexpr std::array<uint64_t, 12> boundaries = {
        0, 1, 0x7FFFFFFC, 0xFFFFFFFC, 0xFFFFFFFF, 0x100000000,
        0x7FFFFFFFFFFFFFFBULL, 0x7FFFFFFFFFFFFFFCULL,
        0x7FFFFFFFFFFFFFFFULL, 0x8000000000000000ULL,
        0xFFFFFFFFFFFFFFFCULL, 0xFFFFFFFFFFFFFFFFULL};
    uint64_t random = 0x822D0498822D2140ULL;
    auto exercise = [&](uint64_t r3) {
      RunCase(&cod3_xenon_thunk_822D0498, 0x822D0498, branch.data(), branch.size(), r3, random);
      RunCase(&cod3_xenon_thunk_822D2140, 0x822D2140, adjust_branch.data(), adjust_branch.size(), r3, random);
      RunCase(&sub_822D0498, 0x822D0498, branch.data(), branch.size(), r3, random);
      RunCase(&sub_822D2140, 0x822D2140, adjust_branch.data(), adjust_branch.size(), r3, random);
    };
    for (auto r3 : boundaries) exercise(r3);
    for (unsigned i = 0; i < 256; ++i) exercise(Next(random));
    std::printf("PASS: %u cases; exact ReXGlue PPCContext (%zu bytes, alignment %zu), "
                "original PPC opcode reference, direct and raw-hook paths, "
                "r3 wrap, all context bytes, guest LR/base and callee output preserved.\n",
                cases, sizeof(PPCContext), alignof(PPCContext));
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  }
}
