#requires -Version 5.1
<#
.SYNOPSIS
    Records the port's changes to the Xenos GPU plugin source as an overlay.

.DESCRIPTION
    The plugin is built from a staged copy of the pinned ReXGlue SDK source
    (integration/vfetch-bounds/source). Anything edited only there is lost the
    moment the stage is refreshed, and is absent from a plugin rebuilt from a
    release package - which is how the foliage workaround silently went
    missing from package rebuilds.

    This script compares the stage against the pristine SDK source and copies
    every changed file into overlay/, together with the pristine SHA-256 it
    was derived from. apply_fix.py copies the overlay back onto every fresh
    stage and refuses if the pristine file no longer matches.

    Run it after editing files under source/.
#>
[CmdletBinding()]
param([string]$PristineRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = [IO.Path]::GetFullPath((Join-Path $here '..\..'))
$stage = Join-Path $here 'source'
if (-not $PristineRoot) {
    foreach ($candidate in @('integration\rexglue-runtime-build\src', 'sdk-source', 'tools\rexglue-source')) {
        $probe = Join-Path $root $candidate
        if (Test-Path -LiteralPath (Join-Path $probe 'src\graphics') -PathType Container) { $PristineRoot = $probe; break }
    }
}
if (-not $PristineRoot) { throw 'Pristine SDK source not found.' }
if (-not (Test-Path -LiteralPath $stage -PathType Container)) { throw "Stage not found: $stage" }
$PristineRoot = [IO.Path]::GetFullPath($PristineRoot)
$stage = [IO.Path]::GetFullPath($stage)

$overlay = Join-Path $here 'overlay'
$entries = New-Object System.Collections.Generic.List[object]
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $stage 'src'), (Join-Path $stage 'include') -Recurse -File) {
    $relative = $file.FullName.Substring($stage.Length + 1)
    $pristine = Join-Path $PristineRoot $relative
    $stagedHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $pristine -PathType Leaf) {
        $pristineHash = (Get-FileHash -LiteralPath $pristine -Algorithm SHA256).Hash
        if ($pristineHash -eq $stagedHash) { continue }
    } else {
        $pristineHash = $null
    }
    $target = Join-Path $overlay $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    $entries.Add([ordered]@{
        path = $relative.Replace('\', '/')
        pristine_sha256 = $pristineHash
        overlay_sha256 = $stagedHash
    })
    Write-Host ("  {0}  {1}" -f $(if ($pristineHash) { 'changed' } else { 'new    ' }), $relative)
}

$manifest = [ordered]@{
    schema_version = 1
    purpose = 'Port-specific changes to the pinned ReXGlue Xenos plugin source, applied by apply_fix.py onto every fresh stage.'
    pristine_root = $PristineRoot
    files = $entries.ToArray()
}
New-Item -ItemType Directory -Path $overlay -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $overlay 'overlay-manifest.json'), (($manifest | ConvertTo-Json -Depth 6) + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Overlay: $($entries.Count) file(s) recorded in $overlay"
