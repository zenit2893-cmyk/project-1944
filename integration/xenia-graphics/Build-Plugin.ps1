[CmdletBinding()]
param(
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string]$Configuration = 'RelWithDebInfo',
    [switch]$SkipProbe
)

$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sourceRoot = Join-Path $PSScriptRoot 'standalone'
$buildRoot = Join-Path $PSScriptRoot 'standalone-build'
$stageRoot = Join-Path $PSScriptRoot 'standalone-stage\bin'
$cmake = Join-Path $workspace 'tools\cmake\bin\cmake.exe'
$ninja = Join-Path $workspace 'tools\ninja\ninja.exe'

foreach ($required in @($cmake, $ninja,
        (Join-Path $workspace 'win-amd64\lib\cmake\rexglue\rexglueConfig.cmake'),
        (Join-Path $workspace 'win-amd64\bin\rexruntimerd.dll'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required standalone-build input is missing: $required"
    }
}

# The source checkout is read-only input. This guard prevents accidentally
# selecting a different revision than the patch provenance was built from.
$git = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe'
if (-not (Test-Path -LiteralPath $git -PathType Leaf)) {
    $git = (Get-Command git -ErrorAction Stop).Source
}
$rexHead = (& $git -C (Join-Path $workspace 'tools\rexglue-source') rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $rexHead -ne '0c7b01a0ac0479801757507d80533f662fa0815d') {
    throw "ReXGlue source is not pinned to 0c7b01a0ac0479801757507d80533f662fa0815d (found '$rexHead')"
}

. (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet

& $cmake -S $sourceRoot -B $buildRoot -G Ninja `
    "-DCMAKE_MAKE_PROGRAM=$ninja" `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DCMAKE_PREFIX_PATH=$(Join-Path $workspace 'win-amd64')" `
    '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure failed with exit code $LASTEXITCODE"
}

& $cmake --build $buildRoot --target rexgpu-xenos-patched xenia_graphics_abi_probe --parallel
if ($LASTEXITCODE -ne 0) {
    throw "Standalone plugin build failed with exit code $LASTEXITCODE"
}

New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
$pluginName = switch ($Configuration) {
    'Release' { 'rexgpu-xenos.dll' }
    'RelWithDebInfo' { 'rexgpu-xenosrd.dll' }
    'Debug' { 'rexgpu-xenosd.dll' }
}
$runtimeName = switch ($Configuration) {
    'Release' { 'rexruntime.dll' }
    'RelWithDebInfo' { 'rexruntimerd.dll' }
    'Debug' { 'rexruntimed.dll' }
}
$tracyName = switch ($Configuration) {
    'Release' { 'TracyClient.dll' }
    'RelWithDebInfo' { 'TracyClientrd.dll' }
    'Debug' { 'TracyClientd.dll' }
}
$pluginPath = Join-Path $buildRoot "bin\$pluginName"
if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
    throw "Built plugin was not found: $pluginPath"
}
Copy-Item -LiteralPath $pluginPath -Destination (Join-Path $stageRoot $pluginName) -Force
Copy-Item -LiteralPath (Join-Path $workspace "win-amd64\bin\$runtimeName") -Destination (Join-Path $stageRoot $runtimeName) -Force
$tracyPath = Join-Path $workspace "win-amd64\bin\$tracyName"
if (Test-Path -LiteralPath $tracyPath -PathType Leaf) {
    Copy-Item -LiteralPath $tracyPath -Destination (Join-Path $stageRoot $tracyName) -Force
}

if (-not $SkipProbe) {
    $probePath = Join-Path $buildRoot 'bin\xenia_graphics_abi_probe.exe'
    & $probePath (Join-Path $stageRoot $pluginName)
    if ($LASTEXITCODE -ne 0) {
        throw "Native ABI/export/load probe failed with exit code $LASTEXITCODE"
    }
}

Write-Output "Standalone plugin staged under $stageRoot"
Write-Output "  plugin: $pluginName"
Write-Output "  runtime import: $runtimeName"
Write-Output "  source: tools/rexglue-source @ $rexHead"
Write-Output "  active SDK and cod3-pc were not modified"
