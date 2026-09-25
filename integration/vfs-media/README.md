# CoD3 extracted-data VFS mapping

This directory contains a read-only, native-side path mapping for the
verified extracted tree at `game/cod3`. It is deliberately independent of the
active `cod3-pc` target so that path-policy changes can be reviewed and tested
without changing the generated guest code or copying game assets.

The mapping follows the extracted-XEX convention used by Xenia:

- `GAME:` and `D:` are symbolic links to one host-path device.
- The physical device name is `\\Device\\Harddisk0\\Partition1`.
- Separators and ASCII case are normalized before lookup.
- `.` and `..` are canonicalized, but traversal above the game root is
  rejected by this adapter before a host path is formed.
- `cache:` and `update:` are outside this mapping. No missing-file success
  path or content alias is synthesized.

The corresponding Xenia source references are `tools/Xenia-source/src/xenia/emulator.h:59-60`
for the `GAME:`/`D:` names, `tools/Xenia-source/src/xenia/emulator.cc:448-473`
for device registration and links, `tools/Xenia-source/src/xenia/emulator.cc:600-613`
for the extracted-XEX launch layout, and
`tools/Xenia-source/src/xenia/vfs/virtual_file_system.cc:128-155` for guest
path normalization, link resolution, and device lookup. ReXGlue's isolated
runtime applies the same mount shape in
`integration/rexglue-runtime-build/src/src/system/runtime.cpp:295-323`.

## Source inventory

The supplied XDVDFS image was already verified by the repository extraction
workflow as 553 files, 41 directories, and 6,193,138,297 bytes. The native
test checks those counts against the live `game/cod3` tree and checks every
file in the root, `config`, `media`, and `movies` startup areas by name. The
remaining `sp` and `mp` trees are included in the full recursive count and
are not copied here.

The observed startup misses are recorded in `cod3_vfs_media.toml` and
`ObservedMissingPaths()`:

- `d:/config/language.cfg`, `d:/config/bro.cfg`, and
  `d:/config/autoexec.cfg` are absent. The `config` directory itself is
  present with 13 other `.cfg` files.
- `d:/movies/legal-us-en.wma`, `d:/movies/legal-us-fr.wma`, and
  `d:/movies/legal-us-de.wma` are absent. The `movies` directory is present
  with 40 `.wma`/`.wmv` files, including the unsuffixed
  `legal-us.wma` and `legal-us.wmv`.
- The 14 probed language directories (`_english`, `_french`, `_german`,
  `_italian`, `_spanish`, `_british`, `_russian`, `_polish`, `_korean`,
  `_taiwanese`, `_japanese`, `_chinese`, `_thai`, `_leet`) are absent.
- `d:/hunkusage.dat` is absent.

The unsuffixed `legal-us.wma` is a candidate for a future title-level
fallback only. Its alias is explicitly disabled because a same-size or
same-container file is not proof that the title expects that language path.
The resolver therefore continues to return the requested missing path, and
the test requires it to remain absent. The smallest reversible content fix is
to provide the exact files from the user's licensed source or to add a
reviewed, opt-in runtime fallback after language behavior is proven; this
integration does neither automatically.

## Test

Configure and run the standalone native test from the workspace root:

```powershell
& .\scripts\toolchain-env.ps1 -Quiet
cmake -S .\tests\vfs-media -B .\tests\vfs-media\out -G Ninja
cmake --build .\tests\vfs-media\out --config RelWithDebInfo
ctest --test-dir .\tests\vfs-media\out --output-on-failure -C RelWithDebInfo
```

The test only enumerates and stats existing files and performs lexical path
checks. It does not launch Xenia or the game, write to `game/cod3`, create
missing content, or use copyrighted bytes as test fixtures.
