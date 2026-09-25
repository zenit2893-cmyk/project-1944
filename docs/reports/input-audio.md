# CoD3 input/audio integration report

The native runtime already reaches the ReXGlue SDL and audio paths. The
captured logs show SDL 3.4.14 and the input system initialized, XMA MMIO
handlers registered, the XMA decoder and audio worker threads created, and a
real `Xbox One Controller` discovered. The same runs report a 48 kHz, two
channel Windows endpoint. These observations establish host initialization;
they do not establish full controller coverage, mission gameplay, or audio
correctness through every asset.

## Evidence from the supplied runs

| Evidence | Observation | Interpretation |
| --- | --- | --- |
| `logs/cod3-pc-run-20260905-082655.log` | SDL 3.4.14, input initialized, XMA MMIO registered, decoder/audio worker started | The ReXGlue host subsystems reached their setup paths |
| same log | `SDL OnControllerDeviceAdded: "Xbox One Controller"`, connection order 0, device 1 | One physical SDL gamepad was observed; this is not a test of every controller |
| same log | endpoint `Наушники (JBL Tune 720BT)`, 2 ch, 48000 Hz | The explicit stereo fold path is the appropriate output plan for that run |
| `logs/cod3-pc-run-20260905-085521.log` | endpoint `XG27ACS (NVIDIA High Definition Audio)`, 2 ch, 48000 Hz | A second endpoint also reached the same 2-channel contract |
| `logs/cod3-pc-run-20260905-082655.log` | initial `SDLCallback: no frames queued (silence)` messages followed by queued frames | Startup prefill behavior is visible; the lines alone do not prove a sustained underrun |
| all captured runs | `SDL GameControllerDB: file 'gamecontrollerdb.txt' does not exist` | Optional mapping data was absent. SDL still recognized the Xbox controller through its built-in mapping |
| all captured runs | missing `D:\movies\legal-us-*.wma` and config paths | Some guest files are absent from the extracted data; this can affect legal/cutscene media and is separate from host controller routing |
| `cod3-pc-run-20260905-100006.log` | later fatal guest access violation after host setup | The failure occurs after input/audio initialization; this report does not assign it to input/audio without a targeted repro |

The supplied Xenia audit also records that the Xenia release archive contains
no SDL library, controller database, renderer DLL, or audio plugin that can be
copied into the native target. The reusable evidence is source-level behavior:
Xenia loads optional controller mappings through SDL and uses XAudio2/XMA
source paths, while the native ReXGlue runtime uses SDL3 and its own audio
objects. The adapter therefore shares policy and conversion contracts only;
it does not mix SDL2 and SDL3 binaries or copy emulator payloads.

## Corrected keyboard/mouse routing

The current launcher preset in `scripts/run-cod3.ps1` emits both
`--keybind_dpad_up=Up` and the SDK's default `keybind_rstick_up=Up` (and the
same collision for the other three arrows). Because
`tools/rexglue-source/src/input/mnk/mnk_input_driver.cpp` matches modifier
masks exactly, pressing a bare arrow drives both logical controls. This is a
real host mapping bug: it can move the camera while the player intends to use
the D-pad.

The exact integration fix is to use the SDK defaults for the D-pad:

```text
--keybind_dpad_up=Shift+Up
--keybind_dpad_down=Shift+Down
--keybind_dpad_left=Shift+Left
--keybind_dpad_right=Shift+Right
```

The adapter emits those four values and tests that the bare-arrow form is not
present. The parent game launcher can adopt the four arguments after review.
No guest function, button bit, or gameplay action table is changed.

There is a second input edge case in the current SDK that the parent should
fix in the SDK integration when it is ready. `MnkInputDriver::OnMouseMove`
continues accumulating deltas while the window is focused, but
`GetDeviceState` returns early when `is_active()` is false, before reaching the
normal delta drain. Opening an overlay and then returning to gameplay can
therefore apply stale mouse movement as one camera jump. The exact safe fix is
to zero `mouse_dx_` and `mouse_dy_` under `state_mutex_` in the inactive/focus
early-return path (or call a helper that drains them) before returning. This
is an input lifetime fix, not a change to guest action semantics; it is outside
this scoped adapter because the SDK source and active game target are owned by
another integration area.

## Audio policy

The policy in `integration/input-audio` follows the existing ReXGlue SDL audio
implementation. The guest submits sequential six-channel, 48 kHz XMA output.
The host callback submits two channels with the explicit stereo fold on mono or
stereo endpoints, and six channels with the surround mix on wider endpoints.
The queue target remains eight frames, bounded by the runtime's four-to-64
frame range. Empty output is filled with silence; stale guest buffers are not
replayed. These are host safety properties, not a measurement of latency or
audio quality on every endpoint.

## Verification scope

`tests/input-audio/Run.ps1` builds and runs a standalone C++23 contract test.
It covers the corrected D-pad bindings, the full SDL-to-XInput button table,
vertical axis parity with ReXGlue/Xenia, trigger clamping, optional versus
required mapping-file diagnostics, audio endpoint selection, and invalid
queue/sample/XMA configurations. It does not launch the game, enumerate the
user's devices, require a GUI, use a fake device, or claim 120 FPS or physics
invariance.
