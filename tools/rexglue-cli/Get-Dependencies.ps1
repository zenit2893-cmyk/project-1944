#requires -Version 5.1
<#
.SYNOPSIS
    Fetches the two header-only dependencies the ReXGlue code-generation CLI
    needs and that the SDK source tree keeps as empty git submodules.

.DESCRIPTION
    rexglue.exe is not redistributed with this project because it statically
    links the GNU binutils PowerPC disassembler (GPL). Building it locally is
    the supported route, and everything it needs is already present except two
    header-only libraries:

      CLI11 (BSD-3-Clause)  - command line parser, included as <CLI/CLI.hpp>
      inja  (MIT)           - template engine, ships nlohmann/json (MIT) with it

    Both are downloaded from their own upstream repositories as source
    tarballs; nothing is redistributed by this project. License texts are
    copied next to the headers.
#>
[CmdletBinding()]
param(
    [string]$SdkSourceRoot,
    [string]$CacheDirectory,
    # Also fetch Dear ImGui (MIT), which the Xenos GPU plugin compiles directly.
    # Not needed by the code-generation CLI, so it is off by default.
    [switch]$IncludeImGui,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Here = $PSScriptRoot
$script:Root = [IO.Path]::GetFullPath((Join-Path $script:Here '..\..'))

if (-not $SdkSourceRoot) {
    foreach ($candidate in @('tools\rexglue-source', 'sdk-source')) {
        $probe = Join-Path $script:Root $candidate
        if (Test-Path -LiteralPath (Join-Path $probe 'thirdparty') -PathType Container) {
            $SdkSourceRoot = $probe
            break
        }
    }
}
if (-not $SdkSourceRoot -or -not (Test-Path -LiteralPath $SdkSourceRoot -PathType Container)) {
    throw "ReXGlue SDK source tree not found. Pass -SdkSourceRoot explicitly (expected tools\rexglue-source or sdk-source)."
}
$SdkSourceRoot = [IO.Path]::GetFullPath($SdkSourceRoot)
if (-not $CacheDirectory) { $CacheDirectory = Join-Path $script:Here 'downloads' }
New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null

$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
    throw 'tar.exe was not found in System32. Windows 10 1803 or newer is required.'
}

function Get-Tarball([string]$Name, [string]$Url) {
    $archive = Join-Path $CacheDirectory "$Name.tar.gz"
    if ((Test-Path -LiteralPath $archive -PathType Leaf) -and -not $Force) {
        Write-Host "  cached  $Name ($([math]::Round((Get-Item $archive).Length / 1MB, 1)) MB)"
        return $archive
    }
    Write-Host "  fetch   $Name <- $Url"
    Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 180 -OutFile $archive
    Write-Host "  got     $Name ($([math]::Round((Get-Item $archive).Length / 1MB, 1)) MB)"
    return $archive
}

function Expand-Tarball([string]$Archive, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    # GitHub source tarballs carry a single <repo>-<ref>/ top directory.
    & $tar -xzf $Archive -C $Destination --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw "tar failed for $Archive (exit $LASTEXITCODE)" }
}

function Copy-Tree([string]$From, [string]$To) {
    if (-not (Test-Path -LiteralPath $From -PathType Container)) { throw "Expected directory is missing: $From" }
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    Copy-Item -LiteralPath $From -Destination (Split-Path -Parent $To) -Recurse -Force
}

$results = New-Object System.Collections.Generic.List[object]

# --- CLI11 -----------------------------------------------------------------
$cli11Target = Join-Path $SdkSourceRoot 'thirdparty\cli11'
$cli11Header = Join-Path $cli11Target 'include\CLI\CLI.hpp'
if ((Test-Path -LiteralPath $cli11Header -PathType Leaf) -and -not $Force) {
    Write-Host 'CLI11: already present'
} else {
    Write-Host 'CLI11:'
    $archive = Get-Tarball 'cli11' 'https://codeload.github.com/CLIUtils/CLI11/tar.gz/refs/heads/main'
    $staging = Join-Path $CacheDirectory 'cli11-src'
    Expand-Tarball $archive $staging
    New-Item -ItemType Directory -Path $cli11Target -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $staging 'include') -Destination $cli11Target -Recurse -Force
    foreach ($file in @('LICENSE', 'README.md')) {
        $source = Join-Path $staging $file
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $cli11Target -Force }
    }
    if (-not (Test-Path -LiteralPath $cli11Header -PathType Leaf)) { throw "CLI11 headers did not land at $cli11Header" }
}
$results.Add([ordered]@{ name = 'CLI11'; license = 'BSD-3-Clause'; path = $cli11Header })

# --- inja (and nlohmann/json) ----------------------------------------------
$injaTarget = Join-Path $SdkSourceRoot 'thirdparty\inja'
$injaHeader = Join-Path $injaTarget 'single_include\inja\inja.hpp'
$jsonHeader = Join-Path $injaTarget 'third_party\include\nlohmann\json.hpp'
if ((Test-Path -LiteralPath $injaHeader -PathType Leaf) -and (Test-Path -LiteralPath $jsonHeader -PathType Leaf) -and -not $Force) {
    Write-Host 'inja: already present'
} else {
    Write-Host 'inja:'
    $archive = Get-Tarball 'inja' 'https://codeload.github.com/pantor/inja/tar.gz/refs/heads/main'
    $staging = Join-Path $CacheDirectory 'inja-src'
    Expand-Tarball $archive $staging
    New-Item -ItemType Directory -Path $injaTarget -Force | Out-Null
    foreach ($subtree in @('single_include', 'third_party')) {
        Copy-Item -LiteralPath (Join-Path $staging $subtree) -Destination $injaTarget -Recurse -Force
    }
    foreach ($file in @('LICENSE', 'README.md')) {
        $source = Join-Path $staging $file
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $injaTarget -Force }
    }
    if (-not (Test-Path -LiteralPath $injaHeader -PathType Leaf)) { throw "inja header did not land at $injaHeader" }
    if (-not (Test-Path -LiteralPath $jsonHeader -PathType Leaf)) { throw "nlohmann/json header did not land at $jsonHeader" }
}
$results.Add([ordered]@{ name = 'inja'; license = 'MIT'; path = $injaHeader })
$results.Add([ordered]@{ name = 'nlohmann/json'; license = 'MIT'; path = $jsonHeader })

# --- Dear ImGui -------------------------------------------------------------
if ($IncludeImGui) {
    $imguiTarget = Join-Path $SdkSourceRoot 'thirdparty\imgui'
    $imguiSource = Join-Path $imguiTarget 'imgui.cpp'
    if ((Test-Path -LiteralPath $imguiSource -PathType Leaf) -and -not $Force) {
        Write-Host 'Dear ImGui: already present'
    } else {
        Write-Host 'Dear ImGui:'
        # Pinned to the version the SDK build used; the plugin compiles these
        # translation units directly, so the version has to match its headers.
        $archive = Get-Tarball 'imgui' 'https://codeload.github.com/ocornut/imgui/tar.gz/refs/tags/v1.92.5'
        $staging = Join-Path $CacheDirectory 'imgui-src'
        Expand-Tarball $archive $staging
        New-Item -ItemType Directory -Path $imguiTarget -Force | Out-Null
        foreach ($file in @('imgui.cpp', 'imgui_demo.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp',
                            'imgui.h', 'imgui_internal.h', 'imstb_rectpack.h', 'imstb_textedit.h', 'imstb_truetype.h',
                            'LICENSE.txt')) {
            $source = Join-Path $staging $file
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Dear ImGui archive is missing $file" }
            Copy-Item -LiteralPath $source -Destination $imguiTarget -Force
        }
        if (-not (Test-Path -LiteralPath $imguiSource -PathType Leaf)) { throw "Dear ImGui sources did not land at $imguiTarget" }
    }
    $results.Add([ordered]@{ name = 'Dear ImGui'; license = 'MIT'; path = $imguiSource })
}

Write-Host ''
foreach ($row in $results) {
    Write-Host ("  {0,-16} {1,-14} {2}" -f $row.name, $row.license, $row.path)
}
Write-Host ''
Write-Host 'Dependencies are in place. Run Build-RexGlueCli.ps1 next.'
