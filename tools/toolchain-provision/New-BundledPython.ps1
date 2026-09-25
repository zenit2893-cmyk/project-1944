#requires -Version 7.0
<#
.SYNOPSIS
    Assembles the relocatable CPython the package carries as
    tools/toolchain/bootstrap-python.

.DESCRIPTION
    A virtual environment cannot travel: its pyvenv.cfg names the interpreter
    it was made from by absolute path, so on any other machine its python.exe
    stops with "No Python at '...'". (The first packages shipped exactly that,
    and the Xenon bridge step failed on every tester's PC.)

    This script copies a real CPython instead - python.exe, its DLLs and the
    standard library - from -Base, leaves out what the rebuild never uses (the
    test suite, Tk, IDLE, headers, import libraries, the base's own
    site-packages and Scripts launchers, which also carry absolute paths), and
    adds the packages the rebuild needs (PortableMSVC and its dependencies)
    from -SitePackages. A standard CPython layout finds its standard library
    next to python.exe, so the result works from any folder.

    Nothing is downloaded. CPython is under the PSF license; the packages keep
    their own licenses, listed in their .dist-info folders.

.EXAMPLE
    New-BundledPython.ps1 -Base <python 3.12 folder> -SitePackages <venv>\Lib\site-packages
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$SitePackages,
    [string]$Destination = (Join-Path $PSScriptRoot '..\toolchain\bootstrap-python'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Base = [IO.Path]::GetFullPath($Base).TrimEnd('\')
$SitePackages = [IO.Path]::GetFullPath($SitePackages).TrimEnd('\')
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')

foreach ($required in @('python.exe', 'Lib\os.py', 'DLLs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Base $required))) { throw "Not a CPython installation (no $required): $Base" }
}
if (Test-Path -LiteralPath (Join-Path $Base 'pyvenv.cfg')) { throw "The base is itself a virtual environment: $Base" }
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw "Destination exists; pass -Force to replace it: $Destination" }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

# What of the base goes along. Root files by name, folders by rule.
$rootFiles = @('python.exe', 'pythonw.exe', 'python3.dll', 'LICENSE.txt', 'vcruntime140.dll', 'vcruntime140_1.dll')
$rootFiles += @(Get-ChildItem -LiteralPath $Base -File -Filter 'python3*.dll' | ForEach-Object Name)
$skipLib = @('site-packages', 'test', 'idlelib', 'tkinter', 'turtledemo', 'lib2to3\tests', 'unittest\test', 'ctypes\test', 'sqlite3\test', 'distutils\tests')
$skipDlls = @('_tkinter.pyd', 'tcl86t.dll', 'tk86t.dll', 'zlib1.dll.bak')

function Copy-Tree([string]$From, [string]$To, [string[]]$SkipRelative, [string[]]$SkipNames) {
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $From -Recurse -File -Force) {
        $relative = $file.FullName.Substring($From.Length + 1)
        if ($relative -match '(^|\\)__pycache__\\') { continue }
        if ($SkipNames -contains $file.Name) { continue }
        $skip = $false
        foreach ($prefix in $SkipRelative) {
            if ($relative.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $target = Join-Path $To $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $count++
    }
    return $count
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach ($name in ($rootFiles | Sort-Object -Unique)) {
    $source = Join-Path $Base $name
    if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $Destination }
}
$stdlib = Copy-Tree (Join-Path $Base 'Lib') (Join-Path $Destination 'Lib') $skipLib @()
$dlls = Copy-Tree (Join-Path $Base 'DLLs') (Join-Path $Destination 'DLLs') @() $skipDlls
# The packages: everything the environment had, minus caches and the
# installer records that name the build machine's paths.
$packages = Copy-Tree $SitePackages (Join-Path $Destination 'Lib\site-packages') @() @('direct_url.json')

# The result must not point anywhere outside itself.
$leak = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Include '*.cfg', '*.pth', '*.txt', '*.json', 'RECORD' |
    Select-String -SimpleMatch -Pattern $Base -List | ForEach-Object Path)
if ($leak.Count -gt 0) { throw "Files still name the base interpreter: $($leak -join ', ')" }

$python = Join-Path $Destination 'python.exe'
# Compared inside Python: a non-ASCII path would not survive the console.
$probe = & $python -I -c "import os, sys, ssl, sqlite3, ctypes, venv, portablemsvc; home = os.path.dirname(sys.executable); print(sys.version.split()[0]); print(sys.prefix == home and sys.base_prefix == home)"
if ($LASTEXITCODE -ne 0) { throw 'The assembled interpreter does not start.' }
if (($probe | Select-Object -Last 1) -ne 'True') { throw 'The assembled interpreter does not treat its own folder as its home.' }
$size = (Get-ChildItem -LiteralPath $Destination -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("CPython {0}: {1} standard library files, {2} DLLs, {3} package files, {4:n0} MB -> {5}" -f
    ($probe | Select-Object -First 1), $stdlib, $dlls, $packages, $size, $Destination)
