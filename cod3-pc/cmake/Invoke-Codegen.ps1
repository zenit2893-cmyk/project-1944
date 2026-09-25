[CmdletBinding()]
param(
    [string]$ReXGlue = (Join-Path $PSScriptRoot '../../win-amd64/bin/rexglue.exe'),
    [switch]$IgnoreStamp
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$manifestName = 'cod3_pc_manifest.toml'
$manifestPath = Join-Path $projectRoot $manifestName
$manifestText = [IO.File]::ReadAllText($manifestPath)

# The manifest points ReXGlue at a template overlay that wires the coroutine
# bridge into the generated PCH. If that directory is missing ReXGlue does not
# complain - it falls back to its stock templates and emits code that builds
# and then crashes in the scheduler. Refuse instead.
$templateMatch = [regex]::Match($manifestText, '(?m)^\s*template_dir\s*=\s*"([^"]+)"')
if ($templateMatch.Success) {
    $templateDir = [IO.Path]::GetFullPath((Join-Path $projectRoot $templateMatch.Groups[1].Value))
    $overlay = Join-Path $templateDir 'codegen/pch_h.inja'
    if (-not (Test-Path -LiteralPath $overlay -PathType Leaf)) {
        throw "The codegen template overlay is missing: $overlay. Run integration/coroutines/Prepare-FromGame.ps1 first; without it the generated code silently loses the coroutine bridge."
    }
}
$defaultOutput = Join-Path $projectRoot 'generated/default'
$logRoot = Join-Path $workspaceRoot 'logs'
$analysisRoot = Join-Path $workspaceRoot 'analysis'
[IO.Directory]::CreateDirectory($logRoot) | Out-Null
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)

function Read-ManifestString([string]$Text, [string]$Key) {
    # This scaffold uses simple quoted ASCII relative paths. Reject unsupported
    # strings rather than silently changing an arbitrary TOML configuration.
    $matches = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"([A-Za-z0-9_./-]+)"\s*(?:#.*)?$')
    if ($matches.Count -ne 1) { throw "Expected one simple quoted '$Key' field in a manifest module." }
    return $matches[0].Groups[1].Value
}

function Write-IfDifferent([string]$Path, [string]$Content) {
    if (-not [IO.File]::Exists($Path) -or [IO.File]::ReadAllText($Path) -cne $Content) {
        [IO.File]::WriteAllText($Path, $Content, $utf8)
    }
}

function Escape-DepfilePath([string]$Path) {
    return $Path.Replace('\', '/').Replace('$', '$$').Replace('#', '\#').Replace(' ', '\ ').Replace(':', '\:')
}

$moduleBlocks = [regex]::Split($manifestText, '(?m)^\[\[modules\]\]\s*$')
if ($moduleBlocks.Length -lt 2) { throw 'Expected COD3 mission DLL modules in the manifest.' }
$modules = @()
$seenTargets = @{}
foreach ($block in $moduleBlocks[1..($moduleBlocks.Length - 1)]) {
    $guestPath = Read-ManifestString $block 'guest_path'
    $filePath = Read-ManifestString $block 'file_path'
    $outputPath = Read-ManifestString $block 'out_directory_path'
    $target = [IO.Path]::GetFileNameWithoutExtension($filePath)
    if ($target -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $seenTargets.ContainsKey($target)) {
        throw "Invalid or duplicate module target '$target'."
    }
    $seenTargets[$target] = $true
    if ($outputPath -cne "generated/$target") { throw "Unexpected output directory for '$target': $outputPath" }
    $inputFullPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $filePath))
    if (-not $inputFullPath.StartsWith([IO.Path]::GetFullPath((Join-Path $workspaceRoot 'game/cod3/')), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Module input leaves game/cod3: $filePath"
    }
    if (-not (Test-Path -LiteralPath $inputFullPath -PathType Leaf)) { throw "Missing module: $inputFullPath" }
    $modules += [pscustomobject]@{ target = $target; guest_path = $guestPath; input = $inputFullPath; output = $outputPath }
}

$started = [DateTime]::UtcNow.ToString('o')
$runs = @()
$targetFragments = @()
$overallExit = 0
Push-Location $projectRoot
try {
    foreach ($module in $modules) {
        $targetStarted = [DateTime]::UtcNow.ToString('o')
        $logPath = Join-Path $logRoot "cod3-pc-codegen-$($module.target).log"
        $arguments = @('--log-level', 'info', 'codegen', $manifestName, '--target', $module.target)
        if ($IgnoreStamp) { $arguments += '--ignore-stamp' }
        # A fresh process isolates each mission overlay at guest base 0x89000000.
        # Relative manifest argument avoids the SDK's narrow-path Unicode bug.
        & $ReXGlue @arguments *> $logPath
        $targetExit = $LASTEXITCODE
        $runs += [ordered]@{
            target = $module.target; stage = 'codegen'
            started_utc = $targetStarted; finished_utc = [DateTime]::UtcNow.ToString('o')
            exit_code = $targetExit; input_path = $module.input
            input_sha256 = (Get-FileHash -LiteralPath $module.input -Algorithm SHA256).Hash
            generated_directory = "cod3-pc/$($module.output)"
            log_path = "logs/cod3-pc-codegen-$($module.target).log"
            command = "rexglue codegen $manifestName --target $($module.target)"
        }
        $runs | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $analysisRoot 'cod3-pc-module-codegen-receipts.json') -Encoding utf8
        if ($targetExit -ne 0) {
            $overallExit = $targetExit
            Get-Content -LiteralPath $logPath -Tail 50
            throw "Strict codegen failed for '$($module.target)' (exit $targetExit)."
        }
        # Preserve the SDK's exact per-target CMake, then combine all targets.
        $fragment = [IO.File]::ReadAllText((Join-Path $defaultOutput 'dll_targets.cmake'))
        if (-not $fragment.Contains("add_library(cod3_pc_$($module.target) SHARED")) {
            throw "Missing native DLL target for '$($module.target)' in SDK output."
        }
        $targetFragments += $fragment
        Write-Output "Strict codegen passed: $($module.target)"
    }

    $registry = [Text.StringBuilder]::new()
    [void]$registry.AppendLine('// COD3 complete mission module registry; rebuilt after isolated SDK codegen.')
    [void]$registry.AppendLine('#include <rex/system/kernel_state.h>')
    [void]$registry.AppendLine('void RegisterRecompiledModules(rex::system::KernelState* kernel_state) {')
    foreach ($module in $modules) {
        $filename = [IO.Path]::GetFileName($module.guest_path)
        [void]$registry.AppendLine("  kernel_state->RegisterRecompiledModule(`"$filename`", `"$($module.guest_path)`", `"cod3_pc_$($module.target)`");")
    }
    [void]$registry.AppendLine('}')
    Write-IfDifferent (Join-Path $defaultOutput 'module_registry.cpp') $registry.ToString()
    Write-IfDifferent (Join-Path $defaultOutput 'dll_targets.cmake') ($targetFragments -join "`n")

    # A UTF-8 depfile records every input, not only the final selected overlay.
    $stampPath = Join-Path $defaultOutput 'codegen.build.stamp'
    $dependencies = @($manifestPath, (Join-Path $PSScriptRoot 'Invoke-Codegen.ps1'), (Join-Path $workspaceRoot 'game/cod3/default.xex')) + @($modules | ForEach-Object { $_.input })
    $depfile = (Escape-DepfilePath $stampPath) + ': ' + (($dependencies | ForEach-Object { Escape-DepfilePath $_ }) -join ' ') + "`n"
    Write-IfDifferent (Join-Path $defaultOutput 'codegen.d') $depfile
    [IO.File]::WriteAllText($stampPath, [DateTime]::UtcNow.ToString('o'), $utf8)

    $files = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'generated') -Recurse -File)
    $cppFiles = @($files | Where-Object Extension -eq '.cpp')
    [ordered]@{
        stage = 'codegen'; started_utc = $started; finished_utc = [DateTime]::UtcNow.ToString('o')
        exit_code = 0; input_sha256 = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'game/cod3/default.xex') -Algorithm SHA256).Hash
        manifest = 'cod3-pc/cod3_pc_manifest.toml'; manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        generated_directory = 'cod3-pc/generated/default'; all_generated_directory = 'cod3-pc/generated'
        executable = $ReXGlue; sdk_version = '0.10.0.5-dev.g0c7b01a'
        working_directory = 'cod3-pc'; command = 'cmake/Invoke-Codegen.ps1 (one ReXGlue --target process per mission overlay)'
        log_path = 'logs/cod3-pc-codegen-isolated.log'; target_receipts = 'analysis/cod3-pc-module-codegen-receipts.json'
        module_count = $modules.Count; generated_cpp_files = $cppFiles.Count
        generated_total_files = $files.Count; generated_bytes = ($files | Measure-Object Length -Sum).Sum
        boundary_evidence = 'analysis/cod3-boundary-evidence.json'
        registry = 'cod3-pc/generated/default/module_registry.cpp'; native_module_targets = 'cod3-pc/generated/default/dll_targets.cmake'
        note = 'Strict codegen success is not a native build, boot, gameplay, or 120 FPS physics validation.'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $analysisRoot 'cod3-pc-codegen-receipt.json') -Encoding utf8
    Write-Output "Generated COD3 main executable and $($modules.Count) mission DLLs; complete native module registry restored."
} catch {
    if ($overallExit -eq 0) { $overallExit = 1 }
    Write-Error $_ -ErrorAction Continue
} finally {
    Pop-Location
}
exit $overallExit
