# CoD3 input and audio host boundary

This directory contains a small native policy adapter for the ReXGlue host
boundary. It has no SDL, XInput, XMA, or ReXGlue link dependency. It does not
enumerate devices, create a virtual HID device, inject input, or change guest
time. A future launcher can use `BuildInputLaunchArguments` to produce the
input CVar arguments, and the native test can run before the game target is
rebuilt.

The physical controller path is SDL3 by default. An optional external
`gamecontrollerdb.txt` can be supplied, but an absent file is only a warning:
SDL's built-in mapping is still allowed. The adapter emits an empty
`--hid_mappings_file=` for an SDL profile with no external file so the SDK does
not repeatedly warn about its default relative path. XInput profiles omit the
SDL mapping option.

The keyboard/mouse preset follows the existing ReXGlue MnK driver and keeps
the current action choices (WASD movement, RMB aim, LMB fire, and the existing
button chords). It corrects one host mapping collision in the current
`scripts/run-cod3.ps1` preset: that script assigns bare arrow keys to both the
D-pad and the right-stick fallback. The adapter uses `Shift+Arrow` for the
D-pad, matching the SDK's own defaults. ReXGlue's modifier matching is exact,
so bare arrows continue to serve the right-stick keybinds and the shifted
arrows serve the D-pad. This changes only the host key routing; it does not
change guest button bits or action semantics.

The vertical SDL axis conversion intentionally matches both the installed
ReXGlue driver and the pinned Xenia source (`~value` in the XInput int16
representation). Trigger conversion clamps malformed negative host values
before converting to the XInput byte range. SDL button indices use the same
order as ReXGlue, and Guide remains opt-in.

The audio policy describes the existing XMA contract: six guest channels at
48 kHz, a queue target of eight frames, a maximum of 64 frames, and silence on
an output underrun. `PlanAudioEndpoint` mirrors the ReXGlue SDL backend: mono
and stereo endpoints use the explicit 5.1-to-stereo fold; wider endpoints use
the six-channel passthrough stream. An endpoint observation is host metadata,
not a claim that gameplay audio has been listened to or that a full mission
run passed.

Build the isolated contract test with:

```powershell
pwsh -NoProfile -File tests/input-audio/Run.ps1
```

The test is intentionally independent of a connected controller, audio
endpoint, GUI, game executable, Xenia binary, or ReXGlue runtime DLL. To use
the adapter in `cod3-pc`, the parent target may add the directory and call
`cod3_enable_input_audio(cod3_pc)` after reviewing the policy; this task does
not modify the active game CMake target.
