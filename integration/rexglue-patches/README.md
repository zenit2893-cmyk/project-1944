# XEX heap reservation fix

Patch: `0001-preserve-xex-heap-reservations.patch`

Base SDK commit: `0c7b01a0ac0479801757507d80533f662fa0815d`

The shipped `rexruntime.dll` forgets the entire guest XEX heap allocation map whenever it loads another XEX. Call of Duty 3's main image at `0x82000000` and level images at `0x89000000` share that heap. In the isolated public API probe, loading Saint-Lo changes the main image from reserve+commit (`state=3`) to free (`state=0`); a reservation overlapping the main image is then accepted. The source of this behavior is `XexModule::ReadImage()` calling `LookupHeap(base_address_)->Reset()`.

The patch removes that reset, explicitly owns each primary image reservation, reserves before committing so overlaps fail, and releases only the owned allocation after a failed decode. A retail-key failure can therefore retry with the devkit key without dropping another image or the dispatch tables from the allocation map. Unload releases only an allocation the module actually owns. This is a loader bookkeeping correction; it changes no guest instructions, simulation timing or game data.

The patch has been checked against the pinned source with `git apply --check`. The installed `win-amd64` SDK and the pinned source checkout are not edited by the audit. `candidate/` contains the two patched source files for review and isolated compilation.

Validation performed:

- `tests/runtime-module-probe/Run.ps1`: reproduces the defect through the shipped public Runtime API, with `guest_entry_executed=false`; the child process exits 2 to indicate the known defect. The result and hashes are in `analysis/runtime-module-probe.json` and `analysis/runtime-module-probe-receipt.json`.
- `tests/runtime-module-probe/Run.ps1 -Candidate`: links the patched `XexModule` implementation locally to the original runtime's memory system and passes 13 checks, including unrelated reservation preservation, overlap rejection, successful unload and forced retail-key failure followed by successful devkit-key retry. The devkit fixture is a temporary memory buffer; no game file is changed. Results are in `analysis/runtime-module-probe-candidate.json` and its receipt.
- The candidate source compiles as `runtime_xex_patch_syntax` against the installed SDK and matching private third-party headers. This target is separate from the original public API probe.
- Clang 22.1.8 record layouts for the Windows MSVC ABI agree for every pre-existing field, base and virtual layout. `XexModule` remains 360 bytes aligned to 8. The new flag occupies the previously unused byte at offset 283; `base_address_` remains at 284. Evidence: `analysis/runtime-patch-abi-layout.json` and the two `logs/runtime-layout-*.log` files.

The isolated candidate test does not prove an entire replacement DLL. After building a replacement SDK, run the original public API probe with the replacement DLL first in its process DLL search path. The expected fixed result is child exit 0, main `state=3` before and after the level load, and both overlap attempts rejected. Compare the replacement DLL's exported names with the shipped runtime and run the native app before treating the replacement as integrated.

For the current Windows Release build, this patch alone preserves the relevant class layout. A rebuilt runtime still needs the same C++/MSVC ABI, Release CRT, public exports and dependency versions. Compile runtime sources with the patched header ahead of the installed include directory.

The change is limited to primary image allocation. Existing title-update allocation behavior is not redesigned by this patch. Retail and devkit retries, existing image conflicts and normal load/unload are the paths validated here.
