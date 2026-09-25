// SDL joystick settings that must be in place before the runtime starts SDL.
//
// Every device arrival or removal (a pad waking up or going to sleep, a
// headset, a USB stick) makes SDL enumerate DirectInput devices, and it does
// so holding its joystick lock. The SDK's input driver calls SDL from the game
// thread (opening and closing pads, rumble, instance lookups), so the game
// waited for that enumeration: a tester log showed 183, 225 and 300 ms frames,
// each right at an "Xbox One Controller" added/removed event.
//
// Xbox pads keep working through XInput and PlayStation/Switch pads through
// HIDAPI; only plain DirectInput pads drop out. SDL reads hints from the
// environment, so SDL_JOYSTICK_DIRECTINPUT=1 set before launch brings them back.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

namespace {

void DefaultEnvironment(const wchar_t* name, const wchar_t* value) {
  if (GetEnvironmentVariableW(name, nullptr, 0) == 0) SetEnvironmentVariableW(name, value);
}

// Static initialisation of the host executable runs before its main(), so
// long before the window and SDL come up.
[[maybe_unused]] const bool g_sdl_hints_applied = [] {
  DefaultEnvironment(L"SDL_JOYSTICK_DIRECTINPUT", L"0");
  return true;
}();

}  // namespace
