#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$audit = Join-Path $workspace 'scripts\native-boundary-v2\audit_native_boundary.ps1'
if (-not (Test-Path -LiteralPath $audit -PathType Leaf)) {
    throw "Native boundary audit wrapper is missing: $audit"
}

& $audit -Check
if ($LASTEXITCODE -ne 0) {
    throw "Native boundary v2 check failed with exit code $LASTEXITCODE."
}
Write-Host 'PASS: native boundary v2 static checks completed; no executable was launched.'
