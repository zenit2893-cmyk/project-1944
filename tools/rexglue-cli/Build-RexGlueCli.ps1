#requires -Version 5.1
<#
.SYNOPSIS
    Builds rexglue.exe, the ReXGlue code-generation CLI, from the SDK source.

.DESCRIPTION
    The project's packages ship the ReXGlue SDK without this executable: it
    statically links the GNU binutils PowerPC disassembler, which is GPL, so
    redistributing the binary would require the corresponding source of
    everything linked into it. Building it here, on the machine that will use
    it, sidesteps that entirely - the GPL restricts distribution, not use.

    Everything else the build needs is already present: the SDK's import
    libraries and headers under win-amd64, the SDK source, and the local
    toolchain. Get-Dependencies.ps1 fetches the two header-only libraries the
    SDK keeps as empty submodules.

.PARAMETER NoStage
    Leave the result in the build directory instead of copying it into
    win-amd64\bin\rexglue.exe. Staging is the default.
#>
[CmdletBinding()]
param(
    [string]$SdkSourceRoot,
    [string]$SdkPackageRoot,
    [string]$Configuration = 'RelWithDebInfo',
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$NoStage,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = [IO.Path]::GetFullPath((Join-Path $here '..\..'))

function Resolve-First([string[]]$Candidates, [string]$Marker) {
    foreach ($candidate in $Candidates) {
        $full = Join-Path $root $candidate
        if (Test-Path -LiteralPath (Join-Path $full $Marker)) { return [IO.Path]::GetFullPath($full) }
    }
    return $null
}

if (-not $SdkSourceRoot) { $SdkSourceRoot = Resolve-First @('tools\rexglue-source', 'sdk-source') 'src\codegen\codegen.cpp' }
if (-not $SdkSourceRoot) { throw 'ReXGlue SDK source tree not found (looked for tools\rexglue-source and sdk-source). Pass -SdkSourceRoot.' }
if (-not $SdkPackageRoot) { $SdkPackageRoot = Resolve-First @('win-amd64') 'lib\cmake\rexglue\rexglueConfig.cmake' }
if (-not $SdkPackageRoot) { throw 'Installed ReXGlue SDK not found at win-amd64. Pass -SdkPackageRoot.' }

Write-Host "SDK source : $SdkSourceRoot"
Write-Host "SDK package: $SdkPackageRoot"

# The toolchain script dot-sources into the current process: Clang, CMake,
# Ninja, the MSVC environment and CMAKE_PREFIX_PATH for the SDK.
$toolchainScript = Join-Path $root 'scripts\toolchain-env.ps1'
if (-not (Test-Path -LiteralPath $toolchainScript -PathType Leaf)) {
    throw "Toolchain script is missing: $toolchainScript"
}
. $toolchainScript -Quiet

# A PowerShell script, so it reports failure by throwing; $LASTEXITCODE stays
# untouched and must not be consulted here.
& (Join-Path $here 'Get-Dependencies.ps1') -SdkSourceRoot $SdkSourceRoot

$buildDir = Join-Path $here "build\$Configuration"
if ($Clean -and (Test-Path -LiteralPath $buildDir)) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

$cmake = Join-Path $root 'tools\cmake\bin\cmake.exe'
if (-not (Test-Path -LiteralPath $cmake -PathType Leaf)) { $cmake = 'cmake' }

Write-Host ''
Write-Host '=== Configure ==='
& $cmake -S $here -B $buildDir -G Ninja `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DREXGLUE_SOURCE_ROOT=$($SdkSourceRoot -replace '\\','/')" `
    "-DCMAKE_PREFIX_PATH=$($SdkPackageRoot -replace '\\','/')" `
    "-DCMAKE_C_COMPILER=clang-cl" `
    "-DCMAKE_CXX_COMPILER=clang-cl"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed (exit $LASTEXITCODE)." }

Write-Host ''
Write-Host '=== Build ==='
& $cmake --build $buildDir --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)." }

$produced = Join-Path $buildDir 'rexglue.exe'
if (-not (Test-Path -LiteralPath $produced -PathType Leaf)) { throw "Build reported success but $produced is missing." }
$hash = (Get-FileHash -LiteralPath $produced -Algorithm SHA256).Hash

Write-Host ''
Write-Host "Built: $produced"
Write-Host ("Size : {0:N1} MB" -f ((Get-Item -LiteralPath $produced).Length / 1MB))
Write-Host "SHA256: $hash"

if (-not $NoStage) {
    $destination = Join-Path $SdkPackageRoot 'bin\rexglue.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $produced -Destination $destination -Force
    Write-Host "Staged: $destination"
}

$receipt = [ordered]@{
    schema_version = 1
    tool = 'rexglue'
    reason = 'Built locally because the binary links GPL-licensed GNU binutils code and is therefore not redistributed with this project.'
    configuration = $Configuration
    sdk_source_root = $SdkSourceRoot
    sdk_package_root = $SdkPackageRoot
    output = $produced
    staged = (-not $NoStage)
    sha256 = $hash
    bytes = (Get-Item -LiteralPath $produced).Length
}
$receiptPath = Join-Path $here 'build-receipt.json'
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Receipt: $receiptPath"
