[CmdletBinding()]
param([switch]$RequireBaselineParity, [switch]$SkipInventory)
$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspaceRoot 'scripts\toolchain-env.ps1') -Quiet
$pythonPath = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) { throw "Python runtime not found: $pythonPath" }
$extractArgs = @((Join-Path $PSScriptRoot 'extract_blocks.py'))
if (-not $SkipInventory) { $extractArgs += '--inventory' }
& $pythonPath @extractArgs
if ($LASTEXITCODE -ne 0) { throw 'Generated instruction extraction failed.' }
$binary = Join-Path $PSScriptRoot 'native_math_test.exe'
$compileFlags = @('-std=c++23', '-O2', '-ffp-model=strict', '-ffp-contract=off',
    '-fno-strict-aliasing', '-fwrapv', '-mavx2', '-mfma', '-Wno-ignored-attributes')
& $env:CXX @compileFlags '-I' (Join-Path $workspaceRoot 'win-amd64\include') `
    (Join-Path $PSScriptRoot 'native_math_test.cpp') '-o' $binary
if ($LASTEXITCODE -ne 0) { throw 'Native math comparison compilation failed.' }
$testArgs = @()
if ($RequireBaselineParity) { $testArgs += '--require-baseline-parity' }
$lines = & $binary @testArgs
$testExitCode = $LASTEXITCODE
$records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
$report = [ordered]@{
    checked_at_utc = [DateTime]::UtcNow.ToString('o')
    compiler = (& $env:CXX '--version' | Select-Object -First 1)
    compile_flags = $compileFlags
    cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    target = 'native Windows x64 AVX2/FMA instruction-comparison harness'
    xenia_commit = '0e1307bd2e6bfeeff29635a6b823e72e61c97ce9'
    rexglue_commit = '0c7b01a0ac0479801757507d80533f662fa0815d'
    sdk_context_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'win-amd64\include\rex\ppc\context.h')).Hash
    binary_sha256 = (Get-FileHash -LiteralPath $binary).Hash
    generated_blocks = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'actual_blocks.json') -Raw | ConvertFrom-Json)
    results = $records
    exit_code = $testExitCode
    integrated_into_game = $false
    game_executed = $false
    fps_or_physics_validation = $false
}
$reportPath = Join-Path $workspaceRoot 'docs\reports\ppc-math-validation.json'
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
$records | Where-Object { $_.summary -or $_.baseline_differs } | ConvertTo-Json -Depth 5
Write-Host "Native comparison report: $reportPath"
if ($testExitCode -ne 0) { throw "Native math test exit code $testExitCode (see report)." }
