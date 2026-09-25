#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1, 8)]
    [int]$Workers = 4,
    [ValidateRange(5, 120)]
    [int]$Timeout = 30,
    [switch]$RebuildXenos
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$python = Join-Path $workspaceRoot 'tools/toolchain/bootstrap-python/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    $python = (Get-Command python -CommandType Application -ErrorAction Stop).Source
}
$artifactDirectory = Join-Path $PSScriptRoot 'artifacts'
$batchReport = Join-Path $workspaceRoot 'docs/reports/xenos-gradients-v2-batch.json'
$testResult = Join-Path $PSScriptRoot 'test-result.json'
$finalReport = Join-Path $workspaceRoot 'docs/reports/xenos-gradients-v2.json'

if ($RebuildXenos) {
    & (Join-Path $workspaceRoot 'scripts/xenos-build.ps1') -Jobs $Workers
    if ($LASTEXITCODE -ne 0) { throw "XenosRecomp rebuild failed with exit code $LASTEXITCODE." }
}

$xenos = Join-Path $workspaceRoot 'tools/XenosRecomp/build/XenosRecomp/XenosRecomp.exe'
if (-not (Test-Path -LiteralPath $xenos -PathType Leaf)) {
    throw "Missing XenosRecomp executable: $xenos"
}

& $python (Join-Path $workspaceRoot 'scripts/xenos-batch.py') `
    --manifest (Join-Path $workspaceRoot 'analysis/graphics-prepared/manifest.json') `
    --output $artifactDirectory `
    --report $batchReport `
    --semantic-audit (Join-Path $workspaceRoot 'analysis/graphics-texture-feature-inventory.json') `
    --workers $Workers `
    --timeout $Timeout
if ($LASTEXITCODE -ne 0) { throw "610-entry XenosRecomp batch failed with exit code $LASTEXITCODE." }

& $python (Join-Path $PSScriptRoot '../../tests/xenos-gradients-v2/gradient_semantics.py') `
    $artifactDirectory $batchReport $testResult
if ($LASTEXITCODE -ne 0) { throw "Xenos gradient contract tests failed with exit code $LASTEXITCODE." }

$result = Get-Content -LiteralPath $testResult -Raw | ConvertFrom-Json
if (-not $result.passed) { throw "Xenos gradient contract tests reported failure." }
$batchResult = Get-Content -LiteralPath $batchReport -Raw | ConvertFrom-Json

$report = [ordered]@{
    schema_version = 1
    generated_utc = [DateTime]::UtcNow.ToString('o')
    xenia_source_commit = '0e1307bd2e6bfeeff29635a6b823e72e61c97ce9'
    game_launch_performed = $false
    emulator_launch_performed = $false
    batch_report = [IO.Path]::GetFullPath($batchReport)
    test_result = [IO.Path]::GetFullPath($testResult)
    artifacts = [IO.Path]::GetFullPath($artifactDirectory)
    compiler_acceptance = $result.generated_artifacts.batch_summary
    xenos_executable_sha256 = $batchResult.xenos_executable_sha256
    dxc_executable_sha256 = $batchResult.dxc_executable_sha256
    source_contract = $result.source_contract
    gradient_contract = $result.generated_artifacts.counts
    numerical_oracle = $result.numerical_oracle
    input_containers_unchanged = $result.generated_artifacts.source_containers_unchanged
    known_semantic_blockers = $result.generated_artifacts.known_semantic_blockers
    runtime_integration_verified = $false
    rendering_correctness_verified = $false
    status = 'compiler and translation contract passed; runtime binding and rendering remain unverified'
}
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $finalReport -Encoding utf8
Write-Output "Batch report: $batchReport"
Write-Output "Gradient contract report: $finalReport"
