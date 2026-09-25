[CmdletBinding()]
param(
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspaceRoot 'scripts/toolchain-env.ps1') -Quiet

$buildRoot = Join-Path $PSScriptRoot ('out/' + $Configuration.ToLowerInvariant())
& cmake -S $PSScriptRoot -B $buildRoot -G Ninja `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DCMAKE_CXX_COMPILER=$env:CXX"
if ($LASTEXITCODE -ne 0) { throw "Input/audio CMake configure failed: $LASTEXITCODE" }

& cmake --build $buildRoot --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Input/audio build failed: $LASTEXITCODE" }

$testOutput = & ctest --test-dir $buildRoot --output-on-failure -V 2>&1
$testExit = $LASTEXITCODE
$testText = $testOutput | Out-String
$testText | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-test-output.txt') -Encoding utf8
Write-Output $testText

$testCases = 0
if ($testText -match 'PASS: input/audio policy contract') {
    $testCases = 1
}
$executable = Join-Path $buildRoot 'input_audio_native_test.exe'
$receipt = [ordered]@{
    checked_utc = [DateTime]::UtcNow.ToString('o')
    configuration = $Configuration
    test_exit_code = $testExit
    native_contracts = $testCases
    passed = ($testExit -eq 0 -and $testCases -eq 1)
    executable_sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    adapter_source_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'integration/input-audio/src/input_audio_adapter.cpp') -Algorithm SHA256).Hash.ToLowerInvariant()
    scope = 'Host input/audio policy and conversion contracts only; no SDL/XInput device enumeration, no virtual HID, no ReXGlue/game launch, no guest timing or physics changes.'
}
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding utf8
if (-not $receipt.passed) { throw "Input/audio policy test failed (exit $testExit)" }
