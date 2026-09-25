#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('cod3-pc', 'cod3')]
    [string]$ProjectDirectory = 'cod3-pc',
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string]$Configuration = 'RelWithDebInfo',
    [ValidateRange(0, 300)]
    [int]$SmokeSeconds = 0,
    [ValidateSet('KeyboardMouse', 'Gamepad')]
    [string]$InputMode = 'KeyboardMouse',
    [ValidateSet('1440p', '1080p', '720p', 'NativeDisplay')]
    [string]$OutputSize = '1080p',
    # Internal render-target scale (EDRAM draws and resolves). The guest front
    # buffer is 1280x720, so 2 renders it at exactly 2560x1440.
    [ValidateRange(1, 3)]
    [int]$RenderScale = 1,
    # Guest video-mode refresh rate reported to the game and used for its vblank.
    [ValidateSet(60, 120)]
    [int]$RefreshRate = 60,
    # Workaround for the stretched-foliage artifact: replaces the foliage
    # control-map sample in vertex shaders with a constant, so grass blades
    # collapse instead of stretching into streaks. Removes the grass geometry;
    # ground textures are unaffected. Needs the patched plugin from
    # integration/vfetch-bounds.
    [switch]$NoFoliage,
    [switch]$DumpShaders,
    [switch]$TimingTrace,
    [ValidateSet('info', 'debug', 'trace')]
    [string]$LogLevel = 'info'
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$preset = 'win-amd64-' + $Configuration.ToLowerInvariant()
$targetName = if ($ProjectDirectory -eq 'cod3-pc') { 'cod3_pc' } else { 'cod3' }
$executable = Join-Path $workspace "$ProjectDirectory/out/build/$preset/$targetName.exe"
$xex = Join-Path $workspace 'game/cod3/default.xex'
$buildReceiptPath = Join-Path $workspace "analysis/$ProjectDirectory-native-build-receipt.json"
foreach ($required in @($executable, $xex, $buildReceiptPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required runtime input is missing: $required" }
}
$buildReceipt = Get-Content -LiteralPath $buildReceiptPath -Raw | ConvertFrom-Json
$exeHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
$xexHash = (Get-FileHash -LiteralPath $xex -Algorithm SHA256).Hash
if ($buildReceipt.exit_code -ne 0 -or $buildReceipt.executable_sha256 -ne $exeHash -or $buildReceipt.input_sha256 -ne $xexHash) {
    throw 'The executable and game input must match a successful build receipt. Run scripts/build-cod3.ps1 first.'
}
foreach ($artifact in @($buildReceipt.runtime_artifacts)) {
    if ($null -eq $artifact) { continue }
    $artifactPath = Join-Path (Split-Path -Parent $executable) $artifact.name
    if (-not (Test-Path -LiteralPath $artifactPath) -or (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -ne $artifact.sha256) {
        throw "Runtime DLL differs from the successful build receipt: $artifactPath"
    }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$logRelative = "logs/$ProjectDirectory-run-$stamp.log"
$receiptPath = Join-Path $workspace "analysis/$ProjectDirectory-runtime-probe-$stamp.json"
foreach ($dir in @("$ProjectDirectory/userdata", "$ProjectDirectory/cache", 'logs')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $workspace $dir) | Out-Null
}
$launchArgs = @(
    '--gpu_plugin=xenos',
    '--game_data_root=game/cod3', "--user_data_root=$ProjectDirectory/userdata", "--cache_root=$ProjectDirectory/cache",
    "--log_file=$logRelative", "--log_level=$LogLevel"
)
switch ($OutputSize) {
    '1440p' { $launchArgs += @('--window_width=2560', '--window_height=1440', '--fullscreen=false') }
    '1080p' { $launchArgs += @('--window_width=1920', '--window_height=1080', '--fullscreen=false') }
    '720p' { $launchArgs += @('--window_width=1280', '--window_height=720', '--fullscreen=false') }
    'NativeDisplay' { $launchArgs += '--fullscreen=true' }
}
# This changes host presentation only. The console-facing video mode and clock
# remain at their original defaults until simulation/render separation is proven.
$launchArgs += @('--present_letterbox=true', '--present_effect=bilinear')
if ($InputMode -eq 'KeyboardMouse') {
    $launchArgs += @(
        '--mnk_mode=true', '--mnk_mouse=true',
        '--keybind_a=Space', '--keybind_b=C,Backspace', '--keybind_x=R,F', '--keybind_y=Q',
        '--keybind_left_trigger=RMB', '--keybind_right_trigger=LMB',
        '--keybind_left_shoulder=4', '--keybind_right_shoulder=G',
        '--keybind_lstick_up=W,Shift+W', '--keybind_lstick_down=S,Shift+S',
        '--keybind_lstick_left=A,Shift+A', '--keybind_lstick_right=D,Shift+D',
        '--keybind_lstick_press=Shift+W', '--keybind_rstick_press=V,MMB',
        # Keep bare arrows on the right stick; Shift+arrows are the D-pad.
        # This matches the SDK's exact modifier matching and avoids one key
        # silently driving both camera and menu navigation.
        '--keybind_dpad_up=Shift+Up', '--keybind_dpad_down=Shift+Down',
        '--keybind_dpad_left=Shift+Left', '--keybind_dpad_right=Shift+Right',
        '--keybind_start=Return,Escape', '--keybind_back=Tab'
    )
} else {
    $launchArgs += '--mnk_mode=false'
}
if ($RenderScale -gt 1) {
    $launchArgs += @("--draw_resolution_scale_x=$RenderScale", "--draw_resolution_scale_y=$RenderScale")
}
if ($RefreshRate -ne 60) {
    $launchArgs += "--video_mode_refresh_rate=$RefreshRate"
}
if ($DumpShaders) {
    $dumpRelative = "analysis/runtime-shaders-$stamp"
    New-Item -ItemType Directory -Force -Path (Join-Path $workspace $dumpRelative) | Out-Null
    $launchArgs += "--dump_shaders=$dumpRelative"
}

# Keep the SDK's guest clock, vblank and video-mode defaults for initial bring-up.
# A 120 Hz host display is not evidence that the game simulation is correct at 120 FPS.
$info = [System.Diagnostics.ProcessStartInfo]::new()
$info.FileName = $executable
$info.WorkingDirectory = $workspace
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
if ($NoFoliage) {
    # Texture fetch constant 18 is the foliage control map; 0 makes the guest
    # shader's own length test fail, so no blade geometry is emitted.
    $info.Environment['COD3_VS_TEX_ZERO'] = '18'
    $info.Environment['COD3_VS_TEX_CONST'] = '0'
} else {
    $info.Environment.Remove('COD3_VS_TEX_ZERO') | Out-Null
    $info.Environment.Remove('COD3_VS_TEX_CONST') | Out-Null
}
if ($TimingTrace) {
    $info.Environment['COD3_TIMING_TRACE'] = '1'
    $info.Environment['COD3_TIMING_OUTPUT_DIR'] = 'analysis/timing/captures'
    $info.Environment['COD3_TIMING_MAX_CALLS'] = '65536'
} else {
    $info.Environment.Remove('COD3_TIMING_TRACE') | Out-Null
    $info.Environment.Remove('COD3_TIMING_OUTPUT_DIR') | Out-Null
    $info.Environment.Remove('COD3_TIMING_MAX_CALLS') | Out-Null
}
foreach ($argument in $launchArgs) { $info.ArgumentList.Add($argument) }
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $info
$receipt = [ordered]@{
    stage = 'runtime-probe'
    started_utc = [DateTime]::UtcNow.ToString('o')
    finished_utc = $null
    executable = $executable
    executable_sha256 = $exeHash
    input_sha256 = $xexHash
    input_mode = $InputMode
    requested_host_output = $OutputSize
    render_scale = $RenderScale
    guest_refresh_rate = $RefreshRate
    guest_video_mode_changed = ($RefreshRate -ne 60)
    timing_trace = [bool]$TimingTrace
    runtime_artifacts = @($buildReceipt.runtime_artifacts)
    arguments = $launchArgs
    log_path = Join-Path $workspace $logRelative
    process_id = $null
    exit_code = $null
    observation = 'not-started'
    boot = 'not-verified'
    gameplay = 'not-verified'
    fps_120 = 'not-verified'
    physics = 'not-verified'
}
try {
    if (-not $process.Start()) { throw 'Could not start the native application.' }
    $receipt.process_id = $process.Id
    $receipt.observation = 'process-started'
    Write-Host "Native process $($process.Id) started. Log: $($receipt.log_path)"
    if ($SmokeSeconds -gt 0) {
        if (-not $process.WaitForExit($SmokeSeconds * 1000)) {
            $process.Refresh()
            $receipt.observation = 'alive-at-probe-limit-then-stopped'
            $receipt['working_set_bytes'] = $process.WorkingSet64
            $receipt['cpu_seconds'] = $process.TotalProcessorTime.TotalSeconds
            # Stop only the process started by this invocation.
            $process.Kill($true)
            $process.WaitForExit()
        } else {
            $receipt.observation = 'exited-during-probe'
        }
        $receipt.exit_code = $process.ExitCode
    } else {
        Write-Host 'The game window is independent of this launcher. Use the game window to exit.'
    }
}
finally {
    $receipt.finished_utc = [DateTime]::UtcNow.ToString('o')
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    $process.Dispose()
    Write-Host "Runtime observation: $receiptPath"
}
