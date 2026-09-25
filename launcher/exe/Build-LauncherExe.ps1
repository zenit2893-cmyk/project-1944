<#
.SYNOPSIS
    Builds Project1944.exe, the launcher executable, from Project1944.cs.

.DESCRIPTION
    Uses the C# compiler that ships with the .NET Framework on every Windows
    10/11 (csc.exe v4.x), so nothing has to be installed.

    The icon is made from a picture by build_icon.py:
      -IconSource <image>            this picture;
      launcher\exe\icon-source.*     otherwise, a local picture if present
                                     (kept out of the repository: a game box
                                     is the publisher's artwork);
      launcher\assets\emblem.png     otherwise, the project's own emblem.

    Output: launcher\exe\bin\Project1944.exe and build-receipt.json beside it.
    The packager copies the exe to the package root.
#>
[CmdletBinding()]
param([string]$IconSource)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = [IO.Path]::GetFullPath((Join-Path $here '..\..'))

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw "The .NET Framework C# compiler is missing: $csc" }
$automation = Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter 'System.Management.Automation.dll' |
    Select-Object -First 1
if (-not $automation) { throw 'Windows PowerShell 5.1 (System.Management.Automation) is missing.' }

if (-not $IconSource) {
    $local = @(Get-ChildItem -LiteralPath $here -File -Filter 'icon-source.*' -ErrorAction SilentlyContinue)
    $IconSource = if ($local.Count -gt 0) { $local[0].FullName } else { Join-Path $root 'launcher\assets\emblem.png' }
}
if (-not (Test-Path -LiteralPath $IconSource -PathType Leaf)) { throw "Icon picture not found: $IconSource" }

$python = Join-Path $root 'tools\toolchain\bootstrap-python\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { $python = 'python' }
$icon = Join-Path $here 'Project1944.ico'
& $python (Join-Path $here 'build_icon.py') $IconSource $icon
if ($LASTEXITCODE -ne 0) { throw "Making the icon failed (exit $LASTEXITCODE)." }

$bin = Join-Path $here 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$exe = Join-Path $bin 'Project1944.exe'
$arguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/utf8output',
    "/out:$exe", "/win32icon:$icon", "/win32manifest:$(Join-Path $here 'Project1944.manifest')",
    "/reference:$($automation.FullName)", '/reference:System.Windows.Forms.dll',
    (Join-Path $here 'Project1944.cs'))
& $csc @arguments
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)." }

$receipt = [ordered]@{
    schema_version = 1
    output = 'launcher/exe/bin/Project1944.exe'
    sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    bytes = (Get-Item -LiteralPath $exe).Length
    compiler = "csc $((Get-Item -LiteralPath $csc).VersionInfo.FileVersion)"
    icon_source = Split-Path -Leaf $IconSource
    icon_sha256 = (Get-FileHash -LiteralPath $icon -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $bin 'build-receipt.json'), ($receipt | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Write-Host "Built $exe ($($receipt.bytes) bytes), icon from $($receipt.icon_source)"
