#requires -Version 7.2

<#!
.SYNOPSIS
    Stage reproducible native Call of Duty 3 bundles without game data.

.DESCRIPTION
    Builds two deliberately separate deliverables from an already successful
    native build:

      Runtime   - cod3_pc.exe, native mission/helper DLLs, and the ReXGlue
                  runtime DLLs needed by that executable.
      Developer - source, integration code, scripts, reports, and provenance
                  needed to reproduce the build with user-owned game data.

    The allowlist is intentionally source-oriented. It never copies the ISO,
    an XEX, extracted game content, generated guest C++, shader output, debug
    symbols, compiler payloads, or user data. A SHA-256 manifest and a
    sanitized build-evidence receipt are written into each staged bundle.

    Archives use sorted paths and a fixed ZIP timestamp. The manifest itself
    omits wall-clock time so repeated staging of identical inputs has stable
    payload content. The external report records the time and archive hash.

.EXAMPLE
    .\scripts\release-package\New-Cod3Package.ps1 -Bundle Developer

.EXAMPLE
    .\scripts\release-package\New-Cod3Package.ps1 -Bundle Runtime -Force

.EXAMPLE
    .\scripts\release-package\New-Cod3Package.ps1 -Bundle Both -Force
#>

[CmdletBinding()]
param(
    [ValidateSet('Runtime', 'Developer', 'Both', 'Toolchain', 'Full')]
    [string]$Bundle = 'Both',

    [string]$WorkspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')),

    [string]$BuildDirectory = 'cod3-pc/out/build/win-amd64-relwithdebinfo',

    [string]$BuildReceipt = 'analysis/cod3-pc-native-build-receipt.json',

    [string]$OutputDirectory = 'integration/release-packaging/staging',

    [string]$ArchiveDirectory = 'integration/release-packaging/artifacts',

    [switch]$SkipArchive,

    [switch]$SkipReceiptValidation,

    # Authenticode-sign the staged payload before it is hashed and zipped, so
    # the manifest describes the signed bytes recipients actually receive.
    # Pass the thumbprint of a code-signing certificate in your personal store.
    [string]$SignWithThumbprint,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$script:OutputRoot = [IO.Path]::GetFullPath((Join-Path $script:Workspace $OutputDirectory))
$script:ArchiveRoot = [IO.Path]::GetFullPath((Join-Path $script:Workspace $ArchiveDirectory))
$script:BuildRoot = [IO.Path]::GetFullPath((Join-Path $script:Workspace $BuildDirectory))
$script:BuildReceiptPath = [IO.Path]::GetFullPath((Join-Path $script:Workspace $BuildReceipt))
$script:PolicyPath = Join-Path $script:Workspace 'integration/release-packaging/package-policy.json'
$script:LicenseManifestPath = Join-Path $script:Workspace 'integration/release-packaging/license-manifest.json'
$script:SourceDateEpoch = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Get-RelativeWorkspacePath([string]$Path) {
    return ([IO.Path]::GetRelativePath($script:Workspace, [IO.Path]::GetFullPath($Path))).Replace('\', '/')
}

function Resolve-WorkspaceInput([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $script:Workspace $Path))
}

function Assert-SafeResetTarget([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $workspace = $script:Workspace.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parent = [IO.Path]::GetDirectoryName($workspace)
    if (-not $parent) { throw "Refusing to remove a root-level path: $Path" }
    if ($full -eq $workspace -or $full -eq $parent -or $full.Length -lt 4) {
        throw "Refusing to remove a broad path: $full"
    }
}

function Reset-Directory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not $Force) {
            throw "Output already exists: $Path. Use -Force only when replacing this exact staging directory."
        }
        Assert-SafeResetTarget $Path
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Reset-File([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not $Force) {
            throw "Archive already exists: $Path. Use -Force only when replacing this exact archive."
        }
        Assert-SafeResetTarget $Path
        Remove-Item -LiteralPath $Path -Force
    }
}

function Normalize-FileTimestamp([string]$Path) {
    $utc = $script:SourceDateEpoch.UtcDateTime
    [IO.File]::SetCreationTimeUtc($Path, $utc)
    [IO.File]::SetLastAccessTimeUtc($Path, $utc)
    [IO.File]::SetLastWriteTimeUtc($Path, $utc)
}

function Copy-PayloadFile([string]$SourcePath, [string]$DestinationRoot, [string]$DestinationRelativePath) {
    $source = Resolve-WorkspaceInput $SourcePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required package input is missing: $SourcePath"
    }
    $relative = $DestinationRelativePath.Replace('\', '/').TrimStart('/')
    if (-not $relative -or $relative.Contains('..')) { throw "Invalid package destination: $DestinationRelativePath" }
    $destination = Join-Path $DestinationRoot ($relative -replace '/', '\')
    $destinationParent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Normalize-FileTimestamp $destination
    return [ordered]@{
        source = Get-RelativeWorkspacePath $source
        destination = $relative
        bytes = (Get-Item -LiteralPath $destination).Length
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
}

function Write-PayloadText([string]$DestinationRoot, [string]$RelativePath, [string]$Text) {
    $relative = $RelativePath.Replace('\', '/').TrimStart('/')
    $destination = Join-Path $DestinationRoot ($relative -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    [IO.File]::WriteAllText($destination, $Text, [Text.UTF8Encoding]::new($false))
    Normalize-FileTimestamp $destination
    return [ordered]@{
        source = $null
        destination = $relative
        bytes = (Get-Item -LiteralPath $destination).Length
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
}

function Test-NativeAmd64Pe([string]$Path) {
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
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON input is missing: $Path" }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Malformed JSON input '$Path': $($_.Exception.Message)" }
}

function Get-DeclaredReceiptArtifact($Receipt, [string]$Name) {
    return @($Receipt.runtime_artifacts | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Read-BuildEvidence {
    $receipt = $null
    if (Test-Path -LiteralPath $script:BuildReceiptPath -PathType Leaf) {
        $receipt = Read-JsonFile $script:BuildReceiptPath
    }
    if (-not $SkipReceiptValidation) {
        if ($null -eq $receipt) { throw "A successful native build receipt is required: $(Get-RelativeWorkspacePath $script:BuildReceiptPath)" }
        if ($receipt.exit_code -ne 0) { throw 'The native build receipt reports a non-zero exit code.' }
    }

    $executablePath = Join-Path $script:BuildRoot 'cod3_pc.exe'
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw "Native executable is missing: $executablePath" }
    if (-not (Test-NativeAmd64Pe $executablePath)) { throw "Native executable is not an AMD64 PE32+ image: $executablePath" }
    $executableHash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash
    if (-not $SkipReceiptValidation -and $receipt.executable_sha256 -ne $executableHash) {
        throw 'The native executable differs from the SHA-256 recorded in the successful build receipt.'
    }

    $missionFiles = @(Get-ChildItem -LiteralPath $script:BuildRoot -File -Filter 'cod3_pc_*.dll' | Sort-Object Name)
    if ($missionFiles.Count -eq 0) { throw "No native mission DLLs found in $script:BuildRoot" }
    $requiredNames = @('cod3_coroutines.dll') + @($missionFiles | ForEach-Object Name) + @('rexgpu-xenosrd.dll', 'rexruntimerd.dll', 'TracyClientrd.dll')
    $requiredNames = @($requiredNames | Sort-Object -Unique)
    $artifactRows = [Collections.Generic.List[object]]::new()
    foreach ($name in $requiredNames) {
        if ($name -match '[\\/]') { throw "Receipt or build artifact contains a path separator: $name" }
        $path = Join-Path $script:BuildRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required native runtime DLL is missing: $path" }
        if (-not (Test-NativeAmd64Pe $path)) { throw "Required native runtime DLL is not an AMD64 PE32+ image: $path" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $declared = @(Get-DeclaredReceiptArtifact $receipt $name)
        if (-not $SkipReceiptValidation -and ($declared.Count -ne 1 -or $declared[0].sha256 -ne $hash)) {
            throw "Runtime DLL '$name' differs from the successful build receipt."
        }
        $artifactRows.Add([ordered]@{
            name = $name
            path = Get-RelativeWorkspacePath $path
            bytes = (Get-Item -LiteralPath $path).Length
            sha256 = $hash
            receipt_sha256 = if ($declared.Count -eq 1) { $declared[0].sha256 } else { $null }
        })
    }

    $inputHash = if ($receipt) { [string]$receipt.input_sha256 } else { $null }
    $manifestHash = if ($receipt) { [string]$receipt.manifest_sha256 } else { $null }
    $receiptHash = if (Test-Path -LiteralPath $script:BuildReceiptPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $script:BuildReceiptPath -Algorithm SHA256).Hash
    } else { $null }
    return [ordered]@{
        validation = if ($SkipReceiptValidation) { 'skipped_by_request' } else { 'passed' }
        receipt_path = Get-RelativeWorkspacePath $script:BuildReceiptPath
        receipt_sha256 = $receiptHash
        receipt_exit_code = if ($receipt) { $receipt.exit_code } else { $null }
        configuration = if ($receipt) { $receipt.configuration } else { $null }
        input_xex_sha256 = $inputHash
        input_xex_included = $false
        manifest_sha256 = $manifestHash
        executable = [ordered]@{
            name = 'cod3_pc.exe'
            path = Get-RelativeWorkspacePath $executablePath
            bytes = (Get-Item -LiteralPath $executablePath).Length
            sha256 = $executableHash
            receipt_sha256 = if ($receipt) { $receipt.executable_sha256 } else { $null }
        }
        runtime_artifacts = $artifactRows.ToArray()
    }
}

function Get-ToolchainProvenance {
    $statusPath = Join-Path $script:Workspace 'docs/reports/toolchain-status.json'
    $status = if (Test-Path -LiteralPath $statusPath -PathType Leaf) { Read-JsonFile $statusPath } else { $null }
    $sdkVerificationPath = Join-Path $script:Workspace 'docs/reports/sdk-verification.json'
    $xenosInstallPath = Join-Path $script:Workspace 'docs/reports/xenos-install.json'
    $xenonInstallPath = Join-Path $script:Workspace 'docs/reports/xenon-install.json'
    $xeniaDepsPath = Join-Path $script:Workspace 'docs/reports/xenia-dependencies.json'
    $provenanceFiles = @($statusPath, $sdkVerificationPath, $xenosInstallPath, $xenonInstallPath, $xeniaDepsPath)

    $toolRows = [Collections.Generic.List[object]]::new()
    $toolDefinitions = @(
        [ordered]@{ id = 'clang-cl'; path = 'tools/toolchain/llvm/bin/clang-cl.exe'; class = 'build-tool'; redistributable = $false },
        [ordered]@{ id = 'cmake'; path = 'tools/cmake/bin/cmake.exe'; class = 'build-tool'; redistributable = $false },
        [ordered]@{ id = 'ninja'; path = 'tools/ninja/ninja.exe'; class = 'build-tool'; redistributable = $false },
        [ordered]@{ id = 'rexglue'; path = 'win-amd64/bin/rexglue.exe'; class = 'codegen-tool'; redistributable = 'license-review' },
        [ordered]@{ id = 'rexruntimerd'; path = 'tools/rexglue-patched-sdk/bin/rexruntimerd.dll'; class = 'sdk-runtime-input'; redistributable = 'license-review' },
        [ordered]@{ id = 'XenosRecomp'; path = 'tools/XenosRecomp/build/XenosRecomp/XenosRecomp.exe'; class = 'shader-tool'; redistributable = 'license-review' },
        [ordered]@{ id = 'XenonRecomp'; path = 'tools/XenonRecomp/out/build/windows-release/XenonRecomp/XenonRecomp.exe'; class = 'analysis-tool'; redistributable = 'license-review' },
        [ordered]@{ id = 'XenonAnalyse'; path = 'tools/XenonRecomp/out/build/windows-release/XenonAnalyse/XenonAnalyse.exe'; class = 'analysis-tool'; redistributable = 'license-review' }
    )
    foreach ($definition in $toolDefinitions) {
        $path = Resolve-WorkspaceInput $definition.path
        $present = Test-Path -LiteralPath $path -PathType Leaf
        $toolRows.Add([ordered]@{
            id = $definition.id
            path = $definition.path
            class = $definition.class
            redistributable = $definition.redistributable
            present = $present
            bytes = if ($present) { (Get-Item -LiteralPath $path).Length } else { $null }
            sha256 = if ($present) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        })
    }

    $evidenceRows = [Collections.Generic.List[object]]::new()
    foreach ($path in $provenanceFiles) {
        $present = Test-Path -LiteralPath $path -PathType Leaf
        $evidenceRows.Add([ordered]@{
            path = Get-RelativeWorkspacePath $path
            present = $present
            bytes = if ($present) { (Get-Item -LiteralPath $path).Length } else { $null }
            sha256 = if ($present) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        })
    }

    return [ordered]@{
        schema_version = 1
        source_date_epoch = $script:SourceDateEpoch.ToString('o')
        versions = if ($status) { $status.versions } else { $null }
        toolchain_status_path = if ($status) { Get-RelativeWorkspacePath $statusPath } else { $null }
        tools = $toolRows.ToArray()
        evidence_files = $evidenceRows.ToArray()
        microsoft_compiler_and_windows_sdk_payloads_included = $false
        note = 'Hashes identify local inputs used for this build. Toolchain payloads and Microsoft compiler/Windows SDK files are not copied into this bundle.'
    }
}

function Get-LicenseEntries([string]$BundleName) {
    $manifest = Read-JsonFile $script:LicenseManifestPath
    $entries = @($manifest.entries | Where-Object { $_.bundles -contains $BundleName })
    if ($entries.Count -eq 0) { throw "No license entries are defined for bundle '$BundleName'." }
    return $entries
}

function Copy-LicenseBundle([string]$BundleName, [string]$DestinationRoot) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($entry in Get-LicenseEntries $BundleName) {
        $source = Resolve-WorkspaceInput $entry.source
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            if ($entry.required -eq $true) { throw "Required license source is missing: $($entry.source)" }
            continue
        }
        $row = Copy-PayloadFile $entry.source $DestinationRoot $entry.destination
        $row['id'] = $entry.id
        $row['license'] = $entry.license
        $rows.Add($row)
    }
    return $rows.ToArray()
}

function Test-DeveloperSourcePath([string]$RelativePath) {
    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    # The SDK writes this project scaffold once, at init time; it is checked in
    # and read at configure time, long before any code generation runs. Without
    # it a package cannot configure at all, so it is not "generated output" in
    # the sense the filter below is about.
    if ($normalized -eq 'cod3-pc/generated/rexglue.cmake') { return $true }
    $segments = @($normalized -split '/')
    $forbiddenSegments = @('game', 'generated', 'out', 'build', 'cache', 'userdata', 'metadata', '__pycache__', 'staging', 'artifacts', 'artifacts-fresh', 'test-artifacts', 'xenon-generated', 'cmakefiles', 'cmakescratch', 'trycompile')
    foreach ($segment in $segments) {
        if ($forbiddenSegments -contains $segment) { return $false }
        if ($segment -match '(^|[-_])(generated|artifacts?|outputs?|results?)$') { return $false }
    }
    # The receipt is generated outside the source bundle and contains a
    # wall-clock timestamp/archive hash, so including it would make a source
    # archive change merely because packaging ran again.
    if ($normalized -match '^docs/reports/release-packaging-receipt\.(json|md)$') { return $false }
    # The test harness keeps source CMake files at the root and generated
    # configure trees below tests/build-system/*.
    if ($normalized -match '^tests/build-system/[^/]+/') { return $false }
    # Staged third-party SDK trees. They are reproduced locally by the patch
    # scripts from the pinned upstream sources and are not ours to ship.
    if ($normalized -match '^integration/vfetch-bounds/source/') { return $false }
    if ($normalized -match '^integration/upscaling/(runtime-source|overlay)/') { return $false }
    if ($normalized -match '^integration/rexglue-runtime-build/(src|probe-consumer)/') { return $false }
    if ($normalized -match '^integration/rexglue-patches/candidate/') { return $false }
    # The keyboard/mouse button art is the project's own drawing (build_icons.py
    # renders it from scratch); the launcher hands this folder to the GPU plugin.
    if ($normalized -match '^integration/button-icons/[^/]+\.(c3tex|png)$') { return $true }
    # Launcher artwork, likewise painted by launcher/assets/build_art.py (and
    # the language flags by build_flags.py).
    if ($normalized -match '^launcher/assets/(cursors/[a-z]+/)?[^/]+\.(jpg|png|cur)$') { return $true }
    $extension = [IO.Path]::GetExtension($normalized)
    $forbiddenExtensions = @('.iso', '.7z', '.zip', '.xex', '.cod', '.wbk', '.obj', '.pdb', '.dmp', '.xsh', '.xpso', '.dll', '.exe', '.lib', '.a', '.bin', '.cab', '.hlsl', '.spv', '.dxil', '.kwj')
    if ($forbiddenExtensions -contains $extension) { return $false }
    if ($extension -eq '.log' -or $extension -eq '.xml') { return $false }
    # .inl/.ipp/.tcc carry real code: tests/timebase keeps one, and toml++ ships
    # its whole implementation that way. Dropping them produced a package that
    # only failed when somebody rebuilt from it.
    $allowedExtensions = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.inc', '.inl', '.ipp', '.tcc', '.cmake', '.ps1', '.py', '.json', '.md', '.txt', '.toml', '.patch', '.in', '.natvis', '.rc', '.yml', '.yaml', '.sh', '.cmd', '.bat', '.cs', '.manifest')
    if ($allowedExtensions -contains $extension) { return $true }
    $name = [IO.Path]::GetFileName($normalized)
    return $name -in @('.gitignore', '.gitmodules', 'license', 'copying', 'notice') -or $name -match '(^|[-_])(license|copying|notice)$'
}

function Copy-DeveloperSource([string]$DestinationRoot) {
    $rows = [Collections.Generic.List[object]]::new()
    # The package root holds one thing to start: Project1944.exe (copied by
    # Copy-LauncherExe). launcher/PLAY-COD3.cmd, the fallback, comes with the
    # launcher sources; START-COD3-PC.cmd is a workspace shortcut.
    $rootFiles = @('README.md', 'LICENSE', '.gitignore')
    foreach ($rootFile in $rootFiles) {
        $rows.Add((Copy-PayloadFile $rootFile $DestinationRoot $rootFile))
    }

    $sourceRoots = @('cod3-pc', 'integration', 'launcher', 'scripts', 'tests')
    foreach ($sourceRoot in $sourceRoots) {
        $absoluteRoot = Resolve-WorkspaceInput $sourceRoot
        if (-not (Test-Path -LiteralPath $absoluteRoot -PathType Container)) { throw "Developer source root is missing: $sourceRoot" }
        foreach ($file in Get-ChildItem -LiteralPath $absoluteRoot -Recurse -File | Sort-Object FullName) {
            $relative = Get-RelativeWorkspacePath $file.FullName
            if (-not (Test-DeveloperSourcePath $relative)) { continue }
            $rows.Add((Copy-PayloadFile $relative $DestinationRoot $relative))
        }
    }

    $docsRoot = Resolve-WorkspaceInput 'docs'
    if (-not (Test-Path -LiteralPath $docsRoot -PathType Container)) { throw 'Documentation root is missing: docs' }
    foreach ($file in Get-ChildItem -LiteralPath $docsRoot -Recurse -File | Sort-Object FullName) {
        $relative = Get-RelativeWorkspacePath $file.FullName
        if (-not (Test-DeveloperSourcePath $relative)) { continue }
        $extension = [IO.Path]::GetExtension($file.Name).ToLowerInvariant()
        if ($extension -notin @('.md', '.txt', '.json')) { continue }
        $rows.Add((Copy-PayloadFile $relative $DestinationRoot $relative))
    }

    $sourceLock = Resolve-WorkspaceInput 'analysis/disc-source-lock.json'
    if (Test-Path -LiteralPath $sourceLock -PathType Leaf) {
        $rows.Add((Copy-PayloadFile 'analysis/disc-source-lock.json' $DestinationRoot 'analysis/disc-source-lock.json'))
    }
    # The per-file list of the verified disc: path, size, MD5 and SHA-256 of
    # every file, no game bytes. scripts/copy-cod3-game.ps1 checks a game the
    # player unpacked themselves, or a Games on Demand package, against it.
    $discManifest = Resolve-WorkspaceInput 'analysis/disc-file-manifest.csv'
    if (Test-Path -LiteralPath $discManifest -PathType Leaf) {
        $rows.Add((Copy-PayloadFile 'analysis/disc-file-manifest.csv' $DestinationRoot 'analysis/disc-file-manifest.csv'))
    }
    # Code generation keeps a partition sidecar per image: which output file
    # each guest function goes to (addresses and file numbers, no code). It
    # reuses it, so the recompiled C++ comes out split exactly as the code the
    # ready-made build was compiled from - otherwise a fresh split produces the
    # same functions in different files, and nothing could be compared.
    foreach ($partition in @(Get-ChildItem -LiteralPath (Resolve-WorkspaceInput 'cod3-pc/generated') -Recurse -File -Filter 'codegen.partition.json')) {
        $relative = Get-RelativeWorkspacePath $partition.FullName
        $rows.Add((Copy-PayloadFile $relative $DestinationRoot $relative))
    }
    # The coroutine map generator and its identity manifest (paths, names,
    # hashes, bases - no game bytes). The map itself records guest instruction
    # words, so it is rebuilt from the user's own modules and never shipped.
    foreach ($analysisInput in @('analysis/cod3-allmodule-coroutine-sites.py', 'analysis/cod3-allmodule-coroutine-manifest.json')) {
        $rows.Add((Copy-PayloadFile $analysisInput $DestinationRoot $analysisInput))
    }
    return $rows.ToArray()
}

function Test-SdkSourcePath([string]$RelativePath) {
    # The SDK source ships as the complete corresponding source of the bundled
    # rexglue.exe (GPL-2.0-or-later through the binutils disassembler) and so
    # the recipient can rebuild it. Source only: no build products, and none
    # of the prebuilt GNU binutils executables the SDK keeps under
    # tools/binutils (GPL binaries whose corresponding source is not part of
    # this workspace).
    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    foreach ($segment in ($normalized -split '/')) {
        if ($segment -in @('.git', '.vs', '__pycache__')) { return $false }
    }
    if ($normalized.StartsWith('tools/binutils/')) { return $false }
    $extension = [IO.Path]::GetExtension($normalized)
    if ($extension -in @('.exe', '.dll', '.lib', '.pdb', '.obj', '.a', '.so', '.dylib', '.ilk', '.exp')) { return $false }
    return $true
}

function Copy-SdkSource([string]$DestinationRoot) {
    $sourceRoot = Resolve-WorkspaceInput 'tools/rexglue-source'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw 'ReXGlue SDK source tree is missing: tools/rexglue-source'
    }
    $copied = 0
    $bytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | Sort-Object FullName) {
        $relative = ([IO.Path]::GetRelativePath($sourceRoot, $file.FullName)).Replace('\', '/')
        if (-not (Test-SdkSourcePath $relative)) { continue }
        $destination = Join-Path $DestinationRoot ('sdk-source\' + ($relative -replace '/', '\'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        Normalize-FileTimestamp $destination
        $copied++
        $bytes += $file.Length
    }
    if ($copied -eq 0) { throw 'SDK source payload is empty after filtering.' }
    return @(, [ordered]@{
        source = 'tools/rexglue-source'
        destination = 'sdk-source/'
        bytes = $bytes
        sha256 = $null
        note = "ReXGlue SDK source: $copied files, prebuilt binutils executables and build products excluded."
    })
}

function Copy-LgplSources([string]$DestinationRoot) {
    # rexruntimerd.dll statically links FFmpeg and libmspack, both LGPL-2.1.
    # Section 6 of that license gives the recipient the right to modify either
    # library and relink the runtime, which means the source has to accompany
    # the binaries. A single tester archive is only complete if it carries them
    # itself instead of relying on a companion file travelling alongside.
    $rows = [Collections.Generic.List[object]]::new()
    $roots = @(
        @{ Source = 'integration/rexglue-runtime-build/src/thirdparty/FFmpeg'; Destination = 'lgpl-sources/FFmpeg' },
        @{ Source = 'integration/rexglue-runtime-build/src/thirdparty/libmspack'; Destination = 'lgpl-sources/libmspack' }
    )
    foreach ($entry in $roots) {
        $absolute = Resolve-WorkspaceInput $entry.Source
        if (-not (Test-Path -LiteralPath $absolute -PathType Container)) {
            throw "LGPL corresponding-source root is missing: $($entry.Source)"
        }
        $copied = 0
        $bytes = 0
        foreach ($file in Get-ChildItem -LiteralPath $absolute -Recurse -File -Force | Sort-Object FullName) {
            $relative = ([IO.Path]::GetRelativePath($absolute, $file.FullName)).Replace('\', '/')
            $normalized = $relative.ToLowerInvariant()
            if (@($normalized -split '/') -contains '.git') { continue }
            $extension = [IO.Path]::GetExtension($normalized)
            # Build products and disc inputs only; a library's own test corpus
            # is part of its source and stays.
            if ($extension -in @('.exe', '.dll', '.pdb', '.obj', '.o', '.so', '.dylib', '.iso', '.xex')) { continue }
            $destination = Join-Path $DestinationRoot (($entry.Destination + '/' + $relative) -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            Normalize-FileTimestamp $destination
            $copied++
            $bytes += $file.Length
        }
        if ($copied -eq 0) { throw "LGPL corresponding-source root produced no files: $($entry.Source)" }
        $rows.Add([ordered]@{
            source = $entry.Source
            destination = $entry.Destination + '/'
            bytes = $bytes
            sha256 = $null
            note = "LGPL-2.1 corresponding source: $copied files."
        })
    }
    $rows.Add((Write-PayloadText $DestinationRoot 'lgpl-sources/README.txt' @'
Corresponding source for the LGPL libraries inside rexruntimerd.dll
===================================================================

FFmpeg (libavcodec, libavutil), LGPL-2.1-or-later, and libmspack, LGPL-2.1,
are statically linked into the ReXGlue runtime this package ships. Section 6
of the LGPL gives you the right to modify either library and relink the runtime
against your modified version, so these are the exact trees the shipped runtime
was built from.

FFmpeg here is configured with CONFIG_GPL 0, CONFIG_NONFREE 0 and
CONFIG_VERSION3 0: no GPL-only or version-3-only component is present.

The "work that uses the library" - the ReXGlue SDK source that produces the
runtime - is in sdk-source/ beside this directory, and the scripts that build
it are under integration/ and tools/. Together they make the relink possible in
practice, not only in principle.

License texts: licenses/ffmpeg/ and licenses/libmspack/.
Full component inventory: THIRD-PARTY-NOTICES.md.
'@))
    return $rows.ToArray()
}

function Copy-BundledToolchain([string]$DestinationRoot) {
    # The build tools the licenses allow us to carry, staged under
    # tools/toolchain-bundle so a rebuild does not have to download them.
    # LLVM publishes one driver binary under several names and decides what to
    # be from argv[0]; storing it once and recreating the names at install
    # time is the difference between 300 MB and 700 MB.
    $specPath = Resolve-WorkspaceInput 'tools/toolchain-provision/bundle-spec.json'
    if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) { throw "Bundle spec is missing: $specPath" }
    $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $rows = [Collections.Generic.List[object]]::new()
    $summary = [Collections.Generic.List[object]]::new()
    foreach ($name in $spec.components.PSObject.Properties.Name) {
        $component = $spec.components.$name
        $sourceRoot = Resolve-WorkspaceInput $component.source
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            throw "Bundled toolchain component '$name' is missing from the workspace: $($component.source)"
        }
        $stageRoot = Join-Path $DestinationRoot ("tools\toolchain-bundle\" + $name)
        $copied = 0
        $bytes = 0
        $skipped = [Collections.Generic.List[string]]::new()

        $wanted = [Collections.Generic.List[string]]::new()
        foreach ($file in @($component.files)) { if ($file) { $wanted.Add($file) } }
        foreach ($tree in @($component.trees)) {
            if (-not $tree) { continue }
            $treeRoot = if ($tree -eq '.') { $sourceRoot } else { Join-Path $sourceRoot ($tree -replace '/', '\') }
            if (-not (Test-Path -LiteralPath $treeRoot -PathType Container)) { throw "Bundled tree is missing: $treeRoot" }
            foreach ($item in Get-ChildItem -LiteralPath $treeRoot -Recurse -File -Force) {
                $relative = ([IO.Path]::GetRelativePath($sourceRoot, $item.FullName)).Replace('\', '/')
                $excluded = $false
                $excludeTrees = if ($component.PSObject.Properties.Name -contains 'exclude_trees') { @($component.exclude_trees) } else { @() }
                foreach ($exclude in $excludeTrees) {
                    if ($exclude -and $relative.StartsWith(($exclude.TrimEnd('/') + '/'), [StringComparison]::OrdinalIgnoreCase)) { $excluded = $true; break }
                }
                foreach ($segment in ($relative.ToLowerInvariant() -split '/')) {
                    if ($segment -in @('__pycache__', '.git')) { $excluded = $true; break }
                }
                if (-not $excluded) { $wanted.Add($relative) }
            }
        }

        foreach ($relative in ($wanted | Select-Object -Unique)) {
            $source = Join-Path $sourceRoot ($relative -replace '/', '\')
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                $skipped.Add($relative)
                continue
            }
            $destination = Join-Path $stageRoot ($relative -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Normalize-FileTimestamp $destination
            $copied++
            $bytes += (Get-Item -LiteralPath $source).Length
        }
        if ($copied -eq 0) { throw "Bundled toolchain component '$name' produced no files." }

        $probe = Join-Path $stageRoot ($component.probe -replace '/', '\')
        $aliasTargets = @($component.aliases.PSObject.Properties | ForEach-Object { $_.Name })
        if (-not (Test-Path -LiteralPath $probe -PathType Leaf) -and ($aliasTargets -notcontains $component.probe)) {
            throw "Bundled component '$name' does not contain its probe file $($component.probe) and no alias provides it."
        }
        $summary.Add([ordered]@{
            component = $name
            files = $copied
            bytes = $bytes
            aliases = $aliasTargets.Count
            skipped = $skipped.ToArray()
        })
        $rows.Add([ordered]@{
            source = $component.source
            destination = "tools/toolchain-bundle/$name/"
            bytes = $bytes
            sha256 = $null
            note = "$copied files, $($aliasTargets.Count) aliases recreated on install."
        })
    }

    $rows.Add((Copy-PayloadFile 'tools/toolchain-provision/bundle-spec.json' $DestinationRoot 'tools/toolchain-bundle/bundle-spec.json'))
    # Measure-Object cannot read a property off an ordered dictionary.
    $totals = 0
    foreach ($entry in $summary) { $totals += [int64]$entry.bytes }
    $rows.Add((Write-PayloadText $DestinationRoot 'tools/toolchain-bundle/README.txt' @"
Build tools carried in this package
===================================

Install-Toolchain.ps1 installs from here instead of downloading. Each
component is the same build the project itself uses.

What is here and why it may be: Clang/LLVM (Apache-2.0 WITH LLVM-exception),
CMake (BSD-3-Clause), Ninja (Apache-2.0), xdvdfs (MIT), uv (MIT OR
Apache-2.0), CPython (PSF-2.0) and the two Python extension modules the disc
image analysis imports. All of them permit redistribution.

What is NOT here, and cannot be: MSVC and the Windows SDK. Microsoft's license
forbids redistributing them at any size, so the rebuild fetches those from
Microsoft's own servers - or reuses a Visual Studio you already have, which
Install-Toolchain.ps1 looks for first. That download is the only one left.

LLVM ships one driver binary under four names, and one linker under several.
They are stored once here; the other names are recreated as hard links when
the component is installed, which is why bin/ looks larger after install than
it does in this archive.

Total staged: $([math]::Round($totals / 1MB)) MB.
"@))
    return $rows.ToArray()
}

function Test-ToolSourcePath([string]$RelativePath) {
    # These are third-party or vendored source trees that have to compile after
    # extraction, so the rule is "everything except build products". An
    # allowlist of extensions silently drops whatever it has not heard of -
    # toml++ ships its implementation as .inl, and losing those turned into a
    # compile failure only once someone rebuilt from a package.
    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    foreach ($segment in ($normalized -split '/')) {
        if ($segment -in @('.git', '.vs', '__pycache__', 'node_modules', 'out', 'build', 'staging', 'downloads')) { return $false }
    }
    $extension = [IO.Path]::GetExtension($normalized)
    if ($extension -in @('.exe', '.dll', '.lib', '.pdb', '.obj', '.o', '.a', '.so', '.dylib', '.ilk', '.exp', '.res',
                         '.iso', '.xex', '.cod', '.wbk', '.7z')) { return $false }
    return $true
}

function Copy-ProvisioningTools([string]$DestinationRoot) {
    # Everything needed to obtain the components the packages cannot carry: the
    # CLI build harness, the toolchain provisioner, the signing helpers, the
    # vendored PortableMSVC sources and XenonRecomp.
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($toolRoot in @('tools/rexglue-cli', 'tools/toolchain-provision', 'tools/toolchain-bootstrap',
                            'tools/xenon-bridge-build', 'tools/signing', 'tools/XenonRecomp')) {
        $absolute = Resolve-WorkspaceInput $toolRoot
        if (-not (Test-Path -LiteralPath $absolute -PathType Container)) { throw "Provisioning tool root is missing: $toolRoot" }
        $copied = 0
        $bytes = 0
        foreach ($file in Get-ChildItem -LiteralPath $absolute -Recurse -File -Force | Sort-Object FullName) {
            $relative = Get-RelativeWorkspacePath $file.FullName
            $withinRoot = $relative.Substring($toolRoot.Length).TrimStart('/')
            if (-not (Test-ToolSourcePath $withinRoot)) { continue }
            $destination = Join-Path $DestinationRoot ($relative -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            Normalize-FileTimestamp $destination
            $copied++
            $bytes += $file.Length
        }
        if ($copied -eq 0) { throw "Provisioning tool root produced no files: $toolRoot" }
        $rows.Add([ordered]@{
            source = $toolRoot
            destination = $toolRoot + '/'
            bytes = $bytes
            sha256 = $null
            note = "$copied files, build products excluded."
        })
    }
    # XenonAnalyse and XenonRecomp themselves, built from tools/XenonRecomp
    # as shipped (MIT, with the GNU binutils PowerPC disassembler, so the two
    # executables are GPL-2.0-or-later; their source is right beside them).
    # Built, a recompilation regenerates the Xenon bridge without a compiler.
    foreach ($tool in @('XenonAnalyse/XenonAnalyse.exe', 'XenonRecomp/XenonRecomp.exe')) {
        $relative = "tools/XenonRecomp/out/build/windows-release/$tool"
        $source = Resolve-WorkspaceInput $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "XenonRecomp is not built: $relative" }
        $newestSource = Get-ChildItem -LiteralPath (Resolve-WorkspaceInput 'tools/XenonRecomp') -Recurse -File |
            Where-Object { $_.FullName -notmatch '\\out\\' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newestSource.LastWriteTime -gt (Get-Item -LiteralPath $source).LastWriteTime) {
            throw "$relative is older than its source ($($newestSource.Name)); rebuild XenonRecomp first."
        }
        $rows.Add((Copy-PayloadFile $relative $DestinationRoot $relative))
    }
    return $rows.ToArray()
}

function Test-RexGlueSdkPath([string]$RelativePath) {
    # The SDK is BSD-3-Clause and may be redistributed, but two parts are
    # pruned. rexglue.exe statically links the GNU binutils PowerPC
    # disassembler (GPL-2.0-or-later), so shipping it would put the whole
    # executable under the GPL; the recipient supplies it from their own SDK
    # install. Debug and Release configurations are dropped because the port
    # builds RelWithDebInfo only - their CMake target files go with them so
    # CMake's imported-file check stays satisfied.
    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    if ($normalized -eq 'bin/rexglue.exe') { return $false }
    if ($normalized.EndsWith('-debug.cmake') -or $normalized.EndsWith('-release.cmake')) { return $false }
    $extension = [IO.Path]::GetExtension($normalized)
    if ($extension -eq '.pdb') { return $false }
    if ($extension -in @('.lib', '.dll', '.exe')) {
        $base = [IO.Path]::GetFileNameWithoutExtension($normalized)
        if ($base -notmatch 'rd$') { return $false }
    }
    return $true
}

function Copy-RexGlueSdk([string]$DestinationRoot) {
    $sdkRoot = Resolve-WorkspaceInput 'win-amd64'
    if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
        throw 'ReXGlue SDK root is missing: win-amd64'
    }
    $copied = 0
    $bytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $sdkRoot -Recurse -File | Sort-Object FullName) {
        $relative = ([IO.Path]::GetRelativePath($sdkRoot, $file.FullName)).Replace('\', '/')
        if (-not (Test-RexGlueSdkPath $relative)) { continue }
        $destination = Join-Path $DestinationRoot ('win-amd64\' + ($relative -replace '/', '\'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        Normalize-FileTimestamp $destination
        $copied++
        $bytes += $file.Length
    }
    if ($copied -eq 0) { throw 'ReXGlue SDK payload is empty after pruning.' }
    # rexglue.exe as built from the SDK source this package carries
    # (tools/rexglue-cli/Build-RexGlueCli.ps1 over sdk-source), not the SDK
    # vendor's binary: GPL-2.0-or-later requires the corresponding source to
    # travel with it, and sdk-source/ is exactly that source.
    $cliReceiptPath = Resolve-WorkspaceInput 'tools/rexglue-cli/build-receipt.json'
    $cliBinary = Resolve-WorkspaceInput 'tools/rexglue-cli/build/RelWithDebInfo/rexglue.exe'
    if (-not (Test-Path -LiteralPath $cliReceiptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $cliBinary -PathType Leaf)) {
        throw 'rexglue.exe has not been built from the SDK source; run tools/rexglue-cli/Build-RexGlueCli.ps1 first.'
    }
    $cliReceipt = Read-JsonFile $cliReceiptPath
    if ((Get-FileHash -LiteralPath $cliBinary -Algorithm SHA256).Hash -ne ([string]$cliReceipt.sha256).ToUpperInvariant()) {
        throw 'tools/rexglue-cli/build/RelWithDebInfo/rexglue.exe does not match its build receipt.'
    }
    $cliDestination = Join-Path $DestinationRoot 'win-amd64\bin\rexglue.exe'
    Copy-Item -LiteralPath $cliBinary -Destination $cliDestination -Force
    Normalize-FileTimestamp $cliDestination
    $copied++
    $bytes += (Get-Item -LiteralPath $cliBinary).Length
    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add((Write-PayloadText $DestinationRoot 'win-amd64/SDK-PRUNING.txt' @'
ReXGlue SDK, redistributed under its BSD-3-Clause license, with one change
and one removal.

1. bin/rexglue.exe is the code generator built from the SDK source in this
   package (sdk-source/, by tools/rexglue-cli/Build-RexGlueCli.ps1), not the
   SDK vendor's binary. It statically links the PowerPC disassembler from GNU
   binutils (thirdparty/disasm, GPL-2.0-or-later), so this executable as a
   whole is distributed under the GPL-2.0-or-later. Its complete corresponding
   source is sdk-source/ in this same archive, with the build script above;
   the GPL-2.0 text is in licenses/gnu-binutils/. It ships built so that a
   recompilation needs no compiler when its output matches the ready-made
   build (scripts/complete-recompile.ps1).

2. Debug and Release configurations are removed. Only RelWithDebInfo import
   libraries, DLLs and CMake target files are present, matching the
   configuration the port builds. The corresponding *-debug.cmake and
   *-release.cmake files were removed with them, so CMake's imported-target
   file check remains satisfied.

lib/disasmrd.lib is present and is GPL-2.0-or-later as a separate work; the
port links nothing against it. Its corresponding source ships in
cod3-pc-sdk-sources.zip, and the GPL-2.0 text is in licenses/gnu-binutils/.

See THIRD-PARTY-NOTICES.md for the full component list and licenses/ for the
license texts.
'@))
    $rows.Add([ordered]@{
        source = 'win-amd64'
        destination = 'win-amd64/'
        bytes = $bytes
        sha256 = $null
        note = "ReXGlue SDK payload: $copied files, rexglue.exe built from sdk-source, Debug/Release configurations pruned."
    })
    return $rows.ToArray()
}

function Assert-NoForbiddenPayload([string]$DestinationRoot) {
    $forbidden = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $DestinationRoot -Recurse -File) {
        $relative = ([IO.Path]::GetRelativePath($DestinationRoot, $file.FullName)).Replace('\', '/')
        $lower = $relative.ToLowerInvariant()
        # The checked-in files under generated/: the SDK's project scaffold and
        # the codegen partition sidecars (addresses and file numbers only).
        if ($lower -eq 'cod3-pc/generated/rexglue.cmake') { continue }
        if ($lower -match '^cod3-pc/generated/[a-z0-9_]+/codegen\.partition\.json$') { continue }

        # Shipped third-party trees are not this project's output. Their
        # directory names are upstream's business - pip really does ship
        # _internal/metadata and operations/build - and the generated-artifact
        # extension ban does not apply either. Game inputs stay banned
        # everywhere, which is what the check is actually for.
        $thirdPartyTree = $lower.StartsWith('sdk-source/') -or $lower.StartsWith('lgpl-sources/') -or
                          $lower.StartsWith('tools/xenonrecomp/') -or $lower.StartsWith('tools/toolchain-bootstrap/') -or
                          $lower.StartsWith('tools/toolchain-bundle/')
        if (-not $thirdPartyTree) {
            $segments = @($lower -split '/')
            if ($segments | Where-Object { $_ -in @('game', 'generated', 'out', 'build', 'cache', 'userdata', 'metadata', '__pycache__', 'staging', 'artifacts') }) {
                $forbidden.Add($relative)
                continue
            }
        }
        $banned = if ($thirdPartyTree) {
            @('.iso', '.7z', '.zip', '.xex', '.cod', '.wbk', '.dmp', '.xsh', '.xpso')
        } else {
            @('.iso', '.7z', '.zip', '.xex', '.cod', '.wbk', '.obj', '.pdb', '.dmp', '.xsh', '.xpso', '.bin', '.cab', '.hlsl', '.spv', '.dxil', '.kwj')
        }
        if ([IO.Path]::GetExtension($lower) -in $banned) {
            $forbidden.Add($relative)
        }
    }
    if ($forbidden.Count -gt 0) {
        throw "Package contains forbidden game/generated/build content: $($forbidden -join ', ')"
    }
    return $true
}

function Write-DeterministicZip([string]$SourceDirectory, [string]$ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Reset-File $ArchivePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $ArchivePath) -Force | Out-Null
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Sort-Object FullName) {
            $relative = ([IO.Path]::GetRelativePath($SourceDirectory, $file.FullName)).Replace('\', '/')
            $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $script:SourceDateEpoch
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try { $input.CopyTo($output) }
            finally { $output.Dispose(); $input.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
        $stream.Dispose()
    }
    Normalize-FileTimestamp $ArchivePath
    return [ordered]@{
        path = Get-RelativeWorkspacePath $ArchivePath
        bytes = (Get-Item -LiteralPath $ArchivePath).Length
        sha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    }
}

function Get-PayloadRows([string]$DestinationRoot) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $DestinationRoot -Recurse -File | Sort-Object FullName) {
        $relative = ([IO.Path]::GetRelativePath($DestinationRoot, $file.FullName)).Replace('\', '/')
        if ($relative -eq 'package-manifest.json') { continue }
        $rows.Add([ordered]@{
            path = $relative
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        })
    }
    return $rows.ToArray()
}

function Write-CommonBundleFiles([string]$BundleName, [string]$DestinationRoot, $BuildEvidence, $Toolchain) {
    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/THIRD-PARTY-NOTICES.md' $DestinationRoot 'THIRD-PARTY-NOTICES.md'))
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/TOOLCHAIN-BOUNDARIES.md' $DestinationRoot 'TOOLCHAIN-BOUNDARIES.md'))
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/package-policy.json' $DestinationRoot 'package-policy.json'))
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/license-manifest.json' $DestinationRoot 'license-manifest.json'))
    $rows.AddRange(@(Copy-LicenseBundle $BundleName $DestinationRoot))
    $evidenceText = $BuildEvidence | ConvertTo-Json -Depth 12
    $rows.Add((Write-PayloadText $DestinationRoot 'build-evidence.json' ($evidenceText + "`n")))
    $toolchainText = $Toolchain | ConvertTo-Json -Depth 12
    $rows.Add((Write-PayloadText $DestinationRoot 'toolchain-provenance.json' ($toolchainText + "`n")))
    return $rows.ToArray()
}

function Invoke-PayloadSigning([string]$DestinationRoot) {
    # Signing has to happen before the manifest is written: a signature changes
    # the bytes, so hashing first would describe files nobody receives.
    if (-not $SignWithThumbprint) { return }
    $signer = Resolve-WorkspaceInput 'tools/signing/Set-Cod3Signature.ps1'
    if (-not (Test-Path -LiteralPath $signer -PathType Leaf)) { throw "Signing script is missing: $signer" }
    Write-Host "Signing staged payload with certificate $SignWithThumbprint"
    & $signer -CertificateThumbprint $SignWithThumbprint -Root $DestinationRoot -IncludeBinaries
    $receipt = Join-Path $DestinationRoot 'signing-receipt.json'
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { throw 'Signing produced no receipt; refusing to package an unsigned payload after -SignWithThumbprint was requested.' }
    $summary = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($summary.failed_count -gt 0) { throw "Signing failed for $($summary.failed_count) file(s); see $receipt" }
    Write-Host "  signed $($summary.signed_count) files"
}

function Write-ManifestAndReport(
    [string]$BundleName,
    [string]$DestinationRoot,
    [string]$ArchivePath,
    $BuildEvidence,
    $Toolchain,
    $CopiedRows
) {
    Assert-NoForbiddenPayload $DestinationRoot | Out-Null
    Invoke-PayloadSigning $DestinationRoot
    $payloadRows = Get-PayloadRows $DestinationRoot
    $licenseManifest = Read-JsonFile $script:LicenseManifestPath
    $licenseRows = [Collections.Generic.List[object]]::new()
    $licenseBundleName = if ($BundleName -eq 'toolchain') { 'developer' } else { $BundleName }
    foreach ($entry in @($licenseManifest.entries | Where-Object { $_.bundles -contains $licenseBundleName })) {
        $licensePath = Join-Path $DestinationRoot ($entry.destination -replace '/', '\\')
        if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
            throw "License manifest entry was not staged: $($entry.destination)"
        }
        $licenseRows.Add([ordered]@{
            id = $entry.id
            destination = $entry.destination
            license = $entry.license
            sha256 = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash
        })
    }
    $manifest = [ordered]@{
        schema_version = 1
        bundle = $BundleName
        platform = 'windows-amd64'
        source_date_epoch = $script:SourceDateEpoch.ToString('o')
        game_data_included = $false
        generated_guest_code_included = $false
        shader_cache_included = $false
        debug_symbols_included = $false
        compiler_payloads_included = $false
        input_xex_sha256 = if ($BuildEvidence) { $BuildEvidence.input_xex_sha256 } else { $null }
        input_xex_included = $false
        native_build_receipt_sha256 = if ($BuildEvidence) { $BuildEvidence.receipt_sha256 } else { $null }
        native_executable_sha256 = if ($BuildEvidence) { $BuildEvidence.executable.sha256 } else { $null }
        license_files = $licenseRows.ToArray()
        payload_files = $payloadRows
        note = 'This manifest describes a native host/runtime or source bundle. It does not certify game boot, gameplay, renderer correctness, physics invariance, or 120 FPS.'
    }
    $manifestText = $manifest | ConvertTo-Json -Depth 20
    Write-PayloadText $DestinationRoot 'package-manifest.json' ($manifestText + "`n") | Out-Null
    Assert-NoForbiddenPayload $DestinationRoot | Out-Null
    $archive = $null
    if (-not $SkipArchive) {
        $archive = Write-DeterministicZip $DestinationRoot $ArchivePath
    }
    return [ordered]@{
        name = $BundleName
        staging_path = Get-RelativeWorkspacePath $DestinationRoot
        manifest_path = (Get-RelativeWorkspacePath (Join-Path $DestinationRoot 'package-manifest.json'))
        manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $DestinationRoot 'package-manifest.json') -Algorithm SHA256).Hash
        payload_file_count = @($payloadRows).Count
        archive = $archive
    }
}

function New-ToolchainBundle([string]$DestinationRoot) {
    $toolchain = Get-ToolchainProvenance
    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/TOOLCHAIN-BOUNDARIES.md' $DestinationRoot 'TOOLCHAIN-BOUNDARIES.md'))
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/package-policy.json' $DestinationRoot 'package-policy.json'))
    $rows.Add((Copy-PayloadFile 'integration/release-packaging/license-manifest.json' $DestinationRoot 'license-manifest.json'))
    $rows.AddRange(@(Copy-LicenseBundle 'developer' $DestinationRoot))
    $rows.Add((Write-PayloadText $DestinationRoot 'README.txt' @'
This is a toolchain provenance bundle, not a compiler distribution.

It records versions and SHA-256 values for the local build/code-generation
inputs. Compiler payloads, the MSVC installation, the Windows SDK, the ISO,
extracted game data, generated guest code, and user data are intentionally not
included. Obtain each tool under its own applicable license and place it where
the developer setup instructions expect it.
'@))
    $rows.Add((Write-PayloadText $DestinationRoot 'toolchain-provenance.json' (($toolchain | ConvertTo-Json -Depth 12) + "`n")))
    Assert-NoForbiddenPayload $DestinationRoot | Out-Null
    return @{ rows = $rows.ToArray(); evidence = $toolchain }
}

function New-NativeRuntimeBundle([string]$DestinationRoot, $BuildEvidence, $Toolchain) {
    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add((Copy-PayloadFile $BuildEvidence.executable.path $DestinationRoot 'cod3_pc.exe'))
    foreach ($artifact in $BuildEvidence.runtime_artifacts) {
        $rows.Add((Copy-PayloadFile $artifact.path $DestinationRoot $artifact.name))
    }
    # Tester launcher: a GUI over the same command line, plus the tester and
    # control documentation. It contains no game data and no game paths.
    $rows.Add((Copy-LauncherExe $DestinationRoot))
    $rows.Add((Copy-PayloadFile 'launcher/PLAY-COD3.cmd' $DestinationRoot 'launcher/PLAY-COD3.cmd'))
    $rows.Add((Copy-PayloadFile 'launcher/Cod3Launcher.ps1' $DestinationRoot 'launcher/Cod3Launcher.ps1'))
    # The launcher's translations (en, uk, be, es, de); without the file it
    # simply stays in Russian.
    $rows.Add((Copy-PayloadFile 'launcher/strings.json' $DestinationRoot 'launcher/strings.json'))
    # Language flags, painted by launcher/assets/build_flags.py.
    foreach ($art in @('hero.jpg', 'emblem.png', 'flag-en.png', 'flag-uk.png', 'flag-be.png', 'flag-es.png', 'flag-de.png')) {
        $rows.Add((Copy-PayloadFile "launcher/assets/$art" $DestinationRoot "launcher/assets/$art"))
    }
    # Mouse pointers for the launcher and the game window (both read them from
    # launcher/assets/cursors).
    foreach ($cursor in @(Get-ChildItem -LiteralPath (Resolve-WorkspaceInput 'launcher/assets/cursors') -Recurse -File |
                         Where-Object { $_.Extension -in @('.cur', '.png') })) {
        $relative = Get-RelativeWorkspacePath $cursor.FullName
        $rows.Add((Copy-PayloadFile $relative $DestinationRoot $relative))
    }
    foreach ($icons in @(Get-ChildItem -LiteralPath (Resolve-WorkspaceInput 'integration/button-icons') -Filter '*.c3tex' -File)) {
        $relative = 'integration/button-icons/' + $icons.Name
        $rows.Add((Copy-PayloadFile $relative $DestinationRoot $relative))
    }
    $rows.Add((Copy-PayloadFile 'docs/testers.md' $DestinationRoot 'docs/testers.md'))
    $rows.Add((Copy-PayloadFile 'docs/controls.md' $DestinationRoot 'docs/controls.md'))
    $rows.Add((Copy-PayloadFile 'docs/legal.md' $DestinationRoot 'docs/legal.md'))
    $rows.AddRange(@(Write-CommonBundleFiles 'runtime' $DestinationRoot $BuildEvidence $Toolchain))
    $rows.Add((Write-PayloadText $DestinationRoot 'README.txt' @'
Call of Duty 3 native runtime bundle (Windows AMD64)

Start with Project1944.exe: it opens the launcher, where the game data folder is
selected and the installation is verified. docs/testers.md has the details.

This bundle contains the native host and ReXGlue runtime DLLs only. It does
not contain Call of Duty 3 data. Supply a legally obtained, user-owned game
data tree separately and pass its path as --game_data_root, or place it under
game/cod3 beside this executable when using the developer launcher.

The runtime statically links FFmpeg and libmspack, which are LGPL-2.1. The
companion archive cod3-pc-sdk-sources.zip in the same release carries their
complete sources and the SDK sources that build the runtime, so it can be
relinked against a modified library. Keep the two files together when passing
this bundle on. docs/legal.md and THIRD-PARTY-NOTICES.md have the details.

The included binaries are a RelWithDebInfo native build. The manifest records
the source XEX hash for identity checking; the XEX bytes are not included.

Host presentation options such as 1920x1080 do not establish a 120 FPS game
simulation or physics result. Review the project's timing evidence before
making a frame-rate claim.
'@))
    return $rows.ToArray()
}

function Copy-LauncherExe([string]$DestinationRoot) {
    # Project1944.exe, built by launcher/exe/Build-LauncherExe.ps1: it hosts
    # launcher/Cod3Launcher.ps1 in-process and is what a player double-clicks.
    $exe = Resolve-WorkspaceInput 'launcher/exe/bin/Project1944.exe'
    $receiptPath = Resolve-WorkspaceInput 'launcher/exe/bin/build-receipt.json'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Project1944.exe is not built; run launcher/exe/Build-LauncherExe.ps1 first.'
    }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne [string](Read-JsonFile $receiptPath).sha256) {
        throw 'launcher/exe/bin/Project1944.exe does not match its build receipt.'
    }
    foreach ($source in @('Project1944.cs', 'Project1944.manifest')) {
        if ((Get-Item -LiteralPath (Resolve-WorkspaceInput "launcher/exe/$source")).LastWriteTimeUtc -gt (Get-Item -LiteralPath $exe).LastWriteTimeUtc) {
            throw "launcher/exe/$source is newer than Project1944.exe; rebuild it with Build-LauncherExe.ps1."
        }
    }
    return (Copy-PayloadFile 'launcher/exe/bin/Project1944.exe' $DestinationRoot 'Project1944.exe')
}

function Write-RecompileReference([string]$DestinationRoot, $BuildEvidence) {
    # What the ready-made build was compiled from, as SHA-256 hashes only: the
    # generated C++ (from the workspace, where it was compiled) and the port
    # sources (as staged). scripts/complete-recompile.ps1 compares a tester's
    # fresh recompilation against it; when both match, the ready-made binaries
    # are exactly what compiling would produce and nothing is compiled.
    . (Join-Path $script:Workspace 'scripts\recompile-reference.ps1')
    $generated = @(Get-RecompileGeneratedFiles $script:Workspace)
    if ($generated.Count -eq 0) { throw 'No generated code in the workspace to record a recompilation reference from.' }
    # The shipped binaries must come from exactly this generated code.
    $executable = Resolve-WorkspaceInput $BuildEvidence.executable.path
    $newest = $generated | ForEach-Object { (Get-Item -LiteralPath (Join-Path $script:Workspace ($_ -replace '/', '\'))).LastWriteTimeUtc } |
        Sort-Object -Descending | Select-Object -First 1
    if ($newest -gt (Get-Item -LiteralPath $executable).LastWriteTimeUtc) {
        throw 'Generated code is newer than the built executable; build the game before packaging.'
    }
    $binaries = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $DestinationRoot -File | Where-Object { $_.Extension -in @('.exe', '.dll') } | Sort-Object Name) {
        $binaries[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $reference = [ordered]@{
        schema_version = 1
        purpose = 'SHA-256 of the code the ready-made build in this package was compiled from - the C++ generated from the supported game revision and the port sources. Hashes only, no code. scripts/complete-recompile.ps1 compares a recompilation against it.'
        binaries = $binaries
        sources = Get-RecompileHashes $DestinationRoot @(Get-RecompileSourceFiles $DestinationRoot)
        generated = Get-RecompileHashes $script:Workspace $generated
    }
    Write-Host ("Recompilation reference: {0} generated files, {1} sources, {2} binaries" -f $generated.Count, $reference.sources.Count, $binaries.Count)
    return (Write-PayloadText $DestinationRoot 'analysis/recompile-reference.json' (($reference | ConvertTo-Json -Depth 4) + "`n"))
}

function New-FullBundle([string]$DestinationRoot, $BuildEvidence, $Toolchain) {
    # One archive for both audiences: the prebuilt host at the root so a tester
    # can play at once, plus the source tree so the launcher's rebuild button
    # can regenerate it from the tester's own disc image. Neither game data nor
    # the SDK/compiler payloads are included.
    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add((Copy-PayloadFile $BuildEvidence.executable.path $DestinationRoot 'cod3_pc.exe'))
    foreach ($artifact in $BuildEvidence.runtime_artifacts) {
        $rows.Add((Copy-PayloadFile $artifact.path $DestinationRoot $artifact.name))
    }
    $rows.Add((Copy-LauncherExe $DestinationRoot))
    $rows.AddRange(@(Copy-DeveloperSource $DestinationRoot))
    $rows.AddRange(@(Copy-ProvisioningTools $DestinationRoot))
    $rows.AddRange(@(Copy-RexGlueSdk $DestinationRoot))
    $rows.AddRange(@(Copy-SdkSource $DestinationRoot))
    $rows.AddRange(@(Copy-LgplSources $DestinationRoot))
    $rows.AddRange(@(Copy-BundledToolchain $DestinationRoot))
    $rows.Add((Write-RecompileReference $DestinationRoot $BuildEvidence))
    $rows.AddRange(@(Write-CommonBundleFiles 'developer' $DestinationRoot $BuildEvidence $Toolchain))
    $rows.Add((Write-PayloadText $DestinationRoot 'PACKAGE-README.txt' @'
Call of Duty 3 native port - single package (Windows AMD64)
===========================================================

Play: two clicks
----------------
Unpack this archive anywhere and run Project1944.exe (if an antivirus blocks
it, launcher\PLAY-COD3.cmd opens the same launcher). In the launcher:

  1. "Выбрать образ" - pick your own Call of Duty 3 disc image (.iso), or
     just drag the .iso onto the launcher window. A game you have already
     unpacked into a folder works too (pick its default.xex or drag the
     folder), and so does a Games on Demand package (drag its 415607E1 or
     00007000 folder); the game code is checked against the disc byte for
     byte.
  2. "Установить и играть" - the launcher unpacks the image (or copies the
     game) into game\cod3 next to itself, recompiles the game from it on
     this machine and starts it. Progress is shown in the window; it can be
     minimised.

No folders to pick and nothing to install. After that the button is simply
"Играть". Turning off "Рекомпилировать игру на этом компьютере" skips the
recompilation and plays the prebuilt binaries in this archive instead.
docs/testers.md has the details, docs/controls.md the key bindings.

What the recompilation does
---------------------------
It translates your own copy of the game - default.xex and the fifteen level
modules - into C++ with rexglue.exe, and regenerates the two Xenon bridge
thunks (XenonAnalyse/XenonRecomp) and the coroutine bridge from it. That takes
about a minute and needs no compiler: the three tools ship built, and the
Python the analysis uses is in tools/toolchain-bundle.

The result is then compared with analysis/recompile-reference.json, the
SHA-256 of the code the ready-made build in this archive was compiled from
(hashes only, no code). If it matches byte for byte and the port sources are
unchanged, compiling it again would reproduce that build, so the ready-made
binaries are the result (scripts/complete-recompile.ps1 records this in
analysis/recompile-receipt.json). Otherwise - or with "Пересобрать игру" - the
game is compiled in full, 10-30 minutes.

A full compile needs a compiler. Clang/LLVM, CMake and Ninja are in
tools/toolchain-bundle. MSVC and the Windows SDK cannot be: Microsoft's license
forbids redistributing them. A Visual Studio already on the machine is reused;
otherwise they are downloaded from Microsoft's own servers, about 280 MB, once.

rexglue.exe, XenonAnalyse.exe and XenonRecomp.exe contain the GNU binutils
PowerPC disassembler and are distributed under the GPL-2.0-or-later. Their
complete corresponding source is in this archive: sdk-source/ (built by
tools/rexglue-cli/Build-RexGlueCli.ps1) and tools/XenonRecomp/. The GPL-2.0
text is in licenses/gnu-binutils/ (see win-amd64/SDK-PRUNING.txt).

See docs/build-from-source.md and docs/legal.md.

Antivirus, SmartScreen, Smart App Control
-----------------------------------------
Rebuilding means downloading a compiler and running executables that were
created minutes ago, which is also what malware does, so heuristics have an
opinion. docs/antivirus.md explains exactly what gets flagged and the three
ways out; the short version is that signing the build with
tools/signing/Set-Cod3Signature.ps1 fixes the cause, a Defender path exclusion
(tools/signing/Set-DefenderExclusions.ps1, run by you, elevated) works around
it, and Smart App Control accepts neither - it needs a certificate from a
public CA or to be turned off, which is your decision to make.

What is not here
----------------
No ISO, no XEX, no extracted mission data, no generated guest C++, no shader
cache, no debug symbols and no compiler payload. The manifest records the
source XEX hash for identity checking only. Supply a legally obtained,
user-owned copy of the game.

Licensing
---------
This archive is self-contained for licensing purposes: nothing has to travel
alongside it. The runtime statically links FFmpeg and libmspack (LGPL-2.1), and
their complete corresponding source is in lgpl-sources/, with the SDK source
that builds the runtime in sdk-source/, so the runtime can be relinked against
a modified library. Component inventory and license texts: THIRD-PARTY-NOTICES.md
and licenses/.

Scope of the claims
-------------------
The prebuilt binaries are a RelWithDebInfo build. Host presentation options
such as 2560x1440 or 120 Hz do not by themselves certify gameplay, physics
invariance or a frame-rate claim; see docs/reports for the evidence.
'@))
    return $rows.ToArray()
}

function New-DeveloperBundle([string]$DestinationRoot, $BuildEvidence, $Toolchain) {
    $rows = [Collections.Generic.List[object]]::new()
    $rows.AddRange(@(Copy-DeveloperSource $DestinationRoot))
    $rows.AddRange(@(Write-CommonBundleFiles 'developer' $DestinationRoot $BuildEvidence $Toolchain))
    $rows.Add((Write-PayloadText $DestinationRoot 'PACKAGE-README.txt' @'
Call of Duty 3 native-port developer bundle

This source/evidence bundle is intentionally incomplete without the recipient's
user-owned Call of Duty 3 input and separately installed SDK/toolchain. It
contains no ISO, XEX, extracted mission data, generated guest C++, shader cache,
debug symbols, compiler payload, or user data.

Start from the workspace README after restoring the source tree, then run the
source-controlled preparation and build scripts with a matching local game
input. The package manifest and toolchain-provenance file identify the inputs
used for the build that produced this bundle.
'@))
    return $rows.ToArray()
}

function Write-ExternalReport($BundleRows, $BuildEvidence, $Toolchain) {
    $reportDirectory = Join-Path $script:Workspace 'docs/reports'
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    $report = [ordered]@{
        schema_version = 1
        generated_utc = [DateTime]::UtcNow.ToString('o')
        workspace = $script:Workspace
        scope = 'Native-port packaging audit and staging; no game launch, emulator launch, or game-data copy performed by this script.'
        bundles = @($BundleRows)
        build_evidence = $BuildEvidence
        toolchain = $Toolchain
        exclusions = @('Call of Duty 3 ISO/7z/archive', 'default.xex and extracted game data', 'generated guest C++', 'shader caches and generated shader outputs', 'PDB/OBJ/debug dumps', 'compiler/MSVC/Windows SDK payloads', 'user data')
    }
    $jsonPath = Join-Path $reportDirectory 'release-packaging-receipt.json'
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Native-port release packaging receipt')
    $lines.Add('')
    $lines.Add("Generated UTC: $($report.generated_utc)")
    $lines.Add('')
    $lines.Add('The staging script uses explicit runtime/source allowlists and fails if a forbidden game or generated path appears in the staged result. No game launch is performed.')
    $lines.Add('')
    $lines.Add('| Bundle | Staging | Files | Manifest SHA-256 | Archive SHA-256 |')
    $lines.Add('| --- | --- | ---: | --- | --- |')
    foreach ($bundle in $BundleRows) {
        $archiveHash = if ($bundle.archive) { $bundle.archive.sha256 } else { 'not written' }
        $lines.Add("| $($bundle.name) | ``$($bundle.staging_path)`` | $($bundle.payload_file_count) | ``$($bundle.manifest_sha256)`` | ``$archiveHash`` |")
    }
    $lines.Add('')
    $lines.Add('The `native-runtime` bundle is the distributable host/runtime package and still requires user-owned game data. The `developer-source` bundle contains source and evidence and requires the same user-owned input plus separately obtained tools. The `toolchain` record is provenance only; Microsoft compiler and Windows SDK payloads are not redistributed.')
    $lines.Add('')
    $lines.Add('The recorded build input is identified by SHA-256 only. This receipt does not certify game boot, gameplay, renderer correctness, physics invariance, or 120 FPS.')
    $lines | Set-Content -LiteralPath (Join-Path $reportDirectory 'release-packaging-receipt.md') -Encoding utf8
    return [ordered]@{ json = Get-RelativeWorkspacePath $jsonPath; markdown = Get-RelativeWorkspacePath (Join-Path $reportDirectory 'release-packaging-receipt.md') }
}

if (-not (Test-Path -LiteralPath $script:Workspace -PathType Container)) { throw "Workspace root is missing: $script:Workspace" }
if (-not (Test-Path -LiteralPath $script:PolicyPath -PathType Leaf)) { throw "Package policy is missing: $script:PolicyPath" }
if (-not (Test-Path -LiteralPath $script:LicenseManifestPath -PathType Leaf)) { throw "License manifest is missing: $script:LicenseManifestPath" }

$requestedBundles = switch ($Bundle) {
    'Both' { @('Runtime', 'Developer') }
    default { @($Bundle) }
}

$buildEvidence = $null
$toolchain = Get-ToolchainProvenance
if ($requestedBundles -contains 'Runtime' -or $requestedBundles -contains 'Developer' -or
    $requestedBundles -contains 'Full') {
    $buildEvidence = Read-BuildEvidence
}

New-Item -ItemType Directory -Path $script:OutputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $script:ArchiveRoot -Force | Out-Null
$bundleResults = [Collections.Generic.List[object]]::new()

foreach ($requested in $requestedBundles) {
    $name = $requested.ToLowerInvariant()
    $destination = Join-Path $script:OutputRoot $name
    Reset-Directory $destination
    $archivePath = Join-Path $script:ArchiveRoot "cod3-pc-$name.zip"
    $rows = $null
    if ($requested -eq 'Runtime') {
        $rows = New-NativeRuntimeBundle $destination $buildEvidence $toolchain
    } elseif ($requested -eq 'Full') {
        $rows = New-FullBundle $destination $buildEvidence $toolchain
    } elseif ($requested -eq 'Developer') {
        $rows = New-DeveloperBundle $destination $buildEvidence $toolchain
    } else {
        $toolchainResult = New-ToolchainBundle $destination
        $rows = $toolchainResult.rows
        $toolchain = $toolchainResult.evidence
    }
    $bundleResults.Add((Write-ManifestAndReport $name $destination $archivePath $buildEvidence $toolchain $rows))
}

$externalReport = Write-ExternalReport $bundleResults.ToArray() $buildEvidence $toolchain
Write-Host "Staged bundle(s): $($bundleResults.Count)"
foreach ($result in $bundleResults) {
    Write-Host ("  {0}: {1}" -f $result.name, $result.staging_path)
    if ($result.archive) { Write-Host ("  archive: {0} ({1})" -f $result.archive.path, $result.archive.sha256) }
}
Write-Host "Evidence: $($externalReport.json)"
Write-Host "Report: $($externalReport.markdown)"
