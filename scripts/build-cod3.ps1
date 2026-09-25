#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('cod3-pc', 'cod3')]
    [string]$ProjectDirectory = 'cod3-pc',
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string]$Configuration = 'RelWithDebInfo',
    [ValidateRange(1, 16)]
    [int]$Jobs = 4,
    [switch]$SaintLoDiagnostics,
    [string]$RuntimeDll = '',
    # Replacement Xenos GPU plugin, built by integration/vfetch-bounds.
    [string]$GpuPlugin = ''
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace $ProjectDirectory
$targetName = if ($ProjectDirectory -eq 'cod3-pc') { 'cod3_pc' } else { 'cod3' }
$xex = Join-Path $workspace 'game/cod3/default.xex'
$environmentScript = Join-Path $PSScriptRoot 'toolchain-env.ps1'
foreach ($required in @($environmentScript, $xex, (Join-Path $project 'generated/default/sources.cmake'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required build input is missing: $required" }
}
$sourceLockPath = Join-Path $workspace 'analysis/disc-source-lock.json'
if (-not (Test-Path -LiteralPath $sourceLockPath)) { throw 'The verified source lock is missing. Complete disc extraction first.' }
$sourceLock = Get-Content -LiteralPath $sourceLockPath -Raw | ConvertFrom-Json
$inputHash = (Get-FileHash -LiteralPath $xex -Algorithm SHA256).Hash
if ($sourceLock.expected_default_xex.sha256 -ne $inputHash) {
    throw 'The XEX differs from the verified CoD3 revision. Its function boundaries and Xenon hooks must be reviewed before building.'
}
. $environmentScript
$cmake = (Get-Command cmake -ErrorAction Stop).Source
$preset = 'win-amd64-' + $Configuration.ToLowerInvariant()
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$logPath = Join-Path $workspace "logs/$ProjectDirectory-build-$stamp.log"
$receiptPath = Join-Path $workspace "analysis/$ProjectDirectory-native-build-receipt.json"
$executable = Join-Path $project "out/build/$preset/$targetName.exe"
$sdkPrefix = (Join-Path $workspace 'win-amd64').Replace('\', '/')
$receipt = [ordered]@{
    stage = 'native-build'
    started_utc = [DateTime]::UtcNow.ToString('o')
    finished_utc = $null
    exit_code = $null
    configuration = $Configuration
    jobs = $Jobs
    saintlo_diagnostics = [bool]$SaintLoDiagnostics
    runtime_override = $RuntimeDll
    input_sha256 = $inputHash
    manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $project ($targetName + '_manifest.toml')) -Algorithm SHA256).Hash
    executable = $executable
    executable_sha256 = $null
    runtime_artifacts = @()
    log_path = $logPath
    error = $null
}

Push-Location -LiteralPath $project
try {
    $configureArgs = @('--preset', $preset, "-DCMAKE_PREFIX_PATH=$sdkPrefix", '-DREXSDK_VERSION=0.10.0.5')
    if ($ProjectDirectory -eq 'cod3-pc') {
        $diagnosticsValue = if ($SaintLoDiagnostics) { 'ON' } else { 'OFF' }
        $configureArgs += "-DCOD3_SAINTLO_DIAGNOSTICS=$diagnosticsValue"
        if ($RuntimeDll) { $RuntimeDll = (Resolve-Path -LiteralPath $RuntimeDll).Path.Replace('\', '/') }
        $configureArgs += "-DCOD3_RUNTIME_DLL=$RuntimeDll"
        if ($GpuPlugin) { $GpuPlugin = (Resolve-Path -LiteralPath $GpuPlugin).Path.Replace('\', '/') }
        $configureArgs += "-DCOD3_GPU_PLUGIN=$GpuPlugin"
    }
    & $cmake @configureArgs 2>&1 | Tee-Object -FilePath $logPath
    $configureExit = $LASTEXITCODE
    if ($configureExit -ne 0) { throw "CMake configure failed with exit code $configureExit. See $logPath" }
    & $cmake --build --preset $preset --parallel $Jobs 2>&1 | Tee-Object -FilePath $logPath -Append
    $receipt.exit_code = $LASTEXITCODE
    if ($receipt.exit_code -ne 0) { throw "Native build failed with exit code $($receipt.exit_code). See $logPath" }
    if (-not (Test-Path -LiteralPath $executable)) { throw "Build did not produce expected executable: $executable" }
    $receipt.executable_sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    $receipt.runtime_artifacts = @(Get-ChildItem -LiteralPath (Split-Path -Parent $executable) -File -Filter '*.dll' | ForEach-Object {
        [ordered]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    Write-Host "Native executable: $executable"
    Write-Host 'Compilation is complete. Boot, gameplay and 120 FPS physics still require runtime verification.'
}
catch {
    if ($null -eq $receipt.exit_code -or $receipt.exit_code -eq 0) { $receipt.exit_code = 1 }
    $receipt.error = $_.Exception.Message
    throw
}
finally {
    Pop-Location
    $receipt.finished_utc = [DateTime]::UtcNow.ToString('o')
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8
}
