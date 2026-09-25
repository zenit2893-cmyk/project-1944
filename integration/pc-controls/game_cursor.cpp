// The game-window mouse pointer: the launcher's style, shown only when it
// should be.
//
// The SDK window is an SDL3 window, and SDL3 is linked statically inside the
// runtime DLL, so its cursor API is out of reach from here. The window is
// subclassed instead and answers WM_SETCURSOR in the client area itself:
//
//  * hidden whenever the SDK has hidden the pointer (mouse look captures it);
//    this is decided from the SDK's own state, not from whatever cursor the
//    thread last had - Windows puts the arrow back after the pointer crosses
//    the frame or the window is re-activated, and relying on that left the
//    pointer on top of the game;
//  * in a menu (menu_mouse.cpp releases the mouse there) always shown, except
//    right after the selection was moved with the keys or a pad, until the
//    mouse moves again;
//  * otherwise (gamepad play, an unfocused window) shown on mouse movement
//    and hidden again after a short idle time, so no arrow is left in the
//    middle of the game.
#include "game_cursor.h"
#include "menu_mouse.h"
#include "pc_controls.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <commctrl.h>

#include <rex/logging.h>
#include <rex/ui/window.h>

#include <cwchar>
#include <filesystem>
#include <string>

namespace cod3::controls {
namespace {

constexpr UINT_PTR kSubclassId = 0xC0D3;
constexpr UINT_PTR kIdleTimerId = 0xC0D4;
constexpr UINT kIdleTimerMs = 250;
constexpr ULONGLONG kIdleHideMs = 2000;

HWND g_window = nullptr;
rex::ui::Window* g_rex_window = nullptr;
HCURSOR g_cursor = nullptr;       // the style's pointer, or the Windows arrow
bool g_owns_cursor = false;       // loaded from a file, so destroyed with the window
std::wstring g_path;
ULONGLONG g_last_input = 0;       // last mouse movement or button, GetTickCount64
LPARAM g_last_move = -1;          // client position of the last WM_MOUSEMOVE
bool g_shown = true;              // what this subclass last put up

HWND FindGameWindow() {
  struct Search {
    DWORD process;
    HWND sdl;
    HWND any;
  } search{GetCurrentProcessId(), nullptr, nullptr};
  EnumWindows(
      [](HWND hwnd, LPARAM parameter) -> BOOL {
        auto* s = reinterpret_cast<Search*>(parameter);
        DWORD process = 0;
        GetWindowThreadProcessId(hwnd, &process);
        if (process != s->process || !IsWindowVisible(hwnd)) return TRUE;
        wchar_t name[64] = {};
        GetClassNameW(hwnd, name, 64);
        if (std::wcscmp(name, L"SDL_app") == 0) {
          s->sdl = hwnd;
          return FALSE;
        }
        if (!s->any) s->any = hwnd;
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.sdl ? search.sdl : search.any;
}

// The .cur carries 32, 48 and 64 px images; pick the one for this DPI.
HCURSOR LoadForWindow(HWND hwnd) {
  const UINT dpi = GetDpiForWindow(hwnd);
  const int wanted = MulDiv(32, dpi ? int(dpi) : 96, 96);
  const int size = wanted <= 40 ? 32 : wanted <= 56 ? 48 : 64;
  return static_cast<HCURSOR>(LoadImageW(nullptr, g_path.c_str(), IMAGE_CURSOR, size, size, LR_LOADFROMFILE));
}

void SetStyleCursor(HCURSOR cursor, bool owned) {
  if (!cursor) return;
  const HCURSOR old = g_cursor;
  const bool old_owned = g_owns_cursor;
  g_cursor = cursor;
  g_owns_cursor = owned;
  if (old && old_owned && old != cursor) DestroyCursor(old);
}

bool ShouldShow() {
  using Visibility = rex::ui::Window::CursorVisibility;
  const Visibility visibility = g_rex_window ? g_rex_window->GetCursorVisibility() : Visibility::kVisible;
  if (visibility == Visibility::kHidden) return false;
  if (MenuOwnsMouse()) return !menus::PointerHiddenByNavigation();
  return GetTickCount64() - g_last_input < kIdleHideMs;
}

bool PointerOverClient(HWND hwnd) {
  POINT point{};
  if (!GetCursorPos(&point) || WindowFromPoint(point) != hwnd) return false;
  ScreenToClient(hwnd, &point);
  RECT client{};
  GetClientRect(hwnd, &client);
  return PtInRect(&client, point) != FALSE;
}

void Apply() {
  g_shown = ShouldShow();
  SetCursor(g_shown ? g_cursor : nullptr);
}

LRESULT CALLBACK CursorSubclass(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  switch (message) {
    case WM_MOUSEMOVE:
      // Windows also sends a WM_MOUSEMOVE without motion (after a click, a
      // focus change); only real motion brings a stepped-aside pointer back.
      if (lparam != g_last_move) {
        g_last_move = lparam;
        g_last_input = GetTickCount64();
        menus::OnPointerMotion();
        if (!g_shown && ShouldShow()) Apply();
      }
      break;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN:
    case WM_MOUSEWHEEL:
      g_last_input = GetTickCount64();
      break;
    case WM_SETCURSOR:
      if (LOWORD(lparam) == HTCLIENT) {
        Apply();
        return TRUE;
      }
      break;
    case WM_TIMER:
      if (wparam == kIdleTimerId) {
        // Menus opening and closing, idle hiding and the SDK capturing the
        // pointer happen without a mouse message, so nothing else would send
        // WM_SETCURSOR. SDL also puts its own arrow up when it lets go of the
        // pointer; that is replaced here too.
        if (PointerOverClient(hwnd)) {
          const bool show = ShouldShow();
          if (show != g_shown || (show && GetCursor() != g_cursor)) Apply();
        }
        return 0;
      }
      break;
    case WM_DPICHANGED:
      if (g_owns_cursor) SetStyleCursor(LoadForWindow(hwnd), true);
      break;
    case WM_NCDESTROY:
      KillTimer(hwnd, kIdleTimerId);
      RemoveWindowSubclass(hwnd, CursorSubclass, id);
      if (g_window == hwnd) {
        g_window = nullptr;
        g_rex_window = nullptr;
      }
      break;
    default:
      break;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

}  // namespace

bool InstallGameCursor(rex::ui::Window* window, const std::string& style) {
  if (g_window) return true;
  // The style's file, or the Windows arrow for "system" and anything unknown:
  // the visibility handling above is wanted either way.
  std::wstring path;
  bool valid_style = !style.empty() && style != "system" && style != "none";
  for (char c : style) {
    if (!(c >= 'a' && c <= 'z')) valid_style = false;
  }
  if (valid_style) {
    std::error_code error;
    const auto candidate = std::filesystem::current_path(error) / L"launcher" / L"assets" / L"cursors" /
                           std::wstring(style.begin(), style.end()) / L"arrow.cur";
    if (!error && std::filesystem::is_regular_file(candidate, error)) {
      path = candidate.wstring();
    } else {
      REXLOG_WARN("PC controls: cursor style '{}' not found under launcher/assets/cursors", style);
    }
  }
  const HWND hwnd = FindGameWindow();
  if (!hwnd) return false;  // not open yet; retried from the next window event

  HCURSOR cursor = nullptr;
  bool owned = false;
  if (!path.empty()) {
    g_path = path;
    cursor = LoadForWindow(hwnd);
    owned = cursor != nullptr;
    if (!cursor) REXLOG_WARN("PC controls: could not load the '{}' cursor", style);
  }
  if (!cursor) cursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));  // IDC_ARROW
  if (!SetWindowSubclass(hwnd, CursorSubclass, kSubclassId, 0)) {
    if (owned) DestroyCursor(cursor);
    return true;
  }
  SetStyleCursor(cursor, owned);
  g_window = hwnd;
  g_rex_window = window;
  g_last_input = GetTickCount64();
  SetTimer(hwnd, kIdleTimerId, kIdleTimerMs, nullptr);
  REXLOG_INFO("PC controls: game window pointer '{}' ({} dpi): shown in menus, hidden in mouse look, "
              "otherwise hidden after {} ms idle",
              owned ? style : std::string("system"), GetDpiForWindow(hwnd), kIdleHideMs);
  return true;
}

}  // namespace cod3::controls
