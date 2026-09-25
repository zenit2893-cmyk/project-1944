# Third-party notices for the native CoD3 port bundles

This file describes the provenance of every component that is present in a
shipped binary, in a shipped header tree, or is required to rebuild the port.
The packaging script copies the exact license texts named in
`license-manifest.json` into `licenses/`; a bundle is rejected when a required
notice is missing.

No Call of Duty 3 data is present in any bundle. See "Game-data boundary".

## What each bundle contains

| Bundle | Payload |
|---|---|
| `cod3-pc-runtime.zip` | Prebuilt `cod3_pc.exe`, the ReXGlue runtime DLLs, launcher, docs, licenses. |
| `cod3-pc-full.zip` | The runtime payload, the port sources, **and the pruned ReXGlue SDK under `win-amd64/`**. |
| `cod3-pc-developer.zip` | Port sources, evidence and licenses only. |
| `cod3-pc-sdk-sources.zip` | Corresponding sources for the LGPL and GPL components described below. |

## ReXGlue SDK

The native host uses the ReXGlue SDK and its runtime. The SDK checkout is
identified by commit `0c7b01a0ac0479801757507d80533f662fa0815d`; its own
BSD-3-Clause text is copied to `licenses/rexglue/LICENSE.txt`. ReXGlue contains
portions derived from Xenia, which is stated in that license and in the runtime
provenance report.

The Full bundle redistributes the SDK under that BSD-3-Clause grant, **pruned**
in two ways:

1. **`bin/rexglue.exe` is not redistributed.** The SDK's code-generation
   executable statically links `thirdparty/disasm`, the PowerPC disassembler
   from GNU binutils (`ppc-dis.c`, `ppc.h`), which is GPL-2.0-or-later. Shipping
   that executable would place the whole binary under the GPL and require the
   complete corresponding source of everything linked into it. The project does
   not do that, so the executable is left out and the recipient supplies it from
   their own SDK installation. `licenses/gnu-binutils/` carries the binutils
   notice and the GPL-2.0 text.
2. **Debug and Release configurations are removed.** Only the RelWithDebInfo
   import libraries, DLLs and CMake configuration files are shipped, because
   that is the configuration the port builds. The `*-debug.cmake` and
   `*-release.cmake` target files are removed together with their binaries so
   that CMake's imported-target file check stays satisfied.

`lib/disasmrd.lib` **is** shipped. It is a separate, self-contained work under
GPL-2.0-or-later; the port links nothing against it. Its complete corresponding
source (`thirdparty/disasm`: `ppc-dis.c`, `ppc.h`, `ppc-inst.h`, `dis-asm.h`,
`disasm.c`, `CMakeLists.txt`) is in `cod3-pc-sdk-sources.zip` and the GPL-2.0
text is in `licenses/gnu-binutils/COPYING.GPL-2.0.txt`.

## LGPL components and the relink right

`rexruntimerd.dll` statically links two LGPL libraries:

- **FFmpeg** (`libavcodec`, `libavutil`), LGPL-2.1-or-later. The build sets
  `CONFIG_GPL 0`, `CONFIG_NONFREE 0` and `CONFIG_VERSION3 0`, so no GPL-only or
  version-3-only FFmpeg component is present. Texts:
  `licenses/ffmpeg/COPYING.LGPLv2.1.txt` and `licenses/ffmpeg/LICENSE.md`.
- **libmspack**, LGPL-2.1. Text: `licenses/libmspack/COPYING.LIB.txt`.

To honour LGPL-2.1 section 6, `cod3-pc-sdk-sources.zip` accompanies the release
and contains the complete source of both libraries as built, plus the ReXGlue
SDK source that produces `rexruntimerd.dll` and the scripts that build it, so a
recipient can modify either library and relink the runtime. That archive is part
of the same release as the binaries.

## Components linked into the shipped binaries

Each has its full license text under `licenses/`.

| Component | License | Where it is |
|---|---|---|
| ReXGlue SDK | BSD-3-Clause | runtime DLLs, GPU plugin, headers |
| Xenia-derived code | BSD-3-Clause | runtime, GPU plugin, shader adapter |
| SDL3 | Zlib | statically linked into the runtime |
| FFmpeg (`libavcodec`, `libavutil`) | LGPL-2.1-or-later | statically linked into the runtime |
| libmspack | LGPL-2.1 | statically linked into the runtime |
| fmt | MIT | statically linked into the runtime, headers shipped |
| spdlog | MIT | statically linked into the runtime, headers shipped |
| xxHash | BSD-2-Clause | statically linked into the runtime |
| Tracy | BSD-3-Clause | `TracyClientrd.dll`, headers shipped |
| toml++ | MIT | headers shipped, used by the runtime |
| utfcpp | BSL-1.0 | headers shipped, used by the runtime |
| simde | MIT | headers shipped, used by the runtime |
| disruptorplus | MIT | headers shipped, used by the runtime |
| Dear ImGui | MIT | GPU plugin overlay |
| o1heap | MIT | runtime allocator |
| aes_128 | MIT | runtime crypto |
| tiny-AES-c | Unlicense | runtime crypto |
| DES (Faraz Fallahi) | MIT | runtime crypto |
| RC4 (Whistle Communications) | BSD-style | runtime crypto |
| Rijndael reference implementation | public-domain-style | runtime crypto |
| SHA-256 (Stephan Brumme) | Zlib | runtime hashing |
| TinySHA1 | MIT | runtime hashing |
| AMD DXBC checksum helper | permissive, notice preservation | DXBC shader writer |
| stb_image | MIT OR Unlicense | runtime image loading |
| DirectX Shader Compiler headers | NCSA (LLVM Release License) | headers shipped |
| RenderDoc in-application API header | MIT | headers shipped |
| Microsoft PE/COFF structure declarations | header declarations | PE parsing |

Upstream repositories for the SDK's third-party components are recorded in
`.gitmodules` of the SDK source; the exact revisions are the gitlinks of that
checkout.

## Xenia-derived code

The D3D12 texture-cache overlay and the CoD3 shader adaptation contain code
derived from Xenia. The relevant Xenia Canary source revision is
`0e1307bd2e6bfeeff29635a6b823e72e61c97ce9`. The full BSD-3-Clause text is copied
to `licenses/xenia/XENIA-LICENSE.txt`. The notice is retained in every bundle
that carries the native runtime.

The Xenia-derived shader gradient and cube algorithms are part of the
developer-side XenosRecomp adapter. Their dedicated notice and full license are
copied to `licenses/xenosrecomp/XENIA-GRADIENT-NOTICE.txt` and
`licenses/xenosrecomp/XENIA-GRADIENT-LICENSE.txt`.

## XenosRecomp

The optional shader conversion tool is pinned to `hedge-dev/XenosRecomp` commit
`990d03b28a27b50277ee5d8d942e1c5f873869d1`. Its MIT license is copied to
`licenses/xenosrecomp/LICENSE.md`. The runtime bundle does not contain the
XenosRecomp executable or generated shader files; the notice appears there only
for the runtime's Xenia-derived renderer provenance, while the complete
XenosRecomp notice is required in the developer bundle.

## XenonRecomp

The optional CPU analysis/code-generation tool is pinned to
`hedge-dev/XenonRecomp` commit `ddd128bcca99fe8bfbb99bea583c972351fa6ace`. Its
MIT license is copied to `licenses/xenonrecomp/LICENSE.md` in the developer
bundle. XenonRecomp output is not shipped as a replacement runtime; the native
executable uses the bounded, reviewed integration described by the project
reports.

## Compiler toolchain

The Full bundle carries, under `tools/toolchain-bundle`, the redistributable
build tools so a rebuild needs no downloads for them: PowerShell 7.6.5 (MIT;
the official `PowerShell-7.6.5-win-x64.zip`, SHA-256
`32eb8f6cdce08f86e987d625a2733e54ac3e289ae7e1621b14c0b5bcec2434ea`; its
license and `ThirdPartyNotices.txt` for the bundled .NET runtime are copied to
`licenses/powershell/`), Clang/LLVM (Apache-2.0 WITH LLVM-exception), CMake
(BSD-3-Clause), Ninja (Apache-2.0), xdvdfs (MIT), CPython (PSF-2.0) and the
xxhash, cryptography and capstone modules. Each tree keeps its own license
files; `tools/toolchain-provision/bundle-spec.json` lists the contents.

MSVC and the Windows SDK are not redistributed in any bundle: their license
does not allow it. `TOOLCHAIN-BOUNDARIES.md` records what was used.

For a package without the bundle, `tools/toolchain-provision/Install-Toolchain.ps1`
downloads CMake, Ninja and Clang/LLVM from their own release pages and verifies
each against the SHA-256 pinned in `toolchain-pins.json`. MSVC and the Windows SDK are fetched
from Microsoft's servers by PortableMSVC (MIT, Travis Bender), whose sources
ship under `tools/toolchain-bootstrap`; its license text is copied to
`licenses/portablemsvc/LICENSE.txt`. When the machine has no usable Python,
`uv` (MIT OR Apache-2.0) is downloaded to supply one.

## Components built on the recipient's machine

Three things are deliberately produced locally rather than shipped:

- **`rexglue.exe`** is compiled from the SDK source in `sdk-source/` by
  `tools/rexglue-cli/Build-RexGlueCli.ps1`. The GPL restricts distribution, not
  use, so a binary the recipient builds for themselves carries no obligation
  toward anyone else. Two header-only dependencies the SDK keeps as empty
  submodules are fetched from their own repositories: CLI11 (BSD-3-Clause) and
  inja with nlohmann/json (MIT). Their license texts are in `licenses/`.
- **The two Xenon bridge thunks** are generated by XenonRecomp (MIT, sources
  shipped under `tools/XenonRecomp`) from the recipient's own `default.xex`.
  They are derived from the game, so they are never present in a bundle.
  `tools/xenon-bridge-build/Build-XenonBridge.ps1` verifies both the guest
  opcodes and the generated text against the reviewed expectations and refuses
  anything else.
- **The patched Xenos GPU plugin** is built from the SDK source; Dear ImGui
  (MIT), another empty submodule, is fetched from its own repository.

## Project and game-data boundary

The project license is copied to `licenses/project/LICENSE.txt`. No bundle
contains the Call of Duty 3 ISO, an XEX, extracted game files, mission assets,
generated guest C++, shader caches, debug symbols, or user data. The launcher
expects the recipient to provide a legally obtained, user-owned game data tree
separately. The package manifest records the input XEX SHA-256 as build
provenance only; it never copies the input bytes.
