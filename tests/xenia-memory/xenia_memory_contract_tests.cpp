// SPDX-License-Identifier: BSD-3-Clause

#include <cstdint>
#include <iostream>

#include "xenia_memory_contract.h"
#include "xenia_mmio_contract.h"

namespace {

using cod3::xenia_memory::FaultAddressSpace;
using cod3::xenia_memory::GuestAddress;
using cod3::xenia_memory::GuestRegion;
using cod3::xenia_memory::GuestRegionInfo;
using cod3::xenia_memory::HostAddress;
using cod3::xenia_memory::MMIODispatchTable;
using cod3::xenia_memory::PhysicalResolutionPolicy;
using cod3::xenia_memory::PhysicalAddress;
using cod3::xenia_memory::MappingLayout;

struct CallbackState {
  std::uint32_t reads = 0;
  std::uint32_t writes = 0;
  std::uint32_t last_address = 0;
  std::uint32_t last_value = 0;
  void* last_ppc_context = nullptr;
};

std::uint32_t ReadRegister(void* ppc_context, void* callback_context, std::uint32_t address) {
  auto* state = static_cast<CallbackState*>(callback_context);
  ++state->reads;
  state->last_address = address;
  state->last_ppc_context = ppc_context;
  return 0xAABBCCDDu;
}

void WriteRegister(void* ppc_context, void* callback_context, std::uint32_t address,
                   std::uint32_t value) {
  auto* state = static_cast<CallbackState*>(callback_context);
  ++state->writes;
  state->last_address = address;
  state->last_value = value;
  state->last_ppc_context = ppc_context;
}

std::uint32_t ReadFirst(void*, void*, std::uint32_t) { return 0x11111111u; }
std::uint32_t ReadSecond(void*, void*, std::uint32_t) { return 0x22222222u; }

}  // namespace

int main() {
  std::uint32_t checks = 0;
  std::uint32_t passed = 0;
  const auto check = [&](bool condition, const char* name) {
    ++checks;
    if (condition) {
      ++passed;
      return;
    }
    std::cerr << "FAIL: " << name << '\n';
  };

  const GuestRegionInfo v4k = cod3::xenia_memory::DescribeGuestAddress(0x3FFFFFFFu);
  check(v4k.region == GuestRegion::kVirtual4K && v4k.page_size == 0x1000u,
        "virtual 4K upper boundary");

  const GuestRegionInfo v64k = cod3::xenia_memory::DescribeGuestAddress(0x40000000u);
  check(v64k.region == GuestRegion::kVirtual64K && v64k.page_size == 0x10000u,
        "virtual 64K lower boundary");

  const GuestRegionInfo writeback = cod3::xenia_memory::DescribeGuestAddress(0x7FC7FFFFu);
  check(writeback.region == GuestRegion::kGpuWriteback && writeback.physical_alias &&
            !writeback.mmio,
        "GPU writeback is physical alias, not MMIO");

  const GuestRegionInfo mmio = cod3::xenia_memory::DescribeGuestAddress(0x7FC80000u);
  check(mmio.region == GuestRegion::kMmio && mmio.mmio && !mmio.physical_alias,
        "MMIO begins at 0x7FC80000");

  const GuestRegionInfo xma = cod3::xenia_memory::DescribeGuestAddress(0x7FEA0000u);
  check(xma.region == GuestRegion::kMmio && cod3::xenia_memory::IsHardwareMmioAddress(0x7FEA1234u),
        "XMA register window is MMIO");

  const GuestRegionInfo physical_64k = cod3::xenia_memory::DescribeGuestAddress(0xA0000000u);
  check(physical_64k.region == GuestRegion::kPhysical64K && physical_64k.page_size == 0x10000u,
        "physical 64K alias");

  const GuestRegionInfo physical_16m = cod3::xenia_memory::DescribeGuestAddress(0xC0000000u);
  check(physical_16m.region == GuestRegion::kPhysical16M && physical_16m.page_size == 0x01000000u,
        "physical 16M alias");

  const GuestRegionInfo physical_4k = cod3::xenia_memory::DescribeGuestAddress(0xE0000000u);
  check(physical_4k.region == GuestRegion::kPhysical4K &&
            physical_4k.physical_delta == 0x1000u,
        "physical 4K alias carries the 0x1000 file offset");

  check(cod3::xenia_memory::DescribeGuestAddress(0xFFCCFFFFu).mapped,
        "last byte of the E heap is mapped");
  check(cod3::xenia_memory::DescribeGuestAddress(0xFFD00000u).region == GuestRegion::kUnmapped,
        "address after the E heap has no heap metadata");

  PhysicalAddress physical = 0;
  check(cod3::xenia_memory::TryResolvePhysicalAddress(
            0xA0010000u, PhysicalResolutionPolicy::kReXGluePhysicalHeapsOnly, &physical) &&
            physical == 0x10000u,
        "ReXGlue A alias physical conversion");
  check(cod3::xenia_memory::TryResolvePhysicalAddress(
            0xC1000000u, PhysicalResolutionPolicy::kReXGluePhysicalHeapsOnly, &physical) &&
            physical == 0x01000000u,
        "ReXGlue C alias physical conversion");
  check(cod3::xenia_memory::TryResolvePhysicalAddress(
            0xE0000000u, PhysicalResolutionPolicy::kReXGluePhysicalHeapsOnly, &physical) &&
            physical == 0x1000u,
        "ReXGlue E alias physical conversion");
  check(!cod3::xenia_memory::TryResolvePhysicalAddress(
            0x7F000000u, PhysicalResolutionPolicy::kReXGluePhysicalHeapsOnly, &physical),
        "ReXGlue does not claim the omitted v7F heap");
  check(cod3::xenia_memory::TryResolvePhysicalAddress(
            0x7F000000u, PhysicalResolutionPolicy::kXeniaCompatible, &physical) && physical == 0,
        "Xenia resolves the v7F physical alias");
  check(cod3::xenia_memory::TryResolvePhysicalAddress(
            0x00123456u, PhysicalResolutionPolicy::kXeniaCompatible, &physical) &&
            physical == 0x00123456u,
        "Xenia canonical physical pass-through");
  check(!cod3::xenia_memory::TryResolvePhysicalAddress(
            0x1FFFFFFFu, PhysicalResolutionPolicy::kXeniaCompatible, &physical),
        "Xenia canonical pass-through keeps its strict upper boundary");
  check(!cod3::xenia_memory::TryResolvePhysicalAddress(
            0x001FFFFFu, PhysicalResolutionPolicy::kReXGluePhysicalHeapsOnly, &physical),
        "ReXGlue rejects canonical physical pass-through");

  const MappingLayout layout{0x100000000ull, 0x200000000ull, 0x10000u};
  HostAddress host = 0;
  check(cod3::xenia_memory::TryTranslateVirtual(layout, 0xDFFFFFFFu, &host) &&
            host == 0x1DFFFFFFFu,
        "C alias virtual translation has no host offset");
  check(cod3::xenia_memory::TryTranslateVirtual(layout, 0xE0000000u, &host) &&
            host == 0x1E0001000ull,
        "E alias virtual translation adds host offset on coarse host");
  check(cod3::xenia_memory::HostAddressOffsetForGuest(0xE0000000u, 0x1000u) == 0,
        "E alias has no offset on 4K host");
  check(cod3::xenia_memory::HostAddressOffsetForGuest(0xE0000000u, 0x10000u) == 0x1000u,
        "E alias has offset on 64K host");
  check(cod3::xenia_memory::TryTranslatePhysical(layout, 0xF2345678u, &host) &&
            host == 0x212345678ull,
        "physical aperture is masked only after physical classification");

  GuestAddress guest = 0;
  check(cod3::xenia_memory::TryHostToGuestVirtual(layout, 0x1E0001000ull, &guest) &&
            guest == 0xE0000000u,
        "inverse translation removes E host offset");
  check(cod3::xenia_memory::TryHostToGuestVirtual(layout, 0x17FC80000ull, &guest) &&
            guest == 0x7FC80000u,
        "inverse translation identifies virtual MMIO address");
  check(!cod3::xenia_memory::TryHostToGuestVirtual(layout, layout.physical_membase, &guest),
        "physical base is excluded from virtual inverse");

  const HostAddress memory_end = layout.physical_membase + 0x1FFFFFFFull;
  check(cod3::xenia_memory::ClassifyFaultAddress(layout, layout.virtual_membase + 0x20,
                                                 memory_end) == FaultAddressSpace::kVirtualView,
        "fault in virtual view");
  check(cod3::xenia_memory::ClassifyFaultAddress(layout, memory_end, memory_end) ==
            FaultAddressSpace::kPhysicalView,
        "fault at inclusive physical end");
  check(cod3::xenia_memory::ClassifyFaultAddress(layout, memory_end + 1, memory_end) ==
            FaultAddressSpace::kOutsideMapping,
        "fault after inclusive physical end");

  check(cod3::xenia_memory::IsHardwareMmioAddress(0x7FC80000u) &&
            cod3::xenia_memory::IsHardwareMmioAddress(0x7FFFFFFCu) &&
            !cod3::xenia_memory::IsHardwareMmioAddress(0x7FC7FFFFu),
        "hardware MMIO predicate has exact lower boundary");
  check(cod3::xenia_memory::IsLegacyReXGlueMmioPredicate(0x7F000000u) &&
            !cod3::xenia_memory::IsHardwareMmioAddress(0x7F000000u),
        "legacy generated predicate divergence is observable");

  CallbackState state;
  MMIODispatchTable table;
  check(table.RegisterRange(cod3::xenia_memory::kGpuMmioBase,
                            cod3::xenia_memory::kMmioRangeMask,
                            cod3::xenia_memory::kMmioRangeSize, &state, ReadRegister, WriteRegister),
        "register GPU MMIO callback");
  std::uint32_t value = 0;
  void* ppc_context = reinterpret_cast<void*>(static_cast<std::uintptr_t>(0x1234u));
  check(table.CheckLoad(ppc_context, 0x7FC80010u, &value) && value == 0xAABBCCDDu &&
            state.reads == 1 && state.last_address == 0x7FC80010u &&
            state.last_ppc_context == ppc_context,
        "MMIO load callback ABI and address");
  check(table.CheckStore(ppc_context, 0x7FC80014u, 0x55667788u) && state.writes == 1 &&
            state.last_value == 0x55667788u,
        "MMIO store callback ABI and value");
  value = 0xDEADBEEFu;
  check(!table.CheckLoad(ppc_context, 0x7FC70000u, &value) && value == 0xDEADBEEFu,
        "unmatched CheckLoad leaves caller value untouched and reports false");
  check(!table.CheckStore(ppc_context, 0x7FC70000u, 1u),
        "unmatched CheckStore reports false");

  MMIODispatchTable first_match;
  first_match.RegisterRange(0x7FC80000u, 0xFFFF0000u, 0xFFFFu, nullptr, ReadFirst, nullptr);
  first_match.RegisterRange(0x7FC80000u, 0xFFFF0000u, 0xFFFFu, nullptr, ReadSecond, nullptr);
  check(first_match.CheckLoad(nullptr, 0x7FC80020u, &value) && value == 0x11111111u,
        "MMIO lookup preserves first registered range");
  check(table.LookupRange(0x7FEA0000u) == nullptr,
        "GPU registration does not accidentally cover XMA range");

  std::cout << "RESULT " << passed << '/' << checks << " passed\n";
  return passed == checks ? 0 : 1;
}
