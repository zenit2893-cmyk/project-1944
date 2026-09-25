[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& (Join-Path $workspace 'integration/coroutines/Run-Tests.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Coroutine bridge regression runner failed.' }

$mapPath = Join-Path $workspace 'analysis/cod3-allmodule-coroutine-sites.json'
$map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
if ($map.module_count -ne 15 -or $map.capture_count -ne 45) {
    throw 'The verified coroutine site map does not contain 15 modules and 45 captures.'
}
$wrapperSources = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'integration/coroutines/generated') -Filter 'capture_*.cpp')
$captureHooks = 0
foreach ($source in $wrapperSources) {
    $captureHooks += @(Select-String -LiteralPath $source.FullName -Pattern 'REX_HOOK_RAW\(sub_89').Count
}
if ($wrapperSources.Count -ne 15 -or $captureHooks -ne 45) {
    throw "Expected 15 generated wrapper files and 45 capture hooks, got $($wrapperSources.Count) and $captureHooks."
}
$pchPath = Join-Path $workspace 'cod3-pc/generated/default/cod3_pc_pch.h'
$pch = Get-Content -LiteralPath $pchPath -Raw
if ($pch -notmatch 'NoteSetjmp' -or $pch -notmatch 'InterceptLongjmp') {
    throw 'Generated main PCH is missing the scheduler setjmp/longjmp bridge.'
}
$resumeSources = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'cod3-pc/generated/default') -Filter 'cod3_pc_recomp*.cpp')
$resumeHookCount = 0
foreach ($source in $resumeSources) {
    $resumeHookCount += @(Select-String -LiteralPath $source.FullName -Pattern 'Cod3CoroutineResumeRestored\(\)').Count
}
if ($resumeHookCount -ne 2) {
    throw "Expected one declaration and one post-restore resume hook, got $resumeHookCount matches."
}

$receiptPath = Join-Path $workspace 'integration/coroutines/test-results.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw "Missing coroutine bridge receipt: $receiptPath"
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ($receipt.exit_code -ne 0) { throw "Coroutine bridge probe exit code: $($receipt.exit_code)" }
if ($receipt.reference_states -ne 32) { throw 'Coroutine bridge receipt is missing 32 reference states.' }
if (-not $receipt.two_yield_cycles_per_state) { throw 'Coroutine bridge receipt is missing two yield cycles.' }
if ($receipt.root_fiber_modes.Count -ne 2) { throw 'Coroutine bridge receipt is missing both root fiber modes.' }

Write-Host 'PASS coroutine bridge receipt and isolated probe'
Write-Host 'PASS verified 15-module/45-capture map, generated PCH seam, and 824A6480 hook seam'
