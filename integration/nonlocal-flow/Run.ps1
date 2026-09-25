[CmdletBinding()]
param([switch]$Regenerate)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet
if ($Regenerate -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'generated/main/cod3_pc_pch.h'))) {
    Push-Location $PSScriptRoot
    try {
        & (Join-Path $env:REXSDK 'bin/rexglue.exe') codegen nonlocal_manifest.toml *> logs/codegen.log
        if ($LASTEXITCODE -ne 0) { throw "Isolated nonlocal codegen failed: $LASTEXITCODE" }
    } finally { Pop-Location }
}
$build = Join-Path $PSScriptRoot 'build'
& cmake -S $PSScriptRoot -B $build -G Ninja '-DCMAKE_BUILD_TYPE=RelWithDebInfo' "-DCMAKE_CXX_COMPILER=$env:CXX" "-DCMAKE_PREFIX_PATH=$env:REXSDK"
if ($LASTEXITCODE -ne 0) { throw "Nonlocal probe configure failed: $LASTEXITCODE" }
& cmake --build $build --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Nonlocal probe build failed: $LASTEXITCODE" }
$probe = Join-Path $build 'nonlocal_flow_probe.exe'
$start = [Diagnostics.ProcessStartInfo]::new($probe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($start)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(10000)) {
    $process.Kill()
    throw 'The isolated nonlocal probe exceeded 10 seconds.'
}
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'logs/native-probe.log') -Encoding utf8
$stderr | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'logs/native-probe.stderr.log') -Encoding utf8
$generatedFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'generated/main') -Filter 'cod3_pc_recomp.*.cpp')
$callSites = @(
    foreach ($file in $generatedFiles) {
        $currentFunction = ''
        $lines = [IO.File]::ReadAllLines($file.FullName)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match '^DEFINE_REX_FUNC\((\w+)\)') { $currentFunction = $Matches[1] }
            if ($lines[$i] -match '^\s*(?:temp.s64 = )?(ppc_setjmp|ppc_longjmp)\(') {
                [pscustomobject]@{operation=$Matches[1];function=$currentFunction;file=$file.Name;line=$i+1}
            }
        }
    }
)
$result = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    exit_code = $process.ExitCode
    scope = 'Native cross-DLL call/return and PPCContext restoration using the actual generated SDK header; no game entry or scene executed by this probe.'
    configuration = @{setjmp_address='0x82351CC0';longjmp_address='0x8234EEC0';module='entrypoint'}
    generated_setjmp_calls = @($callSites | Where-Object operation -eq 'ppc_setjmp').Count
    generated_longjmp_calls = @($callSites | Where-Object operation -eq 'ppc_longjmp').Count
    native_cases = @($stdout -split "`r?`n" | Where-Object { $_ -match '^\{' } | ForEach-Object { $_ | ConvertFrom-Json })
    probe_sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
    guest_frame_dll_sha256 = (Get-FileHash -LiteralPath (Join-Path $build 'nonlocal_test_guest.dll') -Algorithm SHA256).Hash
    generated_pch_sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'generated/main/cod3_pc_pch.h') -Algorithm SHA256).Hash
    call_sites = $callSites
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding utf8
Write-Host $stdout
if ($stderr) { Write-Host $stderr }
if ($process.ExitCode -ne 0) { throw "Nonlocal-flow probe failed: $($process.ExitCode)" }
