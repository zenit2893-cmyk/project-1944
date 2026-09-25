// Mouse support for CoD3's menus: the front end, the pause menu and dialogs
// (see menu_mouse.cpp).
#pragma once

#include <cstdint>

struct PPCContext;
namespace rex::ui {
class Window;
}

namespace cod3::controls::menus {

// --- UI thread --------------------------------------------------------------
void AttachWindow(rex::ui::Window* window);
// Pointer position in the window's client area (physical pixels).
void OnPointerMove(int32_t x, int32_t y, uint32_t client_width, uint32_t client_height);
// Button presses while the menus own the mouse.
void OnPointerClick(bool right);
// Wheel notches while the menus own the mouse; positive is up.
void OnPointerWheel(int notches);
// Arrow keys or the like moved the selection: the pointer steps aside until the
// mouse moves again, so it does not sit on top of a different entry.
void OnNavigationInput();
void OnPointerMotion();  // any real mouse motion
bool PointerHiddenByNavigation();

// --- any thread -------------------------------------------------------------
// True while a menu screen is up (front end, pause menu, dialog): the mouse
// is released and drives the menu instead of the camera.
bool MenuMode();

// --- guest thread -----------------------------------------------------------
// FEMenuSystem::Update (sub_824EE2E0): hover, clicks and the wheel are applied
// to the active menu of the top-most menu system here.
void UpdateSystem(PPCContext& ctx, uint8_t* base, uint32_t system);
// Pad buttons the mouse presses in menus (A, B, D-pad), for pad 0.
uint16_t TakePadButtons();

// FEMenuSystem::OpenMenu (sub_824E7468): 'system' switches to menu 'index'.
void NoteMenuOpen(uint8_t* base, uint32_t system, int32_t index, int32_t parent, int32_t slot);

// Once per pad poll: development probes (COD3_UI_PROBE) and the scripted-input
// test harness (COD3_INPUT_SCRIPT). Returns true while a test script owns pad
// 0; 'pad' then holds what it presses right now.
struct ScriptPad {
  uint16_t buttons = 0;
  int16_t lx = 0;
  int16_t ly = 0;
  int16_t rx = 0;
  int16_t ry = 0;
};
bool PollDevelopmentHooks(uint8_t* base, ScriptPad& pad);
// The look update ran (gameplay, not a menu or a load); for the test harness.
void NoteGameplayFrame();

}  // namespace cod3::controls::menus
