// Game-window mouse pointer: the launcher's style, and hidden when it should
// be (see game_cursor.cpp). Must run on the UI thread that owns the window;
// the subclass goes away with the window itself (WM_NCDESTROY).
#pragma once

#include <string>

namespace rex::ui {
class Window;
}

namespace cod3::controls {

// Loads launcher/assets/cursors/<style>/arrow.cur (relative to the working
// folder) for the game window; "system" keeps the Windows arrow. Visibility
// follows the SDK window's cursor state, with idle hiding in fullscreen.
// Returns false only if the window does not exist yet, so the caller retries.
bool InstallGameCursor(rex::ui::Window* window, const std::string& style);

}  // namespace cod3::controls
