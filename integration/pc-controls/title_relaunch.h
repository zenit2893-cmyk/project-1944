// The game's reboot into itself between levels (title_relaunch.cpp).
#pragma once

namespace cod3::relaunch {

// Called from every pad poll. In an instance started by a relaunch it tells
// the previous instance, once, that this one is running and on screen, so the
// previous window can close without the desktop showing in between.
void NoteGameLoopRunning();

}  // namespace cod3::relaunch
