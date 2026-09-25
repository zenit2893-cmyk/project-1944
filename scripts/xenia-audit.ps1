#requires -Version 7.2
[CmdletBinding()]
param([switch]$Offline)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$python = Join-Path $workspace 'tools\toolchain\bootstrap-python\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'The isolated toolchain Python environment with pefile is required.' }
$env:PYTHONUTF8 = '1'
$auditArgs = @((Join-Path $PSScriptRoot 'xenia-audit.py'))
if ($Offline) { $auditArgs += '--offline' }
& $python @auditArgs
if ($LASTEXITCODE -ne 0) { throw "Xenia static audit failed: $LASTEXITCODE" }
