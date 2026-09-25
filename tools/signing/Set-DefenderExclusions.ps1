#requires -Version 5.1
<#
.SYNOPSIS
    Adds or removes Microsoft Defender exclusions for this build tree.

.DESCRIPTION
    Run this yourself, from an elevated PowerShell, and only if you want it.
    It changes a security setting on your machine, so it is not part of the
    rebuild and nothing calls it automatically.

    Two separate problems it addresses:

      * Speed. A full recompilation writes tens of thousands of object files.
        Real-time scanning of that tree costs a large part of the build time.
      * False positives. A freshly compiled, unsigned executable has no
        reputation, and heuristics sometimes quarantine one mid-build.

    The exclusion is scoped to this package directory and the tools it
    downloads - not to your whole disk, and not by process name. Everything
    else on the machine stays protected. -Remove puts it back.

    If you would rather not exclude anything, sign the build instead:
    tools/signing/Set-Cod3Signature.ps1. That is the better answer, because it
    fixes the cause rather than telling Defender to look away.

.PARAMETER Root
    The package or workspace directory. Defaults to this file's project root.

.PARAMETER Remove
    Remove the exclusions this script adds.

.PARAMETER WhatIfOnly
    Print what would change and exit.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Remove,
    [switch]$WhatIfOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $here '..\..')) }
$Root = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Directory not found: $Root" }

$paths = @(
    $Root,
    (Join-Path $Root 'cod3-pc\out'),
    (Join-Path $Root 'tools\toolchain'),
    (Join-Path $Root 'tools\XenonRecomp\out'),
    (Join-Path $Root 'integration\vfetch-bounds\build'),
    (Join-Path $Root 'tools\rexglue-cli\build')
) | Select-Object -Unique

Write-Host "Package root: $Root"
Write-Host ''
if ($Remove) { Write-Host 'Removing Defender path exclusions:' } else { Write-Host 'Adding Defender path exclusions:' }
foreach ($path in $paths) { Write-Host ("  {0}" -f $path) }
Write-Host ''

if ($WhatIfOnly) { Write-Host 'Nothing changed (-WhatIfOnly).'; return }

if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    throw 'The Defender PowerShell module is unavailable. If another antivirus replaced Defender, add the exclusion in that product instead.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw @'
This needs an elevated PowerShell: Defender exclusions are a machine setting.

Open "Windows PowerShell" or "Terminal" as administrator and run this script
again. It will not attempt to elevate itself.
'@
}

$changed = New-Object System.Collections.Generic.List[string]
foreach ($path in $paths) {
    try {
        if ($Remove) {
            Remove-MpPreference -ExclusionPath $path -ErrorAction Stop
        } else {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        }
        $changed.Add($path)
        Write-Host ("  ok   {0}" -f $path)
    } catch {
        Write-Host ("  FAIL {0}  {1}" -f $path, $_.Exception.Message)
    }
}

Write-Host ''
Write-Host ("{0} {1} path(s)." -f $(if ($Remove) { 'Removed' } else { 'Added' }), $changed.Count)
Write-Host 'Current exclusions:'
try {
    foreach ($path in (Get-MpPreference).ExclusionPath) { Write-Host ("  {0}" -f $path) }
} catch {
    Write-Host '  (could not read the current list)'
}
if (-not $Remove) {
    Write-Host ''
    Write-Host 'Undo with: Set-DefenderExclusions.ps1 -Remove'
}
