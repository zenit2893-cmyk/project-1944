// SPDX-License-Identifier: BSD-3-Clause
//
// ReXGlue/Xenia memory contract adapter for the CoD3 native port.
//
// This file contains original, header-only contract code.  The ranges and
// address transforms are derived from the BSD-licensed Xenia sources kept in
// tools/Xenia-source/src/xenia/memory.{h,cc} and compared with the BSD-licensed
// ReXGlue port in tools/rexglue-source/{include,rexglue-source}.  It does not
// copy Xenia implementation code and it does not replace the active runtime.
// Keep this adapter isolated until the generated-code ABI is explicitly
// migrated to it.

#pragma once

#include <cstdint>
#include <limits>

namespace cod3::xenia_memory {

using GuestAddress = std::uint32_t;
using PhysicalAddress = std::uint32_t;
using HostAddress = std::uintptr_t;

// Xbox 360 address-space constants used by Xenia's Memory::map_info table.
inline constexpr GuestAddress kVirtual4KBegin = 0x00000000u;
inline constexpr GuestAddress kVirtual4KEnd = 0x40000000u;
inline constexpr GuestAddress kVirtual64KBegin = 0x40000000u;
inline constexpr GuestAddress kVirtual64KEnd = 0x7F000000u;
inline constexpr GuestAddress kGpuWritebackBegin = 0x7F000000u;
inline constexpr GuestAddress kGpuWritebackEnd = 0x7FC80000u;
inline constexpr GuestAddress kMmioBegin = 0x7FC80000u;
inline constexpr GuestAddress kMmioEnd = 0x80000000u;
inline constexpr GuestAddress kXex64KBegin = 0x80000000u;
inline constexpr GuestAddress kXex64KEnd = 0x90000000u;
inline constexpr GuestAddress kXex4KBegin = 0x90000000u;
inline constexpr GuestAddress kXex4KEnd = 0xA0000000u;
inline constexpr GuestAddress kPhysical64KBegin = 0xA0000000u;
inline constexpr GuestAddress kPhysical64KEnd = 0xC0000000u;
inline constexpr GuestAddress kPhysical16MBegin = 0xC0000000u;
inline constexpr GuestAddress kPhysical16MEnd = 0xE0000000u;
inline constexpr GuestAddress kPhysical4KBegin = 0xE0000000u;

// The physical 4 KB heap is 0x1FD00000 bytes in both Xenia and ReXGlue.  The
// rest of the four-gigabyte view remains reserved by the mapping but has no
// heap metadata and must not be treated as allocated guest memory.
inline constexpr GuestAddress kPhysical4KEnd = 0xFFD00000u;
inline constexpr GuestAddress kUnmappedBegin = kPhysical4KEnd;
inline constexpr std::uint64_t kGuestAddressSpaceEnd = 0x100000000ull;

inline constexpr std::uint32_t kPhysicalAddressMask = 0x1FFFFFFFu;
inline constexpr std::uint32_t kPhysical4KFileOffset = 0x1000u;
inline constexpr std::uint32_t kCanonicalPhysicalLimit = 0x1FFFFFFFu;
inline constexpr std::uint32_t kPage4K = 0x1000u;
inline constexpr std::uint32_t kPage64K = 0x10000u;
inline constexpr std::uint32_t kPage16M = 0x01000000u;

enum class GuestRegion : std::uint8_t {
  kVirtual4K,
  kVirtual64K,
  kGpuWriteback,
  kMmio,
  kXex64K,
  kXex4K,
  kPhysical64K,
  kPhysical16M,
  kPhysical4K,
  kUnmapped,
};

struct GuestRegionInfo {
  GuestRegion region;
  std::uint64_t begin;
  std::uint64_t end_exclusive;
  std::uint32_t page_size;
  std::uint32_t physical_delta;
  bool mapped;
  bool physical_alias;
  bool mmio;
};

// This classification intentionally keeps the GPU writeback/XPS alias
// separate from MMIO.  Xenia maps 0x7F000000-0x7FC7FFFF as physical memory and
// leaves only 0x7FC80000-0x7FFFFFFF to MMIO handlers.
constexpr GuestRegionInfo DescribeGuestAddress(GuestAddress address) noexcept {
  if (address < kVirtual4KEnd) {
    return {GuestRegion::kVirtual4K, kVirtual4KBegin, kVirtual4KEnd, kPage4K, 0u, true, false,
            false};
  }
  if (address < kGpuWritebackBegin) {
    return {GuestRegion::kVirtual64K, kVirtual64KBegin, kVirtual64KEnd, kPage64K, 0u, true, false,
            false};
  }
  if (address < kMmioBegin) {
    return {GuestRegion::kGpuWriteback, kGpuWritebackBegin, kGpuWritebackEnd, kPage4K, 0u, true,
            true, false};
  }
  if (address < kXex64KBegin) {
    return {GuestRegion::kMmio, kMmioBegin, kMmioEnd, 0u, 0u, true, false, true};
  }
  if (address < kXex4KBegin) {
    return {GuestRegion::kXex64K, kXex64KBegin, kXex64KEnd, kPage64K, 0u, true, false, false};
  }
  if (address < kPhysical64KBegin) {
    return {GuestRegion::kXex4K, kXex4KBegin, kXex4KEnd, kPage4K, 0u, true, false, false};
  }
  if (address < kPhysical16MBegin) {
    return {GuestRegion::kPhysical64K, kPhysical64KBegin, kPhysical64KEnd, kPage64K, 0u, true,
            true, false};
  }
  if (address < kPhysical4KBegin) {
    return {GuestRegion::kPhysical16M, kPhysical16MBegin, kPhysical16MEnd, kPage16M, 0u, true, true,
            false};
  }
  if (address < kPhysical4KEnd) {
    return {GuestRegion::kPhysical4K, kPhysical4KBegin, kPhysical4KEnd, kPage4K,
            kPhysical4KFileOffset, true, true, false};
  }
  return {GuestRegion::kUnmapped, kUnmappedBegin, kGuestAddressSpaceEnd, 0u, 0u, false, false,
          false};
}

constexpr bool IsMappedGuestAddress(GuestAddress address) noexcept {
  return DescribeGuestAddress(address).mapped;
}

constexpr bool IsPhysicalAlias(GuestAddress address) noexcept {
  return DescribeGuestAddress(address).physical_alias;
}

constexpr bool IsHardwareMmioAddress(GuestAddress address) noexcept {
  return DescribeGuestAddress(address).mmio;
}

// Captures the broad predicate currently emitted by the ReXGlue generated
// pch template.  It is retained for diagnostics so callers can prove where it
// differs from Xenia's actual MMIO window; it should not be used as the safety
// decision for a load or store.
constexpr bool IsLegacyReXGlueMmioPredicate(GuestAddress address) noexcept {
  return address >= 0x7F000000u && address < 0x80000000u;
}

enum class PhysicalResolutionPolicy : std::uint8_t {
  // Xenia's Memory::GetPhysicalAddress accepts the GPU writeback alias and
  // passes through canonical physical addresses below 0x1FFFFFFF.
  kXeniaCompatible,
  // ReXGlue's port currently has no v7F000000 heap and only resolves aliases
  // backed by its PhysicalHeap instances (A..., C..., E...).
  kReXGluePhysicalHeapsOnly,
};

// Resolves the guest address forms accepted by the selected runtime contract.
// The strict boolean result is deliberate: UINT32_MAX is a valid sentinel in
// both runtimes and must never be mistaken for a host pointer or a physical
// address.
constexpr bool TryResolvePhysicalAddress(GuestAddress guest_address,
                                         PhysicalResolutionPolicy policy,
                                         PhysicalAddress* out_physical) noexcept {
  if (!out_physical) {
    return false;
  }

  const GuestRegionInfo info = DescribeGuestAddress(guest_address);
  const bool recompile_alias =
      info.region == GuestRegion::kPhysical64K || info.region == GuestRegion::kPhysical16M ||
      info.region == GuestRegion::kPhysical4K;
  const bool xenia_alias = recompile_alias || info.region == GuestRegion::kGpuWriteback;
  if (xenia_alias &&
      (policy == PhysicalResolutionPolicy::kXeniaCompatible || recompile_alias)) {
    *out_physical = guest_address - static_cast<GuestAddress>(info.begin) + info.physical_delta;
    return true;
  }

  // This mirrors Xenia's historical pass-through condition exactly (strictly
  // less than 0x1FFFFFFF).  ReXGlue intentionally does not expose it through
  // Memory::GetPhysicalAddress, so it is only available in compatibility mode.
  if (policy == PhysicalResolutionPolicy::kXeniaCompatible &&
      info.region == GuestRegion::kVirtual4K && guest_address < kCanonicalPhysicalLimit) {
    *out_physical = guest_address;
    return true;
  }
  return false;
}

// The E... physical view is mapped at file offset 0x100001000.  On hosts with
// allocation granularity greater than 4 KB, MapViewOfFileEx/mmap rounds the
// view offset down and the runtime compensates by adding 0x1000 to the host
// address.  This is a runtime property, not a platform-name property.
constexpr std::uint32_t HostAddressOffsetForGuest(GuestAddress guest_address,
                                                  std::uint32_t allocation_granularity) noexcept {
  const GuestRegionInfo info = DescribeGuestAddress(guest_address);
  if (info.region == GuestRegion::kPhysical4K && allocation_granularity > kPage4K) {
    return kPhysical4KFileOffset;
  }
  return 0u;
}

struct MappingLayout {
  HostAddress virtual_membase;
  HostAddress physical_membase;
  std::uint32_t allocation_granularity;
};

inline bool CheckedHostAdd(HostAddress base, std::uint64_t offset, HostAddress* out_host) noexcept {
  if (!out_host || offset > std::numeric_limits<HostAddress>::max() - base) {
    return false;
  }
  *out_host = base + static_cast<HostAddress>(offset);
  return true;
}

// Checked equivalent of the generated REX_RAW_ADDR arithmetic.  It rejects
// heap-unmapped addresses instead of returning a pointer that happens to fall
// inside the reserved file view.
inline bool TryTranslateVirtual(const MappingLayout& layout, GuestAddress guest_address,
                                HostAddress* out_host) noexcept {
  if (!IsMappedGuestAddress(guest_address)) {
    return false;
  }
  const std::uint64_t offset =
      static_cast<std::uint64_t>(guest_address) +
      HostAddressOffsetForGuest(guest_address, layout.allocation_granularity);
  return CheckedHostAdd(layout.virtual_membase, offset, out_host);
}

// Physical addresses are a 512 MB aperture in Xenia/ReXGlue.  Masking is
// performed only after the caller has identified the value as a physical
// address; this helper never turns an arbitrary guest pointer into a physical
// pointer implicitly.
inline bool TryTranslatePhysical(const MappingLayout& layout, PhysicalAddress physical_address,
                                 HostAddress* out_host) noexcept {
  return CheckedHostAdd(layout.physical_membase,
                        static_cast<std::uint64_t>(physical_address & kPhysicalAddressMask),
                        out_host);
}

// Xenia and ReXGlue expose Memory::HostToGuestVirtual as a best-effort inverse
// for addresses in the virtual half of the mapping.  This checked form keeps
// the inclusive/exclusive boundaries explicit and undoes the E... host offset
// only for the actual 0xE0000000 heap.
inline bool TryHostToGuestVirtual(const MappingLayout& layout, HostAddress host_address,
                                  GuestAddress* out_guest) noexcept {
  if (!out_guest || host_address < layout.virtual_membase ||
      host_address >= layout.physical_membase) {
    return false;
  }
  const std::uint64_t virtual_offset = host_address - layout.virtual_membase;
  if (virtual_offset > std::numeric_limits<GuestAddress>::max()) {
    return false;
  }

  std::uint64_t guest_address = virtual_offset;
  const std::uint32_t host_offset = HostAddressOffsetForGuest(
      kPhysical4KBegin, layout.allocation_granularity);
  const std::uint64_t e_host_begin = static_cast<std::uint64_t>(kPhysical4KBegin) + host_offset;
  const std::uint64_t e_host_end = static_cast<std::uint64_t>(kPhysical4KEnd) + host_offset;
  if (guest_address >= e_host_begin && guest_address < e_host_end) {
    guest_address -= host_offset;
  }
  if (guest_address >= kGuestAddressSpaceEnd ||
      !IsMappedGuestAddress(static_cast<GuestAddress>(guest_address))) {
    return false;
  }
  *out_guest = static_cast<GuestAddress>(guest_address);
  return true;
}

enum class FaultAddressSpace : std::uint8_t {
  kOutsideMapping,
  kVirtualView,
  kPhysicalView,
};

// MMIOHandler passes memory_end as the last valid byte (physical_membase +
// 0x1FFFFFFF), so the upper comparison is intentionally inclusive.
constexpr FaultAddressSpace ClassifyFaultAddress(const MappingLayout& layout,
                                                  HostAddress fault_address,
                                                  HostAddress memory_end) noexcept {
  if (fault_address < layout.virtual_membase || fault_address > memory_end) {
    return FaultAddressSpace::kOutsideMapping;
  }
  return fault_address < layout.physical_membase ? FaultAddressSpace::kVirtualView
                                                  : FaultAddressSpace::kPhysicalView;
}

}  // namespace cod3::xenia_memory

