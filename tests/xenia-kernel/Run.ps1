[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/toolchain-env.ps1') -Quiet
$build = Join-Path $PSScriptRoot 'out'
& cmake -S $PSScriptRoot -B $build -G Ninja '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_CXX_COMPILER=$env:CXX" "-DCMAKE_PREFIX_PATH=$env:REXSDK"
if ($LASTEXITCODE -ne 0) { throw "Kernel test configure failed: $LASTEXITCODE" }
& cmake --build $build --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Kernel test build failed: $LASTEXITCODE" }
# The runtime-export test is intentionally run by Run-CombinedCandidate.ps1
# after staging the heap-fixed candidate DLL next to the probe. Keep this
# baseline command scoped to the isolated adapter contract.
$testText = (& ctest --test-dir $build -R '^message_box_ex_native_contract$' -V --output-on-failure 2>&1 | Out-String)
$testExit = $LASTEXITCODE
$testText | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-test-output.txt') -Encoding utf8
Write-Output $testText
$passedCount = 0
$totalCount = 0
if ($testText -match 'RESULT (\d+)/(\d+) passed') {
  $passedCount = [int]$Matches[1]
  $totalCount = [int]$Matches[2]
}
$receipt = [ordered]@{
  generated_utc = [DateTime]::UtcNow.ToString('o')
  test_exit_code = $testExit
  passed_checks = $passedCount
  total_checks = $totalCount
  passed = ($testExit -eq 0 -and $totalCount -eq 15 -and $passedCount -eq $totalCount)
  candidate_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspace 'integration/xenia-kernel/candidate/src/kernel/xam/xam_ui.cpp')).Hash
  compiled_adapter_sha256 = (Get-FileHash -LiteralPath (Join-Path $build 'candidate_adapter.inl')).Hash
  executable_sha256 = (Get-FileHash -LiteralPath (Join-Path $build 'xenia_kernel_probe.exe')).Hash
  sdk_dll_sha256 = (Get-FileHash -LiteralPath (Join-Path $env:REXSDK 'bin/rexruntime.dll')).Hash
  main_xex_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspace 'game/cod3/default.xex')).Hash
  compiler = (& clang++ --version | Select-Object -First 1)
  scope = 'Candidate typed adapter and real SDK headless/deferred event contract; complete candidate translation unit compiled separately. No game entry, GUI, CPU JIT, physics, FPS or active SDK changes.'
}
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding utf8
if (-not $receipt.passed) { throw 'Kernel contract probe failed; inspect results and output.' }
