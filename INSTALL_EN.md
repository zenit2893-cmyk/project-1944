# Project 1944 1.0 — installation

English · [Русский](INSTALL_RU.md) · [Українська](INSTALL_UK.md)

**You need your own legally obtained Call of Duty 3 (USA, Europe) copy for Xbox 360.** Project 1944 does not provide or download the game. The supported `default.xex` SHA-256 is `2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692`.

## Before you start

- Windows 10/11 x64 and a Direct3D 12 capable GPU.
- About 7 GB of free space for installation; about 12 GB if you request a full compile.
- Your own Xbox 360 disc ISO, an extracted folder containing `default.xex`, or a compatible Games on Demand package under `415607E1\00007000`.

## Install and play

1. Download **`cod3-pc-full.zip`** and `SHA256SUMS.txt` from the same [Project 1944 release](https://github.com/zenit2893-cmyk/project-1944/releases). Compare the ZIP's SHA-256 with the checksum file. In PowerShell: `Get-FileHash .\cod3-pc-full.zip -Algorithm SHA256`.
2. Extract the entire ZIP into a new folder on a drive with enough free space. Use a path made of Latin letters and digits if possible; the game may reject a path with non-Latin characters when Windows has no 8.3 short name for it.
3. Run `Project1944.exe`. The fallback `launcher\PLAY-COD3.cmd` opens the same launcher if Windows blocks the unsigned executable. See [antivirus guidance](docs/antivirus.md) before changing Windows security settings.
4. Press **Choose image**, or drag your ISO, `default.xex`, extracted game folder, or GOD package into the launcher.
5. Press **Install and play**. The launcher checks the source, copies game data locally to `game\cod3`, performs a recompilation check, and starts the game. An interrupted installation can be resumed.

The local code translation usually takes about a minute on the tested PC; it needs no compiler when it matches the included build. The optional **Rebuild the game** action performs a full compile and may take 10–30 minutes. If Visual Studio C++ is absent, that action downloads MSVC and Windows SDK from Microsoft. You can also switch off **Recompile the game on this computer** to use the included build after source verification.

## If something goes wrong

The first Saint-Lô mission was tested, but the full campaign and other hardware have not been verified. Grass can appear as stretched strips; the default workaround hides the blades. Older DirectInput-only gamepads are not detected by default. See [tester details](docs/testers.md) and [controls](docs/controls.md).

Use **Bug report** in the launcher and describe the mission, checkpoint, steps, and result. Review the diagnostic ZIP for personal information before sharing it. Never attach your ISO, extracted game files, or generated game code.
