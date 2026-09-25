<#
.SYNOPSIS
    Parses project PowerShell files and checks the launcher BOM and translations.
.DESCRIPTION
    Runs without game data or a compiler. Compatible with Windows PowerShell
    5.1 and PowerShell 7 so CI can run it under both hosts.
#>
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|out|build|staging|artifacts)[\\/]' })

foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error in $($script.FullName): $($errors[0].Message)"
    }
}

$launcher = Join-Path $root 'launcher\Cod3Launcher.ps1'
$bytes = [IO.File]::ReadAllBytes($launcher)
if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
    throw 'launcher/Cod3Launcher.ps1 must start with a UTF-8 BOM.'
}

$stringsPath = Join-Path $root 'launcher\strings.json'
$rows = Get-Content -LiteralPath $stringsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$languages = @('ru', 'en', 'uk', 'be', 'es', 'de')
foreach ($row in $rows) {
    foreach ($language in $languages) {
        if (-not ($row.PSObject.Properties.Name -contains $language) -or [string]::IsNullOrWhiteSpace([string]$row.$language)) {
            throw "Missing launcher translation '$language' in entry $($row.ru)"
        }
    }
    $reference = @([regex]::Matches([string]$row.ru, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object)
    foreach ($language in $languages) {
        $actual = @([regex]::Matches([string]$row.$language, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object)
        if (($reference -join ',') -ne ($actual -join ',')) {
            throw "Placeholder mismatch for '$language' in entry $($row.ru)"
        }
    }
}
Write-Output "Parsed $($scripts.Count) PowerShell files; checked launcher BOM and $($rows.Count) translations."
