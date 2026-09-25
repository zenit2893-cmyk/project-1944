#requires -Version 5.1
<#
.SYNOPSIS
    Builds the coroutine capture wrappers and the codegen PCH overlay from the
    user's own copy of the game.

.DESCRIPTION
    The coroutine bridge needs two things before code generation runs:

      * analysis/cod3-allmodule-coroutine-sites.json - the verified map of the
        45 capture sites across the 15 mission modules. It records guest
        instruction words, so it is derived from the game and is never shipped;
        analysis/cod3-allmodule-coroutine-sites.py rebuilds it from the
        mission DLLs and refuses any module whose hash differs from the locked
        manifest.
      * integration/coroutines/generated/* and templates/codegen/pch_h.inja,
        written by Prepare.ps1 from that map.

    Without the overlay template, code generation does not fail - it quietly
    falls back to the SDK's stock PCH, and the rebuilt game loses the setjmp
    and longjmp interception the coroutine scheduler depends on. That is why
    this step exists instead of relying on whatever happens to be on disk.

    On a fresh install this runs before the first code generation, because the
    overlay is one of its inputs. The map is then built with every
    instruction-level check but without the "registered in the ReXGlue output"
    check, which has nothing to look at yet. -VerifyOnly, scheduled right after
    code generation, rebuilds the map strictly and requires the same 45
    capture addresses, now confirmed as registered functions.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Force,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$Root = [IO.Path]::GetFullPath($Root)

$targets = Join-Path $Root 'integration\coroutines\generated\capture_targets.cmake'
$overlay = Join-Path $Root 'integration\coroutines\templates\codegen\pch_h.inja'
if ((Test-Path -LiteralPath $targets -PathType Leaf) -and (Test-Path -LiteralPath $overlay -PathType Leaf) -and -not $Force -and -not $VerifyOnly) {
    Write-Host 'Coroutine wrappers and the PCH overlay are already in place.'
    exit 0
}

foreach ($required in @(
    'analysis\cod3-allmodule-coroutine-sites.py',
    'analysis\cod3-allmodule-coroutine-manifest.json',
    'scripts\analyze-title-image.py',
    'scripts\analyze-title-xex.py',
    'integration\coroutines\Prepare.ps1',
    'game\cod3\default.xex')) {
    $path = Join-Path $Root $required
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required input is missing: $path" }
}

# The map generator imports xxhash and cryptography from analysis/title-python.
# Prefer the interpreter the package carries; a real system Python also works.
# A candidate has to actually start: a virtual environment copied from another
# machine has a python.exe that only says "No Python at ...".
$python = $null
$prefix = @()
foreach ($candidate in @(
    (Join-Path $Root 'tools\toolchain\bootstrap-python\python.exe'),
    (Join-Path $Root 'tools\toolchain\bootstrap-python\Scripts\python.exe'))) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    & $candidate -c "import sys" 2>$null
    if ($LASTEXITCODE -eq 0) { $python = $candidate; break }
}
if (-not $python) {
    $system = Get-Command python -ErrorAction SilentlyContinue
    if ($system -and ((& $system.Source --version 2>&1 | Out-String) -match 'Python\s+3\.\d')) { $python = $system.Source }
}
if (-not $python) {
    $uv = Join-Path $Root 'tools\uv\uv.exe'
    if (-not (Test-Path -LiteralPath $uv -PathType Leaf)) {
        throw 'No Python is available. Run tools/toolchain-provision/Install-Toolchain.ps1 first.'
    }
    $python = $uv
    $prefix = @('run', '--python', '3.12', '--with', 'xxhash', '--with', 'cryptography')
}
Write-Host "Python: $python $($prefix -join ' ')"

$logs = Join-Path $Root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null

$generator = Join-Path $Root 'analysis\cod3-allmodule-coroutine-sites.py'
$map = Join-Path $Root 'analysis\cod3-allmodule-coroutine-sites.json'

function Invoke-MapGenerator([string[]]$Extra, [string]$LogName) {
    $log = Join-Path $logs $LogName
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $python
    $arguments = @($prefix) + @($generator, '--workspace', $Root) + @($Extra)
    $info.Arguments = ($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $info.WorkingDirectory = $Root
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [IO.File]::WriteAllText($log, $stdout + $stderr, (New-Object Text.UTF8Encoding($false)))
    if ($process.ExitCode -ne 0) {
        $tail = (($stdout + $stderr) -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join [Environment]::NewLine
        throw "The coroutine map could not be built (exit $($process.ExitCode)). See $log`n$tail"
    }
    if (-not (Test-Path -LiteralPath $map -PathType Leaf)) { throw "The generator finished but $map is missing." }
    Write-Host "  ok, log: $log"
}

function Get-CaptureSet {
    $data = Get-Content -LiteralPath $map -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($data.modules | ForEach-Object {
        $module = $_.module
        $_.captures | ForEach-Object { "$module/$($_.kind)/$($_.address)/$($_.size)" }
    } | Sort-Object)
}

if ($VerifyOnly) {
    Write-Host ''
    Write-Host '=== Coroutine map against the generated code ==='
    if (-not (Test-Path -LiteralPath $map -PathType Leaf)) { throw "There is no coroutine map to verify: $map" }
    $before = Get-CaptureSet
    Invoke-MapGenerator @() 'verify-coroutine-map.log'
    $after = Get-CaptureSet
    $data = Get-Content -LiteralPath $map -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $data.registration_checked -or $data.verified_module_count -ne 15 -or $data.capture_count -ne 45) {
        throw 'The strict coroutine map did not verify all 15 modules against the generated code.'
    }
    if (($before -join "`n") -ne ($after -join "`n")) {
        throw 'The capture addresses found in the generated code differ from the ones the PCH overlay was built from.'
    }
    Write-Host "  45 capture functions confirmed as registered in the generated code."
    exit 0
}

# Before the first code generation there is no ReXGlue output to check the
# captures against; the run after codegen (-VerifyOnly) does that.
$registerFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'cod3-pc\generated') -Filter 'cod3_pc_register.cpp' -Recurse -File -ErrorAction SilentlyContinue)
$extra = @()
if ($registerFiles.Count -lt 15) { $extra = @('--before-codegen') }

Write-Host ''
Write-Host '=== Coroutine capture map from your mission modules ==='
Invoke-MapGenerator $extra 'prepare-coroutine-map.log'
Write-Host ''
Write-Host '=== Capture wrappers and PCH overlay ==='
& (Join-Path $Root 'integration\coroutines\Prepare.ps1')

foreach ($expected in @($targets, $overlay)) {
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { throw "Prepare.ps1 finished but $expected is missing." }
}
$overlayText = [IO.File]::ReadAllText($overlay)
foreach ($marker in @('cod3_coroutines.h', 'NoteSetjmp', 'InterceptLongjmp')) {
    if ($overlayText -notmatch [regex]::Escape($marker)) { throw "The PCH overlay lacks $marker; refusing to continue with a template that would drop the coroutine bridge." }
}
Write-Host ''
Write-Host 'Coroutine bridge prepared from your copy of the game.'
