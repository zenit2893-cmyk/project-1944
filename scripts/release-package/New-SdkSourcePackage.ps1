#requires -Version 7.0
<#
.SYNOPSIS
    Builds cod3-pc-sdk-sources.zip, the corresponding-source archive that
    accompanies every release carrying the ReXGlue runtime binaries.

.DESCRIPTION
    Two obligations make this archive part of the release rather than an extra:

    * rexruntimerd.dll statically links FFmpeg and libmspack, both LGPL-2.1.
      Section 6 of that license requires the recipient to be able to modify
      either library and relink the runtime. This archive therefore carries the
      complete source of both libraries as built, the ReXGlue SDK source that
      produces the runtime, and the scripts that drive the build.

    * lib/disasmrd.lib in the Full bundle is the GNU binutils PowerPC
      disassembler, GPL-2.0-or-later. Its complete corresponding source is in
      the SDK source tree that this archive carries.

    Prebuilt binaries are never copied here: the GNU binutils executables under
    the SDK's tools/binutils are excluded because their own corresponding
    source is not part of this workspace.
#>
param(
    [string]$WorkspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')),
    [string]$OutputDirectory = 'integration/release-packaging/staging',
    [string]$ArchiveDirectory = 'integration/release-packaging/artifacts',
    [switch]$SkipArchive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$script:StagingRoot = [IO.Path]::GetFullPath((Join-Path $script:Workspace (Join-Path $OutputDirectory 'sdk-source')))
$script:ArchivePath = [IO.Path]::GetFullPath((Join-Path $script:Workspace (Join-Path $ArchiveDirectory 'cod3-pc-sdk-sources.zip')))
$script:LicenseManifestPath = Join-Path $script:Workspace 'integration/release-packaging/license-manifest.json'
$script:SourceDateEpoch = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Resolve-WorkspaceInput([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $script:Workspace $Path))
}

function Assert-SafeResetTarget([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $workspace = $script:Workspace.TrimEnd('\', '/')
    if ($full -eq $workspace -or $full.Length -lt 4) { throw "Refusing to remove a broad path: $full" }
    if (-not $full.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside the workspace: $full"
    }
}

function Reset-Directory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not $Force) { throw "Output already exists: $Path. Use -Force to replace it." }
        Assert-SafeResetTarget $Path
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Normalize-FileTimestamp([string]$Path) {
    $utc = $script:SourceDateEpoch.UtcDateTime
    [IO.File]::SetCreationTimeUtc($Path, $utc)
    [IO.File]::SetLastAccessTimeUtc($Path, $utc)
    [IO.File]::SetLastWriteTimeUtc($Path, $utc)
}

# Source archives carry source. Anything that is a build product, a prebuilt
# tool, or user/game content is refused.
$script:BinaryExtensions = @('.exe', '.dll', '.lib', '.a', '.so', '.dylib', '.pdb', '.obj', '.o', '.ilk', '.exp', '.res')
$script:GameExtensions = @('.iso', '.xex', '.cod', '.wbk', '.7z', '.xsh', '.xpso', '.kwj')

function Test-SourcePath([string]$RelativePath, [string]$ComponentRoot) {
    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    foreach ($segment in ($normalized -split '/')) {
        if ($segment -in @('.git', '.vs', '__pycache__', 'node_modules')) { return $false }
    }
    # The SDK vendors prebuilt GNU binutils executables. They are GPL binaries
    # whose own corresponding source is not in this workspace, so they are not
    # redistributed in any form.
    if ($ComponentRoot -eq 'rexglue-sdk-source' -and $normalized.StartsWith('tools/binutils/')) { return $false }
    # License texts win over every extension rule. libmspack names its LGPL text
    # COPYING.LIB, which an extension filter would otherwise throw away.
    $name = [IO.Path]::GetFileName($normalized)
    if ($name -match '^(copying|license|licence|notice|authors|credits)(\.|$)') { return $true }
    $extension = [IO.Path]::GetExtension($normalized)
    if ($extension -in $script:BinaryExtensions) { return $false }
    # Upstream test corpora belong to the library source. Inside lgpl-sources
    # only true disc/game inputs are refused, not a library's own fixtures.
    if ($ComponentRoot.StartsWith('lgpl-sources')) {
        if ($extension -in @('.iso', '.xex', '.cod', '.wbk', '.7z')) { return $false }
        return $true
    }
    if ($extension -in $script:GameExtensions) { return $false }
    return $true
}

function Copy-SourceTree([string]$SourceRoot, [string]$DestinationRelative) {
    $absolute = Resolve-WorkspaceInput $SourceRoot
    if (-not (Test-Path -LiteralPath $absolute -PathType Container)) {
        throw "Corresponding-source root is missing: $SourceRoot"
    }
    $copied = 0
    $skipped = 0
    $bytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $absolute -Recurse -File -Force | Sort-Object FullName) {
        $relative = ([IO.Path]::GetRelativePath($absolute, $file.FullName)).Replace('\', '/')
        if (-not (Test-SourcePath $relative $DestinationRelative)) { $skipped++; continue }
        $destination = Join-Path $script:StagingRoot ((($DestinationRelative + '/' + $relative)) -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        Normalize-FileTimestamp $destination
        $copied++
        $bytes += $file.Length
    }
    if ($copied -eq 0) { throw "Corresponding-source root produced no files: $SourceRoot" }
    return [ordered]@{
        component = $DestinationRelative
        source = $SourceRoot
        files = $copied
        excluded_files = $skipped
        bytes = $bytes
    }
}

function Copy-SourceFile([string]$SourcePath, [string]$DestinationRelative) {
    $absolute = Resolve-WorkspaceInput $SourcePath
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Missing input: $SourcePath" }
    $destination = Join-Path $script:StagingRoot ($DestinationRelative -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $absolute -Destination $destination -Force
    Normalize-FileTimestamp $destination
}

function Write-StagedText([string]$DestinationRelative, [string]$Text) {
    $destination = Join-Path $script:StagingRoot ($DestinationRelative -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    [IO.File]::WriteAllText($destination, $Text, [Text.UTF8Encoding]::new($false))
    Normalize-FileTimestamp $destination
}

function Assert-NoForbiddenPayload {
    $forbidden = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $script:StagingRoot -Recurse -File) {
        $relative = ([IO.Path]::GetRelativePath($script:StagingRoot, $file.FullName)).Replace('\', '/').ToLowerInvariant()
        $segments = @($relative -split '/')
        $componentRoot = if ($segments.Count -gt 1) { $segments[0] } else { '' }
        $withinComponent = if ($segments.Count -gt 1) { ($segments[1..($segments.Count - 1)] -join '/') } else { $relative }
        if (-not (Test-SourcePath $withinComponent $componentRoot)) {
            $forbidden.Add($relative)
            continue
        }
        if ($relative -match '(^|/)(game|userdata)/') { $forbidden.Add($relative) }
    }
    if ($forbidden.Count -gt 0) {
        throw "Source archive contains build products or game content: $(($forbidden | Select-Object -First 10) -join ', ')"
    }
}

function Write-DeterministicZip([string]$SourceDirectory, [string]$ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ArchivePath) {
        if (-not $Force) { throw "Archive already exists: $ArchivePath. Use -Force to replace it." }
        Assert-SafeResetTarget $ArchivePath
        Remove-Item -LiteralPath $ArchivePath -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $ArchivePath) -Force | Out-Null
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Sort-Object FullName) {
                $entryName = ([IO.Path]::GetRelativePath($SourceDirectory, $file.FullName)).Replace('\', '/')
                $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $script:SourceDateEpoch
                $entryStream = $entry.Open()
                try {
                    $fileStream = [IO.File]::OpenRead($file.FullName)
                    try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose() }
                } finally { $entryStream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    return [ordered]@{
        path = ([IO.Path]::GetRelativePath($script:Workspace, $ArchivePath)).Replace('\', '/')
        bytes = (Get-Item -LiteralPath $ArchivePath).Length
        sha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    }
}

Reset-Directory $script:StagingRoot

$components = [Collections.Generic.List[object]]::new()

# The library sources the LGPL relink right applies to.
$components.Add((Copy-SourceTree 'integration/rexglue-runtime-build/src/thirdparty/FFmpeg' 'lgpl-sources/FFmpeg'))
$components.Add((Copy-SourceTree 'integration/rexglue-runtime-build/src/thirdparty/libmspack' 'lgpl-sources/libmspack'))

# The "work that uses the library": the SDK source that produces the runtime,
# which also carries thirdparty/disasm, the GPL component of the SDK.
$components.Add((Copy-SourceTree 'tools/rexglue-source' 'rexglue-sdk-source'))

# The scripts this project uses to build and verify the runtime and the patched
# GPU plugin from that source.
foreach ($name in @('CMakeLists.txt', 'README.md', 'Run-Regression.ps1', 'verify_exports.py')) {
    Copy-SourceFile "integration/rexglue-runtime-build/$name" "build-scripts/rexglue-runtime-build/$name"
}
foreach ($name in @('apply_fix.py', 'Build-GpuPlugin.ps1', 'fix-receipt.json', 'plugin-receipt.json')) {
    Copy-SourceFile "integration/vfetch-bounds/$name" "build-scripts/vfetch-bounds/$name"
}

# License texts for this archive.
$licenseManifest = Get-Content -LiteralPath $script:LicenseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$licenseRows = [Collections.Generic.List[object]]::new()
foreach ($entry in @($licenseManifest.entries | Where-Object { $_.bundles -contains 'sdk-source' })) {
    Copy-SourceFile $entry.source $entry.destination
    $licenseRows.Add([ordered]@{ id = $entry.id; destination = $entry.destination; license = $entry.license })
}
Copy-SourceFile 'integration/release-packaging/THIRD-PARTY-NOTICES.md' 'THIRD-PARTY-NOTICES.md'

Write-StagedText 'README.txt' @'
Corresponding sources for the Call of Duty 3 native port release
================================================================

This archive is part of the same release as cod3-pc-full.zip and
cod3-pc-runtime.zip. It exists so that the license obligations attached to
those binaries are actually met, not merely described.

lgpl-sources/FFmpeg, lgpl-sources/libmspack
    FFmpeg (LGPL-2.1-or-later) and libmspack (LGPL-2.1) are statically linked
    into rexruntimerd.dll. Section 6 of the LGPL gives you the right to modify
    either library and relink the runtime against your modified version. These
    are the exact trees the shipped runtime was built from. FFmpeg is
    configured with CONFIG_GPL 0, CONFIG_NONFREE 0 and CONFIG_VERSION3 0, so no
    GPL-only or version-3-only component is present.

rexglue-sdk-source
    The ReXGlue SDK source (BSD-3-Clause) that produces rexruntimerd.dll and
    rexgpu-xenosrd.dll - the "work that uses the library" - so the relink is
    possible in practice and not only in principle. It also contains
    thirdparty/disasm, the GNU binutils PowerPC disassembler that the Full
    bundle ships as lib/disasmrd.lib; that component is GPL-2.0-or-later and
    this is its complete corresponding source. The GPL-2.0 text is in
    licenses/gnu-binutils/.

    The SDK's own thirdparty submodules are empty in this tree, exactly as they
    are upstream before checkout. Their repositories are listed in
    rexglue-sdk-source/.gitmodules. The prebuilt GNU binutils executables the
    SDK keeps under tools/binutils are deliberately NOT included: they are GPL
    binaries whose corresponding source is not part of this project.

build-scripts
    The scripts this project uses to build and verify the runtime and the
    patched Xenos GPU plugin from the source above.

licenses, THIRD-PARTY-NOTICES.md
    License texts and the full component inventory for the release.

No Call of Duty 3 data, no ISO, no XEX and no generated guest code is present
in this archive or in any other archive of this release.
'@

Assert-NoForbiddenPayload

$totals = Get-ChildItem -LiteralPath $script:StagingRoot -Recurse -File | Measure-Object Length -Sum
$manifest = [ordered]@{
    schema_version = 1
    bundle = 'sdk-source'
    purpose = 'Corresponding sources for the LGPL (FFmpeg, libmspack) and GPL (GNU binutils disassembler) components of the released binaries.'
    source_date_epoch = $script:SourceDateEpoch.ToString('o')
    game_data_included = $false
    prebuilt_binaries_included = $false
    total_files = $totals.Count
    total_bytes = $totals.Sum
    components = $components.ToArray()
    license_files = $licenseRows.ToArray()
}
Write-StagedText 'SOURCE-MANIFEST.json' (($manifest | ConvertTo-Json -Depth 12) + "`n")

$archive = $null
if (-not $SkipArchive) {
    $archive = Write-DeterministicZip $script:StagingRoot $script:ArchivePath
}

[ordered]@{
    staging = ([IO.Path]::GetRelativePath($script:Workspace, $script:StagingRoot)).Replace('\', '/')
    files = $totals.Count
    bytes = $totals.Sum
    components = $components.ToArray()
    archive = $archive
} | ConvertTo-Json -Depth 12
