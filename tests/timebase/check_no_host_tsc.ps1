[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdapterDirectory
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($AdapterDirectory)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Adapter directory not found: $root"
}

$files = @(Get-ChildItem -LiteralPath $root -File |
    Where-Object { $_.Extension -in @('.h', '.cpp') })
$matches = @($files | Select-String -Pattern '(?i)\b(__rdtsc|rdtsc)\b')
if ($matches.Count -ne 0) {
    $matches | ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }
    throw 'The ReXGlue timebase adapter contains a direct host TSC reference.'
}

Write-Output "PASS: no direct host TSC token in $($files.Count) adapter source files"
