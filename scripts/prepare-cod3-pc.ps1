#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('All', 'Cpu', 'Shaders')][string]$Stage = 'All',
    [string]$Python = (Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe')
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$sourceLock = Get-Content -LiteralPath (Join-Path $workspace 'analysis/disc-source-lock.json') -Raw | ConvertFrom-Json
$xex = Join-Path $workspace 'game/cod3/default.xex'
$xexHash = (Get-FileHash -LiteralPath $xex -Algorithm SHA256).Hash
if ($xexHash -ne $sourceLock.expected_default_xex.sha256) { throw 'The input revision does not match the reviewed CoD3 executable.' }
if (-not (Test-Path -LiteralPath $Python)) { throw 'Supply -Python with a real Python interpreter; the WindowsApps placeholder is insufficient.' }
$steps = [Collections.Generic.List[object]]::new()
$started = [DateTime]::UtcNow.ToString('o')

function Invoke-Preparation([string]$Name, [string]$Program, [string[]]$Arguments) {
    $log = Join-Path $workspace "logs/prepare-$Name.log"
    & $Program @Arguments *> $log
    $status = $LASTEXITCODE
    $steps.Add([ordered]@{ name = $Name; exit_code = $status; log_path = $log })
    if ($status -ne 0) { throw "Preparation '$Name' failed ($status). See $log" }
    Write-Host "Completed: $Name"
}

Push-Location -LiteralPath $workspace
try {
    if ($Stage -in @('All', 'Cpu')) {
        New-Item -ItemType Directory -Force -Path 'analysis/title-xenon-generated' | Out-Null
        Invoke-Preparation 'image' $Python @('scripts/analyze-title-image.py', 'game/cod3/default.xex', '--out-prefix', 'analysis/title-default-image')
        Invoke-Preparation 'helpers' $Python @('scripts/analyze-title-xenon.py')
        Invoke-Preparation 'xenon-analysis' 'tools/XenonRecomp/out/build/windows-release/XenonAnalyse/XenonAnalyse.exe' @('game/cod3/default.xex', 'analysis/xenon-switch-tables.toml')
        Invoke-Preparation 'xenon-codegen' 'tools/XenonRecomp/out/build/windows-release/XenonRecomp/XenonRecomp.exe' @('cod3-pc/config/xenon-main.toml', 'tools/XenonRecomp/XenonUtils/ppc_context.h')
        # Xenon reports unsupported full-game operations despite exit 0. Only
        # reviewed bodies may cross the SDK ABI through the constrained adapter.
        & './integration/xenon/extract-generated-thunks.ps1' -GeneratedDirectory './analysis/title-xenon-generated' *> 'logs/prepare-thunks.log'
        Invoke-Preparation 'xenon-bridge-test' (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile', '-File', 'tests/xenon-bridge/run.ps1', '-Configuration', 'RelWithDebInfo')
        Write-Host 'Only the two verified Xenon thunks are linked; full Xenon output retains unsupported operations.'
    }
    if ($Stage -in @('All', 'Shaders')) {
        Invoke-Preparation 'shader-containers' $Python @('scripts/shader_prepare.py', 'game/cod3', '--output-root', 'analysis/graphics-prepared', '--max-decoded-mib', '128', '--max-stored-mib', '128')
        Invoke-Preparation 'shader-feature-audit' $Python @('scripts/shader_texture_inventory.py', 'analysis/graphics-prepared/manifest.json', '--output', 'analysis/graphics-texture-feature-inventory.json')
        Invoke-Preparation 'xenos-programs' $Python @('scripts/xenos-batch.py', '--workers', '4')
        $shaderReport = Get-Content -LiteralPath 'docs/reports/xenos-cod3-shaders.json' -Raw | ConvertFrom-Json
        Write-Host "Shader compiler passes: $($shaderReport.summary.passed_all_stages)/$($shaderReport.summary.total). Known semantic blockers: $($shaderReport.summary.entries_with_known_semantic_blockers)."
        Write-Host 'These artifacts are prepared for shader integration; the active runtime GPU plugin still translates its own shaders.'
    }
}
finally {
    Pop-Location
    [ordered]@{
        stage = 'supporting-tool-pipeline'
        selection = $Stage
        started_utc = $started
        finished_utc = [DateTime]::UtcNow.ToString('o')
        input_sha256 = $xexHash
        steps = @($steps.ToArray())
        gameplay_verified = $false
        fps_120_verified = $false
        full_xenon_cpu_compatibility_verified = $false
        xenos_runtime_integration_verified = $false
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $workspace 'analysis/cod3-pc-tools-pipeline.json') -Encoding utf8
}
