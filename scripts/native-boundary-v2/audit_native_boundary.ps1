#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$BuildDirectory = '',
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$python = Join-Path $workspace 'tools\toolchain\bootstrap-python\python.exe'
$script = Join-Path $PSScriptRoot 'audit_native_boundary.py'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Bundled Python is missing: $python"
}
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "Audit script is missing: $script"
}

$arguments = @($script, '--workspace', $workspace)
if ($BuildDirectory) {
    $arguments += @('--build-dir', $BuildDirectory)
}
if ($Check) {
    $arguments += '--check'
}

& $python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Native boundary v2 audit failed with exit code $LASTEXITCODE."
}
