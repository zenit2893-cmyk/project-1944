#requires -Version 7.0
<#
.SYNOPSIS
    Safely audits the local Call of Duty 3 recompilation workspace.
.DESCRIPTION
    Executes only tool version/help probes (12 second timeout). It never builds,
    launches a game, alters the ISO, or interprets executable existence as boot.
    Reports distinguish structural checks from game evidence requiring review.
    Exit 0 means the audit ran, not that a working port has been produced.
    Use -RequireThrough for an automation gate; unmet gates then return exit 2.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$IsoPath = 'Call of Duty 3 (USA, Europe).iso',
    [string]$SdkRoot = 'win-amd64',
    [string]$GameRoot = 'game/cod3',
    [Alias('ProjectDirectory')]
    [string]$ProjectRoot = 'cod3-pc',
    [string]$ReportDirectory = 'docs/reports',
    [ValidateSet('none', 'sdk-smoke', 'support-tools', 'extracted-xex', 'codegen-success', 'native-build')]
    [string]$RequireThrough = 'none',
    [switch]$SkipToolProbes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)

function Resolve-WorkspacePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $Path))
}

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Read-JsonIfPresent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FirstFile([string[]]$Candidates, [string]$CommandName) {
    foreach ($candidate in $Candidates) {
        $resolved = Resolve-WorkspacePath $candidate
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
    }
    $command = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Invoke-ToolProbe([string]$Name, [string]$Path, [string]$Arguments = '--version', [string]$ExpectedOutput = '') {
    if (-not $Path) { return [ordered]@{ name = $Name; status = 'MISSING'; path = $null } }
    if ($SkipToolProbes) { return [ordered]@{ name = $Name; status = 'SKIPPED'; path = $Path } }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $WorkspaceRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit(12000)
        if (-not $exited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        $logPath = Join-Path $script:ReportPath ('validation-{0}-probe.log' -f $Name)
        @("Executable: $Path", "Arguments: $Arguments", "UTC: $script:AuditUtc", '[stdout]', $output, '[stderr]', $errorOutput) |
            Set-Content -LiteralPath $logPath -Encoding utf8
        return [ordered]@{
            name = $Name
            status = $(if (-not $exited) { 'TIMEOUT' } elseif ($process.ExitCode -eq 0 -and (-not $ExpectedOutput -or ($output + $errorOutput) -match $ExpectedOutput)) { 'PASS' } else { 'FAIL' })
            path = $Path
            arguments = $Arguments
            exit_code = $(if ($exited) { $process.ExitCode } else { $null })
            output = ($output + $errorOutput).Trim()
            log_path = $logPath
        }
    }
    catch {
        return [ordered]@{ name = $Name; status = 'FAIL'; path = $Path; error = $_.Exception.Message }
    }
    finally { $process.Dispose() }
}

function Add-Check([string]$Id, [string]$Status, [string]$Summary, $Evidence = $null) {
    $script:Checks.Add([pscustomobject][ordered]@{ id = $Id; status = $Status; summary = $Summary; evidence = $Evidence })
}

function Test-NonemptyFile([string]$Path) {
    return $Path -and (Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -gt 0
}

function Test-NativeAmd64Executable([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { return $false }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 26)) { return $false }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return $false }
        if ($reader.ReadUInt16() -ne 0x8664) { return $false }
        $stream.Position = $peOffset + 24
        return $reader.ReadUInt16() -eq 0x020B
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Test-GeneratedDirectory([string]$Path) {
    $sources = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.cpp' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
    $headers = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.h', '.hpp') -and $_.Length -gt 0 })
    if ($sources.Count -lt 1 -or $headers.Count -lt 1) { throw "No nonempty generated C++ source/header artifacts in: $Path" }
    $hasGuestFunctions = $false
    foreach ($source in $sources) {
        if (Select-String -LiteralPath $source.FullName -Pattern 'DEFINE_REX_FUNC\(|REX_FUNC_PROLOGUE|PPC_FUNC_IMPL|PPC_FUNC\(|PPC_FUNC_PROLOGUE|void\s+sub_[0-9a-fA-F]+' -Quiet) { $hasGuestFunctions = $true; break }
    }
    if (-not $hasGuestFunctions) { throw "No recognized generated guest function declarations or implementations in: $Path" }
    return [ordered]@{ directory = $Path; cpp_count = $sources.Count; header_count = $headers.Count }
}

function Read-CommandReceipt([string]$Path, [string]$ExpectedStage) {
    $receipt = Read-JsonIfPresent $Path
    if ($null -eq $receipt) { return $null }
    $receiptStage = Get-Value $receipt 'stage'
    if ($receiptStage -and $receiptStage -ne $ExpectedStage) { throw "Receipt stage '$receiptStage' does not match '$ExpectedStage'." }
    $exitCode = Get-Value $receipt 'exit_code' (Get-Value $receipt 'exitCode')
    if ($null -eq $exitCode) { throw 'Command receipt has no exit_code.' }
    $hash = Get-Value $receipt 'input_sha256' (Get-Value $receipt 'inputSha256')
    if (-not $hash -or -not $script:XexHash -or $hash -ne $script:XexHash) { throw 'Command receipt does not match the current default.xex SHA256.' }
    $manifestPath = Resolve-WorkspacePath (Get-Value $receipt 'manifest')
    $manifestHash = Get-Value $receipt 'manifest_sha256'
    if (-not $manifestPath -and $manifestHash) {
        $manifests = @(Get-ChildItem -LiteralPath $script:ProjectPath -Filter '*manifest.toml' -File -ErrorAction SilentlyContinue)
        if ($manifests.Count -eq 1) { $manifestPath = $manifests[0].FullName }
    }
    if ($manifestHash) {
        if (-not (Test-NonemptyFile $manifestPath) -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $manifestHash) { throw 'Command receipt manifest SHA256 does not match the current project manifest.' }
    }
    foreach ($module in @(Get-Value $receipt 'module_hashes' @())) {
        $modulePath = Resolve-WorkspacePath (Get-Value $module 'path')
        $moduleHash = Get-Value $module 'sha256'
        if (-not (Test-NonemptyFile $modulePath) -or -not $moduleHash -or (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash -ne $moduleHash) { throw "Command receipt module hash does not match: $modulePath" }
    }
    $log = Resolve-WorkspacePath (Get-Value $receipt 'log_path' (Get-Value $receipt 'logPath'))
    if (-not (Test-NonemptyFile $log)) { throw 'Command receipt has no readable, nonempty log.' }
    return [pscustomobject]@{ raw = $receipt; exit_code = $exitCode; log_path = $log; path = $Path }
}

$script:AuditUtc = [DateTime]::UtcNow.ToString('o')
$script:ReportPath = Resolve-WorkspacePath $ReportDirectory
$null = New-Item -ItemType Directory -Path $script:ReportPath -Force
$script:Checks = [Collections.Generic.List[object]]::new()
$script:XexHash = $null

$iso = Resolve-WorkspacePath $IsoPath
if (Test-NonemptyFile $iso) {
    $file = Get-Item -LiteralPath $iso
    Add-Check 'input-present' 'PASS' 'The named ISO is present. This check does not validate the entire disc image.' @{ path = $iso; bytes = $file.Length; last_write_utc = $file.LastWriteTimeUtc.ToString('o') }
}
else { Add-Check 'input-present' 'BLOCKED' 'The named ISO is absent or empty.' @{ path = $iso } }

$sdk = Resolve-WorkspacePath $SdkRoot
$sdkExecutable = Join-Path $sdk 'bin/rexglue.exe'
$sdkRequired = @('bin/rexglue.exe', 'bin/rexruntime.dll', 'include/rex/runtime.h')
$sdkMissing = @($sdkRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sdk $_) -PathType Leaf) })
$sdkProbe = Invoke-ToolProbe 'sdk' $(if (Test-Path -LiteralPath $sdkExecutable -PathType Leaf) { $sdkExecutable } else { $null })
if ($sdkMissing.Count -gt 0) {
    Add-Check 'sdk-smoke' 'BLOCKED' 'Required SDK files are missing.' @{ missing = $sdkMissing; probe = $sdkProbe }
}
elseif ($sdkProbe.status -eq 'PASS') {
    Add-Check 'sdk-smoke' 'PASS' 'The supplied SDK CLI runs and reports its version. Runtime compatibility with COD3 is a later gate.' $sdkProbe
}
else { Add-Check 'sdk-smoke' $(if ($SkipToolProbes) { 'AVAILABLE' } else { 'FAIL' }) 'SDK files exist; the version smoke test was skipped or failed.' $sdkProbe }

$supportTools = @(
    @{ id = 'xenosrecomp-tool'; name = 'XenosRecomp'; candidates = @('tools/XenosRecomp/build/XenosRecomp/XenosRecomp.exe', 'tools/XenosRecomp/build/XenosRecomp/Release/XenosRecomp.exe') },
    @{ id = 'xenonrecomp-tool'; name = 'XenonRecomp'; candidates = @('tools/XenonRecomp/out/build/windows-release/XenonRecomp/XenonRecomp.exe', 'tools/XenonRecomp/build/XenonRecomp/XenonRecomp.exe', 'tools/XenonRecomp/build/XenonRecomp/Release/XenonRecomp.exe') },
    @{ id = 'xenonanalyse-tool'; name = 'XenonAnalyse'; candidates = @('tools/XenonRecomp/out/build/windows-release/XenonAnalyse/XenonAnalyse.exe', 'tools/XenonRecomp/build/XenonAnalyse/XenonAnalyse.exe', 'tools/XenonRecomp/build/XenonAnalyse/Release/XenonAnalyse.exe') }
)
foreach ($tool in $supportTools) {
    $executable = Get-FirstFile $tool.candidates ($tool.name + '.exe')
    $probe = Invoke-ToolProbe $tool.name $executable '' ('Usage:\s+' + $tool.name)
    if ($executable) { $probe['executable_sha256'] = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash }
    if ($probe.status -eq 'PASS') {
        Add-Check $tool.id 'PASS' "$($tool.name) executes and displays its no-argument usage. This does not establish linkage or runtime interoperability with ReXGlue." $probe
    }
    else {
        Add-Check $tool.id $(if ($probe.status -eq 'SKIPPED') { 'AVAILABLE' } elseif ($probe.status -eq 'MISSING') { 'BLOCKED' } else { 'FAIL' }) "$($tool.name) executable is absent, not probed, or failed its no-argument usage check." $probe
    }
}

$toolCandidates = [ordered]@{
    clang = @{ candidates = @('tools/toolchain/llvm/bin/clang-cl.exe', 'tools/llvm/bin/clang-cl.exe'); command = 'clang-cl.exe' }
    cmake = @{ candidates = @('tools/cmake/bin/cmake.exe', 'tools/toolchain/cmake/bin/cmake.exe'); command = 'cmake.exe' }
    ninja = @{ candidates = @('tools/ninja/ninja.exe', 'tools/toolchain/ninja/ninja.exe'); command = 'ninja.exe' }
}
$toolProbes = @(
    foreach ($name in $toolCandidates.Keys) {
        $tool = $toolCandidates[$name]
        Invoke-ToolProbe $name (Get-FirstFile $tool.candidates $tool.command)
    }
)
$toolchainStatusPath = Resolve-WorkspacePath 'docs/reports/toolchain-status.json'
$toolchainEvidence = $null
try { $toolchainEvidence = Read-JsonIfPresent $toolchainStatusPath }
catch { $toolchainEvidence = @{ error = $_.Exception.Message } }
$toolFailures = @($toolProbes | Where-Object { $_.status -notin @('PASS', 'SKIPPED') })
$toolchainDetails = @{ probes = $toolProbes; installer_report_path = $toolchainStatusPath; recorded_smoke = Get-Value $toolchainEvidence 'smoke' }
if ($toolFailures.Count -gt 0) {
    Add-Check 'native-toolchain' 'BLOCKED' 'One or more compiler/build-tool version checks are unavailable or unsuccessful.' $toolchainDetails
}
else {
    $smoke = Get-Value $toolchainEvidence 'smoke'
    $smokeVerified = $false
    try {
        if ($SkipToolProbes -or (Get-Value $smoke 'passed') -ne $true -or (Get-Value $smoke 'build_exit_code' -1) -ne 0 -or (Get-Value $smoke 'run_exit_code' -1) -ne 0) { throw 'No successful compile/run smoke receipt accompanies fresh tool probes.' }
        $sourcePath = Resolve-WorkspacePath (Get-Value $smoke 'source_path')
        if (-not (Test-NonemptyFile $sourcePath) -or (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne (Get-Value $smoke 'source_sha256')) { throw 'Recorded toolchain smoke source hash is absent or differs.' }
        $variants = @(Get-Value $smoke 'variants' @())
        if ($variants.Count -eq 0) { throw 'The toolchain smoke receipt has no compiled variants.' }
        foreach ($variant in $variants) {
            $variantExe = Resolve-WorkspacePath (Get-Value $variant 'exe_path')
            $variantLog = Resolve-WorkspacePath (Get-Value $variant 'log_path')
            if ((Get-Value $variant 'configure_exit_code' -1) -ne 0 -or (Get-Value $variant 'build_exit_code' -1) -ne 0 -or (Get-Value $variant 'run_exit_code' -1) -ne 0) { throw 'A recorded toolchain smoke configure/build/run was unsuccessful.' }
            if (-not (Test-NonemptyFile $variantExe) -or -not (Test-NonemptyFile $variantLog)) { throw 'A recorded toolchain smoke executable or log is missing.' }
            if ((Get-FileHash -LiteralPath $variantExe -Algorithm SHA256).Hash -ne (Get-Value $variant 'exe_sha256')) { throw 'A recorded toolchain smoke executable SHA256 differs.' }
        }
        $smokeVerified = $true
    }
    catch { $toolchainDetails['smoke_limitation'] = $_.Exception.Message }
    if ($smokeVerified) {
        Add-Check 'native-toolchain' 'PASS' 'Fresh tool version probes and recorded compile/link/run smoke checks pass; source and executable hashes match. This is SDK/toolchain evidence, not gameplay.' $toolchainDetails
    }
    else { Add-Check 'native-toolchain' 'AVAILABLE' 'Compiler, CMake and Ninja are available; a matching recorded compile/run smoke check is unavailable or probes were skipped.' $toolchainDetails }
}

$game = Resolve-WorkspacePath $GameRoot
$xex = Join-Path $game 'default.xex'
if (Test-NonemptyFile $xex) {
    $file = Get-Item -LiteralPath $xex
    $stream = [IO.File]::OpenRead($xex)
    try {
        $magicBytes = [byte[]]::new(4)
        $read = $stream.Read($magicBytes, 0, 4)
        $magic = [Text.Encoding]::ASCII.GetString($magicBytes)
    }
    finally { $stream.Dispose() }
    $script:XexHash = (Get-FileHash -LiteralPath $xex -Algorithm SHA256).Hash
    if ($read -eq 4 -and $magic -eq 'XEX2') {
        $assetCount = @(Get-ChildItem -LiteralPath $game -Recurse -File -ErrorAction SilentlyContinue).Count
        Add-Check 'extracted-xex' 'PASS' 'default.xex exists with an XEX2 header and a recorded SHA256. This does not assert that all game assets are extracted.' @{ path = $xex; bytes = $file.Length; sha256 = $script:XexHash; game_directory_file_count = $assetCount }
    }
    else { Add-Check 'extracted-xex' 'FAIL' 'default.xex does not have a valid XEX2 magic header.' @{ path = $xex; magic = $magic; sha256 = $script:XexHash } }
}
else { Add-Check 'extracted-xex' 'BLOCKED' 'No nonempty game/cod3/default.xex was found.' @{ path = $xex } }

$project = Resolve-WorkspacePath $ProjectRoot
$script:ProjectPath = $project
$projectName = Split-Path -Leaf $project.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$codegenReceiptPath = Resolve-WorkspacePath "analysis/$projectName-codegen-receipt.json"
try {
    $receipt = Read-CommandReceipt $codegenReceiptPath 'codegen'
    if ($null -eq $receipt) {
        Add-Check 'codegen-success' 'NOT_RUN' 'No code-generation receipt is recorded; scaffolding alone does not satisfy this gate.' @{ expected_receipt = $codegenReceiptPath }
    }
    elseif ($receipt.exit_code -ne 0) {
        Add-Check 'codegen-success' 'FAIL' 'The recorded code-generation command failed.' $receipt
    }
    else {
        $generated = Resolve-WorkspacePath (Get-Value $receipt.raw 'generated_directory')
        if (-not $generated) { $generated = Join-Path $project 'generated' }
        $generatedEvidence = Test-GeneratedDirectory $generated
        $moduleEvidence = [Collections.Generic.List[object]]::new()
        $moduleCount = Get-Value $receipt.raw 'module_count' 0
        if ($moduleCount -gt 0) {
            $targetReceiptsPath = Resolve-WorkspacePath (Get-Value $receipt.raw 'target_receipts')
            if (-not (Test-NonemptyFile $targetReceiptsPath)) { throw 'Receipt declares game modules but their command receipts are missing.' }
            $targetReceipts = @(Read-JsonIfPresent $targetReceiptsPath)
            if ($targetReceipts.Count -ne $moduleCount) { throw 'Declared game-module count differs from the target receipt count.' }
            $uniqueTargets = @($targetReceipts | ForEach-Object { Get-Value $_ 'target' } | Sort-Object -Unique)
            if ($uniqueTargets.Count -ne $moduleCount) { throw 'Game-module receipts contain duplicate targets.' }
            foreach ($targetReceipt in $targetReceipts) {
                $targetName = Get-Value $targetReceipt 'target'
                $targetInput = Resolve-WorkspacePath (Get-Value $targetReceipt 'input_path')
                $targetLog = Resolve-WorkspacePath (Get-Value $targetReceipt 'log_path')
                $targetGenerated = Resolve-WorkspacePath (Get-Value $targetReceipt 'generated_directory')
                if ((Get-Value $targetReceipt 'exit_code' -1) -ne 0) { throw "A game-module code-generation command failed: $targetName" }
                if (-not (Test-NonemptyFile $targetInput) -or (Get-FileHash -LiteralPath $targetInput -Algorithm SHA256).Hash -ne (Get-Value $targetReceipt 'input_sha256')) { throw "A game-module input SHA256 differs: $targetName" }
                if (-not (Test-NonemptyFile $targetLog)) { throw "A game-module code-generation log is absent: $targetName" }
                $moduleArtifacts = Test-GeneratedDirectory $targetGenerated
                $moduleEvidence.Add(@{ target = $targetName; log_path = $targetLog; input_path = $targetInput; generated = $moduleArtifacts })
            }
        }
        Add-Check 'codegen-success' 'PASS' 'Successful recorded code generation matches the current XEX, manifest and declared module inputs, with generated guest C++ artifacts. Semantic correctness remains unverified.' @{ receipt_path = $codegenReceiptPath; log_path = $receipt.log_path; generated = $generatedEvidence; modules = $moduleEvidence.ToArray(); input_sha256 = $script:XexHash }
    }
}
catch { Add-Check 'codegen-success' 'FAIL' $_.Exception.Message @{ receipt_path = $codegenReceiptPath } }

$nativeReceiptPath = Resolve-WorkspacePath "analysis/$projectName-native-build-receipt.json"
$nativeHash = $null
try {
    $receipt = Read-CommandReceipt $nativeReceiptPath 'native-build'
    if ($null -eq $receipt) {
        Add-Check 'native-build' 'NOT_RUN' 'No native-build receipt is recorded. Finding an EXE would not prove a successful COD3 build or launch.' @{ expected_receipt = $nativeReceiptPath }
    }
    elseif ($receipt.exit_code -ne 0) { Add-Check 'native-build' 'FAIL' 'The recorded native build failed.' $receipt }
    else {
        $executable = Resolve-WorkspacePath (Get-Value $receipt.raw 'executable')
        if (-not (Test-NonemptyFile $executable)) { throw 'Successful build receipt has no nonempty executable.' }
        if (-not (Test-NativeAmd64Executable $executable)) { throw 'Build artifact is not an AMD64 PE32+ executable.' }
        $nativeHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
        $expectedHash = Get-Value $receipt.raw 'executable_sha256'
        if (-not $expectedHash -or $expectedHash -ne $nativeHash) { throw 'Build executable hash is absent from the receipt or does not match.' }
        $nativeModules = [Collections.Generic.List[object]]::new()
        $codegenCheck = $script:Checks | Where-Object { $_.id -eq 'codegen-success' } | Select-Object -First 1
        if ($codegenCheck.status -eq 'PASS') {
            $declaredModuleCount = @($codegenCheck.evidence.modules).Count
            if ($declaredModuleCount -gt 0) {
                $moduleTargetsFile = Join-Path $project 'generated/default/dll_targets.cmake'
                if (-not (Test-NonemptyFile $moduleTargetsFile)) { throw 'The declared native module target list is missing.' }
                $targetNames = @([regex]::Matches((Get-Content -LiteralPath $moduleTargetsFile -Raw), 'add_library\(\s*([A-Za-z0-9_]+)\s+SHARED') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                if ($targetNames.Count -ne $declaredModuleCount) { throw 'Native module target count differs from the code-generation module count.' }
                foreach ($targetName in $targetNames) {
                    $moduleDll = Join-Path (Split-Path -Parent $executable) "$targetName.dll"
                    if (-not (Test-NonemptyFile $moduleDll) -or -not (Test-NativeAmd64Executable $moduleDll)) { throw "A declared mission module is absent or not AMD64 PE32+: $moduleDll" }
                    $nativeModules.Add(@{ path = $moduleDll; sha256 = (Get-FileHash -LiteralPath $moduleDll -Algorithm SHA256).Hash; hash_source = 'observed-at-audit-time' })
                }
            }
        }
        Add-Check 'native-build' 'PASS' 'Successful recorded build has a matching AMD64 executable and declared native mission modules. Boot and gameplay require separate observations.' @{ receipt_path = $nativeReceiptPath; executable = $executable; executable_sha256 = $nativeHash; native_modules = $nativeModules.ToArray(); log_path = $receipt.log_path; input_sha256 = $script:XexHash }
    }
}
catch { Add-Check 'native-build' 'FAIL' $_.Exception.Message @{ receipt_path = $nativeReceiptPath } }

$runtimeEvidencePath = Resolve-WorkspacePath "analysis/$projectName-game-validation.json"
$runtimeEvidence = $null
$runtimeEvidenceError = $null
$runtimeProbe = $null
$runtimeProbePath = $null
try {
    $latestProbe = Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot 'analysis') -Filter "$projectName-runtime-probe-*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($latestProbe) {
        $runtimeProbePath = $latestProbe.FullName
        $runtimeProbe = Read-JsonIfPresent $runtimeProbePath
    }
}
catch { $runtimeProbe = @{ read_error = $_.Exception.Message } }
try { $runtimeEvidence = Read-JsonIfPresent $runtimeEvidencePath }
catch { $runtimeEvidenceError = $_.Exception.Message }
foreach ($stage in @('boot', 'gameplay', 'render-120fps', 'physics-invariance')) {
    $entry = $null
    $entries = Get-Value $runtimeEvidence 'checks' @()
    if ($entries) { $entry = @($entries | Where-Object { (Get-Value $_ 'id') -eq $stage }) | Select-Object -First 1 }
    if ($runtimeEvidenceError) {
        Add-Check $stage 'FAIL' 'The optional game-validation evidence JSON is malformed; no game success is inferred.' @{ path = $runtimeEvidencePath; error = $runtimeEvidenceError }
    }
    elseif ($null -eq $entry) {
        Add-Check $stage 'NOT_VERIFIED' 'No reviewed evidence for this game stage is recorded. SDK, generated C++, EXE existence and synthetic tests do not satisfy it.' @{ expected_evidence = $runtimeEvidencePath; latest_runtime_probe_path = $runtimeProbePath; latest_runtime_probe = $runtimeProbe }
    }
    else {
        $problems = [Collections.Generic.List[string]]::new()
        if ((Get-Value $entry 'source') -ne 'game') { $problems.Add('source must be game, never synthetic') }
        if (-not $nativeHash -or (Get-Value $entry 'executable_sha256') -ne $nativeHash) { $problems.Add('native executable SHA256 is missing or differs') }
        if (-not $script:XexHash -or (Get-Value $entry 'input_sha256') -ne $script:XexHash) { $problems.Add('XEX SHA256 is missing or differs') }
        if (-not (Get-Value $entry 'reviewed_by') -or -not (Get-Value $entry 'reviewed_utc')) { $problems.Add('reviewer and review timestamp are required') }
        if (-not (Get-Value $entry 'observations')) { $problems.Add('concrete observations are required') }
        $artifacts = @(Get-Value $entry 'artifacts' @())
        if ($artifacts.Count -eq 0) { $problems.Add('at least one actual capture or trace artifact is required') }
        foreach ($artifact in $artifacts) {
            $artifactPath = Resolve-WorkspacePath (Get-Value $artifact 'path')
            if (-not (Test-NonemptyFile $artifactPath)) { $problems.Add("artifact missing or empty: $artifactPath"); continue }
            $artifactHash = Get-Value $artifact 'sha256'
            if (-not $artifactHash -or $artifactHash -ne (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash) { $problems.Add("artifact SHA256 mismatch: $artifactPath") }
        }
        if ($problems.Count -gt 0) {
            Add-Check $stage 'NOT_VERIFIED' 'Game evidence does not satisfy the identity/review/artifact requirements.' @{ evidence_path = $runtimeEvidencePath; problems = $problems.ToArray() }
        }
        else {
            Add-Check $stage 'REVIEW_REQUIRED' 'A reviewed game evidence bundle is recorded. This structural audit does not interpret the capture or certify the stated verdict; review the observations and stage-specific acceptance criteria.' @{ evidence_path = $runtimeEvidencePath; stated_verdict = Get-Value $entry 'verdict'; entry = $entry }
        }
    }
}

$report = [ordered]@{
    schema_version = 1
    audited_utc = $script:AuditUtc
    workspace = $WorkspaceRoot
    project_directory = $project
    game = 'Call of Duty 3 (Xbox 360)'
    overall = 'GAME_AND_120FPS_PHYSICS_REQUIRE_SEPARATE_VALIDATION'
    game_success_certified_by_this_script = $false
    audit_mode = $(if ($SkipToolProbes) { 'read-only-artifacts' } else { 'read-only-artifacts-and-version-help-probes' })
    checks = $script:Checks.ToArray()
}
$jsonPath = Join-Path $script:ReportPath 'validation-status.json'
$markdownPath = Join-Path $script:ReportPath 'validation-status.md'
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# COD3 workspace audit')
$lines.Add('')
$lines.Add("Recorded UTC: $script:AuditUtc")
$lines.Add("Project: $project")
$lines.Add('')
$lines.Add('This report separates tool readiness and build artifacts from actual game correctness. It never treats a scaffold, SDK smoke test, executable, or synthetic timing test as a working game.')
$lines.Add('')
$lines.Add('| Gate | State | Evidence / limitation |')
$lines.Add('| --- | --- | --- |')
foreach ($check in $script:Checks) { $lines.Add("| $($check.id) | **$($check.status)** | $($check.summary.Replace('|', '\|')) |") }
$lines.Add('')
$lines.Add('Detailed paths, hashes, tool output and receipt information are in validation-status.json. Acceptance requirements are in validation-acceptance.md.')
$lines.Add('')
$lines.Add('Exit 0 only means the audit completed. A requested -RequireThrough gate returns exit 2 if its prerequisite checks are unmet. Game observation stages are never automatically certified by this script.')
$lines | Set-Content -LiteralPath $markdownPath -Encoding utf8
$script:Checks | Select-Object id, status, summary | Format-Table -Wrap -AutoSize | Out-Host
Write-Host "JSON: $jsonPath"
Write-Host "Report: $markdownPath"

if ($RequireThrough -ne 'none') {
    $requirements = switch ($RequireThrough) {
        'sdk-smoke' { @('input-present', 'sdk-smoke') }
        'support-tools' { @('input-present', 'sdk-smoke', 'xenosrecomp-tool', 'xenonrecomp-tool', 'xenonanalyse-tool') }
        'extracted-xex' { @('input-present', 'sdk-smoke', 'extracted-xex') }
        'codegen-success' { @('input-present', 'sdk-smoke', 'extracted-xex', 'codegen-success') }
        'native-build' { @('input-present', 'sdk-smoke', 'native-toolchain', 'extracted-xex', 'codegen-success', 'native-build') }
    }
    $unmet = @($script:Checks | Where-Object { $_.id -in $requirements -and $_.status -ne 'PASS' })
    if ($unmet.Count -gt 0) { exit 2 }
}
exit 0
