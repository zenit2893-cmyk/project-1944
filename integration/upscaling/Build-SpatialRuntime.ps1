#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateRange(1, 16)][int]$Jobs = 4,
    [switch]$RefreshStage
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sourceWorktree = Join-Path $workspace 'integration\rexglue-runtime-build\src'
$stageRoot = Join-Path $PSScriptRoot 'runtime-source'
$runtimeProject = Join-Path $PSScriptRoot 'runtime'
$buildRoot = Join-Path $PSScriptRoot 'runtime-build'
$overlayRoot = Join-Path $PSScriptRoot 'overlay'
$manifestPath = Join-Path $PSScriptRoot 'overlay-manifest.json'
$probe = Join-Path $workspace 'integration\rexglue-runtime-build\probe-build\runtime_heap_abi_probe.exe'
$gameRoot = Join-Path $workspace 'game\cod3'

if (-not (Test-Path -LiteralPath $sourceWorktree -PathType Container)) {
    throw "Patched ReXGlue source worktree is missing: $sourceWorktree"
}
if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
    throw "Existing public-ABI load probe is missing: $probe"
}
if (-not (Test-Path -LiteralPath $gameRoot -PathType Container)) {
    throw "Extracted game root is missing: $gameRoot"
}

. (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet

$rexHead = (& git -C $sourceWorktree rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $rexHead -ne '0c7b01a0ac0479801757507d80533f662fa0815d') {
    throw "Unexpected patched ReXGlue source revision: $rexHead"
}

# Stage from the already patched heap worktree. This keeps the spatial build
# separate from both the source SDK and the installed patched runtime. The
# root .git worktree pointer is intentionally excluded; CMake needs only the
# source and populated submodule files.
function Copy-TreeWithoutGit {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force |
        Where-Object { $_.Name -ne '.git' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Destination $_.Name) `
                -Recurse -Force
        }
}

if ($RefreshStage -and (Test-Path -LiteralPath $stageRoot)) {
    $resolvedStage = [IO.Path]::GetFullPath($stageRoot)
    $resolvedParent = [IO.Path]::GetFullPath($PSScriptRoot)
    if (-not $resolvedStage.StartsWith($resolvedParent + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to refresh a stage outside integration/upscaling: $resolvedStage"
    }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) {
    Copy-TreeWithoutGit -Source $sourceWorktree -Destination $stageRoot
}

# Recreate only the generated presenter overlay and preserve the exact source
# hash manifest before staging it into the isolated runtime tree.
$python = Join-Path $workspace 'tools\toolchain\bootstrap-python\Scripts\python.exe'
& $python (Join-Path $PSScriptRoot 'prepare_overlay.py')
if ($LASTEXITCODE -ne 0) { throw 'Spatial overlay preparation failed.' }

Get-ChildItem -LiteralPath $overlayRoot -File -Recurse | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($overlayRoot, $_.FullName)
    $destination = Join-Path $stageRoot $relative
    $destinationParent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
}

$compiler = $env:CXX
$cCompiler = $env:CC
& cmake -S $runtimeProject -B $buildRoot -G Ninja `
    -DCMAKE_BUILD_TYPE=RelWithDebInfo `
    "-DCMAKE_C_COMPILER=$cCompiler" "-DCMAKE_CXX_COMPILER=$compiler"
if ($LASTEXITCODE -ne 0) { throw 'Spatial runtime configure failed.' }
& cmake --build $buildRoot --target rexruntime --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw 'Spatial runtime build failed.' }

$runtimeDll = Join-Path $buildRoot 'bin\rexruntimerd.dll'
if (-not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) {
    throw "Spatial runtime output is missing: $runtimeDll"
}

$probeResultPath = Join-Path $buildRoot 'spatial-probe-result.json'
$probeStdoutPath = Join-Path $buildRoot 'spatial-probe-stdout.log'
$probeStderrPath = Join-Path $buildRoot 'spatial-probe-stderr.log'
$runtimeBin = Split-Path -Parent $runtimeDll
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $probe
$start.WorkingDirectory = $workspace
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.Encoding]::UTF8
$start.StandardErrorEncoding = [Text.Encoding]::UTF8
$start.Environment['PATH'] = $runtimeBin + ';' + $env:PATH
$start.ArgumentList.Add($gameRoot)
$start.ArgumentList.Add($probeResultPath)
$child = [Diagnostics.Process]::Start($start)
try {
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(30000)) {
        $child.Kill()
        $child.WaitForExit()
        throw 'Spatial runtime load probe timed out.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $stdout | Set-Content -LiteralPath $probeStdoutPath -Encoding utf8
    $stderr | Set-Content -LiteralPath $probeStderrPath -Encoding utf8
    $loaded = $null
    $match = [regex]::Match($stdout, '(?m)^DIAGNOSTIC_LOADED_RUNTIME=(.+)\r?$')
    if ($match.Success) { $loaded = $match.Groups[1].Value.TrimEnd("`r") }
    $exitCode = $child.ExitCode
}
finally {
    $child.Dispose()
}

$result = $null
if (Test-Path -LiteralPath $probeResultPath -PathType Leaf) {
    $result = Get-Content -LiteralPath $probeResultPath -Raw | ConvertFrom-Json
}
$expectedLoaded = [IO.Path]::GetFullPath($runtimeDll)
$receipt = [ordered]@{
    schema_version = 1
    status = if ($exitCode -eq 0 -and [string]::Equals($loaded, $expectedLoaded,
            [StringComparison]::OrdinalIgnoreCase) -and $result -and
            -not [bool]$result.regression_reproduced) { 'PASS' } else { 'FAIL' }
    recorded_utc = [datetime]::UtcNow.ToString('o')
    reXglue_source_commit = $rexHead
    source_worktree = $sourceWorktree
    stage_root = $stageRoot
    spatial_overlay_manifest = $manifestPath
    spatial_overlay_manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    configuration = 'RelWithDebInfo'
    compiler = 'Clang 22.1.8 with MSVC ABI'
    spatial_compile_define = 'REX_HAS_FIDELITYFX_SPATIAL=1'
    temporal_runtime = $false
    guest_clock_modified = $false
    guest_video_mode_modified = $false
    runtime_dll = $runtimeDll
    runtime_dll_sha256 = (Get-FileHash -LiteralPath $runtimeDll -Algorithm SHA256).Hash
    probe = $probe
    probe_sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
    requested_runtime = $expectedLoaded
    observed_runtime = $loaded
    runtime_path_verified = [string]::Equals($loaded, $expectedLoaded,
        [StringComparison]::OrdinalIgnoreCase)
    probe_exit_code = $exitCode
    probe_result = $result
    probe_result_path = $probeResultPath
    no_game_entry_executed = if ($result) { -not [bool]$result.guest_entry_executed } else { $false }
}
$receiptPath = Join-Path $PSScriptRoot 'spatial-runtime-receipt.json'
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
$receipt | ConvertTo-Json -Depth 8
if ($receipt.status -ne 'PASS') { throw 'Spatial runtime load probe failed.' }
