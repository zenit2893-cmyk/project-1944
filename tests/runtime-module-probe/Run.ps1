[CmdletBinding()]
param([switch]$SkipBuild, [switch]$Candidate, [string]$RuntimeDirectory = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet
$source = Join-Path $workspace 'integration\rexglue-runtime-probe'
$build = Join-Path $PSScriptRoot 'build'
$runtimeBin = if ($RuntimeDirectory) { (Resolve-Path -LiteralPath $RuntimeDirectory).Path } else { Join-Path $env:REXSDK 'bin' }
$runtimeDll = Join-Path $runtimeBin 'rexruntime.dll'
if (-not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) { throw "Runtime DLL is missing: $runtimeDll" }
$resultStem = if ($Candidate) { 'runtime-module-probe-candidate' } elseif ($RuntimeDirectory) { 'runtime-module-probe-replacement' } else { 'runtime-module-probe' }
$target = if ($Candidate) { 'runtime_xex_patch_candidate_probe' } else { 'rexglue_runtime_module_probe' }
$output = Join-Path $workspace ('analysis\' + $resultStem + '.json')
if (-not $SkipBuild) {
    & cmake -S $source -B $build -G Ninja '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_CXX_COMPILER=$env:CXX" "-DCMAKE_PREFIX_PATH=$env:REXSDK"
    if ($LASTEXITCODE -ne 0) { throw "Probe CMake configure failed: $LASTEXITCODE" }
    & cmake --build $build --target $target --parallel 2
    if ($LASTEXITCODE -ne 0) { throw "Probe build failed: $LASTEXITCODE" }
}
$probe = Join-Path $build ($target + '.exe')
if (Test-Path -LiteralPath (Join-Path $build 'rexruntime.dll')) {
    throw 'A DLL next to the probe would take priority over the requested runtime. Use a probe build directory without an application-local rexruntime.dll.'
}
$gameRoot = Join-Path $workspace 'game\cod3'
$start = [Diagnostics.ProcessStartInfo]::new($probe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.Environment['PATH'] = $runtimeBin + ';' + $env:PATH
$start.ArgumentList.Add($gameRoot)
$start.ArgumentList.Add($output)
$process = [Diagnostics.Process]::Start($start)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(20000)) {
    $process.Kill()
    throw 'The isolated probe exceeded 20 seconds.'
}
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath (Join-Path $workspace ('logs\' + $resultStem + '.stdout.log')) -Encoding utf8
$stderr | Set-Content -LiteralPath (Join-Path $workspace ('logs\' + $resultStem + '.stderr.log')) -Encoding utf8
$receipt = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    candidate_loader = [bool]$Candidate
    exit_code = $process.ExitCode
    executable_sha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
    sdk_dll_path = $runtimeDll
    sdk_dll_sha256 = (Get-FileHash -LiteralPath $runtimeDll -Algorithm SHA256).Hash
    main_xex_sha256 = (Get-FileHash -LiteralPath (Join-Path $gameRoot 'default.xex') -Algorithm SHA256).Hash
    level_xex_sha256 = (Get-FileHash -LiteralPath (Join-Path $gameRoot 'sp\saint_lo\saint_lo.dll') -Algorithm SHA256).Hash
    result_file = $output
    interpretation = if ($Candidate) { 'Exit 0 means all candidate-loader checks passed; any other code is failure. Uses locally linked candidate XexModule, not a rebuilt SDK DLL.' } else { 'Exit 2 confirms the shared-heap bookkeeping regression; exit 0 means it did not reproduce. Other codes indicate setup/test failure.' }
}
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workspace ('analysis\' + $resultStem + '-receipt.json')) -Encoding utf8
Write-Host $stdout
if ($stderr) { Write-Host $stderr }
if ($process.ExitCode -notin @(0, 2)) { throw "Probe setup/execution failed: $($process.ExitCode)" }
if ($Candidate -and $process.ExitCode -ne 0) { throw "Candidate loader tests failed: $($process.ExitCode)" }
Get-Content -LiteralPath $output
