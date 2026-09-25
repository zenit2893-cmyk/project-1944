[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/toolchain-env.ps1') -Quiet
& (Join-Path $PSScriptRoot 'Prepare.ps1')
$build = Join-Path $PSScriptRoot 'build'
& cmake -S $PSScriptRoot -B $build -G Ninja '-DCMAKE_BUILD_TYPE=RelWithDebInfo' '-DCOD3_COROUTINE_TESTS=ON' "-DCMAKE_CXX_COMPILER=$env:CXX" "-DCMAKE_PREFIX_PATH=$env:REXSDK"
if ($LASTEXITCODE -ne 0) { throw 'Coroutine test configure failed.' }
& cmake --build $build --target coroutine_probe coroutine_adapter_syntax --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'Coroutine test build failed.' }
$probe = Join-Path $build 'coroutine_probe.exe'
$start = [Diagnostics.ProcessStartInfo]::new($probe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($start)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(20000)) {
    $process.Kill()
    throw 'Isolated coroutine test exceeded 20 seconds.'
}
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath (Join-Path $build 'result.log') -Encoding utf8
$stderr | Set-Content -LiteralPath (Join-Path $build 'stderr.log') -Encoding utf8
[ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    exit_code = $process.ExitCode
    compile_flags = @('-ffp-model=strict','-fno-strict-aliasing','-fwrapv')
    configuration = 'RelWithDebInfo, Win64 MSVC ABI'
    reference_states = 32
    two_yield_cycles_per_state = $true
    root_fiber_modes = @('bridge-owned rex::thread::Fiber conversion','borrowed XThread::main_fiber rex::thread::Fiber')
    scope = 'Native continuation and adapter compilation tests with synthetic guest bodies and independent original-opcode state fixtures. No game entry executed by the test.'
    probe_sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
    core_dll_sha256 = (Get-FileHash -LiteralPath (Join-Path $build 'cod3_coroutines.dll') -Algorithm SHA256).Hash
    fixture_dll_sha256 = (Get-FileHash -LiteralPath (Join-Path $build 'coroutine_fixture.dll') -Algorithm SHA256).Hash
    independent_fixture_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspace 'tests/coroutine-reference/generated/vectors.hpp') -Algorithm SHA256).Hash
    core_source_sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'cod3_coroutines.cpp') -Algorithm SHA256).Hash
    output = $stdout.Trim()
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'test-results.json') -Encoding utf8
Write-Host $stdout
if ($stderr) { Write-Host $stderr }
if ($process.ExitCode -ne 0) { throw "Coroutine tests failed: $($process.ExitCode)" }
