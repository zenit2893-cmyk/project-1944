[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/toolchain-env.ps1') -Quiet

$build = Join-Path $PSScriptRoot 'build'
& cmake -S $PSScriptRoot -B $build -G Ninja `
  '-DCMAKE_BUILD_TYPE=RelWithDebInfo' `
  "-DCMAKE_CXX_COMPILER=$env:CXX" `
  "-DCMAKE_PREFIX_PATH=$env:REXSDK"
if ($LASTEXITCODE -ne 0) { throw "Thread contract configure failed: $LASTEXITCODE" }

& cmake --build $build --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Thread contract build failed: $LASTEXITCODE" }

$testText = (& ctest --test-dir $build --output-on-failure 2>&1 | Out-String)
$testExit = $LASTEXITCODE
$testText | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-test-output.txt') -Encoding utf8
Write-Output $testText

$probe = Join-Path $build 'cod3_xenia_threads_contract.exe'
$receipt = [ordered]@{
  schema = 'cod3-xenia-threads-receipt-v1'
  generated_utc = [DateTime]::UtcNow.ToString('o')
  test_exit_code = $testExit
  passed = ($testExit -eq 0)
  configuration = 'RelWithDebInfo, Windows x64, MSVC ABI'
  compiler = (& clang++ --version | Select-Object -First 1)
  probe_sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
  sdk_runtime_sha256 = (Get-FileHash -LiteralPath (Join-Path $env:REXSDK 'bin/rexruntime.dll') -Algorithm SHA256).Hash
  xenia_source_commit = (& git -C (Join-Path $workspace 'tools/Xenia-source') rev-parse HEAD).Trim()
  rexglue_source_commit = (& git -C (Join-Path $workspace 'tools/rexglue-source') rev-parse HEAD).Trim()
  scope = 'Headless native ReXGlue threading, event, semaphore, timer, APC and fiber contract checks. No game entry, GUI, emulator, CPU JIT, SDK rebuild, simulation clock or physics path.'
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content `
  -LiteralPath (Join-Path $PSScriptRoot 'test-results.json') -Encoding utf8

if ($testExit -ne 0) { throw 'Thread contract probe failed; inspect last-test-output.txt.' }
