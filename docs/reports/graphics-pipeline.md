# Call of Duty 3: graphics preparation and integration evidence

The local disc now has a reproducible shader preparation stage. It reads the game's KAPF directories, decodes selected real NCH/LZO archive blocks, locates legacy Xbox 360 shader containers, and preserves their original bytes with SHA-256 and source offsets. XenosRecomp conversion and DXC validation are handled by `scripts/xenos-batch.py`; the current authoritative conversion results are in `docs/reports/xenos-cod3-shaders.json`.

These build artifacts are not yet the shaders used by the ReXGlue GPU plugin during a game draw. That runtime currently processes Xenos command buffers and translates microcode internally. A native renderer needs an explicit resource, vertex-input, constant-buffer, and shader-selection implementation before it can consume the separately generated XenosRecomp output.

## Verified local inputs and preparation

| Item | Result |
| --- | --- |
| ReXGlue SDK source matching bundled SDK | `0c7b01a0ac0479801757507d80533f662fa0815d` |
| XenosRecomp upstream source | `990d03b28a27b50277ee5d8d942e1c5f873869d1`, with local compatibility edits owned by the Xenos build stage |
| Archive format | `KAPF`, version approximately `2.06`, description `CODAUTO30` |
| `.cod` archives inspected | 451 |
| Metadata span total | 8,732,040 bytes |
| Unique shader source names | 92 `.xefx` names |
| Source-name plus declared-size variants | 99 |
| Selected archive blocks | 35 |
| Selected stored bytes | 69,020,468 |
| Decoded bytes | 121,468,508 |
| Unique extracted shader containers | 437 |
| Pixel / vertex containers | 246 / 191 |
| Total unique container bytes | 804,656 |
| Preparation elapsed time in recorded run | 1.578 seconds |
| Preparation errors | 0 |

The selection covers every observed source-name plus declared-size combination. Equal source names and lengths do **not** establish binary equivalence. Other occurrences in the 761 shader-containing blocks may contain different shader binaries. This is a bounded, useful corpus, not a claim that every possible shader permutation is covered. Inspecting every such block would involve approximately 1.65 GB stored and 2.31 GB decoded.

Initial strict signature scans are retained as evidence: the raw XEX and selected raw archives did not contain containers accepted by unmodified XenosRecomp. Decoding the archive and recognizing the older container revision resolved that result; no shader header bytes were rewritten to make a scan pass.

## Reproduce preparation

Run from `<workspace>` using Python 3.10 or later. The bundled interpreter used for the verified commands was `python`.

```powershell
$python = 'python'
& $python -m pip install --disable-pip-version-check --no-deps --target analysis/graphics-python-deps dissect.util==3.23
& $python scripts/shader_prepare.py game/cod3 --output-root analysis/graphics-prepared --max-decoded-mib 128 --max-stored-mib 128
```

`dissect.util` 3.23 is installed only under `analysis/graphics-python-deps`; its package metadata specifies Apache-2.0. It supplies the actual LZO decompressor. Preparation validates NCH signatures, declared input boundaries, contiguous decoded offsets, individual decoded lengths, final block length, and APKF output signature. Per-chunk and per-block SHA-256 values are retained. The two checksum words in the NCH headers are preserved as raw values and are **not** claimed to have been verified.

For a metadata-only estimate, append `--plan-only`. The command writes `plan.json` before decoding and refuses plans that exceed the explicit stored/decoded budgets. The original game directory is always opened for reading. Existing extracted outputs are reused only if their bytes hash identically.

The smaller diagnostic commands remain available:

```powershell
& $python scripts/shader_kapf_inventory.py game/cod3/sp/global.cod --output analysis/graphics-global-kapf.json --decode-block 0:1 --decoded-output analysis/graphics-global-block-0-1.apkf --max-decoded-mib 32
& $python scripts/shader_inventory.py analysis/graphics-global-block-0-1.apkf --output analysis/graphics-global-legacy-shaders.json --max-total-mib 32 --max-file-mib 32 --extract-dir analysis/graphics-shaders --max-extract 256 --include-legacy
```

## Legacy container facts

The corpus contains 246 containers with flags `0x102A1000`, 18 with `0x102A1001`, and 173 with `0x102A1021`. Unmodified upstream XenosRecomp targets `0x102A11xx`, so support must be an explicit compatibility path.

All 430 nonempty primary definition tables in this corpus have their list size at `+0x18` and the definition list at `+0x20`. Upstream's newer layout starts the list at `+0x14`. The old list contains one float-definition entry followed by three zero terminators. Observed entries define either four or eight `float4` registers. Register/physical bounds pass for every inspected table. Header padding varies and must not be required to be zero. The other seven containers have no definition table. Detailed observations are in `analysis/graphics-legacy-definition-layout.json`.

For all 173 `0x102A1021` containers, the fields at `+0x1C` and `+0x20` point to a second definition table and a second shader record. Both sets of metadata and microcode fit within the original container, and every secondary microcode length is a multiple of 12 bytes. See `analysis/graphics-legacy-auxiliary-layout.json`. An implementation must preserve primary/secondary selection explicitly; the game's runtime choice between them has not been established by this static analysis.

The source container is immutable across conversion. A converter may choose an entry via a command-line option, but the input file itself must retain the original hash.

## Texture instruction coverage

`scripts/shader_texture_inventory.py` follows the control-flow EXEC sequence bits and inventories active texture operations in all 610 primary/secondary entries. It does not scan arbitrary ALU words as if they were texture instructions. The recorded inventory has zero parsing errors:

| Active operation | Occurrences |
| --- | --- |
| TextureFetch | 1,209 |
| GetTextureWeights | 93 |
| GetTextureGradients | 332 |
| SetTextureGradientsHorz | 30 |
| SetTextureGradientsVert | 30 |
| SetTextureLod | 3 |

The corpus includes 36 texture fetches requesting explicit gradients: 9 use 2D textures and 27 use cube textures. All of those gradient instructions occur in pixel shaders. Unmodified upstream XenosRecomp silently omitted gradient-state operations, so bytecode compilation alone cannot detect this class of semantic omission. The current adapter/report must either implement each active operation or mark the corresponding entries as semantically incomplete.

Three grass vertex shader entries set a register LOD immediately before texture fetches. The two entries of container `4e7bb6...` use `r1.w`, and container `f7a42c...` uses `r0.y`. Their texture instructions set `useRegisterLod=1` and `useComputedLod=0`; forcing an arbitrary LOD 0 would lose real shader behavior. See `analysis/graphics-grass-texture-fetch.json`. Guest sampler LOD bias, base-map mode, and clamps remain part of the host-resource binding contract.

```powershell
& $python scripts/shader_texture_inventory.py analysis/graphics-prepared/manifest.json --output analysis/graphics-texture-feature-inventory.json
```

## ReXGlue runtime boundary

The packaged SDK has `REXGLUE_USE_VULKAN OFF`. Its `rexgpu-xenos` plugin creates the D3D12 backend when the default backend `any` is requested. CMake needs `GPU_PLUGINS xenos` on the configured target, and runtime startup must set `gpu_plugin` to `xenos`; the default is empty. There is no separate `gpu` CVar in this SDK's ReXApp startup path.

The plugin's D3D12 pipeline calls `DxbcShaderTranslator::TranslateAnalyzedShader`; DXC is not required for that primary translation path. The optional DXIL conversion/disassembly path is a different feature. The plugin stores raw shader microcode in its `.xsh` cache and tracks pipeline modifications. XenosRecomp directory mode instead emits an Unleashed Recompiled C++ cache of compiled shader artifacts. Neither its cache layout nor its constant/resource bindings match the ReXGlue plugin automatically.

The hash inputs also differ: ReXGlue hashes the guest microcode bytes loaded for a draw, whereas upstream XenosRecomp's directory mode hashes an entire shader container. The prepared manifest uses SHA-256 for provenance. A native renderer must define which entry and which hash it looks up rather than treating those keys as interchangeable.

Once a game reaches GPU draws, useful diagnostics are `--gpu_plugin xenos` and `--dump_shaders <directory>`. Raw dumps are named `shader_<hash>.ucode.bin.vert` or `.frag`; they contain host-endian microcode, not complete reflected XenosRecomp containers. The dump directory can also receive disassembly and translated shader data. These diagnostic paths are available in source; reaching actual COD3 draws still depends on CPU/runtime bring-up.

Disabling `vsync` is not a safe display-only 120 FPS switch. In this SDK, `--vsync=false` changes the guest vblank callback interval to 1/1000 of the guest tick frequency. Any 120 FPS work must preserve the independently measured simulation cadence and validate gameplay/physics against a baseline.

## Concrete work remaining

1. Keep conversion failures explicit and tied to source container and primary/secondary entry. Compile success establishes shader syntax and target-bytecode validity, not visual equivalence.
2. Correlate actual runtime microcode loads with prepared containers/entries once the recompiled CPU reaches graphics. The mapping needs both entries of the `0x102A1021` containers.
3. Implement native vertex-input mapping. Some real COD3 vertex shaders have repeated `POSITION0`/`NORMAL0` semantics at different microcode instruction addresses. Merging those inputs would remove the distinction between their fetch instructions. In the inspected example, all six stored fetch instructions still have constant index 95 with zero stride/offset/format, consistent with placeholders awaiting runtime vertex-declaration patching; actual host-buffer bindings cannot be inferred from those placeholders alone.
4. Implement the host resource and constant layout used by generated shaders, including pixel boolean-bank addressing and vertex texture-bank addressing. No fake default constants or sampler placeholders should hide a missing binding.
5. Compare menu, gameplay, depth/shadow, transparency, vegetation, particles, and post-processing output with the existing plugin/reference before claiming renderer compatibility.

## Primary references

- [XenosRecomp source and documented renderer assumptions](https://github.com/hedge-dev/XenosRecomp/tree/990d03b28a27b50277ee5d8d942e1c5f873869d1).
- [Matching ReXGlue GPU plugin entry point](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/graphics/plugin_main.cpp).
- [Matching ReXGlue D3D12 shader pipeline](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/graphics/d3d12/pipeline_cache.cpp).
- [Matching ReXGlue guest vblank worker](https://github.com/rexglue/rexglue-sdk/blob/0c7b01a0ac0479801757507d80533f662fa0815d/src/graphics/graphics_system.cpp).
- [GameExtractor's KAPF metadata reader](https://github.com/wattostudios/GameExtractor/blob/master/src/org/watto/ge/plugin/archive/Plugin_COD_KAPF.java), used as a format reference and checked against local bytes.
- [Dissect LZO implementation](https://github.com/fox-it/dissect.util/blob/main/dissect/util/compression/lzo.py).
