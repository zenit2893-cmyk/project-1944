#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeDirectory,
    [ValidateSet(0, 2)][int]$ExpectedExitCode = 0,
    [ValidatePattern('^[a-z0-9-]+$')][string]$OutputStem = 'patched'
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet
$probe = Join-Path $PSScriptRoot 'probe-build\runtime_heap_abi_probe.exe'
$runtime = Join-Path ([IO.Path]::GetFullPath($RuntimeDirectory)) 'rexruntimerd.dll'
if (-not (Test-Path -LiteralPath $runtime)) { throw "Runtime DLL missing: $runtime" }
if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $probe) 'rexruntimerd.dll')) {
    throw 'An app-local runtime would override the controlled PATH.'
}
$resultPath = Join-Path $PSScriptRoot "$OutputStem-regression.json"
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $probe
$start.WorkingDirectory = $workspace
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.Encoding]::UTF8
$start.StandardErrorEncoding = [Text.Encoding]::UTF8
$start.Environment['PATH'] = [IO.Path]::GetFullPath($RuntimeDirectory) + ';' + $env:PATH
$start.ArgumentList.Add((Join-Path $workspace 'game\cod3'))
$start.ArgumentList.Add($resultPath)
$began = [datetime]::UtcNow
$child = [Diagnostics.Process]::Start($start)
$stdoutTask = $child.StandardOutput.ReadToEndAsync()
$stderrTask = $child.StandardError.ReadToEndAsync()
$loadedRuntime = $null
try {
    if (-not $child.WaitForExit(20000)) { $child.Kill(); $child.WaitForExit(); throw 'Isolated regression probe timed out.' }
    $exitCode = $child.ExitCode
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $match = [regex]::Match($stdout, '(?m)^DIAGNOSTIC_LOADED_RUNTIME=(.+)\r?$')
    if ($match.Success) { $loadedRuntime = $match.Groups[1].Value.TrimEnd("`r") }
    $stdout | Set-Content -LiteralPath (Join-Path $PSScriptRoot "$OutputStem-stdout.log") -Encoding utf8
    $stderrTask.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $PSScriptRoot "$OutputStem-stderr.log") -Encoding utf8
    $receipt = [ordered]@{
        started_utc = $began.ToString('o')
        ended_utc = [datetime]::UtcNow.ToString('o')
        process_id = $child.Id
        configuration = 'RelWithDebInfo'
        executable = $probe
        executable_sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
        source = Join-Path $workspace 'integration\rexglue-runtime-probe\main.cpp'
        source_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspace 'integration\rexglue-runtime-probe\main.cpp') -Algorithm SHA256).Hash
        compiled_against = 'Original win-amd64 SDK headers and import library'
        requested_runtime = $runtime
        observed_runtime = $loadedRuntime
        runtime_path_verified = [string]::Equals($loadedRuntime, $runtime, [StringComparison]::OrdinalIgnoreCase)
        runtime_sha256 = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash
        exit_code = $exitCode
        expected_exit_code = $ExpectedExitCode
        passed = ($exitCode -eq $ExpectedExitCode)
        result_path = $resultPath
    }
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot "$OutputStem-receipt.json") -Encoding utf8
    $receipt
    if ($exitCode -ne $ExpectedExitCode) { throw "Unexpected regression exit code $exitCode; expected $ExpectedExitCode." }
}
finally { $child.Dispose() }
