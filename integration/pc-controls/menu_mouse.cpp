// Mouse support for CoD3's menus: the front end, the pause menu and dialogs.
//
// The menus are Treyarch's console front end (FEMenuSystem / FEMenu /
// FEMenuEntry / FEText) and know nothing about a mouse. While one is on screen
// the pointer is released and shown; moving it over an entry selects that
// entry the way the D-pad does (same sound, same highlight), a left click on
// an entry presses A, the right button presses B and the wheel steps the
// D-pad. In gameplay the pointer is captured again for mouse look.
//
// Guest facts (FEMenu vtable 0x82070EDC, FEMenuSystem vtable 0x82070FC4):
//   FEMenuSystem  +4 FEMenu** menus, +12 active menu index (-1: none)
//     sub_824EE2E0  Update(system, f1 = dt), every system, every frame
//     sub_824E7468  OpenMenu(system, index, parent, slot)
//   FEMenu        +4 FEMenuEntry** entries, +32 s16 first visible row,
//                 +34 s16 selection, +38 s16 entry count, +40 s16 visible
//                 rows, +42 u16 flags (0x1 scrolling list), +48 u8 input
//                 locked, +49 u8 selection moves play a sound
//     vfunc 28      play the selection sound
//     vfunc 164     SetSelection(index, 1), as its own D-pad handlers do
//                   (sub_824C5E50 / sub_824C60D0)
//   FEMenuEntry   +16 FEText* label; vfunc 36 true = skipped by the D-pad
//   FEText        +4 alpha, +44/+48 anchor in the 640x480 front-end space,
//                 +56 highlighted scale
//     vfunc 240/244 width/height at a scale (null: +56)
//     vfunc 292     Align(f1 scale, float* x, float* y): anchor -> top-left,
//                   exactly as FEText::Draw (sub_824CFD58) places the text
#include "menu_mouse.h"

#include <rex/cvar.h>
#include <rex/kernel/xboxkrnl/video.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>
#include <rex/runtime.h>
#include <rex/system/interfaces/graphics.h>
#include <rex/system/xvideo.h>
#include <rex/ui/presenter.h>
#include <rex/ui/window.h>
#include <rex/ui/windowed_app_context.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace cod3::controls::menus {
namespace {

using Clock = std::chrono::steady_clock;

// The front end draws in a 640x480 space stretched over the whole picture.
constexpr float kFrontEndWidth = 640.0f;
constexpr float kFrontEndHeight = 480.0f;

// How long the menus keep the mouse after the last menu update: bridges a
// long frame without dropping the pointer into mouse look and back.
constexpr auto kMenuModeHold = std::chrono::milliseconds(400);
// ...and only once a menu has stayed up this long: some screens flash up for
// a frame or two (seen in a player's log: released and recaptured three times
// in three seconds), and releasing the mouse for those drops mouse look for
// the whole hold time in the middle of a fight.
constexpr auto kMenuModeSettle = std::chrono::milliseconds(60);

// Pointer slack around an entry's text, in front-end units: closes the gaps
// between rows and between the words of a row.
constexpr float kSlackX = 14.0f;
constexpr float kSlackY = 7.0f;

constexpr uint32_t kSystemMenus = 4;
constexpr uint32_t kSystemActive = 12;
constexpr uint32_t kMenuEntries = 4;
constexpr uint32_t kMenuFirstVisible = 32;
constexpr uint32_t kMenuSelection = 34;
constexpr uint32_t kMenuCount = 38;
constexpr uint32_t kMenuVisibleRows = 40;
constexpr uint32_t kMenuFlags = 42;
constexpr uint16_t kMenuFlagScrolling = 0x1;
constexpr uint32_t kMenuLocked = 48;
constexpr uint32_t kMenuSelectSound = 49;
constexpr uint32_t kEntryLabel = 16;
constexpr uint32_t kTextAlpha = 4;
constexpr uint32_t kTextX = 44;
constexpr uint32_t kTextY = 48;
constexpr uint32_t kTextScale = 56;
constexpr uint32_t kSlotMenuSound = 28;
constexpr uint32_t kSlotMenuSetSelection = 164;
constexpr uint32_t kSlotEntrySkipped = 36;
constexpr uint32_t kSlotTextWidth = 240;
constexpr uint32_t kSlotTextHeight = 244;
constexpr uint32_t kSlotTextAlign = 292;

constexpr uint16_t kPadDpadUp = 0x0001;
constexpr uint16_t kPadDpadDown = 0x0002;
constexpr uint16_t kPadStart = 0x0010;
constexpr uint16_t kPadA = 0x1000;
constexpr uint16_t kPadB = 0x2000;

uint32_t LoadU32(const uint8_t* base, uint32_t address) {
  uint32_t value;
  std::memcpy(&value, base + address, sizeof(value));
  return std::byteswap(value);
}
uint16_t LoadU16(const uint8_t* base, uint32_t address) {
  uint16_t value;
  std::memcpy(&value, base + address, sizeof(value));
  return std::byteswap(value);
}
float LoadF32(const uint8_t* base, uint32_t address) { return std::bit_cast<float>(LoadU32(base, address)); }
void StoreF32(uint8_t* base, uint32_t address, float value) {
  const uint32_t raw = std::byteswap(std::bit_cast<uint32_t>(value));
  std::memcpy(base + address, &raw, sizeof(raw));
}

// Objects of the front end live in the title's heap (0x82xxxxxx); floats such
// as 432.0f look like addresses too, so anything else is not followed.
bool IsHeapObject(uint32_t address) { return address >= 0x82000000u && address < 0x83000000u && !(address & 3); }
// The main executable's code section.
bool IsCode(uint32_t address) { return address >= 0x820A0000u && address < 0x825A0000u && !(address & 3); }

uint32_t Slot(const uint8_t* base, uint32_t object, uint32_t slot) {
  const uint32_t vtable = LoadU32(base, object);
  if (!IsHeapObject(vtable)) return 0;
  const uint32_t function = LoadU32(base, vtable + slot);
  return IsCode(function) ? function : 0;
}

// MSVC RTTI of a guest object: vtable[-1] -> complete object locator,
// +12 -> type descriptor, +8 -> ".?AVName@@".
std::string ClassName(const uint8_t* base, uint32_t object) {
  if (!IsHeapObject(object)) return {};
  const uint32_t vtable = LoadU32(base, object);
  if (!IsHeapObject(vtable)) return {};
  const uint32_t locator = LoadU32(base, vtable - 4);
  if (!IsHeapObject(locator)) return {};
  const uint32_t descriptor = LoadU32(base, locator + 12);
  if (!IsHeapObject(descriptor)) return {};
  const char* name = reinterpret_cast<const char*>(base + descriptor + 8);
  std::string text(name, strnlen(name, 64));
  if (text.starts_with(".?AV")) text = text.substr(4);
  if (text.ends_with("@@")) text.resize(text.size() - 2);
  return text;
}

// Calls recompiled guest functions from a hook, on the guest thread that runs
// it. Everything below the caller's stack pointer is free at a hook boundary,
// so the callee gets its stack there, with a small scratch block for out
// parameters just below the caller's frame. The caller's registers are put
// back afterwards; only the memory the callee writes remains.
class GuestCalls {
 public:
  GuestCalls(PPCContext& ctx, uint8_t* base) : ctx_(ctx), base_(base), saved_(ctx) {
    scratch_ = (ctx.r1.u32 - 64u) & ~15u;
  }
  ~GuestCalls() { ctx_ = saved_; }
  GuestCalls(const GuestCalls&) = delete;
  GuestCalls& operator=(const GuestCalls&) = delete;

  uint8_t* base() const { return base_; }
  uint32_t scratch(uint32_t offset) const { return scratch_ + offset; }

  bool Call(uint32_t function, uint32_t r3, uint32_t r4 = 0, uint32_t r5 = 0, double f1 = 0.0) {
    if (!IsCode(function)) return false;
    PPCFunc* host = rex::runtime::ResolveIndirectFunction(function);
    if (!host) return false;
    ctx_.r1.u64 = scratch_ - 256u;
    ctx_.r3.u64 = r3;
    ctx_.r4.u64 = r4;
    ctx_.r5.u64 = r5;
    ctx_.f1.f64 = f1;
    ctx_.lr = 0;
    host(ctx_, base_);
    return true;
  }
  uint32_t r3() const { return ctx_.r3.u32; }
  double f1() const { return ctx_.f1.f64; }

 private:
  PPCContext& ctx_;
  uint8_t* base_;
  PPCContext saved_;
  uint32_t scratch_ = 0;
};

struct Box {
  int index = -1;
  float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
};

// The on-screen box of an FEText, in front-end units.
bool TextBox(GuestCalls& calls, uint32_t text, Box& box) {
  uint8_t* base = calls.base();
  if (!IsHeapObject(text)) return false;
  if (!(LoadF32(base, text + kTextAlpha) > 0.05f)) return false;
  const float scale = LoadF32(base, text + kTextScale);
  if (!(scale > 0.01f && scale < 10.0f)) return false;
  const uint32_t width_fn = Slot(base, text, kSlotTextWidth);
  const uint32_t height_fn = Slot(base, text, kSlotTextHeight);
  const uint32_t align_fn = Slot(base, text, kSlotTextAlign);
  if (!width_fn || !height_fn || !align_fn) return false;
  if (!calls.Call(width_fn, text)) return false;
  const float width = float(calls.f1());
  if (!calls.Call(height_fn, text)) return false;
  const float height = float(calls.f1());
  if (!(width > 0.5f && height > 0.5f && width < 2000.0f && height < 2000.0f)) return false;
  StoreF32(base, calls.scratch(0), LoadF32(base, text + kTextX));
  StoreF32(base, calls.scratch(4), LoadF32(base, text + kTextY));
  if (!calls.Call(align_fn, text, calls.scratch(0), calls.scratch(4), scale)) return false;
  box.x0 = LoadF32(base, calls.scratch(0));
  box.y0 = LoadF32(base, calls.scratch(4));
  box.x1 = box.x0 + width;
  box.y1 = box.y0 + height;
  return std::isfinite(box.x0) && std::isfinite(box.y0);
}

struct MenuView {
  uint32_t menu = 0;
  int count = 0;
  int selection = -1;
  int first = 0;  // visible rows [first, last)
  int last = 0;
};

MenuView ViewOf(const uint8_t* base, uint32_t menu) {
  MenuView view;
  view.menu = menu;
  view.count = std::clamp<int>(int16_t(LoadU16(base, menu + kMenuCount)), 0, 64);
  view.selection = int16_t(LoadU16(base, menu + kMenuSelection));
  view.first = 0;
  view.last = view.count;
  if (LoadU16(base, menu + kMenuFlags) & kMenuFlagScrolling) {
    const int first = int16_t(LoadU16(base, menu + kMenuFirstVisible));
    const int rows = int16_t(LoadU16(base, menu + kMenuVisibleRows));
    if (rows > 0 && first >= 0) {
      view.first = std::min(first, view.count);
      view.last = std::min(first + rows, view.count);
    }
  }
  return view;
}

// A dialog (DialogMenuSystem) does not draw its entries' labels: its panel at
// system +52 has four row texts at +24..+36 and shows the options on them,
// laid out by the option count at +56 (sub_824BDDE8, which also picks the
// highlighted row). Returns the row text showing option 'index', or 0.
uint32_t DialogRowText(const uint8_t* base, uint32_t panel, int index) {
  const uint32_t count = LoadU32(base, panel + 56);
  int row = -1;
  switch (count) {
    case 1:
      row = 2;
      break;
    case 2:
    case 3:
      row = (LoadU32(base, panel + 28) && LoadU32(base, panel + 32)) ? index + 1 : index;
      break;
    case 4:
      row = index;
      break;
    default:
      break;
  }
  if (row < 0 || row > 3) return 0;
  const uint32_t text = LoadU32(base, panel + 24 + uint32_t(row) * 4u);
  return IsHeapObject(text) ? text : 0;
}

// Boxes of the visible entries the D-pad can select. 'dialog_panel' is the
// panel of a dialog, 0 for any other menu.
std::vector<Box> SelectableBoxes(GuestCalls& calls, const MenuView& view, uint32_t dialog_panel) {
  uint8_t* base = calls.base();
  std::vector<Box> boxes;
  const uint32_t entries = LoadU32(base, view.menu + kMenuEntries);
  if (!IsHeapObject(entries)) return boxes;
  for (int i = view.first; i < view.last; ++i) {
    const uint32_t entry = LoadU32(base, entries + uint32_t(i) * 4u);
    if (!IsHeapObject(entry)) continue;
    const uint32_t skipped_fn = Slot(base, entry, kSlotEntrySkipped);
    if (!skipped_fn || !calls.Call(skipped_fn, entry) || (calls.r3() & 0xFF)) continue;
    const uint32_t text = dialog_panel ? DialogRowText(base, dialog_panel, i) : LoadU32(base, entry + kEntryLabel);
    Box box;
    if (!TextBox(calls, text, box)) continue;
    box.index = i;
    boxes.push_back(box);
  }
  // Entries stacked in one column share its widest entry's width, so a short
  // word ("EASY") is as easy to point at as a long one. Entries side by side
  // (tabs) do not overlap horizontally and keep their own width.
  std::vector<Box> merged = boxes;
  for (Box& box : merged) {
    for (const Box& other : boxes) {
      if (other.x0 < box.x1 && box.x0 < other.x1) {
        box.x0 = std::min(box.x0, other.x0);
        box.x1 = std::max(box.x1, other.x1);
      }
    }
  }
  return merged;
}

void LogTextBoxes(GuestCalls& calls, uint32_t object, const char* label) {
  uint8_t* base = calls.base();
  for (uint32_t k = 0; k < 0x40; k += 4) {
    const uint32_t child = LoadU32(base, object + k);
    if (!IsHeapObject(child) || child == object) continue;
    const std::string name = ClassName(base, child);
    if (name != "FEText") continue;
    Box box;
    if (TextBox(calls, child, box)) {
      REXLOG_INFO("UI probe:   {} +{:02X} text {:.1f},{:.1f} - {:.1f},{:.1f} (anchor {:.1f},{:.1f})", label, k,
                  box.x0, box.y0, box.x1, box.y1, LoadF32(base, child + kTextX), LoadF32(base, child + kTextY));
    } else {
      REXLOG_INFO("UI probe:   {} +{:02X} text hidden/empty", label, k);
    }
  }
}

// The entry under a point, with some slack; the nearest one if several.
int HitTest(const std::vector<Box>& boxes, float x, float y) {
  int best = -1;
  float best_distance = 1e9f;
  for (const Box& box : boxes) {
    const float dx = std::max({box.x0 - x, 0.0f, x - box.x1});
    const float dy = std::max({box.y0 - y, 0.0f, y - box.y1});
    if (dx > kSlackX || dy > kSlackY) continue;
    // Adjacent rows overlap by a unit; there the nearer centre wins.
    const float distance = dx + dy * 2.0f + 0.001f * std::abs(y - (box.y0 + box.y1) * 0.5f);
    if (distance < best_distance) {
      best_distance = distance;
      best = box.index;
    }
  }
  return best;
}

// Moves the selection the way the menu's own D-pad handlers do. A dialog
// also moves its panel's highlighted row, as the dialogs themselves do when
// they set their first selection (sub_824BDDE8).
constexpr uint32_t kDialogSetHighlightRow = 0x824BDDE8;

void Select(GuestCalls& calls, uint32_t menu, int index, uint32_t dialog_panel) {
  uint8_t* base = calls.base();
  if (base[menu + kMenuSelectSound]) calls.Call(Slot(base, menu, kSlotMenuSound), menu);
  calls.Call(Slot(base, menu, kSlotMenuSetSelection), menu, uint32_t(index), 1);
  if (dialog_panel) calls.Call(kDialogSetHighlightRow, dialog_panel, uint32_t(index));
}

// ------------------------------------------------------------ shared state

enum class SystemKind { kFrontEnd, kInGame, kDialog, kOther };

struct System {
  uint32_t address = 0;
  uint32_t vtable = 0;  // the front end's systems are freed on the way into a level
  SystemKind kind = SystemKind::kOther;
};

bool Alive(const uint8_t* base, const System& s) { return s.address && LoadU32(base, s.address) == s.vtable; }

std::mutex g_mutex;
std::array<System, 8> g_systems{};
uint32_t g_last_opened = 0;  // the menu most recently opened, any system
rex::ui::Window* g_window = nullptr;

std::atomic<int64_t> g_menu_tick{0};   // steady_clock ticks of the last menu update
std::atomic<int64_t> g_menu_since{0};  // ...and of the first one of this menu stretch
std::atomic<bool> g_nav_hidden{false};

// Pointer input from the UI thread, taken by the guest thread (g_mutex).
struct PointerState {
  float x = -1.0f;  // where the pointer is now, front-end units
  float y = -1.0f;
  bool valid = false;  // over the picture
  bool hover = false;  // moved over the picture since the last menu update
  float hover_x = 0.0f;
  float hover_y = 0.0f;
  int left_clicks = 0;
  int right_clicks = 0;
  int wheel = 0;
};
PointerState g_pointer;

// Pad presses produced by the mouse (g_mutex).
struct Pulses {
  std::deque<uint16_t> queue;
  uint16_t current = 0;
  Clock::time_point until{};
  Clock::time_point next{};
};
Pulses g_pulses;

bool g_dump_boxes = false;  // development: log the hit boxes on the next update

void QueuePulse(uint16_t buttons) {
  if (g_pulses.queue.size() < 6) g_pulses.queue.push_back(buttons);
}

System* Track(const uint8_t* base, uint32_t system) {
  for (auto& s : g_systems) {
    if (s.address == system && Alive(base, s)) return &s;
  }
  for (auto& s : g_systems) {
    if (Alive(base, s)) continue;  // free, or a system that no longer exists
    s.address = system;
    s.vtable = LoadU32(base, system);
    const std::string name = ClassName(base, system);
    s.kind = name == "FrontEndMenuSystem" ? SystemKind::kFrontEnd
             : name == "InGameMenuSystem" ? SystemKind::kInGame
             : name == "DialogMenuSystem" ? SystemKind::kDialog
                                          : SystemKind::kOther;
    return &s;
  }
  return nullptr;
}

uint32_t ActiveMenu(const uint8_t* base, uint32_t system) {
  const int32_t active = int32_t(LoadU32(base, system + kSystemActive));
  if (active < 0 || active >= 64) return 0;
  const uint32_t menus = LoadU32(base, system + kSystemMenus);
  if (!IsHeapObject(menus)) return 0;
  const uint32_t menu = LoadU32(base, menus + uint32_t(active) * 4u);
  return IsHeapObject(menu) ? menu : 0;
}

int Rank(SystemKind kind) {
  switch (kind) {
    case SystemKind::kDialog: return 3;
    case SystemKind::kInGame: return 2;
    case SystemKind::kFrontEnd: return 1;
    default: return 0;
  }
}

// Called under g_mutex: a dialog sits over the pause menu and the front end.
bool CoveredByHigherSystem(const uint8_t* base, const System& self) {
  for (const auto& s : g_systems) {
    if (!Alive(base, s) || s.address == self.address) continue;
    if (Rank(s.kind) > Rank(self.kind) && ActiveMenu(base, s.address)) return true;
  }
  return false;
}

// ------------------------------------------------------------ development

bool ProbeEnabled() {
  static const bool enabled = [] {
    const char* value = std::getenv("COD3_UI_PROBE");
    return value && *value && *value != '0';
  }();
  return enabled;
}

void DumpWords(const uint8_t* base, uint32_t address, uint32_t bytes, const char* label) {
  if (!IsHeapObject(address)) return;
  REXLOG_INFO("UI probe: {} @{:08X}", label, address);
  for (uint32_t offset = 0; offset < bytes; offset += 32) {
    std::string line;
    for (uint32_t k = 0; k < 32; k += 4) {
      char word[12];
      std::snprintf(word, sizeof(word), " %08X", LoadU32(base, address + offset + k));
      line += word;
    }
    REXLOG_INFO("UI probe:   +{:03X}:{}", offset, line);
  }
}

void DumpActiveMenus(const uint8_t* base) {
  for (const auto& s : g_systems) {
    if (!Alive(base, s)) continue;
    const uint32_t menu = ActiveMenu(base, s.address);
    REXLOG_INFO("UI probe: system {:08X} {} active {} menu {} {:08X}", s.address, ClassName(base, s.address),
                int32_t(LoadU32(base, s.address + kSystemActive)), ClassName(base, menu), menu);
    if (!menu) continue;
    DumpWords(base, menu, 0x80, ClassName(base, menu).c_str());
    const MenuView view = ViewOf(base, menu);
    REXLOG_INFO("UI probe: {} entries, selected {}, visible {}..{}", view.count, view.selection, view.first,
                view.last);
  }
}

void WriteBmp(const std::string& path, const rex::ui::RawImage& image) {
  std::ofstream file(path, std::ios::binary);
  if (!file) return;
  const uint32_t row = (image.width * 3u + 3u) & ~3u;
  const uint32_t size = 54u + row * image.height;
  uint8_t header[54] = {'B', 'M'};
  auto put32 = [&](int at, uint32_t v) { std::memcpy(header + at, &v, 4); };
  auto put16 = [&](int at, uint16_t v) { std::memcpy(header + at, &v, 2); };
  put32(2, size);
  put32(10, 54);
  put32(14, 40);
  put32(18, image.width);
  put32(22, image.height);
  put16(26, 1);
  put16(28, 24);
  put32(34, row * image.height);
  file.write(reinterpret_cast<const char*>(header), sizeof(header));
  std::vector<uint8_t> line(row, 0);
  for (uint32_t y = image.height; y-- > 0;) {
    const uint8_t* source = image.data.data() + size_t(y) * image.stride;
    for (uint32_t x = 0; x < image.width; ++x) {
      line[x * 3 + 0] = source[x * 4 + 2];
      line[x * 3 + 1] = source[x * 4 + 1];
      line[x * 3 + 2] = source[x * 4 + 0];
    }
    file.write(reinterpret_cast<const char*>(line.data()), row);
  }
}

// The guest picture as the presenter has it, before letterboxing.
void CaptureGuestOutput(int number) {
  rex::ui::Window* window = g_window;
  if (!window) return;
  window->app_context().CallInUIThreadDeferred([number] {
    rex::Runtime* runtime = rex::Runtime::instance();
    rex::ui::Presenter* presenter =
        runtime && runtime->graphics_system() ? runtime->graphics_system()->presenter() : nullptr;
    rex::ui::RawImage image;
    if (!presenter || !presenter->CaptureGuestOutput(image)) {
      REXLOG_WARN("UI probe: capture {} failed", number);
      return;
    }
    const std::string path = "logs/ui-shot-" + std::to_string(number) + ".bmp";
    WriteBmp(path, image);
    REXLOG_INFO("UI probe: captured {} ({}x{})", path, image.width, image.height);
  });
}

// Captures 'count' guest pictures 'interval_ms' apart on a helper thread and
// logs a hash of the middle of each (the HUD at the edges is left out). How
// long the hash stays the same shows how often a new picture comes out: about
// 8 ms at a true 120 Hz, about 17 ms if the scene only changes at 60 Hz.
void BurstCapture(int count, int interval_ms) {
  std::thread([count, interval_ms] {
    rex::Runtime* runtime = rex::Runtime::instance();
    rex::ui::Presenter* presenter =
        runtime && runtime->graphics_system() ? runtime->graphics_system()->presenter() : nullptr;
    if (!presenter) return;
    const auto start = Clock::now();
    for (int i = 0; i < count; ++i) {
      rex::ui::RawImage image;
      const auto taken = Clock::now();
      if (!presenter->CaptureGuestOutput(image) || !image.width || !image.height) continue;
      uint64_t hash = 1469598103934665603ull;
      // 32x18 luminance thumbnail of the same region: how much the picture
      // moved between two captures, not just whether it changed.
      constexpr uint32_t kCellsX = 32, kCellsY = 18;
      uint32_t sums[kCellsX * kCellsY] = {};
      uint32_t counts[kCellsX * kCellsY] = {};
      const uint32_t x0 = image.width / 4, x1 = image.width * 3 / 4;
      const uint32_t y0 = image.height / 5, y1 = image.height * 7 / 10;
      for (uint32_t y = y0; y < y1; y += 2) {
        const uint8_t* row = image.data.data() + size_t(y) * image.stride;
        const uint32_t cy = (y - y0) * kCellsY / (y1 - y0);
        for (uint32_t x = x0; x < x1; x += 2) {
          hash = (hash ^ (uint64_t(row[x * 4]) | uint64_t(row[x * 4 + 1]) << 8 | uint64_t(row[x * 4 + 2]) << 16)) *
                 1099511628211ull;
          const uint32_t cell = cy * kCellsX + (x - x0) * kCellsX / (x1 - x0);
          sums[cell] += (uint32_t(row[x * 4]) * 3 + uint32_t(row[x * 4 + 1]) * 6 + uint32_t(row[x * 4 + 2])) / 10;
          ++counts[cell];
        }
      }
      std::string thumb;
      thumb.reserve(kCellsX * kCellsY * 2);
      for (uint32_t c = 0; c < kCellsX * kCellsY; ++c) {
        char hex[3];
        std::snprintf(hex, sizeof(hex), "%02X", counts[c] ? sums[c] / counts[c] : 0);
        thumb += hex;
      }
      REXLOG_INFO("UI probe: burst {} at {:.2f} ms hash {:016X} thumb {}", i,
                  std::chrono::duration<double, std::milli>(taken - start).count(), hash, thumb);
      std::this_thread::sleep_until(taken + std::chrono::milliseconds(interval_ms));
    }
  }).detach();
}

uint16_t ButtonBits(const std::string& name) {
  static const std::pair<const char*, uint16_t> kButtons[] = {
      {"UP", 0x0001}, {"DOWN", 0x0002}, {"LEFT", 0x0004}, {"RIGHT", 0x0008}, {"START", 0x0010},
      {"BACK", 0x0020}, {"L3", 0x0040}, {"R3", 0x0080}, {"LB", 0x0100}, {"RB", 0x0200},
      {"A", 0x1000}, {"B", 0x2000}, {"X", 0x4000}, {"Y", 0x8000}};
  for (const auto& [text, bits] : kButtons) {
    if (name == text) return bits;
  }
  return 0;
}

// COD3_INPUT_SCRIPT: a sequence of steps, one per line,
//   <delay s> <BUTTON> [hold ms]   press a pad button
//   <delay s> <BUTTON>? [Class]    press it once a second until a menu (of
//                                  that class) opens
//   <delay s> MOVE <x> <y>         put the pointer at a front-end position
//   <delay s> CLICK | RCLICK       mouse buttons, as the menus take them
//   <delay s> WHEEL <notches>
//   <delay s> DUMP                 log the active menus and hit boxes
//   <delay s> SHOT                 capture the guest picture
// Each delay counts from the end of the previous step. Feeds pad 0 and the
// menu pointer without keyboard focus, so a test drives the menus without
// touching the desktop's keyboard or mouse.
//   <delay s> STICK <lx> <ly> <ms> hold the left stick (-1..1) in the background
//   <delay s> BURST <n> <ms>       capture n pictures, ms apart (BurstCapture)
//   <delay s> WAITGAME             wait until gameplay (the look update) runs
//   <delay s> ACTORS               dump the actor list G_RunFrame walks
//   <delay s> ENTS                 dump type and origin of every game entity
//   <delay s> CVAR <name> <value>  set a setting while the game runs
struct ScriptStep {
  enum Kind {
    kPress, kPressUntilOpen, kDump, kShot, kMove, kClick, kRightClick, kWheel, kStick, kBurst, kWaitGame, kActors,
    kEnts, kCvar
  } kind = kPress;
  double delay = 0;
  uint16_t buttons = 0;
  double hold = 0.12;
  std::string until;
  std::string value;
  float x = 0, y = 0;
  int wheel = 0;
};

struct Script {
  bool loaded = false;
  std::vector<ScriptStep> steps;
  size_t next = 0;
  Clock::time_point step_start{};
  bool step_running = false;
  uint32_t opens = 0;
  uint32_t opens_at_step = 0;
  float stick_x = 0, stick_y = 0;
  Clock::time_point stick_until{};
  float look_x = 0, look_y = 0;
  Clock::time_point look_until{};
};
Script g_script;
std::atomic<int64_t> g_gameplay_tick{0};  // last look update, steady_clock ticks

void LoadScript() {
  g_script.loaded = true;
  const char* path = std::getenv("COD3_INPUT_SCRIPT");
  if (!path || !*path) return;
  std::ifstream file(path);
  std::string line;
  while (std::getline(file, line)) {
    std::istringstream in(line);
    ScriptStep step;
    std::string what;
    if (!(in >> step.delay >> what) || what.empty() || what[0] == '#') continue;
    if (what == "DUMP") {
      step.kind = ScriptStep::kDump;
    } else if (what == "SHOT") {
      step.kind = ScriptStep::kShot;
    } else if (what == "MOVE") {
      step.kind = ScriptStep::kMove;
      in >> step.x >> step.y;
    } else if (what == "CLICK") {
      step.kind = ScriptStep::kClick;
    } else if (what == "RCLICK") {
      step.kind = ScriptStep::kRightClick;
    } else if (what == "WHEEL") {
      step.kind = ScriptStep::kWheel;
      in >> step.wheel;
    } else if (what == "STICK" || what == "LOOK") {
      step.kind = ScriptStep::kStick;
      step.wheel = what == "LOOK" ? 1 : 0;  // right stick
      double hold_ms = 0;
      in >> step.x >> step.y >> hold_ms;
      step.hold = hold_ms / 1000.0;
    } else if (what == "BURST") {
      step.kind = ScriptStep::kBurst;
      in >> step.wheel >> step.hold;  // count, interval ms
    } else if (what == "WAITGAME") {
      step.kind = ScriptStep::kWaitGame;
    } else if (what == "ACTORS") {
      step.kind = ScriptStep::kActors;
    } else if (what == "ENTS") {
      step.kind = ScriptStep::kEnts;
    } else if (what == "CVAR") {
      step.kind = ScriptStep::kCvar;
      in >> step.until >> step.value;
    } else {
      if (what.back() == '?') {
        step.kind = ScriptStep::kPressUntilOpen;
        what.pop_back();
      }
      step.buttons = ButtonBits(what);
      if (!step.buttons) continue;
      if (step.kind == ScriptStep::kPressUntilOpen) {
        in >> step.until;
      } else {
        double hold_ms = 0;
        if (in >> hold_ms) step.hold = hold_ms / 1000.0;
      }
    }
    g_script.steps.push_back(step);
  }
  g_script.step_start = Clock::now();
  REXLOG_INFO("UI probe: input script {} with {} steps", path, g_script.steps.size());
}

// Called under g_mutex.
uint16_t RunScript(const uint8_t* base) {
  auto& s = g_script;
  if (s.next >= s.steps.size()) return 0;
  const auto now = Clock::now();
  const ScriptStep& step = s.steps[s.next];
  const double t = std::chrono::duration<double>(now - s.step_start).count() - step.delay;
  if (t < 0) return 0;
  auto finish = [&] {
    ++s.next;
    s.step_start = now;
    s.step_running = false;
  };
  switch (step.kind) {
    case ScriptStep::kDump:
      REXLOG_INFO("UI probe: dump (step {})", s.next);
      DumpActiveMenus(base);
      g_dump_boxes = true;
      finish();
      return 0;
    case ScriptStep::kShot:
      REXLOG_INFO("UI probe: SHOT {}", s.next);
      CaptureGuestOutput(int(s.next));
      finish();
      return 0;
    case ScriptStep::kMove:
      g_pointer.x = g_pointer.hover_x = step.x;
      g_pointer.y = g_pointer.hover_y = step.y;
      g_pointer.valid = g_pointer.hover = true;
      REXLOG_INFO("UI probe: pointer at {:.0f},{:.0f}", step.x, step.y);
      finish();
      return 0;
    case ScriptStep::kClick:
      ++g_pointer.left_clicks;
      finish();
      return 0;
    case ScriptStep::kRightClick:
      ++g_pointer.right_clicks;
      finish();
      return 0;
    case ScriptStep::kWheel:
      g_pointer.wheel += step.wheel;
      finish();
      return 0;
    case ScriptStep::kPress:
      if (t < step.hold) return step.buttons;
      finish();
      return 0;
    case ScriptStep::kStick:
      if (step.wheel) {
        s.look_x = step.x;
        s.look_y = step.y;
        s.look_until = now + std::chrono::microseconds(int64_t(step.hold * 1e6));
      } else {
        s.stick_x = step.x;
        s.stick_y = step.y;
        s.stick_until = now + std::chrono::microseconds(int64_t(step.hold * 1e6));
      }
      REXLOG_INFO("UI probe: {} stick {:.2f},{:.2f} for {:.0f} ms", step.wheel ? "right" : "left", step.x, step.y,
                  step.hold * 1000.0);
      finish();
      return 0;
    case ScriptStep::kBurst:
      REXLOG_INFO("UI probe: burst of {} every {:.0f} ms", step.wheel, step.hold);
      BurstCapture(step.wheel, int(step.hold));
      finish();
      return 0;
    case ScriptStep::kActors: {
      // G_RunFrame (sub_8256D3E0) walks *(0x82A2AB40)[1..count], count at
      // 0x82A4E790 +148, and skips entries whose +536 is null.
      const uint32_t count = LoadU32(base, 0x82A4E790 + 148);
      const uint32_t list = LoadU32(base, 0x82A2AB40);
      REXLOG_INFO("UI probe: actors {} list {:08X}", count, list);
      for (uint32_t i = 0; i < count && i < 24 && IsHeapObject(list); ++i) {
        const uint32_t actor = LoadU32(base, list + 4 + i * 4);
        if (!IsHeapObject(actor)) continue;
        std::string floats;
        for (uint32_t k = 0; k < 0x300; k += 4) {
          const float v = LoadF32(base, actor + k);
          char item[24];
          if (std::isfinite(v) && std::abs(v) > 1.0f && std::abs(v) < 100000.0f) {
            std::snprintf(item, sizeof(item), " %X:%.1f", k, v);
            floats += item;
          }
        }
        REXLOG_INFO("UI probe: actor {} @{:08X} +536 {:08X}{}", i, actor, LoadU32(base, actor + 536), floats);
      }
      finish();
      return 0;
    }
    case ScriptStep::kEnts: {
      // The entity list the game and the client share (G_RunEntities,
      // CG_SetNextSnap): pointers at 0x82A35AD4, count at 0x82A45CD4; +0
      // type byte, +500 handle, +336/+340/+344 origin (sub_82421AA8 reads it).
      const uint32_t count = std::min<uint32_t>(LoadU32(base, 0x82A45CD4), 1024);
      std::string line;
      int shown = 0;
      for (uint32_t i = 0; i < count; ++i) {
        const uint32_t ent = LoadU32(base, 0x82A35AD4 + i * 4);
        if (ent < 0x10000 || (ent & 3)) continue;
        const float x = LoadF32(base, ent + 336), y = LoadF32(base, ent + 340), z = LoadF32(base, ent + 344);
        if (!std::isfinite(x) || !std::isfinite(y) || (x == 0.0f && y == 0.0f)) continue;
        char item[96];
        std::snprintf(item, sizeof(item), " %u:%u:%08X:%.1f,%.1f,%.1f", i, unsigned(base[ent]), LoadU32(base, ent + 500),
                      x, y, z);
        line += item;
        if (++shown % 16 == 0) {
          REXLOG_INFO("UI probe: ents{}", line);
          line.clear();
        }
      }
      if (!line.empty()) REXLOG_INFO("UI probe: ents{}", line);
      REXLOG_INFO("UI probe: ents end ({} of {})", shown, count);
      finish();
      return 0;
    }
    case ScriptStep::kCvar:
      rex::cvar::SetFlagByName(step.until, step.value);
      REXLOG_INFO("UI probe: cvar {} = {}", step.until, rex::cvar::GetFlagByName(step.until));
      finish();
      return 0;
    case ScriptStep::kWaitGame: {
      const int64_t tick = g_gameplay_tick.load(std::memory_order_relaxed);
      if (tick && Clock::now().time_since_epoch().count() - tick <
                      std::chrono::duration_cast<Clock::duration>(std::chrono::milliseconds(100)).count()) {
        REXLOG_INFO("UI probe: gameplay after {:.1f} s", t);
        finish();
      }
      return 0;
    }
    case ScriptStep::kPressUntilOpen: {
      if (!s.step_running) {
        s.step_running = true;
        s.opens_at_step = s.opens;
      }
      const bool done = step.until.empty() ? s.opens != s.opens_at_step
                                           : ClassName(base, g_last_opened) == step.until;
      if (done) {
        REXLOG_INFO("UI probe: step {} reached {} after {:.1f} s", s.next, ClassName(base, g_last_opened), t);
        finish();
        return 0;
      }
      return std::fmod(t, 1.0) < step.hold ? step.buttons : 0;
    }
  }
  return 0;
}

}  // namespace

// ------------------------------------------------------------ UI thread

void AttachWindow(rex::ui::Window* window) {
  std::lock_guard lock(g_mutex);
  g_window = window;
}

void OnPointerMove(int32_t x, int32_t y, uint32_t client_width, uint32_t client_height) {
  if (!client_width || !client_height) return;
  // Where the presenter puts the guest picture: the display aspect ratio of
  // the guest video mode, fitted and centred (present_letterbox), or
  // stretched over the whole client area.
  static uint32_t aspect_x = 0, aspect_y = 0;
  static bool letterbox = true;
  static Clock::time_point refreshed{};
  const auto now = Clock::now();
  if (!aspect_x || now - refreshed > std::chrono::seconds(2)) {
    refreshed = now;
    rex::system::X_VIDEO_MODE mode{};
    rex::kernel::xboxkrnl::VdQueryVideoMode(&mode);
    aspect_x = std::max<uint32_t>(1, uint32_t(mode.display_width));
    aspect_y = std::max<uint32_t>(1, uint32_t(mode.display_height));
    letterbox = rex::cvar::GetFlagByName("present_letterbox") != "false";
  }
  double width = client_width, height = client_height, left = 0.0, top = 0.0;
  if (letterbox) {
    if (double(client_width) * aspect_y > double(client_height) * aspect_x) {
      width = double(client_height) * aspect_x / aspect_y;
      left = (double(client_width) - width) / 2.0;
    } else {
      height = double(client_width) * aspect_y / aspect_x;
      top = (double(client_height) - height) / 2.0;
    }
  }
  const float u = float((x + 0.5 - left) / width);
  const float v = float((y + 0.5 - top) / height);
  if (ProbeEnabled()) {
    static Clock::time_point logged{};
    if (now - logged > std::chrono::milliseconds(100)) {
      logged = now;
      REXLOG_INFO("UI probe: pointer event {},{} in {}x{} (display {}:{}{}) -> {:.1f},{:.1f}", x, y, client_width,
                  client_height, aspect_x, aspect_y, letterbox ? ", letterboxed" : "", u * kFrontEndWidth,
                  v * kFrontEndHeight);
    }
  }
  std::lock_guard lock(g_mutex);
  g_pointer.x = u * kFrontEndWidth;
  g_pointer.y = v * kFrontEndHeight;
  g_pointer.valid = u >= 0.0f && u <= 1.0f && v >= 0.0f && v <= 1.0f;
  if (g_pointer.valid) {
    g_pointer.hover = true;
    g_pointer.hover_x = g_pointer.x;
    g_pointer.hover_y = g_pointer.y;
  }
}

void OnPointerClick(bool right) {
  std::lock_guard lock(g_mutex);
  if (right) {
    ++g_pointer.right_clicks;
  } else {
    ++g_pointer.left_clicks;
  }
}

void OnPointerWheel(int notches) {
  std::lock_guard lock(g_mutex);
  g_pointer.wheel = std::clamp(g_pointer.wheel + notches, -6, 6);
}

void OnNavigationInput() { g_nav_hidden.store(true, std::memory_order_relaxed); }
void OnPointerMotion() { g_nav_hidden.store(false, std::memory_order_relaxed); }
bool PointerHiddenByNavigation() { return MenuMode() && g_nav_hidden.load(std::memory_order_relaxed); }

// ------------------------------------------------------------ any thread

bool MenuMode() {
  const int64_t tick = g_menu_tick.load(std::memory_order_acquire);
  const int64_t since = g_menu_since.load(std::memory_order_acquire);
  auto ticks = [](auto duration) { return std::chrono::duration_cast<Clock::duration>(duration).count(); };
  return tick != 0 && Clock::now().time_since_epoch().count() - tick < ticks(kMenuModeHold) &&
         tick - since >= ticks(kMenuModeSettle);
}

// ------------------------------------------------------------ guest thread

void UpdateSystem(PPCContext& ctx, uint8_t* base, uint32_t system) {
  PointerState input;
  uint32_t menu = 0;
  uint32_t dialog_panel = 0;
  bool dump = false;
  {
    std::lock_guard lock(g_mutex);
    const System* tracked = Track(base, system);
    if (!tracked) return;
    menu = ActiveMenu(base, system);
    if (!menu || CoveredByHigherSystem(base, *tracked)) return;
    if (tracked->kind == SystemKind::kDialog) {
      dialog_panel = LoadU32(base, system + 52);
      if (!IsHeapObject(dialog_panel)) return;
    }
    // Only this (guest) thread writes these; the start of a new menu stretch
    // is stored first, so a reader never pairs the new tick with an old start.
    const int64_t now_ticks = Clock::now().time_since_epoch().count();
    const int64_t previous = g_menu_tick.load(std::memory_order_relaxed);
    if (!previous ||
        now_ticks - previous >= std::chrono::duration_cast<Clock::duration>(kMenuModeHold).count()) {
      g_menu_since.store(now_ticks, std::memory_order_release);
    }
    g_menu_tick.store(now_ticks, std::memory_order_release);
    input = g_pointer;
    g_pointer.hover = false;
    g_pointer.left_clicks = g_pointer.right_clicks = g_pointer.wheel = 0;
    dump = std::exchange(g_dump_boxes, false);
  }
  const bool click = input.left_clicks > 0 && input.valid;
  const bool pointer_used = input.hover || click;
  if (!pointer_used && !input.right_clicks && !input.wheel && !dump) return;
  // Mid-transition the menu ignores its own D-pad too.
  if (base[menu + kMenuLocked] && !dump) return;

  const MenuView view = ViewOf(base, menu);
  GuestCalls calls(ctx, base);
  std::vector<Box> boxes;
  if (pointer_used || dump) boxes = SelectableBoxes(calls, view, dialog_panel);
  if (dump) {
    REXLOG_INFO("UI probe: {} {:08X} selection {} of {}, {} selectable boxes", ClassName(base, menu), menu,
                view.selection, view.count, boxes.size());
    for (const Box& box : boxes) {
      REXLOG_INFO("UI probe:   box {} {:.1f},{:.1f} - {:.1f},{:.1f}", box.index, box.x0, box.y0, box.x1, box.y1);
    }
    if (dialog_panel) {
      REXLOG_INFO("UI probe: dialog panel {:08X}, {} options, highlighted row {}", dialog_panel,
                  LoadU32(base, dialog_panel + 56), int32_t(LoadU32(base, dialog_panel + 60)));
      LogTextBoxes(calls, dialog_panel, "panel");
    }
  }
  if (base[menu + kMenuLocked]) return;

  uint16_t pulses[8];
  int pulse_count = 0;
  int selection = view.selection;
  if (input.hover) {
    const int hit = HitTest(boxes, input.hover_x, input.hover_y);
    if (hit >= 0 && hit != selection) {
      Select(calls, menu, hit, dialog_panel);
      selection = hit;
    }
  }
  if (click) {
    // A click acts where the pointer is now.
    const int hit = HitTest(boxes, input.x, input.y);
    if (hit >= 0) {
      if (hit != selection) Select(calls, menu, hit, dialog_panel);
      pulses[pulse_count++] = kPadA;
    } else if (boxes.empty() && selection < 0) {
      // Screens with nothing to select ("Press START", notices) take a click
      // anywhere on the picture. A menu whose entries are merely not visible
      // yet (fading in) does not: that click would accept an entry the
      // pointer is not on.
      pulses[pulse_count++] = ClassName(base, menu) == "TitleMenu" ? kPadStart : kPadA;
    }
  }
  if (input.right_clicks > 0) pulses[pulse_count++] = kPadB;
  for (int n = std::min(std::abs(input.wheel), 4); n > 0 && pulse_count < 8; --n) {
    pulses[pulse_count++] = input.wheel > 0 ? kPadDpadUp : kPadDpadDown;
  }
  if (pulse_count) {
    std::lock_guard lock(g_mutex);
    for (int i = 0; i < pulse_count; ++i) QueuePulse(pulses[i]);
  }
}

uint16_t TakePadButtons() {
  std::lock_guard lock(g_mutex);
  const auto now = Clock::now();
  if (now >= g_pulses.until && now >= g_pulses.next && !g_pulses.queue.empty()) {
    g_pulses.current = g_pulses.queue.front();
    g_pulses.queue.pop_front();
    // Held for a few frames, then released for as long, so each one is its
    // own press to the game.
    g_pulses.until = now + std::chrono::milliseconds(60);
    g_pulses.next = now + std::chrono::milliseconds(120);
  }
  return now < g_pulses.until ? g_pulses.current : 0;
}

void NoteMenuOpen(uint8_t* base, uint32_t system, int32_t index, int32_t parent, int32_t slot) {
  std::lock_guard lock(g_mutex);
  Track(base, system);
  ++g_script.opens;
  const uint32_t menus = LoadU32(base, system + kSystemMenus);
  const uint32_t menu = (index >= 0 && IsHeapObject(menus)) ? LoadU32(base, menus + uint32_t(index) * 4u) : 0;
  g_last_opened = IsHeapObject(menu) ? menu : 0;
  if (ProbeEnabled()) {
    REXLOG_INFO("UI probe: open {} {:08X} index {} parent {} slot {} -> {} {:08X}", ClassName(base, system), system,
                index, parent, slot, ClassName(base, menu), menu);
  } else {
    // Menu changes are rare and say a lot in a player's log (which screen
    // flashed up, which one released the mouse).
    std::string system_name = ClassName(base, system);
    if (system_name.ends_with("MenuSystem")) system_name.resize(system_name.size() - 10);
    if (menu) {
      REXLOG_INFO("Game menu: {} opened ({})", ClassName(base, menu), system_name);
    } else {
      REXLOG_INFO("Game menu: {} menus closed", system_name);
    }
  }
}

bool PollDevelopmentHooks(uint8_t* base, ScriptPad& pad) {
  pad = {};
  std::lock_guard lock(g_mutex);
  if (!g_script.loaded) LoadScript();
  if (g_script.steps.empty()) return false;
  pad.buttons = RunScript(base);
  if (Clock::now() < g_script.stick_until) {
    pad.lx = int16_t(std::clamp(g_script.stick_x, -1.0f, 1.0f) * 32767.0f);
    pad.ly = int16_t(std::clamp(g_script.stick_y, -1.0f, 1.0f) * 32767.0f);
  }
  if (Clock::now() < g_script.look_until) {
    pad.rx = int16_t(std::clamp(g_script.look_x, -1.0f, 1.0f) * 32767.0f);
    pad.ry = int16_t(std::clamp(g_script.look_y, -1.0f, 1.0f) * 32767.0f);
  }
  return true;
}

void NoteGameplayFrame() {
  g_gameplay_tick.store(Clock::now().time_since_epoch().count(), std::memory_order_relaxed);
}

}  // namespace cod3::controls::menus
