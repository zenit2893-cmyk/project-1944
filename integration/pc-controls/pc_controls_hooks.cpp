#include "menu_mouse.h"
#include "pc_controls.h"
#include "title_relaunch.h"

#include <rex/hook.h>

#include <bit>
#include <cstring>

// REX_EXTERN gives the SDK's raw hook signature. The strong definitions below
// replace the generated weak names; the __imp__ symbols stay the original
// ReXGlue bodies, so each hook calls straight through and adds to the result.
REX_EXTERN(__imp__sub_8250FF48);
REX_EXTERN(__imp__sub_8250A570);
REX_EXTERN(__imp__sub_82344F98);
REX_EXTERN(__imp__sub_82508238);
REX_EXTERN(__imp__sub_824F6498);
REX_EXTERN(__imp__sub_824E7468);
REX_EXTERN(__imp__sub_824EE2E0);
REX_EXTERN(__imp__sub_82518E40);
REX_EXTERN(__imp__sub_825173F8);
REX_EXTERN(__imp__sub_82563FC0);
REX_EXTERN(__imp__sub_824FC450);
REX_EXTERN(__imp__sub_8250A660);

// Client look/move update (the console CL_GamepadMove). It turns the sticks
// into movement and view angles for this frame. While it runs, the right
// stick reads as zero (sub_8250A570 below); afterwards the mouse is added
// straight into the view angles with the PC Call of Duty model.
REX_EXTERN(sub_8250FF48) {
  {
    cod3::controls::LookUpdateScope scope;
    __imp__sub_8250FF48(ctx, base);
  }
  cod3::controls::ApplyMouseLook(base);
}

// Pad axis read (CL_GamepadAxisValue): r3 = axis, result in f1. Everything
// else that reads the right stick - menus, stick-swirl and stick-toggle
// battle actions - still sees the mouse through the SDK's stick emulation.
REX_EXTERN(sub_8250A570) {
  const uint32_t axis = ctx.r3.u32;
  __imp__sub_8250A570(ctx, base);
  if (cod3::controls::SuppressLookAxis(axis)) {
    ctx.f1.f64 = 0.0;
  }
}

// The game's XInputGetState wrapper: mr r5,r4 ; li r4,0 ; b XamInputGetState.
// Every pad poll goes through here, so this is where the keyboard and mouse
// buttons are merged into the state before the game looks at it.
REX_EXTERN(sub_82344F98) {
  const uint32_t user_index = ctx.r3.u32;
  const uint32_t state_address = ctx.r4.u32;
  cod3::relaunch::NoteGameLoopRunning();
  __imp__sub_82344F98(ctx, base);
  if (ctx.r3.u32 == 0) {
    cod3::controls::PostProcessPad(base, user_index, state_address);
  }
  if (user_index != 0 || state_address == 0) return;
  cod3::controls::UpdateMouseOwnership();
  cod3::controls::menus::ScriptPad scripted;
  if (cod3::controls::menus::PollDevelopmentHooks(base, scripted)) {
    // Development only: COD3_INPUT_SCRIPT drives pad 0 without keyboard focus
    // and without a controller, so pad 0 always reads as connected.
    uint8_t* state = base + state_address;
    if (ctx.r3.u32 != 0) std::memset(state, 0, 16);
    const uint16_t merged = uint16_t((state[4] << 8 | state[5]) | scripted.buttons);
    state[4] = uint8_t(merged >> 8);
    state[5] = uint8_t(merged);
    if (scripted.lx || scripted.ly) {
      state[8] = uint8_t(uint16_t(scripted.lx) >> 8);
      state[9] = uint8_t(scripted.lx);
      state[10] = uint8_t(uint16_t(scripted.ly) >> 8);
      state[11] = uint8_t(scripted.ly);
    }
    if (scripted.rx || scripted.ry) {
      state[12] = uint8_t(uint16_t(scripted.rx) >> 8);
      state[13] = uint8_t(scripted.rx);
      state[14] = uint8_t(uint16_t(scripted.ry) >> 8);
      state[15] = uint8_t(scripted.ry);
    }
    static uint16_t last = 0;
    static uint32_t packet = 1;
    if (merged != last) ++packet;
    last = merged;
    state[0] = uint8_t(packet >> 24);
    state[1] = uint8_t(packet >> 16);
    state[2] = uint8_t(packet >> 8);
    state[3] = uint8_t(packet);
    ctx.r3.u64 = 0;
  }
  // What the mouse presses in menus: A for a click on an entry, B for the
  // right button, the D-pad for the wheel.
  if (ctx.r3.u32 == 0) {
    if (const uint16_t menu = cod3::controls::menus::TakePadButtons()) {
      uint8_t* buttons = base + state_address + 4;
      const uint16_t merged = uint16_t((buttons[0] << 8 | buttons[1]) | menu);
      buttons[0] = uint8_t(merged >> 8);
      buttons[1] = uint8_t(merged);
    }
  }
}

// SV_Frame(msec) (Com_Frame at 0x82536DD0 calls it once per frame; the time
// wrap check against 0x70000000 identifies it). Runs the game simulation -
// G_RunFrame (sub_8256D3E0: actors, scripts, entities) - and builds the
// client's snapshot. With cod3_server_hz it runs at a fixed rate instead of
// once per rendered frame; in the frames between, the client clock is moved
// on by hand (pc_controls.cpp, "The client between two server frames").
REX_EXTERN(sub_82518E40) {
  const uint32_t frame_msec = ctx.r3.u32;
  uint32_t msec = frame_msec;
  if (!cod3::controls::ServerFrameDue(msec)) {
    if (cod3::controls::SkippedServerFrame(base, frame_msec)) {
      // Pose and prepare the models for this frame as the step would, called
      // from here as Com_Frame would call it (same stack pointer), with the
      // "inside the game frame" flag sub_825173F8 sets around G_RunFrame.
      constexpr uint32_t kInGameFrame = 0x82A2A1BC;
      auto* in_game_frame = reinterpret_cast<uint32_t*>(base + kInGameFrame);
      *in_game_frame = std::byteswap(uint32_t(1));
      PPCContext call = ctx;
      call.r3.u64 = frame_msec;
      __imp__sub_82563FC0(call, base);
      *in_game_frame = 0;
      cod3::controls::NoteModelUpdateBetweenSteps(frame_msec);
    }
    return;
  }
  cod3::controls::BeforeServerFrame();
  ctx.r3.u64 = msec;
  __imp__sub_82518E40(ctx, base);
  cod3::controls::AfterServerFrame(base, frame_msec, msec);
}

// SV_Frame's game step: bumps the state generation, flags the game frame and
// calls G_RunFrame(msec). Reached only when the server really simulates (not
// paused, running, not restarting), which is what the client clock follows.
REX_EXTERN(sub_825173F8) {
  cod3::controls::BeginGameFrame();
  __imp__sub_825173F8(ctx, base);
  cod3::controls::EndGameFrame();
}

// G_RunFrame's model update (its only caller): animation passes, distance LOD
// and hidden tags for every animated entity. Inside a server step it runs
// only the time the frames in between have not already run.
REX_EXTERN(sub_82563FC0) {
  ctx.r3.u64 = cod3::controls::ModelUpdateMsec(ctx.r3.u32);
  __imp__sub_82563FC0(ctx, base);
}

// FEMenuSystem::Update(system, f1 = dt), shared by the front end, the in-game
// (pause) and the dialog menu systems. The mouse is applied to the active menu
// before the game updates it.
REX_EXTERN(sub_824EE2E0) {
  cod3::controls::UpdateMenuSystem(ctx, base, ctx.r3.u32);
  __imp__sub_824EE2E0(ctx, base);
}

// FEMenuSystem::OpenMenu: r3 = menu system, r4 = new menu index (-1 closes),
// r5 = parent index, r6 = slot. Every front-end, pause and dialog screen
// change goes through here.
REX_EXTERN(sub_824E7468) {
  const uint32_t system = ctx.r3.u32;
  const int32_t index = int32_t(ctx.r4.u32);
  const int32_t parent = int32_t(ctx.r5.u32);
  const int32_t slot = int32_t(ctx.r6.u32);
  __imp__sub_824E7468(ctx, base);
  cod3::controls::menus::NoteMenuOpen(base, system, index, parent, slot);
}

// InteractInputRcvrStickSwirl update (vtable slot 5): r3 = receiver,
// r4 = float* animation speed out, f1 = frame time in seconds. Used for
// turning a charge's fuse and the like.
REX_EXTERN(sub_82508238) {
  const uint32_t receiver = ctx.r3.u32;
  const uint32_t speed_out = ctx.r4.u32;
  cod3::controls::StickPatch patch;
  cod3::controls::BeginStickSwirl(base, receiver, ctx.f1.f64, patch);
  __imp__sub_82508238(ctx, base);
  cod3::controls::EndStickPatch(base, patch, speed_out);
}

// InteractInputRcvrRowboat update (vtable slot 5 of 0x8206CA44): r3 =
// receiver, r5 = float* stroke phase. Reads the oar stick from the stick array.
REX_EXTERN(sub_824FC450) {
  cod3::controls::BeginRowboat(base, ctx.r3.u32);
  __imp__sub_824FC450(ctx, base);
}

// Stores one pad axis event (r3 = axis 0..5, r4 = value) into the stick array
// 0x829C9140 + client*72; its only writer.
REX_EXTERN(sub_8250A660) {
  if (cod3::controls::HoldStickWrite(base, ctx.r3.u32)) return;
  __imp__sub_8250A660(ctx, base);
}

// InteractInputRcvrStickToggleHoriz/Vert update (shared, vtable slot 5):
// r3 = receiver.
REX_EXTERN(sub_824F6498) {
  const uint32_t receiver = ctx.r3.u32;
  cod3::controls::StickPatch patch;
  cod3::controls::BeginStickToggle(base, receiver, patch);
  __imp__sub_824F6498(ctx, base);
  cod3::controls::EndStickPatch(base, patch, 0);
}
