// PC keyboard/mouse layer for the Call of Duty 3 port.
//
// Two separate problems are solved here.
//
// Mouse look. The SDK's keyboard/mouse driver turns mouse motion into right
// stick deflection, and CoD3 then runs that through its console look model: a
// dead zone, an acceleration term (cl_mouseAccel), a turn-rate ceiling scaled
// by m_yaw, and a per-client zoom factor. Every one of those fights a mouse.
// Instead, mouse motion is taken before the SDK driver sees it and written
// straight into the client view angles after the game's own look update,
// with the Call of Duty PC model: degrees = counts * sensitivity * 0.022,
// scaled by the game's own zoom sensitivity while aiming down sights.
//
// Keyboard. The SDK driver cannot bind a bare Shift, Ctrl or Alt, has no mouse
// wheel or side buttons, and no hold/toggle behaviour. This layer owns the
// whole keyboard/mouse-to-pad mapping and merges it into the pad state the
// game reads, right after XInputGetState returns.
#pragma once

#include <cstdint>

struct PPCContext;
namespace rex::ui {
class Window;
}

namespace cod3::controls {

// Start listening to the game window. Safe to call once the window exists.
void Attach(rex::ui::Window* window);
void Detach();

// Called after the guest look update (sub_8250FF48) has run for this frame.
void ApplyMouseLook(uint8_t* base);

// Marks the guest look update as running on this thread. While it is, the
// right-stick axes read through sub_8250A570 are reported as zero, so the
// mouse (which the SDK driver still turns into right-stick input for menus
// and stick-swirl QTEs) does not also rotate the camera through the stick.
class LookUpdateScope {
 public:
  LookUpdateScope();
  ~LookUpdateScope();
  LookUpdateScope(const LookUpdateScope&) = delete;
  LookUpdateScope& operator=(const LookUpdateScope&) = delete;
};

// True if the value of guest axis 'axis' read right now must be replaced by 0.
bool SuppressLookAxis(uint32_t axis);

// Called after the guest XInputGetState wrapper (sub_82344F98) returned
// success for 'user_index'; 'state_address' is the guest XINPUT_STATE.
void PostProcessPad(uint8_t* base, uint32_t user_index, uint32_t state_address);

// SV_Frame (sub_82518E40) with 'msec' since the last frame: true if the server
// should run now; 'msec' is then the time to simulate (cod3_server_hz).
bool ServerFrameDue(uint32_t& msec);
// Around a server frame that runs: BeforeServerFrame, the guest SV_Frame, then
// AfterServerFrame with this frame's msec and the msec it simulated. The game
// frame hook (sub_825173F8) brackets the simulation step with Begin/EndGameFrame.
// A frame without a server step calls SkippedServerFrame instead, which moves
// the client clock on between the last two snapshots; when it returns true the
// caller also runs the model update (sub_82563FC0) for this frame and reports
// the time it ran with NoteModelUpdateBetweenSteps. ModelUpdateMsec trims
// G_RunFrame's own model update by that time.
void BeforeServerFrame();
void BeginGameFrame();
void EndGameFrame();
void AfterServerFrame(uint8_t* base, uint32_t frame_msec, uint32_t simulated_msec);
bool SkippedServerFrame(uint8_t* base, uint32_t frame_msec);
void NoteModelUpdateBetweenSteps(uint32_t msec);
uint32_t ModelUpdateMsec(uint32_t msec);

// Menus and the mouse (menu_mouse.h). True while a menu screen is up and the
// pointer is released to it instead of mouse look.
bool MenuOwnsMouse();
// Every pad poll for pad 0: hands the mouse to the menus or to mouse look.
void UpdateMouseOwnership();
// FEMenuSystem::Update (sub_824EE2E0), before the game's own update.
void UpdateMenuSystem(PPCContext& ctx, uint8_t* base, uint32_t system);

// Stick battle actions (planting a charge, turning a valve, rocking an
// object). Around the guest receiver's update the stick values it reads are
// replaced: keyboard and mouse drive them, and the stick swirl is rescaled to
// the 60 Hz frame it was tuned for. EndStickPatch puts the real values back.
struct StickPatch {
  uint32_t address[2] = {0, 0};
  uint32_t saved[2] = {0, 0};
  int count = 0;
};
void BeginStickSwirl(uint8_t* base, uint32_t receiver, double frame_time, StickPatch& patch);
void BeginStickToggle(uint8_t* base, uint32_t receiver, StickPatch& patch);
void EndStickPatch(uint8_t* base, const StickPatch& patch, uint32_t output_address);

// Rowing a boat (InteractInputRcvrRowboat, sub_824FC450): before each receiver
// update the oar stick is written into the game's stick array from the mouse
// and keys, and HoldStickWrite (from the array writer sub_8250A660) keeps real
// events for that stick out meanwhile; the stick is released at rest after.
void BeginRowboat(uint8_t* base, uint32_t receiver);
bool HoldStickWrite(const uint8_t* base, uint32_t axis);

}  // namespace cod3::controls
