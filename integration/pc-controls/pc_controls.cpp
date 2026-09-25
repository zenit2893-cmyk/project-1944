#include "pc_controls.h"
#include "game_cursor.h"
#include "menu_mouse.h"
#include "stick_qte.h"

#include <rex/cvar.h>
#include <rex/input/mnk/mnk_input_driver.h>
#include <rex/logging.h>
#include <rex/ui/keybinds.h>
#include <rex/ui/ui_event.h>
#include <rex/ui/virtual_key.h>
#include <rex/ui/window.h>
#include <rex/ui/window_listener.h>
#include <rex/ui/windowed_app_context.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <initializer_list>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// Settings. All of them can be passed on the command line (--name=value); the
// launcher writes them from its controls page.
// ---------------------------------------------------------------------------
REXCVAR_DEFINE_BOOL(pc_controls, true, "PC Controls",
                    "Own the keyboard/mouse mapping instead of the SDK keybind_* layer");
REXCVAR_DEFINE_BOOL(pc_mouse_direct, true, "PC Controls",
                    "Write mouse motion straight into the view angles (PC Call of Duty feel) "
                    "instead of emulating the right stick");
REXCVAR_DEFINE_DOUBLE(pc_mouse_sensitivity, 5.0, "PC Controls",
                      "Mouse sensitivity on the Call of Duty PC scale: degrees per count = "
                      "sensitivity * pc_mouse_yaw. World at War defaults to 5")
    .range(0.1, 40.0);
REXCVAR_DEFINE_DOUBLE(pc_mouse_yaw, 0.022, "PC Controls", "Degrees of yaw per count at sensitivity 1 (m_yaw)")
    .range(0.001, 1.0);
REXCVAR_DEFINE_DOUBLE(pc_mouse_pitch, 0.022, "PC Controls", "Degrees of pitch per count at sensitivity 1 (m_pitch)")
    .range(0.001, 1.0);
REXCVAR_DEFINE_BOOL(pc_mouse_invert, false, "PC Controls", "Invert vertical mouse look");
REXCVAR_DEFINE_BOOL(pc_mouse_ads_scaling, true, "PC Controls",
                    "Scale mouse look by the game's own zoom sensitivity while aiming, as the PC "
                    "games do with the field of view");
REXCVAR_DEFINE_DOUBLE(pc_mouse_ads_multiplier, 1.0, "PC Controls",
                      "Extra multiplier applied only while the game reports a zoomed view")
    .range(0.1, 3.0);
REXCVAR_DEFINE_BOOL(pc_ads_toggle, false, "PC Controls",
                    "Aim button toggles aiming down sights instead of holding it");
REXCVAR_DEFINE_INT32(pc_prone_hold_ms, 600, "PC Controls",
                     "How long the prone key holds the crouch button; CoD3 goes prone on a held B");
REXCVAR_DEFINE_BOOL(pc_controls_debug, false, "PC Controls",
                    "Log the applied look deltas and pad merges once per second");
REXCVAR_DEFINE_BOOL(pc_qte_assist, true, "PC Controls",
                    "Stick battle actions (turning a charge's fuse, rocking) follow mouse circles, the "
                    "mouse wheel and WASD/arrows in either direction, on whichever stick the game asks for");
REXCVAR_DEFINE_BOOL(pc_qte_rate_fix, true, "PC Controls",
                    "Rescale the stick-swirl action to the 60 Hz frame it was tuned for; at 120 Hz the "
                    "game otherwise needs twice the turning speed (gamepad included)");
REXCVAR_DEFINE_STRING(pc_cursor, "brass", "PC Controls",
                      "Mouse pointer in the game window: a style under launcher/assets/cursors "
                      "(brass, reticle) or 'system'");
// The console ran G_RunFrame once per 60 Hz frame (16-17 ms), and its AI and
// scripts were tuned for that step. At 120 Hz every rendered frame ran it with
// 8-9 ms steps, and actors got stuck and walked oddly. The client
// interpolates entities between server snapshots, so the picture keeps the
// full rate (verified: a 120 Hz capture burst while walking changes evenly
// every 8.3 ms, and the player covers the same distance in the same time).
// Off by default since 2026-09-25: in this engine the game step also prepares
// what the frame draws (model poses, visibility, the characters' shadow
// passes), so frames without a step drew soldiers and objects without their
// shadows or not at all - blinking at 120 Hz that no screenshot shows, since
// every single frame is correct. Tester trace logs: the two character shadow
// maps rendered strictly every other frame (FpFp) at 120 fps with 60, every
// frame with the step in each frame.
REXCVAR_DEFINE_INT32(cod3_server_hz, 0, "Game",
                     "Rate of the game simulation (server frame: AI, scripts, entities); 0 runs it every "
                     "rendered frame, as the engine is built for. 60 is the console's rate but makes models "
                     "and their shadows blink at higher frame rates")
    .range(0, 1000);
REXCVAR_DEFINE_BOOL(pc_menu_mouse, true, "PC Controls",
                    "Menus (front end, pause, dialogs) release the mouse and show the pointer: hovering "
                    "selects, left click accepts, right click goes back, the wheel scrolls");
REXCVAR_DEFINE_DOUBLE(pc_qte_mouse_gain, 1.0, "PC Controls",
                      "Stick turns per mouse circle in stick-swirl actions")
    .range(0.25, 4.0);

REXCVAR_DEFINE_STRING(pc_bind_forward, "W", "PC Controls/Binds", "Move forward");
REXCVAR_DEFINE_STRING(pc_bind_back, "S", "PC Controls/Binds", "Move back");
REXCVAR_DEFINE_STRING(pc_bind_left, "A", "PC Controls/Binds", "Strafe left");
REXCVAR_DEFINE_STRING(pc_bind_right, "D", "PC Controls/Binds", "Strafe right");
REXCVAR_DEFINE_STRING(pc_bind_sprint, "Shift", "PC Controls/Binds", "Sprint / hold breath (L3)");
REXCVAR_DEFINE_STRING(pc_bind_jump, "Space", "PC Controls/Binds", "Jump / stand (A)");
REXCVAR_DEFINE_STRING(pc_bind_crouch, "C", "PC Controls/Binds", "Crouch (B)");
REXCVAR_DEFINE_STRING(pc_bind_prone, "Control,Z", "PC Controls/Binds", "Prone (held B)");
REXCVAR_DEFINE_STRING(pc_bind_reload, "R", "PC Controls/Binds", "Reload (X)");
REXCVAR_DEFINE_STRING(pc_bind_use, "F,E", "PC Controls/Binds", "Use / interact (X)");
REXCVAR_DEFINE_STRING(pc_bind_weapon, "1,2,WheelUp,WheelDown", "PC Controls/Binds", "Switch weapon (Y)");
REXCVAR_DEFINE_STRING(pc_bind_frag, "G", "PC Controls/Binds", "Frag grenade (RB)");
REXCVAR_DEFINE_STRING(pc_bind_smoke, "4,Mouse5", "PC Controls/Binds", "Smoke grenade (LB)");
REXCVAR_DEFINE_STRING(pc_bind_melee, "V,Mouse4", "PC Controls/Binds", "Melee (R3)");
REXCVAR_DEFINE_STRING(pc_bind_fire, "LMB", "PC Controls/Binds", "Fire (RT)");
REXCVAR_DEFINE_STRING(pc_bind_aim, "RMB", "PC Controls/Binds", "Aim down sights (LT)");
REXCVAR_DEFINE_STRING(pc_bind_binoculars, "B,MMB", "PC Controls/Binds", "Binoculars (D-pad up)");
REXCVAR_DEFINE_STRING(pc_bind_objectives, "Tab", "PC Controls/Binds", "Objectives (Back)");
REXCVAR_DEFINE_STRING(pc_bind_pause, "Escape", "PC Controls/Binds", "Pause menu (Start)");
REXCVAR_DEFINE_STRING(pc_bind_menu_up, "Up", "PC Controls/Binds", "Menu up (D-pad)");
REXCVAR_DEFINE_STRING(pc_bind_menu_down, "Down", "PC Controls/Binds", "Menu down (D-pad)");
REXCVAR_DEFINE_STRING(pc_bind_menu_left, "Left", "PC Controls/Binds", "Menu left (D-pad)");
REXCVAR_DEFINE_STRING(pc_bind_menu_right, "Right", "PC Controls/Binds", "Menu right (D-pad)");
REXCVAR_DEFINE_STRING(pc_bind_menu_accept, "Return,NumpadEnter", "PC Controls/Binds", "Menu accept (A)");
REXCVAR_DEFINE_STRING(pc_bind_menu_back, "Backspace", "PC Controls/Binds", "Menu back (B)");

namespace cod3::controls {
namespace {

using Clock = std::chrono::steady_clock;

// ---------------------------------------------------------------------------
// Guest layout, from the recompiled look update at 0x8250FF48:
//   lis r11,-32093 ; lwz r28,-24120(r11)   -> local client index
//   lis r11,-32091 ; addi r30,r11,30976    -> clientActive[] base
//   mulli r31,r28,7280                      -> element stride
//   +76   flags; bit 0x4000 set means the game skips view input entirely
//   +5696 zoom sensitivity (cgame's scale: field of view, ADS, shell shock)
//   +5732 viewangles[PITCH], +5736 viewangles[YAW]
// ---------------------------------------------------------------------------
constexpr uint32_t kLocalClientIndex = 0x82A2A1C8;
constexpr uint32_t kClientActiveBase = 0x82A57900;
constexpr uint32_t kClientActiveStride = 7280;
constexpr uint32_t kOffsetFlags = 76;
constexpr uint32_t kFlagViewInputDisabled = 0x4000;
constexpr uint32_t kOffsetZoomSensitivity = 5696;
constexpr uint32_t kOffsetPitch = 5732;
constexpr uint32_t kOffsetYaw = 5736;

// ---------------------------------------------------------------------------
// Stick battle actions, from the recompiled InteractInputRcvr* receivers:
//   sub_8250A660 writes the pad axes: 0x829C9140 + client*72 + axis*4, int
//     +-128; axis 0/1 right stick X/Y, 2/3 left stick X/Y, 4/5 triggers
//   receiver +16 -> interaction definition; definition +1092 leftStick,
//     +1088 swirlClockwise
//   StickSwirl update sub_82508238 reads the pair through sub_8250C6D8
//   StickToggle update sub_824F6498 reads one axis (+88 set: vertical, sign
//     inverted) and flips at +-70
// ---------------------------------------------------------------------------
constexpr uint32_t kStickArray = 0x829C9140;
constexpr uint32_t kStickArrayStride = 72;
constexpr uint32_t kReceiverDefinition = 16;
constexpr uint32_t kReceiverToggleVertical = 88;
constexpr uint32_t kDefinitionClockwise = 1088;
constexpr uint32_t kDefinitionLeftStick = 1092;
// While one of these actions ran this recently, the mouse and the wheel
// belong to it: no camera turn, no weapon switch.
constexpr auto kStickQteHold = std::chrono::milliseconds(300);

// Any guest data address: the virtual heaps (0x00000000-0x7FFFFFFF), the
// image (0x8xxxxxxx) and the physical-memory views (0xA0000000 and up). The
// interaction definitions come out of the level's .cod assets, which are
// unpacked into physical memory (0xAxxxxxxx-0xBxxxxxxx); the first version
// accepted only 0x40000000-0x9FFFFFFF, so no charge's fuse ever reached the
// mouse (tester log: no stick-swirl line at all, three Flak88 charges armed
// each time with a gamepad switched on for it).
bool IsGuestPointer(uint32_t address) { return address >= 0x00010000u && address < 0xFFFF0000u && !(address & 3); }

// XINPUT_GAMEPAD button bits and the guest XINPUT_STATE layout (big endian):
// +0 packet number, +4 buttons, +6 LT, +7 RT, +8 LX, +10 LY, +12 RX, +14 RY.
constexpr uint16_t kPadDpadUp = 0x0001;
constexpr uint16_t kPadDpadDown = 0x0002;
constexpr uint16_t kPadDpadLeft = 0x0004;
constexpr uint16_t kPadDpadRight = 0x0008;
constexpr uint16_t kPadStart = 0x0010;
constexpr uint16_t kPadBack = 0x0020;
constexpr uint16_t kPadLeftThumb = 0x0040;
constexpr uint16_t kPadRightThumb = 0x0080;
constexpr uint16_t kPadLeftShoulder = 0x0100;
constexpr uint16_t kPadRightShoulder = 0x0200;
constexpr uint16_t kPadA = 0x1000;
constexpr uint16_t kPadB = 0x2000;
constexpr uint16_t kPadX = 0x4000;
constexpr uint16_t kPadY = 0x8000;

uint32_t LoadU32(const uint8_t* base, uint32_t address) {
  uint32_t value;
  std::memcpy(&value, base + address, sizeof(value));
  return std::byteswap(value);
}
float LoadF32(const uint8_t* base, uint32_t address) {
  return std::bit_cast<float>(LoadU32(base, address));
}
void StoreF32(uint8_t* base, uint32_t address, float value) {
  uint32_t raw = std::byteswap(std::bit_cast<uint32_t>(value));
  std::memcpy(base + address, &raw, sizeof(raw));
}
uint16_t LoadU16(const uint8_t* base, uint32_t address) {
  uint16_t value;
  std::memcpy(&value, base + address, sizeof(value));
  return std::byteswap(value);
}
void StoreU16(uint8_t* base, uint32_t address, uint16_t value) {
  uint16_t raw = std::byteswap(value);
  std::memcpy(base + address, &raw, sizeof(raw));
}
void StoreU32(uint8_t* base, uint32_t address, uint32_t value) {
  uint32_t raw = std::byteswap(value);
  std::memcpy(base + address, &raw, sizeof(raw));
}

// ---------------------------------------------------------------------------
// Actions and binds.
// ---------------------------------------------------------------------------
enum Action : int {
  kForward, kBack, kLeft, kRight, kSprint, kJump, kCrouch, kProne, kReload, kUse,
  kWeapon, kFrag, kSmoke, kMelee, kFire, kAim, kBinoculars, kObjectives, kPause,
  kMenuUp, kMenuDown, kMenuLeft, kMenuRight, kMenuAccept, kMenuBack,
  kActionCount
};

const std::string& BindString(int action) {
  switch (action) {
    case kForward: return REXCVAR_GET(pc_bind_forward);
    case kBack: return REXCVAR_GET(pc_bind_back);
    case kLeft: return REXCVAR_GET(pc_bind_left);
    case kRight: return REXCVAR_GET(pc_bind_right);
    case kSprint: return REXCVAR_GET(pc_bind_sprint);
    case kJump: return REXCVAR_GET(pc_bind_jump);
    case kCrouch: return REXCVAR_GET(pc_bind_crouch);
    case kProne: return REXCVAR_GET(pc_bind_prone);
    case kReload: return REXCVAR_GET(pc_bind_reload);
    case kUse: return REXCVAR_GET(pc_bind_use);
    case kWeapon: return REXCVAR_GET(pc_bind_weapon);
    case kFrag: return REXCVAR_GET(pc_bind_frag);
    case kSmoke: return REXCVAR_GET(pc_bind_smoke);
    case kMelee: return REXCVAR_GET(pc_bind_melee);
    case kFire: return REXCVAR_GET(pc_bind_fire);
    case kAim: return REXCVAR_GET(pc_bind_aim);
    case kBinoculars: return REXCVAR_GET(pc_bind_binoculars);
    case kObjectives: return REXCVAR_GET(pc_bind_objectives);
    case kPause: return REXCVAR_GET(pc_bind_pause);
    case kMenuUp: return REXCVAR_GET(pc_bind_menu_up);
    case kMenuDown: return REXCVAR_GET(pc_bind_menu_down);
    case kMenuLeft: return REXCVAR_GET(pc_bind_menu_left);
    case kMenuRight: return REXCVAR_GET(pc_bind_menu_right);
    case kMenuAccept: return REXCVAR_GET(pc_bind_menu_accept);
    default: return REXCVAR_GET(pc_bind_menu_back);
  }
}

// Input codes: 1..255 are Windows virtual keys (mouse buttons included:
// 1 LMB, 2 RMB, 4 MMB, 5 Mouse4, 6 Mouse5); the wheel gets its own codes.
constexpr int kCodeWheelUp = 256;
constexpr int kCodeWheelDown = 257;

int ParseCode(std::string_view name) {
  if (name == "WheelUp" || name == "MWheelUp") return kCodeWheelUp;
  if (name == "WheelDown" || name == "MWheelDown") return kCodeWheelDown;
  if (name == "Mouse4" || name == "XButton1" || name == "X1") return 0x05;
  if (name == "Mouse5" || name == "XButton2" || name == "X2") return 0x06;
  if (name == "Ctrl") return 0x11;
  auto vk = static_cast<int>(rex::ui::ParseVirtualKey(name));
  return (vk > 0 && vk < 256) ? vk : 0;
}

std::vector<int> ParseBind(const std::string& text) {
  std::vector<int> codes;
  std::string_view rest(text);
  while (!rest.empty()) {
    size_t comma = rest.find(',');
    std::string_view token = rest.substr(0, comma);
    rest = (comma == std::string_view::npos) ? std::string_view() : rest.substr(comma + 1);
    while (!token.empty() && token.front() == ' ') token.remove_prefix(1);
    while (!token.empty() && token.back() == ' ') token.remove_suffix(1);
    if (token.empty()) continue;
    if (int code = ParseCode(token)) codes.push_back(code);
  }
  return codes;
}

// Generic Shift/Ctrl/Alt binds also match the left/right-specific codes.
bool CodeDown(const std::array<bool, 256>& down, int code) {
  if (code <= 0 || code >= 256) return false;
  if (down[code]) return true;
  switch (code) {
    case 0x10: return down[0xA0] || down[0xA1];
    case 0x11: return down[0xA2] || down[0xA3];
    case 0x12: return down[0xA4] || down[0xA5];
    default: return false;
  }
}

struct Pulse {
  Clock::time_point active_until{};
  Clock::time_point next_allowed{};
  int queued = 0;
};

// ---------------------------------------------------------------------------
// Shared state between the UI thread (window events) and the guest thread
// (look update, pad polling).
// ---------------------------------------------------------------------------
class ControlState final : public rex::ui::WindowInputListener, public rex::ui::WindowListener {
 public:
  void Attach(rex::ui::Window* window) {
    std::lock_guard lock(mutex_);
    if (window_ || !window) return;
    window_ = window;
    // Above the SDK keyboard/mouse driver (z 0) so mouse motion is taken
    // before it becomes stick input; below the ImGui overlays (z 64) so the
    // settings and debug menus keep the mouse when they are open.
    window->AddInputListener(this, 32);
    window->AddListener(this);
    has_focus_ = true;
    menus::AttachWindow(window);
    // The pointer is a property of the native window, which belongs to the UI
    // thread; retried from the window events below until the window is open.
    window->app_context().CallInUIThreadDeferred([this] { EnsureCursor(); });
    REXLOG_INFO("PC controls: {}, mouse look {} (sensitivity {:.2f}, m_yaw {:.3f}, invert {}, ADS scaling {}), "
                "ADS {}",
                REXCVAR_GET(pc_controls) ? "on" : "off",
                REXCVAR_GET(pc_mouse_direct) ? "direct" : "stick",
                REXCVAR_GET(pc_mouse_sensitivity), REXCVAR_GET(pc_mouse_yaw),
                REXCVAR_GET(pc_mouse_invert) ? "yes" : "no",
                REXCVAR_GET(pc_mouse_ads_scaling) ? "yes" : "no",
                REXCVAR_GET(pc_ads_toggle) ? "toggle" : "hold");
  }

  void Detach() {
    rex::ui::Window* window = nullptr;
    {
      std::lock_guard lock(mutex_);
      window = window_;
      window_ = nullptr;
    }
    if (window) {
      window->RemoveInputListener(this);
      window->RemoveListener(this);
    }
  }

  // --- window events (UI thread) -------------------------------------------
  void OnKeyDown(rex::ui::KeyEvent& e) override {
    const int code = static_cast<int>(e.virtual_key());
    SetDown(code, true);
    // Arrow keys and the like move the selection themselves; the pointer
    // steps aside until the mouse moves again.
    if (MenuOwnsMouse() && IsNavigationKey(code)) menus::OnNavigationInput();
  }
  void OnKeyUp(rex::ui::KeyEvent& e) override { SetDown(static_cast<int>(e.virtual_key()), false); }

  void OnMouseDown(rex::ui::MouseEvent& e) override {
    const int code = ButtonCode(e.button());
    if (code && MenuOwnsMouse()) {
      // In a menu the buttons act on the menu, never on the game, and a
      // button pressed there stays out of the game until it is released: a
      // click on "Resume" must not also fire the rifle.
      {
        std::lock_guard lock(mutex_);
        menu_held_[code] = true;
      }
      PointerAt(e);
      if (code == 0x01) {
        menus::OnPointerClick(false);
      } else if (code == 0x02 || code == 0x05) {
        menus::OnPointerClick(true);  // right button or "back" side button
      }
      e.set_handled(true);
      return;
    }
    SetDown(code, true);
  }
  void OnMouseUp(rex::ui::MouseEvent& e) override {
    const int code = ButtonCode(e.button());
    bool held = false;
    if (code) {
      std::lock_guard lock(mutex_);
      held = std::exchange(menu_held_[code], false);
    }
    SetDown(code, false);
    if (held) e.set_handled(true);
  }

  void OnMouseWheel(rex::ui::MouseEvent& e) override {
    if (!REXCVAR_GET(pc_controls)) return;
    const bool menu = MenuOwnsMouse();
    int notches = 0;
    {
      std::lock_guard lock(mutex_);
      wheel_accumulator_ += e.scroll_y();
      while (wheel_accumulator_ >= int32_t(rex::ui::MouseEvent::kScrollPerDetent)) {
        wheel_accumulator_ -= rex::ui::MouseEvent::kScrollPerDetent;
        ++notches;
      }
      while (wheel_accumulator_ <= -int32_t(rex::ui::MouseEvent::kScrollPerDetent)) {
        wheel_accumulator_ += rex::ui::MouseEvent::kScrollPerDetent;
        --notches;
      }
      if (!menu) {
        wheel_up_ += std::max(notches, 0);
        wheel_down_ += std::max(-notches, 0);
        qte_wheel_ += std::abs(notches);
      }
    }
    if (menu) {
      if (notches) menus::OnPointerWheel(notches);
      e.set_handled(true);
    }
  }

  void OnMouseMove(rex::ui::MouseEvent& e) override {
    EnsureCursor();
    if (!REXCVAR_GET(pc_controls)) return;
    // Only real motion moves the menu selection: SDL also reports the pointer
    // without motion (focus changes, the capture ending), and that must not
    // undo a selection made with the keys.
    if (e.dx() != 0.0f || e.dy() != 0.0f) {
      menus::OnPointerMotion();
      if (MenuOwnsMouse()) PointerAt(e);
    }
    // Observed, not consumed: the SDK driver below still turns the motion
    // into right-stick input, which the menus read. The camera ignores that
    // stick input (see SuppressLookAxis) and turns from these raw counts
    // instead; the stick battle actions get their own copy. Accumulated only
    // while the pointer is captured, i.e. while the game has mouse look.
    std::lock_guard lock(mutex_);
    if (window_ && window_->GetCursorVisibility() == rex::ui::Window::CursorVisibility::kHidden) {
      if (REXCVAR_GET(pc_mouse_direct)) {
        mouse_dx_ += e.dx();
        mouse_dy_ += e.dy();
      }
      qte_dx_ += e.dx();
      qte_dy_ += e.dy();
      if (e.dx() != 0 || e.dy() != 0) last_mouse_motion_ = Clock::now();
    }
  }

  void OnGotFocus(rex::ui::UISetupEvent&) override {
    EnsureCursor();
    std::lock_guard lock(mutex_);
    has_focus_ = true;
  }

  // UI thread only (Attach's deferred call and window events).
  void EnsureCursor() {
    if (cursor_done_ || !window_) return;
    cursor_done_ = InstallGameCursor(window_, REXCVAR_GET(pc_cursor));
  }
  void OnLostFocus(rex::ui::UISetupEvent&) override {
    std::lock_guard lock(mutex_);
    has_focus_ = false;
    down_.fill(false);
    menu_held_.fill(false);
    mouse_dx_ = mouse_dy_ = 0.0;
    wheel_up_ = wheel_down_ = 0;
    ads_latched_ = false;
    ResetQteInput();
  }

  // --- guest thread ---------------------------------------------------------
  void ApplyMouseLook(uint8_t* base) {
    double dx, dy;
    Clock::time_point previous;
    const auto now = Clock::now();
    {
      std::lock_guard lock(mutex_);
      dx = mouse_dx_;
      dy = mouse_dy_;
      mouse_dx_ = mouse_dy_ = 0.0;
      previous = last_look_apply_;
      last_look_apply_ = now;
      // Outside a stick battle action its copy of the mouse and wheel input
      // is dropped every frame; during one, the camera stays still.
      if (now - last_stick_qte_ > kStickQteHold) {
        ResetQteInput();
      } else {
        dx = dy = 0.0;
      }
    }
    if (!REXCVAR_GET(pc_controls) || !REXCVAR_GET(pc_mouse_direct)) return;
    if (!look_hook_seen_.exchange(true)) {
      REXLOG_INFO("PC controls: view-angle hook active (0x8250FF48)");
    }
    // Motion gathered while the look update was not running (a menu, a pause,
    // a load) belongs to nothing on screen now; applying it would snap the
    // camera on return.
    if (now - previous > std::chrono::milliseconds(250)) return;
    if (dx == 0.0 && dy == 0.0) return;

    const uint32_t local = LoadU32(base, kLocalClientIndex);
    if (local > 3) return;
    const uint32_t client = kClientActiveBase + local * kClientActiveStride;
    if (LoadU32(base, client + kOffsetFlags) & kFlagViewInputDisabled) return;

    double scale = 1.0;
    if (REXCVAR_GET(pc_mouse_ads_scaling)) {
      const float zoom = LoadF32(base, client + kOffsetZoomSensitivity);
      if (std::isfinite(zoom) && zoom > 0.01f && zoom < 4.0f) {
        scale = zoom;
        if (zoom < 0.999f) scale *= REXCVAR_GET(pc_mouse_ads_multiplier);
      }
    }
    const double sensitivity = REXCVAR_GET(pc_mouse_sensitivity) * scale;
    const double yaw_delta = dx * sensitivity * REXCVAR_GET(pc_mouse_yaw);
    double pitch_delta = dy * sensitivity * REXCVAR_GET(pc_mouse_pitch);
    if (REXCVAR_GET(pc_mouse_invert)) pitch_delta = -pitch_delta;

    // Same signs as the game's own look: yaw decreases turning right, pitch
    // increases looking down. The game clamps pitch through delta_angles.
    StoreF32(base, client + kOffsetYaw, float(LoadF32(base, client + kOffsetYaw) - yaw_delta));
    StoreF32(base, client + kOffsetPitch, float(LoadF32(base, client + kOffsetPitch) + pitch_delta));

    if (REXCVAR_GET(pc_controls_debug)) {
      debug_yaw_ += yaw_delta;
      debug_counts_ += std::abs(dx);
      if (now - debug_logged_ > std::chrono::seconds(1)) {
        REXLOG_INFO("PC controls: {:.0f} counts -> {:.2f} deg yaw this second, zoom scale {:.3f}",
                    debug_counts_, debug_yaw_, scale);
        debug_logged_ = now;
        debug_yaw_ = debug_counts_ = 0.0;
      }
    }
  }

  void PostProcessPad(uint8_t* base, uint32_t user_index, uint32_t state) {
    if (!REXCVAR_GET(pc_controls) || user_index != 0 || state == 0) return;
    FinishRowboat(base);
    const auto now = Clock::now();
    if (!pad_hook_seen_.exchange(true)) {
      REXLOG_INFO("PC controls: pad merge hook active (0x82344F98)");
    }

    // In a menu the mouse belongs to the menu (menu_mouse.cpp): its buttons
    // and wheel press nothing here.
    const bool menu_mouse = MenuOwnsMouse();

    // The game may poll from more than one guest thread; the whole update is
    // a few hundred nanoseconds, so it simply runs under the lock.
    std::lock_guard lock(mutex_);
    if (!has_focus_) return;
    if (menu_mouse) {
      NoticePadNavigation(LoadU16(base, state + 4), int16_t(LoadU16(base, state + 8)),
                          int16_t(LoadU16(base, state + 10)));
    }

    std::array<bool, kActionCount> active{};
    // During a stick battle action the wheel turns it instead of switching
    // weapons.
    const bool stick_qte = now - last_stick_qte_ <= kStickQteHold;
    const int wheel_up = stick_qte ? 0 : wheel_up_;
    const int wheel_down = stick_qte ? 0 : wheel_down_;
    wheel_up_ = wheel_down_ = 0;
    RefreshBinds();
    for (int action = 0; action < kActionCount; ++action) {
      for (int code : binds_[action]) {
        if (menu_mouse && IsMouseCode(code)) continue;
        if (code == kCodeWheelUp) {
          pulses_[action].queued += wheel_up;
        } else if (code == kCodeWheelDown) {
          pulses_[action].queued += wheel_down;
        } else if (CodeDown(down_, code)) {
          active[action] = true;
        }
      }
    }

    // Wheel notches become short presses with a release in between, so every
    // notch is seen by the game as its own press.
    for (int action = 0; action < kActionCount; ++action) {
      Pulse& pulse = pulses_[action];
      if (pulse.queued > 0 && now >= pulse.next_allowed) {
        pulse.active_until = now + std::chrono::milliseconds(70);
        pulse.next_allowed = now + std::chrono::milliseconds(140);
        pulse.queued = std::min(pulse.queued - 1, 4);
      }
      if (now < pulse.active_until) active[action] = true;
    }

    // Edges.
    std::array<bool, kActionCount> pressed{};
    for (int action = 0; action < kActionCount; ++action) {
      pressed[action] = active[action] && !previous_[action];
      previous_[action] = active[action];
    }

    // Prone: CoD3 goes prone on a *held* B. One tap of the prone key holds it
    // long enough, and keeps holding while the key stays down.
    if (pressed[kProne]) {
      prone_until_ = now + std::chrono::milliseconds(std::clamp(REXCVAR_GET(pc_prone_hold_ms), 200, 2000));
    }
    const bool prone = active[kProne] || now < prone_until_;

    // Aim: hold, or toggle with the latch released by anything that drops
    // the sights in-game anyway.
    bool aim = active[kAim];
    if (REXCVAR_GET(pc_ads_toggle)) {
      if (pressed[kAim]) ads_latched_ = !ads_latched_;
      if (pressed[kReload] || pressed[kSprint] || pressed[kWeapon] || pressed[kMelee]) ads_latched_ = false;
      aim = ads_latched_;
    } else {
      ads_latched_ = false;
    }

    uint16_t buttons = 0;
    if (active[kSprint]) buttons |= kPadLeftThumb;
    if (active[kJump] || active[kMenuAccept]) buttons |= kPadA;
    if (active[kCrouch] || prone || active[kMenuBack]) buttons |= kPadB;
    if (active[kReload] || active[kUse]) buttons |= kPadX;
    if (active[kWeapon]) buttons |= kPadY;
    if (active[kFrag]) buttons |= kPadRightShoulder;
    if (active[kSmoke]) buttons |= kPadLeftShoulder;
    if (active[kMelee]) buttons |= kPadRightThumb;
    if (active[kBinoculars] || active[kMenuUp]) buttons |= kPadDpadUp;
    if (active[kMenuDown]) buttons |= kPadDpadDown;
    if (active[kMenuLeft]) buttons |= kPadDpadLeft;
    if (active[kMenuRight]) buttons |= kPadDpadRight;
    if (active[kObjectives]) buttons |= kPadBack;
    if (active[kPause]) buttons |= kPadStart;

    StoreU16(base, state + 4, uint16_t(LoadU16(base, state + 4) | buttons));
    uint8_t* lt = base + state + 6;
    uint8_t* rt = base + state + 7;
    if (REXCVAR_GET(pc_ads_toggle)) {
      *lt = aim ? 0xFF : *lt;
    } else if (aim) {
      *lt = 0xFF;
    }
    if (active[kFire]) *rt = 0xFF;

    // Keyboard movement replaces the left stick only while a movement key is
    // down, so a connected gamepad keeps working alongside.
    int lx = 0, ly = 0;
    if (active[kLeft]) lx -= 32767;
    if (active[kRight]) lx += 32767;
    if (active[kForward]) ly += 32767;
    if (active[kBack]) ly -= 32767;
    if (lx != 0 || ly != 0) {
      StoreU16(base, state + 8, uint16_t(int16_t(lx)));
      StoreU16(base, state + 10, uint16_t(int16_t(ly)));
    }
  }

  // --- stick battle actions (guest thread) --------------------------------
  void BeginStickSwirl(uint8_t* base, uint32_t receiver, double frame_time, StickPatch& patch) {
    patch.count = 0;
    const bool assist = REXCVAR_GET(pc_controls) && REXCVAR_GET(pc_qte_assist);
    const bool rate_fix = REXCVAR_GET(pc_qte_rate_fix);
    if (!assist && !rate_fix) return;
    uint32_t pair = 0;
    bool clockwise = false, left = false;
    if (!ReceiverStick(base, receiver, pair, left, clockwise)) return;
    const uint32_t x_address = pair + (left ? 2u : 0u) * 4u;
    const uint32_t y_address = x_address + 4u;

    const auto now = Clock::now();
    std::lock_guard lock(mutex_);
    EnterStickQte(now);

    qte::SwirlInput in;
    in.dt = frame_time;
    in.clockwise = clockwise;
    bool keys_down = false;
    if (assist && has_focus_) {
      // Turning in any direction counts: the game wants one direction, and
      // on a keyboard and mouse there is no reason to make the player guess
      // which.
      double turned = crank_.Advance(qte_dx_, qte_dy_) * REXCVAR_GET(pc_qte_mouse_gain);
      qte_dx_ = qte_dy_ = 0.0;
      turned += qte_wheel_ * (qte::kPi / 4.0);
      qte_wheel_ = 0;
      bool up, down, left_key, right_key;
      ReadDirectionKeys(up, down, left_key, right_key);
      keys_down = up || down || left_key || right_key;
      double angle = 0.0;
      if (qte::KeyDirection(up, down, left_key, right_key, angle)) {
        if (key_direction_valid_) turned += std::abs(qte::WrapAngle(angle - key_direction_));
        key_direction_ = angle;
        key_direction_valid_ = true;
      } else {
        key_direction_valid_ = false;
      }
      in.player_radians = turned;
    }
    // A real stick (a gamepad) counts too, unless the keyboard or the mouse
    // is what moves it right now: the keys are already merged into the left
    // stick and the SDK turns the mouse into the right stick.
    const int real_x = int32_t(LoadU32(base, x_address));
    const int real_y = int32_t(LoadU32(base, y_address));
    const bool kbm_busy = assist && (keys_down || now - last_mouse_motion_ < std::chrono::milliseconds(200));
    in.real_valid = !kbm_busy && std::hypot(double(real_x), double(real_y)) > 40.0;
    in.real_x = real_x;
    in.real_y = real_y;

    const qte::StickValue value = qte::StepSwirl(swirl_, in, rate_fix);
    Patch(base, patch, x_address, uint32_t(value.x));
    Patch(base, patch, y_address, uint32_t(value.y));
    if (!swirl_seen_) {
      swirl_seen_ = true;
      REXLOG_INFO("PC controls: stick-swirl action on the {} stick (clockwise flag {}), keyboard/mouse {}, "
                  "60 Hz rescale {}",
                  left ? "left" : "right", clockwise ? 1 : 0, assist ? "on" : "off", rate_fix ? "on" : "off");
    }
  }

  void BeginStickToggle(uint8_t* base, uint32_t receiver, StickPatch& patch) {
    patch.count = 0;
    if (!REXCVAR_GET(pc_controls) || !REXCVAR_GET(pc_qte_assist)) return;
    uint32_t pair = 0;
    bool clockwise = false, left = false;
    if (!ReceiverStick(base, receiver, pair, left, clockwise)) return;
    const bool vertical = LoadU32(base, receiver + kReceiverToggleVertical) != 0;
    const uint32_t address = pair + ((left ? 2u : 0u) + (vertical ? 1u : 0u)) * 4u;

    const auto now = Clock::now();
    std::lock_guard lock(mutex_);
    EnterStickQte(now);
    if (!has_focus_) return;
    const double dt = std::clamp(std::chrono::duration<double>(now - last_toggle_).count(), 0.0, 0.1);
    last_toggle_ = now;

    bool up, down, left_key, right_key;
    ReadDirectionKeys(up, down, left_key, right_key);
    int keys = 0;
    double mouse = 0.0;
    if (vertical) {
      keys = (up ? 1 : 0) - (down ? 1 : 0);
      mouse = -qte_dy_;
    } else {
      keys = (right_key ? 1 : 0) - (left_key ? 1 : 0);
      mouse = qte_dx_;
    }
    qte_dx_ = qte_dy_ = 0.0;
    qte_wheel_ = 0;
    const int value = qte::StepToggle(toggle_, keys, mouse, dt);
    if (value == 0) return;
    // The receiver negates the vertical axis; only the alternation matters.
    Patch(base, patch, address, uint32_t(vertical ? -value : value));
    if (!toggle_seen_) {
      toggle_seen_ = true;
      REXLOG_INFO("PC controls: stick-toggle action ({}, {} stick) driven by keys and mouse",
                  vertical ? "vertical" : "horizontal", left ? "left" : "right");
    }
  }

  // InteractInputRcvrRowboat update (sub_824FC450), guest thread.
  void BeginRowboat(uint8_t* base, uint32_t receiver) {
    if (!REXCVAR_GET(pc_controls) || !REXCVAR_GET(pc_qte_assist)) return;
    uint32_t pair = 0;
    bool clockwise = false, left = false;
    if (!ReceiverStick(base, receiver, pair, left, clockwise)) return;
    const uint32_t x_address = pair + (left ? 2u : 0u) * 4u;
    const uint32_t y_address = x_address + 4u;

    const auto now = Clock::now();
    std::lock_guard lock(mutex_);
    if (now - last_stick_qte_ > kStickQteHold) row_ = {};
    EnterStickQte(now);  // the mouse rows now; the camera stays put, as on the console
    const double dt = std::clamp(std::chrono::duration<double>(now - last_row_).count(), 0.0, 0.1);
    last_row_ = now;

    qte::RowInput in;
    in.dt = dt;
    if (has_focus_) {
      const double gain = REXCVAR_GET(pc_qte_mouse_gain);
      in.pull = std::max(0.0, qte_dy_) * gain;  // towards the player
      in.push = std::max(0.0, -qte_dy_) * gain;
      qte_dx_ = qte_dy_ = 0.0;
      qte_wheel_ = 0;
      bool up, down, left_key, right_key;
      ReadDirectionKeys(up, down, left_key, right_key);
      in.key_row = up;
    }
    if (in.pull > 0.0 || in.push > 0.0 || in.key_row) last_row_input_ = now;
    // A gamepad keeps its own stick: take over only while the keyboard or
    // the mouse rowed in the last moments.
    if (now - last_row_input_ > std::chrono::milliseconds(1500)) {
      row_override_ = false;
      return;
    }
    const qte::StickValue value = qte::StepRow(row_, in);
    StoreU32(base, x_address, uint32_t(value.x));
    StoreU32(base, y_address, uint32_t(value.y));
    row_override_ = true;
    row_x_address_ = x_address;
    row_y_address_ = y_address;
    if (!row_seen_) {
      row_seen_ = true;
      REXLOG_INFO("PC controls: rowboat on the {} stick driven by the mouse (pull to row) and {}", left ? "left" : "right",
                  "the forward key");
    }
  }

  // sub_8250A660 stores a pad axis event into the stick array; while the oar
  // stick is ours, real events for it (the SDK's mouse-as-stick, a resting
  // pad) would undo the stroke between the game's readers.
  bool HoldStickWrite(const uint8_t* base, uint32_t axis) {
    std::lock_guard lock(mutex_);
    if (!row_override_) return false;
    const uint32_t local = LoadU32(base, kLocalClientIndex);
    if (local > 3 || axis > 5) return false;
    const uint32_t address = kStickArray + local * kStickArrayStride + axis * 4u;
    return address == row_x_address_ || address == row_y_address_;
  }

  // Every pad poll: once the boat is left, give the stick back at rest.
  void FinishRowboat(uint8_t* base) {
    std::lock_guard lock(mutex_);
    if (!row_override_ || Clock::now() - last_row_ <= kStickQteHold) return;
    row_override_ = false;
    StoreU32(base, row_x_address_, 0);
    StoreU32(base, row_y_address_, 0);
  }

  void EndStickPatch(uint8_t* base, const StickPatch& patch, uint32_t output_address) {
    if (REXCVAR_GET(pc_controls_debug) && output_address && patch.count) {
      const auto now = Clock::now();
      std::lock_guard lock(mutex_);
      if (now - qte_debug_logged_ > std::chrono::milliseconds(500)) {
        qte_debug_logged_ = now;
        REXLOG_INFO("PC controls: stick-swirl speed {:.2f}", LoadF32(base, output_address));
      }
    }
    for (int i = patch.count - 1; i >= 0; --i) {
      StoreU32(base, patch.address[i], patch.saved[i]);
    }
  }

 private:
  // Pointer position for the menus, from any mouse event (UI thread).
  void PointerAt(const rex::ui::MouseEvent& e) {
    if (!window_) return;
    menus::OnPointerMove(e.x(), e.y(), window_->GetActualPhysicalWidth(), window_->GetActualPhysicalHeight());
  }

  static bool IsMouseCode(int code) {
    return code == 0x01 || code == 0x02 || code == 0x04 || code == 0x05 || code == 0x06 || code == kCodeWheelUp ||
           code == kCodeWheelDown;
  }

  // Keys bound to menu or movement directions (UI thread).
  bool IsNavigationKey(int code) {
    std::lock_guard lock(mutex_);
    RefreshBinds();
    for (int action : {kMenuUp, kMenuDown, kMenuLeft, kMenuRight, kForward, kBack, kLeft, kRight}) {
      for (int bound : binds_[action]) {
        if (bound == code) return true;
      }
    }
    return false;
  }

  // A gamepad moving the selection in a menu (its D-pad or left stick, on a
  // fresh press): the pointer steps aside as it does for the arrow keys.
  // Called under mutex_, before the keyboard is merged into the state.
  void NoticePadNavigation(uint16_t buttons, int16_t lx, int16_t ly) {
    constexpr uint16_t kDpad = kPadDpadUp | kPadDpadDown | kPadDpadLeft | kPadDpadRight;
    const bool stick = std::abs(int(lx)) > 16000 || std::abs(int(ly)) > 16000;
    if (((buttons & kDpad) & ~pad_navigation_) || (stick && !pad_stick_)) menus::OnNavigationInput();
    pad_navigation_ = buttons & kDpad;
    pad_stick_ = stick;
  }

  bool ReceiverStick(const uint8_t* base, uint32_t receiver, uint32_t& pair, bool& left, bool& clockwise) {
    const uint32_t definition = IsGuestPointer(receiver) ? LoadU32(base, receiver + kReceiverDefinition) : 0;
    const uint32_t local = LoadU32(base, kLocalClientIndex);
    if (!IsGuestPointer(receiver) || !IsGuestPointer(definition) || local > 3) {
      // Say so once: a silent refusal here is what hid the charge fuse.
      static std::atomic<bool> reported{false};
      if (!reported.exchange(true)) {
        REXLOG_WARN("PC controls: stick action not taken over (receiver {:08X}, definition {:08X}, client {})",
                    receiver, definition, local);
      }
      return false;
    }
    left = LoadU32(base, definition + kDefinitionLeftStick) != 0;
    clockwise = LoadU32(base, definition + kDefinitionClockwise) != 0;
    pair = kStickArray + local * kStickArrayStride;
    return true;
  }

  // Called under mutex_. A new action starts from a clean slate, not from
  // whatever the mouse did while walking up to it.
  void EnterStickQte(Clock::time_point now) {
    if (now - last_stick_qte_ > kStickQteHold) {
      ResetQteInput();
      swirl_ = {};
      toggle_ = {};
      crank_ = {};
      last_toggle_ = now;
    }
    last_stick_qte_ = now;
  }

  void ResetQteInput() {
    qte_dx_ = qte_dy_ = 0.0;
    qte_wheel_ = 0;
    key_direction_valid_ = false;
  }

  // Movement keys and arrows, whatever they are bound to. Called under mutex_.
  void ReadDirectionKeys(bool& up, bool& down, bool& left, bool& right) {
    RefreshBinds();
    auto any = [this](std::initializer_list<int> actions) {
      for (int action : actions) {
        for (int code : binds_[action]) {
          if (CodeDown(down_, code)) return true;
        }
      }
      return false;
    };
    up = any({kForward, kMenuUp});
    down = any({kBack, kMenuDown});
    left = any({kLeft, kMenuLeft});
    right = any({kRight, kMenuRight});
  }

  static void Patch(uint8_t* base, StickPatch& patch, uint32_t address, uint32_t value) {
    if (patch.count >= 2) return;
    patch.address[patch.count] = address;
    patch.saved[patch.count] = LoadU32(base, address);
    ++patch.count;
    StoreU32(base, address, value);
  }

  static int ButtonCode(rex::ui::MouseEvent::Button button) {
    switch (button) {
      case rex::ui::MouseEvent::Button::kLeft: return 0x01;
      case rex::ui::MouseEvent::Button::kRight: return 0x02;
      case rex::ui::MouseEvent::Button::kMiddle: return 0x04;
      case rex::ui::MouseEvent::Button::kX1: return 0x05;
      case rex::ui::MouseEvent::Button::kX2: return 0x06;
      default: return 0;
    }
  }

  void SetDown(int code, bool down) {
    if (code <= 0 || code >= 256) return;
    std::lock_guard lock(mutex_);
    if (down && !has_focus_) return;
    down_[code] = down;
  }

  // Binds are re-parsed only when their text changes (settings overlay edits
  // apply live).
  void RefreshBinds() {
    for (int action = 0; action < kActionCount; ++action) {
      const std::string& text = BindString(action);
      if (text != bind_text_[action]) {
        bind_text_[action] = text;
        binds_[action] = ParseBind(text);
      }
    }
  }

  std::mutex mutex_;
  rex::ui::Window* window_ = nullptr;
  bool has_focus_ = false;
  bool cursor_done_ = false;  // UI thread only
  std::array<bool, 256> down_{};
  std::array<bool, 256> menu_held_{};  // mouse buttons pressed in a menu, until released
  uint16_t pad_navigation_ = 0;
  bool pad_stick_ = false;
  double mouse_dx_ = 0.0;
  double mouse_dy_ = 0.0;
  int32_t wheel_accumulator_ = 0;
  int wheel_up_ = 0;
  int wheel_down_ = 0;
  Clock::time_point last_look_apply_{};

  // Pad-update state, also guarded by mutex_.
  std::array<std::string, kActionCount> bind_text_{};
  std::array<std::vector<int>, kActionCount> binds_{};
  std::array<Pulse, kActionCount> pulses_{};
  std::array<bool, kActionCount> previous_{};
  Clock::time_point prone_until_{};
  bool ads_latched_ = false;

  // Stick battle actions, also guarded by mutex_.
  double qte_dx_ = 0.0;
  double qte_dy_ = 0.0;
  int qte_wheel_ = 0;
  Clock::time_point last_mouse_motion_{};
  Clock::time_point last_stick_qte_{};
  Clock::time_point last_toggle_{};
  qte::Crank crank_{};
  qte::SwirlState swirl_{};
  qte::ToggleState toggle_{};
  double key_direction_ = 0.0;
  bool key_direction_valid_ = false;
  bool swirl_seen_ = false;
  bool toggle_seen_ = false;
  Clock::time_point qte_debug_logged_{};
  // Rowboat: the oar stick is written into the game's stick array and real
  // stick events for it are held off while the keyboard or mouse rows.
  qte::RowState row_{};
  Clock::time_point last_row_{};
  Clock::time_point last_row_input_{};
  bool row_override_ = false;
  bool row_seen_ = false;
  uint32_t row_x_address_ = 0;
  uint32_t row_y_address_ = 0;

  // Diagnostics.
  std::atomic<bool> look_hook_seen_{false};
  std::atomic<bool> pad_hook_seen_{false};
  Clock::time_point debug_logged_{};
  double debug_yaw_ = 0.0;
  double debug_counts_ = 0.0;
};

ControlState& State() {
  static ControlState state;
  return state;
}

// Guest axes as the look update reads them (0x8250A570): 0/1 left stick,
// 3/4 right stick.
constexpr uint32_t kAxisRightX = 3;
constexpr uint32_t kAxisRightY = 4;
thread_local int g_look_update_depth = 0;

}  // namespace

LookUpdateScope::LookUpdateScope() { ++g_look_update_depth; }
LookUpdateScope::~LookUpdateScope() { --g_look_update_depth; }

bool SuppressLookAxis(uint32_t axis) {
  return g_look_update_depth > 0 && (axis == kAxisRightX || axis == kAxisRightY) &&
         REXCVAR_GET(pc_controls) && REXCVAR_GET(pc_mouse_direct);
}

bool ServerFrameDue(uint32_t& msec) {
  // Com_Frame (sub_82536DD0) calls SV_Frame on the one guest main thread.
  static uint32_t accumulated = 0;
  static int logged_hz = -1;
  const int hz = REXCVAR_GET(cod3_server_hz);
  if (hz != logged_hz) {
    logged_hz = hz;
    REXLOG_INFO("Game: server frame {}", hz > 0 ? "at " + std::to_string(hz) + " Hz" : std::string("every frame"));
  }
  if (hz <= 0 || int32_t(msec) <= 0) {
    // Off, or a paused frame (0 ms): pass it on unchanged, and keep any time
    // already gathered for the next real frame.
    return true;
  }
  accumulated += msec;
  if (accumulated < uint32_t(1000 / hz)) return false;
  msec = accumulated;
  accumulated = 0;
  return true;
}

// ---------------------------------------------------------------------------
// The client between two server frames.
//
// Single-player CoD3 is a local server and client in one Com_Frame, and the
// client takes its clock straight from the server: SV_Frame publishes the
// level time before its step (stw r30,14896 -> 0x829C3A30), CL_Frame copies
// that into cl.serverTime, and CG_DrawActiveFrame derives cg.frametime from
// it. SV_Frame also stores the frame's msec (0x829C3FA8), which CL_Frame adds
// to cls.realtime and the client movement code reads.
//
// With the simulation at 60 Hz and the picture at 120, every other frame had
// no SV_Frame: the client clock stood still (cg.frametime 0), the dynamic
// shadows and the models using them were left out of that frame - a tester
// log shows the two extra shadow maps rendered and sampled in strictly
// alternating frames (FpFpFp...) - and cls.realtime advanced by the
// accumulated 16-17 ms on every frame, twice the real rate.
//
// So in a frame without a server step the client clock moves on by the real
// frame time, never past the level time the last step reached: the client
// interpolates between the two newest snapshots as a network client does,
// and the shared state generation (0x829BAA5C, bumped by every server frame
// and every new snapshot) moves on so per-frame caches are rebuilt.
//
// That alone did not stop the blinking (next tester log: still FpFFpFp).
// What decides it is G_RunFrame's model update, sub_82563FC0(msec): the
// ANIM/XANM/DRON animation passes that pose every animated model, then per
// entity the distance LOD (sub_82421AA8) and hidden tags. In single player
// the client draws the server's entities directly, and a model nobody posed
// this frame is not drawn - soldiers, animated objects and their shadows.
// It now also runs in the frames between steps with that frame's time, and
// the step's own call runs only the rest, so animations keep real time (and
// move at the display rate) while AI and scripts stay at 60 Hz.
// ---------------------------------------------------------------------------
namespace {

constexpr uint32_t kClientServerTime = 0x829C3A30;
constexpr uint32_t kClientFrameMsec = 0x829C3FA8;
constexpr uint32_t kStateGeneration = 0x829BAA5C;

// Guest main thread only (Com_Frame).
struct ServerClock {
  bool game_ran = false;   // the game frame (sub_825173F8) ran inside this SV_Frame
  bool in_game_step = false;  // inside that game frame right now
  bool valid = false;      // the fields below describe the last server step
  uint32_t step_start = 0;  // client time SV_Frame published: level time before the step
  uint32_t step = 0;        // msec that step simulated
  uint32_t since = 0;       // real frame time since that step
  uint32_t published = 0;   // the client time as last written here
  uint32_t models_ahead = 0;  // model/animation time already run between steps
} g_clock;

void BumpGeneration(uint8_t* base) {
  uint32_t generation = LoadU32(base, kStateGeneration) + 1;
  if (generation == 0) generation = 1;  // as the guest does: 0 means none
  StoreU32(base, kStateGeneration, generation);
}

}  // namespace

void BeginGameFrame() {
  g_clock.game_ran = true;
  g_clock.in_game_step = true;
}

void EndGameFrame() { g_clock.in_game_step = false; }

void BeforeServerFrame() { g_clock.game_ran = false; }

uint32_t ModelUpdateMsec(uint32_t msec) {
  // G_RunFrame's own model update: only the part of the step that the
  // updates between steps have not run yet, so animations keep real time.
  if (!g_clock.in_game_step || g_clock.models_ahead == 0) return msec;
  const uint32_t rest = msec > g_clock.models_ahead ? msec - g_clock.models_ahead : 1u;
  g_clock.models_ahead = 0;
  return rest;
}

void NoteModelUpdateBetweenSteps(uint32_t msec) {
  g_clock.models_ahead += msec;
  static bool logged = false;
  if (!logged) {
    logged = true;
    REXLOG_INFO("Game: models posed every frame between {} Hz server steps (sub_82563FC0)",
                REXCVAR_GET(cod3_server_hz));
  }
}

void AfterServerFrame(uint8_t* base, uint32_t frame_msec, uint32_t simulated_msec) {
  // SV_Frame stored the simulated (accumulated) msec; the client wants this
  // frame's own.
  StoreU32(base, kClientFrameMsec, frame_msec);
  g_clock.models_ahead = 0;
  g_clock.valid = g_clock.game_ran;
  if (!g_clock.valid) return;  // paused, loading, no server: nothing to follow
  g_clock.step_start = LoadU32(base, kClientServerTime);
  g_clock.step = simulated_msec;
  g_clock.since = 0;
  g_clock.published = g_clock.step_start;
}

bool SkippedServerFrame(uint8_t* base, uint32_t frame_msec) {
  StoreU32(base, kClientFrameMsec, frame_msec);
  if (!g_clock.valid) return false;
  // Somebody else set the time (a map load or restart): leave it alone until
  // the next real step.
  if (LoadU32(base, kClientServerTime) != g_clock.published) {
    g_clock.valid = false;
    return false;
  }
  g_clock.since += frame_msec;
  g_clock.published = g_clock.step_start + std::min(g_clock.since, g_clock.step);
  StoreU32(base, kClientServerTime, g_clock.published);
  BumpGeneration(base);
  return true;
}

bool MenuOwnsMouse() {
  return REXCVAR_GET(pc_controls) && REXCVAR_GET(pc_menu_mouse) && menus::MenuMode();
}

void UpdateMouseOwnership() {
  const bool menu = MenuOwnsMouse();
  // The SDK driver captures and hides the pointer for mouse look whenever
  // the window has focus; in a menu it lets go of it.
  rex::input::mnk::SetMouseLookActive(!menu);
  static std::atomic<int> logged{-1};
  if (logged.exchange(menu ? 1 : 0) != (menu ? 1 : 0)) {
    REXLOG_INFO("PC controls: mouse {}", menu ? "released to the menus" : "captured for mouse look");
  }
}

void UpdateMenuSystem(PPCContext& ctx, uint8_t* base, uint32_t system) {
  if (!REXCVAR_GET(pc_controls) || !REXCVAR_GET(pc_menu_mouse)) return;
  menus::UpdateSystem(ctx, base, system);
}

void Attach(rex::ui::Window* window) { State().Attach(window); }
void Detach() { State().Detach(); }
void ApplyMouseLook(uint8_t* base) {
  menus::NoteGameplayFrame();
  State().ApplyMouseLook(base);
}
void PostProcessPad(uint8_t* base, uint32_t user_index, uint32_t state_address) {
  State().PostProcessPad(base, user_index, state_address);
}
void BeginStickSwirl(uint8_t* base, uint32_t receiver, double frame_time, StickPatch& patch) {
  State().BeginStickSwirl(base, receiver, frame_time, patch);
}
void BeginStickToggle(uint8_t* base, uint32_t receiver, StickPatch& patch) {
  State().BeginStickToggle(base, receiver, patch);
}
void EndStickPatch(uint8_t* base, const StickPatch& patch, uint32_t output_address) {
  State().EndStickPatch(base, patch, output_address);
}
void BeginRowboat(uint8_t* base, uint32_t receiver) { State().BeginRowboat(base, receiver); }
bool HoldStickWrite(const uint8_t* base, uint32_t axis) { return State().HoldStickWrite(base, axis); }

}  // namespace cod3::controls
