# Call of Duty 3 disc extraction

The supplied image has been extracted to `<workspace>\game\cod3`. All 553 extracted files have the same byte length and MD5 as their corresponding data read directly from the XDVDFS image. The extracted content totals **6,193,138,297 bytes in 553 files and 41 directories**. A separate SHA256 is recorded for every extracted file.

| Item | Observed value |
| --- | --- |
| Source image | `<workspace>\Call of Duty 3 (USA, Europe).iso` |
| Source size | 7,834,892,288 bytes |
| Source SHA256 | `0FD477CE0A6BA1BF9784292073A43EE7CA7BA1FD04DB60F9C265BFCD5A6C1586` |
| Filesystem | XDVDFS, tool reports `Valid: true` |
| Filesystem creation timestamp | 2006-10-10 17:55:28.281 UTC (raw Windows FILETIME `128049765282810000`) |
| Root directory location | sector 1,532,670; 2,048 bytes |
| Single-player executable | `default.xex`, 7,254,016 bytes |
| Single-player SHA256 | `2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692` |
| Multiplayer executable | `codmp_xenonf.xex`, 7,122,944 bytes |
| Multiplayer SHA256 | `BD57D0DF66172ED58163FCFB8A814640DDDDA3DAC07CE2D6B79BF226B20982F6` |
| Main XEX title / media IDs | `415607E1` / `2E07093A` |
| Main XEX version / disc | `0.0.0.1`; disc 1 of 1 |

Title and media values come from the title-analysis agent's local `analysis/title-metadata.json`, which inspects the cleartext XEX2 headers. The source image's SHA256 was unchanged after extraction. These results establish extraction integrity relative to the user-supplied image, not independent validation against a publisher master or successful game execution.

| Content extension | Files |
| --- | ---: |
| `.cod` | 451 |
| `.wbk` | 30 |
| `.wma` | 20 |
| `.wmv` | 20 |
| `.dll` | 15 |
| `.cfg` | 13 |
| `.xex` | 2 |
| `.ttf` | 1 |
| No extension (system update payload) | 1 |

The 15 DLL files are stored under individual single-player level directories. The title-analysis agent has been notified to determine their executable/module semantics. Both executable names and these DLLs matter when assessing how much code must be recompiled; extracting only `default.xex` would omit assets and additional modules.

The locally installed extraction tool is [antangelo/xdvdfs v0.8.3](https://github.com/antangelo/xdvdfs/releases/tag/v0.8.3), obtained from its official Windows release. Its [upstream documentation](https://github.com/antangelo/xdvdfs/blob/main/README.md) describes the read-only `tree`, `info`, `md5`, and `copy-out` commands used here. The executable, MIT license, ZIP, source URL, commit identity, and locally calculated hashes are retained under `tools/xdvdfs/`. The release API supplied no publisher digest, so the stored download hash is a local reproducibility record.

From `<workspace>`, extraction or content verification can be repeated with:

```powershell
& '.\scripts\extract-cod3.ps1'
```

The script requires PowerShell 7 and the inspected image SHA256, checks every image path before extraction, rejects unknown or changed existing output files, preserves already verified files, and compares all extracted bytes using source-image MD5 values. The ISO is opened for reading with other readers allowed and writes/deletion denied for the duration of the operation. The script also writes per-file SHA256 values and verifies the ISO SHA256 again after its work. An interrupted extraction can be resumed if every existing file is complete and matches the image; a partial or changed file causes a refusal rather than being overwritten.

The output preflight now rejects overlapping asset/report directories, inputs placed inside output directories, drive roots, and reparse points in either the output itself or its ancestors. Report writes occur after content verification and replace complete temporary files, preserving a separate file even if an old report was hard-linked to it. Invalid Windows filename aliases, alternate data streams, and traversal components in image entries are refused before extraction. No output directories or report files are created when the input hash or existing-content preflight fails.

Eleven bounded filesystem checks passed in `scripts/extract-disc-safety-tests.ps1`, including actual junction and hard-link cases, read-lock behavior, preserved unknown/changed files, and the full script's early rejection of a tiny incorrect image. All 594 file/directory paths from the real disc tree passed the revised resolver. This review did not re-extract the game or rerun the 7.8 GB ISO hash; it rechecked the small XEX and the extractor ZIP/executable hashes. The ZIP still contains exactly `LICENSE` and `xdvdfs.exe`.

`analysis/disc-source-lock.json` is the canonical expected-input record for build tooling. It includes the expected ISO and XEX hashes, title/media IDs, and the file-manifest hash. Its ISO verification timestamp is the prior completed extraction check; downstream build tools must compare live input hashes before declaring the source currently verified.

Evidence files:

- `analysis/disc-extraction.json`: machine-readable verification summary.
- `analysis/disc-file-manifest.csv`: path, byte length, source MD5, and output SHA256 for all files.
- `analysis/disc-image-tree.txt`: complete image file and directory listing.
- `analysis/disc-image-info.txt`: volume metadata from xdvdfs.
- `analysis/disc-image-md5.txt`: hashes read from the source image; xdvdfs includes raw directory-table hashes as well as file hashes.
- `analysis/disc-copy-out.log`: tool output from the most recent successful extraction/verification run.
- `analysis/disc-source-lock.json`: canonical expected image, XEX, title/media, and manifest identities for builds.
- `analysis/disc-safety-checks.json`: results of the bounded extraction safety regression checks.
- `tools/xdvdfs/INSTALL.json`: local tool installation provenance.
