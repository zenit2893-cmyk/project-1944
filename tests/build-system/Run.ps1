#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('RelWithDebInfo')]
    [string]$Configuration = 'RelWithDebInfo'
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$toolchainEnvironment = Join-Path $workspace 'scripts/toolchain-env.ps1'
if (-not (Test-Path -LiteralPath $toolchainEnvironment -PathType Leaf)) {
    throw "Toolchain environment script is missing: $toolchainEnvironment"
}
. $toolchainEnvironment -Quiet

$source = Join-Path $workspace 'tests/build-system'
$build = Join-Path $source ("out/" + $Configuration.ToLowerInvariant())
$cmake = (Get-Command cmake -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $build | Out-Null

$receipt = [ordered]@{
    stage = 'build-system-contract'
    configuration = $Configuration
    source = $source
    build = $build
    configure_exit_code = $null
    native_graph_build_exit_code = $null
    build_exit_code = $null
    test_exit_code = $null
    runtime_mismatch_negative_exit_code = $null
    xenia_reference_negative_exit_code = $null
    scope = 'CMake contract only; no ReXGlue runtime, Xenia executable, emulator, or game launch'
}

& $cmake -S $source -B $build -G Ninja `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DCMAKE_CXX_COMPILER=$env:CXX"
$receipt.configure_exit_code = $LASTEXITCODE
if ($receipt.configure_exit_code -ne 0) {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw "Build-system fixture configure failed: $($receipt.configure_exit_code)"
}

& $cmake --build $build --target contract_smoke --parallel 2
$receipt.build_exit_code = $LASTEXITCODE
if ($receipt.build_exit_code -ne 0) {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw "Build-system fixture build failed: $($receipt.build_exit_code)"
}

& $cmake --build $build --target cod3_pc --parallel 2
$receipt.native_graph_build_exit_code = $LASTEXITCODE
if ($receipt.native_graph_build_exit_code -ne 0) {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw "Native graph fixture build failed: $($receipt.native_graph_build_exit_code)"
}

$expectedModules = @(
    'blkbrn', 'chambois', 'credits', 'crssrds', 'falaise', 'forest',
    'fuelplnt', 'hostage', 'island', 'laison', 'mace2', 'mayenne',
    'nightd', 'saint_lo', 'stbert'
)
$runtimeArtifacts = @('rexruntimerd.dll', 'rexruntimerd.pdb', 'rexgpu-xenosrd.dll') +
    @($expectedModules | ForEach-Object { "cod3_pc_$_.dll" })
$missingArtifacts = @($runtimeArtifacts | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $build $_) -PathType Leaf)
})
if ($missingArtifacts.Count -ne 0) {
    $receipt.missing_artifacts = $missingArtifacts
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw "Native graph fixture did not stage all expected artifacts: $($missingArtifacts -join ', ')"
}

& $cmake --build $build --target test --parallel 2
$receipt.test_exit_code = $LASTEXITCODE
if ($receipt.test_exit_code -ne 0) {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw "Build-system fixture test failed: $($receipt.test_exit_code)"
}

# The contract must fail closed if a RelWithDebInfo patched DLL is paired with
# a Release configure.  This is a fresh configure directory and does not touch
# the active cod3-pc outputs.
$mismatchBuild = Join-Path $source 'out/negative-release'
& $cmake -S $source -B $mismatchBuild -G Ninja '-DCMAKE_BUILD_TYPE=Release'
$receipt.runtime_mismatch_negative_exit_code = $LASTEXITCODE
if ($receipt.runtime_mismatch_negative_exit_code -eq 0) {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw 'Runtime mismatch negative test unexpectedly configured successfully'
}

# A target named like an Xenia JIT is rejected from the native graph even when
# it is supplied as an optional extra target.
$xeniaBuild = Join-Path $source 'out/negative-xenia'
& $cmake -S $source -B $xeniaBuild -G Ninja '-DCMAKE_BUILD_TYPE=RelWithDebInfo' '-DCOD3_CONTRACT_ADD_XENIA=ON'
$receipt.xenia_reference_negative_exit_code = $LASTEXITCODE
if ($receipt.xenia_reference_negative_exit_code -eq 0) {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8
    throw 'Xenia reference negative test unexpectedly configured successfully'
}

$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $build 'results.json') -Encoding utf8

Write-Host "Build-system contract passed: $build"
