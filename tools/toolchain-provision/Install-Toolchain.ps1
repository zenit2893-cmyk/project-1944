#requires -Version 5.1
<#
.SYNOPSIS
    Provisions the local build toolchain: Clang/LLVM, CMake, Ninja and a
    portable MSVC + Windows SDK.

.DESCRIPTION
    None of these are redistributed with this project. Clang, CMake and Ninja
    are downloaded from their own release pages and verified against the
    SHA-256 values pinned in toolchain-pins.json. MSVC and the Windows SDK are
    fetched from Microsoft's own servers by PortableMSVC, which is vendored
    under tools/toolchain-bootstrap; Microsoft's terms forbid redistribution,
    so the payload only ever reaches the machine that runs this script.

    The result is the layout scripts/toolchain-env.ps1 expects:

        tools/toolchain/llvm/bin/clang-cl.exe
        tools/toolchain/msvc/env.json
        tools/cmake/bin/cmake.exe
        tools/ninja/ninja.exe

.PARAMETER Component
    Which components to provision. Defaults to everything that is missing.

.PARAMETER ReuseFrom
    Path to another workspace that already has a provisioned toolchain. Each
    component found there is linked with a directory junction instead of being
    downloaded. Intended for testing and for a second checkout on the same
    machine - it does not copy anything.

.PARAMETER DownloadCache
    Where to keep the downloaded archives. An archive already present with the
    expected SHA-256 is reused instead of downloaded again.
#>
[CmdletBinding()]
param(
    # 'tools' is everything except the compilers: the disc image extractor and
    # Python, which is all a recompilation needs when its C++ output matches
    # the build the package carries.
    [ValidateSet('all', 'tools', 'llvm', 'cmake', 'ninja', 'msvc', 'xdvdfs', 'python', 'python-packages')]
    [string[]]$Component = @('all'),
    [string]$Root,
    [string]$ReuseFrom,
    [string]$DownloadCache,
    [string]$PythonExe,
    [switch]$Force,
    [switch]$WhatIfOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here = $PSScriptRoot
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $here '..\..')) }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $DownloadCache) { $DownloadCache = Join-Path $Root 'tools\toolchain\downloads' }

$pinsPath = Join-Path $here 'toolchain-pins.json'
if (-not (Test-Path -LiteralPath $pinsPath -PathType Leaf)) { throw "Pin file is missing: $pinsPath" }
$pins = Get-Content -LiteralPath $pinsPath -Raw -Encoding UTF8 | ConvertFrom-Json

$order = @('cmake', 'ninja', 'xdvdfs', 'python', 'python-packages', 'llvm', 'msvc')
if ($Component -contains 'tools') { $Component = @($Component) + @('xdvdfs', 'python', 'python-packages') }
$selected = if ($Component -contains 'all') { $order } else { @($order | Where-Object { $Component -contains $_ }) }

$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$results = New-Object System.Collections.Generic.List[object]
$script:DownloadHashes = @{}
$script:BundleSpec = $null
$script:BundleSpecLoaded = $false

function Write-Step([string]$Text) { Write-Host ''; Write-Host "=== $Text ===" }
function Write-Detail([string]$Text) { Write-Host "    $Text" }

function Get-ComponentSpec([string]$Name) {
    # A component is described by the download pins, by the bundle carried in
    # the package, or by both. Python and its extension modules only ever come
    # from the bundle, so the pins do not mention them.
    if ($pins.components.PSObject.Properties.Name -contains $Name) { return $pins.components.$Name }
    $bundle = Get-BundleSpec
    if ($bundle -and ($bundle.components.PSObject.Properties.Name -contains $Name)) { return $bundle.components.$Name }
    return $null
}

function Test-ComponentPresent([string]$Name) {
    $spec = Get-ComponentSpec $Name
    if (-not $spec) { return $false }
    $probe = Join-Path (Join-Path $Root ($spec.destination -replace '/', '\')) ($spec.probe -replace '/', '\')
    return (Test-Path -LiteralPath $probe)
}

function New-Junction([string]$Link, [string]$Target) {
    if (Test-Path -LiteralPath $Link) {
        $item = Get-Item -LiteralPath $Link -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            (Get-Item -LiteralPath $Link -Force).Delete()
        } else {
            throw "Refusing to replace a real directory with a junction: $Link"
        }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Link) -Force | Out-Null
    $out = & cmd.exe /d /c mklink /J "`"$Link`"" "`"$Target`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mklink failed for $Link -> $Target : $out" }
}

function Get-VerifiedArchive([string]$Name) {
    $spec = $pins.components.$Name
    New-Item -ItemType Directory -Path $DownloadCache -Force | Out-Null
    $archive = Join-Path $DownloadCache $spec.archive
    # A null pin means the component is fetched from a moving "latest" URL, so
    # there is nothing to compare against; the hash actually received is
    # recorded in the receipt instead.
    $pinned = -not [string]::IsNullOrWhiteSpace([string]$spec.sha256)
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        $have = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if (-not $pinned) {
            Write-Detail "cached archive reused (no pinned hash for this component), sha256 $have"
            return $archive
        }
        Write-Detail "cached archive found, verifying SHA-256"
        if ($have -ieq $spec.sha256) {
            Write-Detail "ok $have"
            return $archive
        }
        Write-Detail "hash mismatch, re-downloading (had $have)"
        Remove-Item -LiteralPath $archive -Force
    }
    Write-Detail "downloading $($spec.approx_download_mb) MB from $($spec.url)"
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $spec.url -UseBasicParsing -TimeoutSec 1800 -OutFile $archive
    } finally {
        $ProgressPreference = $progress
    }
    $have = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($pinned -and $have -ine $spec.sha256) {
        Remove-Item -LiteralPath $archive -Force
        throw "SHA-256 mismatch for $Name. Expected $($spec.sha256), got $have. The download was discarded."
    }
    if ($pinned) { Write-Detail "verified $have" } else { Write-Detail "downloaded, sha256 $have (no pin to verify against)" }
    $script:DownloadHashes[$Name] = $have
    return $archive
}

function Expand-Component([string]$Name, [string]$Archive) {
    $spec = $pins.components.$Name
    $destination = Join-Path $Root ($spec.destination -replace '/', '\')
    $staging = Join-Path $DownloadCache ("stage-" + $Name)
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Write-Detail "extracting to a staging directory"
    if ($spec.kind -eq 'zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $staging)
    } else {
        if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) { throw 'tar.exe was not found in System32 (Windows 10 1803+ required).' }
        & $tar -xf $Archive -C $staging
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $Archive (exit $LASTEXITCODE)" }
    }

    $payload = $staging
    if ($spec.strip_root) {
        $entries = @(Get-ChildItem -LiteralPath $staging -Force)
        if ($entries.Count -ne 1 -or -not $entries[0].PSIsContainer) {
            throw "Expected a single top-level directory in $($spec.archive), found $($entries.Count) entries."
        }
        $payload = $entries[0].FullName
    }

    if (Test-Path -LiteralPath $destination) {
        Write-Detail "replacing existing $($spec.destination)"
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Move-Item -LiteralPath $payload -Destination $destination -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    $probe = Join-Path $destination ($spec.probe -replace '/', '\')
    if (-not (Test-Path -LiteralPath $probe)) { throw "$Name installed but $probe is missing." }

    # Files unpacked from a downloaded archive inherit its mark of the web, so
    # Windows treats every tool in the toolchain as "downloaded from the
    # internet" and warns on each first run. The archive was just verified
    # against its pinned SHA-256, which is a stronger statement than the mark
    # carries, so clear it.
    try {
        Get-ChildItem -LiteralPath $destination -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
        Unblock-File -LiteralPath $Archive -ErrorAction SilentlyContinue
    } catch {
        Write-Detail "could not clear the mark of the web: $($_.Exception.Message)"
    }
    Write-Detail "installed: $probe"
}

function Resolve-Python {
    if ($PythonExe) {
        if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw "Python not found: $PythonExe" }
        return $PythonExe
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($relative in @('tools\toolchain\bootstrap-python\python.exe', 'tools\toolchain\bootstrap-python\Scripts\python.exe')) {
        $vendored = Join-Path $Root $relative
        if (Test-Path -LiteralPath $vendored -PathType Leaf) { $candidates.Add($vendored) }
    }
    foreach ($name in @('python', 'python3')) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { $candidates.Add($found.Source) }
    }
    foreach ($candidate in $candidates) {
        try {
            $version = & $candidate --version 2>&1 | Out-String
        } catch { continue }
        # The Microsoft Store alias prints nothing useful and opens the Store.
        if ($version -match 'Python\s+3\.(\d+)') {
            # PortableMSVC declares requires-python >= 3.10.
            if ([int]$Matches[1] -ge 10) { return $candidate }
        }
    }
    return $null
}

function Get-BundleSpec {
    if ($script:BundleSpecLoaded) { return $script:BundleSpec }
    $script:BundleSpecLoaded = $true
    $path = Join-Path $Root 'tools\toolchain-bundle\bundle-spec.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $script:BundleSpec = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:BundleSpec
}

function New-HardLinkOrCopy([string]$LinkPath, [string]$TargetPath) {
    # A hard link costs nothing on the same volume and keeps one copy of a
    # 100 MB driver on disk. Fall back to a copy when the filesystem refuses.
    if (Test-Path -LiteralPath $LinkPath) { Remove-Item -LiteralPath $LinkPath -Force }
    try {
        New-Item -ItemType HardLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
        return 'link'
    } catch {
        Copy-Item -LiteralPath $TargetPath -Destination $LinkPath -Force
        return 'copy'
    }
}

function Install-FromBundle([string]$Name) {
    $spec = Get-BundleSpec
    if (-not $spec) { return $false }
    if (-not ($spec.components.PSObject.Properties.Name -contains $Name)) { return $false }
    $component = $spec.components.$Name
    $bundleRoot = Join-Path $Root ("tools\toolchain-bundle\" + $Name)
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) { return $false }
    # Windows PowerShell 5.1 has no [IO.Path]::GetRelativePath.
    $bundlePrefix = ([IO.Path]::GetFullPath($bundleRoot)).TrimEnd('\') + '\'

    $destination = Join-Path $Root ($component.destination -replace '/', '\')
    Write-Detail "installing from the package bundle"
    # Whatever an older package left there goes first. Copying over it would
    # keep stale files - an old bundled Python was a virtual environment, and
    # its pyvenv.cfg next to the new python.exe would send it looking for an
    # interpreter on the machine the package was made on.
    if (Test-Path -LiteralPath $destination) {
        $existing = Get-Item -LiteralPath $destination -Force
        if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) { $existing.Delete() }
        else { Remove-Item -LiteralPath $destination -Recurse -Force }
    }
    $copied = 0
    foreach ($file in Get-ChildItem -LiteralPath $bundleRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($bundlePrefix.Length)
        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
    }

    $linked = 0
    foreach ($alias in $component.aliases.PSObject.Properties) {
        $source = Join-Path $destination ($alias.Value -replace '/', '\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Detail "alias source missing, skipped: $($alias.Value)"
            continue
        }
        $link = Join-Path $destination ($alias.Name -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
        New-HardLinkOrCopy $link $source | Out-Null
        $linked++
    }

    $probe = Join-Path $destination ($component.probe -replace '/', '\')
    if (-not (Test-Path -LiteralPath $probe)) { throw "Installed $Name from the bundle but $probe is missing." }
    Write-Detail "$copied files, $linked names recreated"
    Write-Detail "installed: $probe"
    return $true
}

function Install-Uv {
    $spec = $pins.components.uv
    $destination = Join-Path $Root ($spec.destination -replace '/', '\')
    $exe = Join-Path $destination 'uv.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    $existing = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $archive = Get-VerifiedArchive 'uv'
    Expand-Component 'uv' $archive
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "uv did not land at $exe" }
    return $exe
}

function Import-ExistingVisualStudio {
    # MSVC and the Windows SDK are the one thing that cannot ride along in the
    # package. If this machine already has Build Tools or Visual Studio, use
    # them and skip the download entirely: ask vswhere where they are, run
    # vcvars64 in a child cmd, and capture the environment it sets.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $false }
    $installPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
    if (-not $installPath -or -not (Test-Path -LiteralPath $installPath -PathType Container)) { return $false }
    $vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { return $false }

    Write-Detail "found an existing Visual Studio: $installPath"
    $marker = '___COD3_ENV___'
    $output = & $env:ComSpec /d /c "`"$vcvars`" >nul 2>&1 && echo $marker && set" 2>$null
    $seen = $false
    $values = @{}
    foreach ($line in $output) {
        if (-not $seen) {
            if ($line -eq $marker) { $seen = $true }
            continue
        }
        $split = $line.IndexOf('=')
        if ($split -gt 0) { $values[$line.Substring(0, $split)] = $line.Substring($split + 1) }
    }
    foreach ($required in @('INCLUDE', 'LIB', 'VCToolsInstallDir', 'WindowsSdkDir', 'WindowsSDKVersion')) {
        if (-not $values.ContainsKey($required) -or -not $values[$required]) {
            Write-Detail "vcvars64 did not report $required; falling back to PortableMSVC"
            return $false
        }
    }

    $destination = Join-Path $Root ($pins.components.msvc.destination -replace '/', '\')
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $vcTools = $values['VCToolsInstallDir']
    $sdkVersion = $values['WindowsSDKVersion'].TrimEnd('\')
    $spec = [ordered]@{
        VSCMD_ARG_HOST_ARCH = 'x64'
        VCToolsVersion = (Split-Path -Leaf $vcTools.TrimEnd('\'))
        WindowsSDKVersion = $sdkVersion
        VCINSTALLDIR = $(if ($values.ContainsKey('VCINSTALLDIR')) { $values['VCINSTALLDIR'] } else { '' })
        VCToolsInstallDir = $vcTools
        WindowsSDKDir = $values['WindowsSdkDir']
        INCLUDE = @($values['INCLUDE'] -split ';' | Where-Object { $_ })
        LIB = @($values['LIB'] -split ';' | Where-Object { $_ })
        LIBPATH = @($(if ($values.ContainsKey('LIBPATH')) { $values['LIBPATH'] } else { '' }) -split ';' | Where-Object { $_ })
        PATH = @($values['PATH'] -split ';' | Where-Object { $_ -and ($_ -like "*$installPath*" -or $_ -like '*Windows Kits*') })
        source = 'existing Visual Studio installation'
        source_path = $installPath
    }
    $envPath = Join-Path $destination 'env.json'
    [IO.File]::WriteAllText($envPath, (($spec | ConvertTo-Json -Depth 8) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Detail "wrote $envPath from that installation - nothing downloaded"
    return $true
}

function Install-Msvc {
    $spec = $pins.components.msvc
    $destination = Join-Path $Root ($spec.destination -replace '/', '\')
    $bootstrap = Join-Path $Root ($spec.provisioner -replace '/', '\')
    if (-not (Test-Path -LiteralPath (Join-Path $bootstrap 'pyproject.toml') -PathType Leaf)) {
        throw "PortableMSVC sources are missing at $bootstrap."
    }
    if (Import-ExistingVisualStudio) { return }

    $python = Resolve-Python
    $uv = $null
    if (-not $python) {
        # No usable interpreter on this machine - a bare "python" on Windows is
        # often the Microsoft Store alias, which reports no version at all.
        # uv is a single binary that supplies a Python and runs the tool, which
        # is also what PortableMSVC's own README recommends.
        Write-Detail 'no usable Python found; installing uv to supply one'
        $uv = Install-Uv
    }

    $env:PORTABLEMSVC_CACHE = Join-Path $Root 'tools\toolchain\msvc-cache'
    $env:PORTABLEMSVC_DATA = Join-Path $Root 'tools\toolchain\msvc-data'
    $env:PORTABLEMSVC_CONFIG = Join-Path $Root 'tools\toolchain\msvc-config'
    $env:PORTABLEMSVC_TEMP = Join-Path $Root 'tools\toolchain\msvc-temp'
    foreach ($dir in @($env:PORTABLEMSVC_CACHE, $env:PORTABLEMSVC_DATA, $env:PORTABLEMSVC_CONFIG, $env:PORTABLEMSVC_TEMP)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Write-Detail "downloading MSVC $($spec.version) and Windows SDK $($spec.sdk_version) from Microsoft"
    Write-Detail "by continuing you accept $($spec.license)"
    $installArgs = @('install', '--host', 'x64', '--target', 'x64', '--accept-license', '--output', $destination)

    if ($uv) {
        Write-Detail "uv: $uv"
        & $uv tool run --python 3.12 --from $bootstrap portablemsvc @installArgs
        if ($LASTEXITCODE -ne 0) { throw "portablemsvc (via uv) failed (exit $LASTEXITCODE)" }
    } else {
        Write-Detail "python: $python"

        # The Python carried in the package already has PortableMSVC installed,
        # so there is nothing to fetch from PyPI - only Microsoft's own files.
        & $python -c "import portablemsvc" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Detail 'PortableMSVC already present in this interpreter'
            & $python -m portablemsvc.cli @installArgs
            if ($LASTEXITCODE -ne 0) { throw "portablemsvc install failed (exit $LASTEXITCODE)" }
            $probe = Join-Path $destination 'env.json'
            if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw "portablemsvc finished but $probe is missing." }
            Write-Detail "installed: $probe"
            return
        }

        $venv = Join-Path $Root 'tools\toolchain\msvc-venv'
        $venvPython = Join-Path $venv 'Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf) -or $Force) {
            Write-Detail 'creating a private virtual environment'
            if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
            & $python -m venv $venv
            if ($LASTEXITCODE -ne 0) { throw "python -m venv failed (exit $LASTEXITCODE)" }
        }
        Write-Detail 'installing PortableMSVC into it'
        & $venvPython -m pip install --disable-pip-version-check --quiet $bootstrap
        if ($LASTEXITCODE -ne 0) { throw "pip install of PortableMSVC failed (exit $LASTEXITCODE)" }
        & $venvPython -m portablemsvc.cli @installArgs
        if ($LASTEXITCODE -ne 0) { throw "portablemsvc install failed (exit $LASTEXITCODE)" }
    }
    $probe = Join-Path $destination 'env.json'
    if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw "portablemsvc finished but $probe is missing." }
    Write-Detail "installed: $probe"
}

Write-Host "Workspace: $Root"
Write-Host "Components: $($selected -join ', ')"
if ($ReuseFrom) { Write-Host "Reusing from: $ReuseFrom" }
Write-Host "Download cache: $DownloadCache"

foreach ($name in $selected) {
    $spec = Get-ComponentSpec $name
    if (-not $spec) {
        Write-Step $name
        Write-Detail 'not described by the pins or by the package bundle, skipped'
        $results.Add([ordered]@{ component = $name; action = 'unavailable' })
        continue
    }
    $version = if ($spec.PSObject.Properties.Name -contains 'version') { $spec.version } else { 'bundled' }
    Write-Step "$name $version"

    if ((Test-ComponentPresent $name) -and -not $Force) {
        Write-Detail 'already present, skipping'
        $results.Add([ordered]@{ component = $name; action = 'present' })
        continue
    }
    if ($WhatIfOnly) {
        Write-Detail "would install into $($spec.destination)"
        $results.Add([ordered]@{ component = $name; action = 'would-install' })
        continue
    }

    $linked = $false
    if ($ReuseFrom) {
        $source = Join-Path ([IO.Path]::GetFullPath($ReuseFrom)) ($spec.destination -replace '/', '\')
        $sourceProbe = Join-Path $source ($spec.probe -replace '/', '\')
        if (Test-Path -LiteralPath $sourceProbe) {
            $link = Join-Path $Root ($spec.destination -replace '/', '\')
            Write-Detail "linking $($spec.destination) -> $source"
            New-Junction $link $source
            if (-not (Test-ComponentPresent $name)) { throw "Junction created but $name still does not resolve." }
            $results.Add([ordered]@{ component = $name; action = 'linked'; source = $source })
            $linked = $true
        }
    }
    if ($linked) { continue }

    # Anything the package already carries is installed from there; the
    # network is a fallback, not the normal path.
    if ($name -ne 'msvc' -and (Install-FromBundle $name)) {
        $results.Add([ordered]@{ component = $name; action = 'from-bundle' })
        continue
    }

    if ($name -eq 'msvc') {
        Install-Msvc
        $results.Add([ordered]@{ component = $name; action = 'installed' })
    } elseif ($spec.PSObject.Properties.Name -notcontains 'url') {
        throw "Component '$name' is only ever supplied by the package bundle, and tools/toolchain-bundle/$name is not present."
    } else {
        $archive = Get-VerifiedArchive $name
        Expand-Component $name $archive
        $results.Add([ordered]@{ component = $name; action = 'downloaded'; sha256 = $spec.sha256 })
    }
}

Write-Host ''
Write-Host '=== Result ==='
foreach ($row in $results) {
    Write-Host ("    {0,-8} {1}" -f $row.component, $row.action)
}

$missing = @($selected | Where-Object { -not (Test-ComponentPresent $_) })
if ($missing.Count -gt 0 -and -not $WhatIfOnly) {
    Write-Host ''
    Write-Host "Still missing: $($missing -join ', ')"
    exit 1
}

$receipt = [ordered]@{
    schema_version = 1
    root = $Root
    components = $results.ToArray()
    reused_from = $ReuseFrom
    downloaded_sha256 = $script:DownloadHashes
}
[IO.File]::WriteAllText((Join-Path $here 'provision-receipt.json'), (($receipt | ConvertTo-Json -Depth 8) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
if (@('llvm', 'cmake', 'ninja', 'msvc' | Where-Object { $selected -contains $_ }).Count -eq 4) {
    Write-Host 'Toolchain is in place. scripts/toolchain-env.ps1 will now succeed.'
} else {
    Write-Host "In place: $($selected -join ', ')."
}
