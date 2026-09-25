// SPDX-License-Identifier: BSD-3-Clause
//
// Isolated MMIO dispatch contract for the CoD3 ReXGlue integration.
// Address ranges and callback signatures match the BSD-licensed Xenia
// MMIOHandler and the corresponding ReXGlue runtime source.  The dispatch
// table below is original glue code and is not linked into the active runtime.

#pragma once

#include <cstdint>
#include <vector>

namespace cod3::xenia_memory {

using MMIOReadCallback = std::uint32_t (*)(void* ppc_context, void* callback_context,
                                           std::uint32_t address);
using MMIOWriteCallback = void (*)(void* ppc_context, void* callback_context,
                                    std::uint32_t address, std::uint32_t value);

inline constexpr std::uint32_t kMmioRangeMask = 0xFFFF0000u;
inline constexpr std::uint32_t kMmioRangeSize = 0x0000FFFFu;
inline constexpr std::uint32_t kGpuMmioBase = 0x7FC80000u;
inline constexpr std::uint32_t kXmaMmioBase = 0x7FEA0000u;

struct MMIORange {
  std::uint32_t address;
  std::uint32_t mask;
  std::uint32_t size;
  void* callback_context;
  MMIOReadCallback read;
  MMIOWriteCallback write;
};

constexpr bool MatchesMask(const MMIORange& range, std::uint32_t address) noexcept {
  // Xenia/ReXGlue intentionally use mask matching.  The size is retained as
  // metadata and is not an additional predicate in LookupRange.
  return (address & range.mask) == range.address;
}

// The table models the public behavior of MMIOHandler::RegisterRange,
// LookupRange, CheckLoad and CheckStore while making the no-match result
// explicit to callers.  In particular, a failed CheckLoad must never be
// consumed as if its output value had been initialized.
class MMIODispatchTable final {
 public:
  bool RegisterRange(std::uint32_t address, std::uint32_t mask, std::uint32_t size,
                     void* callback_context, MMIOReadCallback read,
                     MMIOWriteCallback write) {
    ranges_.push_back({address, mask, size, callback_context, read, write});
    return true;
  }

  const MMIORange* LookupRange(std::uint32_t address) const noexcept {
    for (const auto& range : ranges_) {
      if (MatchesMask(range, address)) {
        return &range;
      }
    }
    return nullptr;
  }

  bool CheckLoad(void* ppc_context, std::uint32_t address,
                 std::uint32_t* out_value) const noexcept {
    if (!out_value) {
      return false;
    }
    const MMIORange* range = LookupRange(address);
    if (!range || !range->read) {
      return false;
    }
    *out_value = range->read(ppc_context, range->callback_context, address);
    return true;
  }

  bool CheckStore(void* ppc_context, std::uint32_t address, std::uint32_t value) const noexcept {
    const MMIORange* range = LookupRange(address);
    if (!range || !range->write) {
      return false;
    }
    range->write(ppc_context, range->callback_context, address, value);
    return true;
  }

  std::size_t size() const noexcept { return ranges_.size(); }

 private:
  std::vector<MMIORange> ranges_;
};

}  // namespace cod3::xenia_memory

