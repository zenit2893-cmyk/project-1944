# Bundle boundaries

The release workflow produces two separate deliverables.

`native-runtime` is the distributable Windows AMD64 host bundle. It contains
`cod3_pc.exe`, the fifteen native mission DLLs, the coroutine helper, and the
three ReXGlue runtime DLLs required by the built executable. It also contains
the license texts, a user-data setup note, and a manifest with SHA-256 hashes.
It has no game data and therefore cannot start until the recipient supplies
the matching user-owned Call of Duty 3 data tree.

`developer-source` is the reproducible source and evidence bundle. It contains
the native project sources, integration sources, build and analysis scripts,
reports, manifests, license inputs, and the setup instructions. It excludes
all build output, generated guest C++, extracted game files, shader output,
debug symbols, dumps, archives, and user data. A developer must supply the
game input and install or obtain the pinned SDK/toolchain components under
their own applicable terms before running code generation or a build.

The compiler toolchain is represented by version, provenance, and hash records
in `toolchain-provenance.json`; compiler payloads are not copied into either
bundle. In particular, the local MSVC and Windows SDK installation is not
treated as redistributable by this project. ReXGlue, XenosRecomp, XenonRecomp,
and Xenia-derived notices are copied according to
`license-manifest.json`. The package script fails closed if any required
notice is unavailable.

The generated package manifest is deterministic with respect to the selected
input files: paths are normalized, entries are sorted, hashes are SHA-256, and
the optional ZIP uses a fixed entry timestamp. This makes a changed binary,
source file, tool version, or license input visible in the receipt.

