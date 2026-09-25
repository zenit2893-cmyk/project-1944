[CmdletBinding()]
param(
    [string]$CodegenLog = (Join-Path $PSScriptRoot '..\logs\cod3-codegen-relative.log'),
    [string]$SdkSource = (Join-Path $PSScriptRoot '..\tools\rexglue-source'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\analysis'),
    [string]$GeneratedDirectory = '',
    [ValidatePattern('^runtime-[A-Za-z0-9_-]+$')][string]$ReportPrefix = 'runtime-imports'
)

# Read-only with respect to the title and SDK. Only audit reports are written.
# An export registration proves a symbol is available in source, not that its
# semantics or the game path using it work. Review markers are deliberately broad.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $SdkSource).Path
$logPath = if ($GeneratedDirectory) { $null } else { (Resolve-Path -LiteralPath $CodegenLog).Path }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputPath) | Out-Null

function Get-LineNumber([string]$Text, [int]$Index) {
    return 1 + [regex]::Matches($Text.Substring(0, $Index), "`n").Count
}

function Get-FunctionBody([string]$Text, [string]$Name) {
    # Keep offsets stable while removing comments and quoted strings from the
    # brace scan. C++ raw strings are not used by the audited kernel entries.
    $mask = [regex]::Replace($Text, '(?s)/\*.*?\*/|//[^\r\n]*|"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''',
        [Text.RegularExpressions.MatchEvaluator]{ param($m) (' ' * $m.Length) })
    $match = [regex]::Match($mask, '\b' + [regex]::Escape($Name) + '\s*\([^;{}]*\)\s*\{')
    if (-not $match.Success) { return $null }
    $start = $match.Index + $match.Length - 1
    $depth = 1
    for ($i = $start + 1; $i -lt $mask.Length; $i++) {
        if ($mask[$i] -eq '{') { $depth++ }
        elseif ($mask[$i] -eq '}') { $depth-- }
        if ($depth -eq 0) {
            return [pscustomobject]@{
                line = Get-LineNumber $Text $match.Index
                text = $Text.Substring($start, $i - $start + 1)
            }
        }
    }
    return $null
}

$ordinalByName = @{}
foreach ($table in Get-ChildItem -LiteralPath (Join-Path $sourcePath 'src\kernel') -Recurse -Filter 'export_table.inc') {
    $tableText = [IO.File]::ReadAllText($table.FullName)
    foreach ($m in [regex]::Matches($tableText, 'XE_EXPORT\(\s*(\w+),\s*(0x[0-9A-Fa-f]+),\s*(\w+),\s*(kFunction|kVariable)\s*\)')) {
        $ordinalByName[$m.Groups[3].Value] = [pscustomobject]@{
            library = $m.Groups[1].Value
            ordinal = $m.Groups[2].Value
            kind = $m.Groups[4].Value
        }
    }
}

$exportsBySymbol = @{}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourcePath 'src\kernel') -Recurse -Filter '*.cpp') {
    $sourceText = [IO.File]::ReadAllText($file.FullName)
    $pattern = '(?m)^\s*(REX_EXPORT_STUB_RETURN|REX_EXPORT_STUB|REX_EXPORT|REX_HOOK_RAW|REX_HOOK)\s*\(\s*(__imp__\w+)(?:\s*,\s*([\w:]+))?'
    foreach ($m in [regex]::Matches($sourceText, $pattern)) {
        $macro = $m.Groups[1].Value
        $symbol = $m.Groups[2].Value
        $entry = $m.Groups[3].Value
        $body = $null
        if ($macro -eq 'REX_EXPORT' -or $macro -eq 'REX_HOOK') {
            $body = Get-FunctionBody $sourceText ($entry -replace '^.*::', '')
        }
        $markers = @()
        if ($null -ne $body) {
            $markers = @([regex]::Matches($body.text, '(?im)^.*(?:\bSTUB\b|\bTODO\b|\bFIXME\b|NOT_IMPLEMENTED|CALL_NOT_IMPLEMENTED|assert_always|assert_unhandled_case|not implemented).*$') |
                ForEach-Object { $_.Value.Trim() })
        }
        $status = if ($macro -match 'STUB') { 'explicit_stub' } else { 'registered_body' }
        $exportsBySymbol[$symbol] = [pscustomobject]@{
            status = $status
            macro = $macro
            entry = $entry
            source = [IO.Path]::GetRelativePath($sourcePath, $file.FullName).Replace('\', '/')
            registration_line = Get-LineNumber $sourceText $m.Index
            body_line = if ($null -ne $body) { $body.line } else { $null }
            review_markers = $markers
        }
    }
}

$logText = if ($logPath) { [IO.File]::ReadAllText($logPath) } else { '' }
$generatedFiles = @()
$importMatches = @()
if ($GeneratedDirectory) {
    $generatedPath = (Resolve-Path -LiteralPath $GeneratedDirectory).Path
    $registerFiles = @(Get-ChildItem -LiteralPath $generatedPath -Filter '*_register.cpp')
    if ($registerFiles.Count -ne 1) { throw "Expected one generated *_register.cpp in $generatedPath." }
    foreach ($file in $registerFiles) {
        $generatedFiles += [pscustomobject]@{ path = $file.FullName; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        $generatedText = [IO.File]::ReadAllText($file.FullName)
        $importMatches += [regex]::Matches($generatedText, 'registrar->SetFunction\(\s*(0x[0-9A-Fa-f]+)\s*,\s*(__imp__\w+)\s*\)')
    }
} else {
    $importMatches = @([regex]::Matches($logText, 'FunctionNode (0x[0-9A-Fa-f]+) \((__imp__\w+)\): DISCOVERED as import'))
}
$rows = @(
    foreach ($m in $importMatches) {
        $symbol = $m.Groups[2].Value
        $name = $symbol.Substring(7)
        $ordinal = $ordinalByName[$name]
        $registration = $exportsBySymbol[$symbol]
        [pscustomobject]@{
            name = $name
            symbol = $symbol
            guest_thunk = $m.Groups[1].Value
            library = if ($ordinal) { $ordinal.library } else { $null }
            ordinal = if ($ordinal) { $ordinal.ordinal } else { $null }
            status = if ($registration) { $registration.status } else { 'registration_not_found' }
            evidence = $registration
        }
    }
)
if ($rows.Count -eq 0) { throw 'No resolved function imports in the input; refusing to report an empty compatibility result.' }
$rows = @($rows | Sort-Object library, name -Unique)
$variables = @(
    foreach ($m in [regex]::Matches($logText, 'Patched variable import (\w+):(0x[0-9A-Fa-f]+) \((\w+)\) -> (0x[0-9A-Fa-f]+)')) {
        [pscustomobject]@{ library = $m.Groups[1].Value; ordinal = $m.Groups[2].Value;
            name = $m.Groups[3].Value; patched_address = $m.Groups[4].Value }
    }
)
$unresolvedVariables = @([regex]::Matches($logText, 'Variable import .* not implemented') | ForEach-Object { $_.Value })
$unresolvedOrdinals = @([regex]::Matches($logText, 'Cannot resolve ordinal .*') | ForEach-Object { $_.Value })
$sourceCommit = (& git -C $sourcePath rev-parse HEAD).Trim()
$report = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    source_commit = $sourceCommit
    codegen_log = $logPath
    codegen_log_sha256 = if ($logPath) { (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash } else { $null }
    generated_files = $generatedFiles
    scope = 'Static source registration and loader log/generated code audit; game behavior and shipped DLL symbols require independent validation. Generated registration files contain functions only; no variable compatibility claim is made without a loader log.'
    function_import_count = $rows.Count
    registered_body_count = @($rows | Where-Object status -eq 'registered_body').Count
    explicit_stub_count = @($rows | Where-Object status -eq 'explicit_stub').Count
    registration_not_found_count = @($rows | Where-Object status -eq 'registration_not_found').Count
    review_marker_count = @($rows | Where-Object { $null -ne $_.evidence -and $_.evidence.review_markers.Count -gt 0 }).Count
    patched_variable_count = $variables.Count
    unresolved_variable_messages = $unresolvedVariables
    unresolved_ordinal_messages = $unresolvedOrdinals
    functions = $rows
    variables = $variables
}
$report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $outputPath "$ReportPrefix.json") -Encoding utf8
$rows | Select-Object library, ordinal, name, guest_thunk, status,
    @{n='source';e={if ($_.evidence) { $_.evidence.source }}},
    @{n='line';e={if ($_.evidence) { $_.evidence.body_line }}},
    @{n='review_markers';e={if ($_.evidence) { $_.evidence.review_markers -join ' | ' }}} |
    Export-Csv -LiteralPath (Join-Path $outputPath "$ReportPrefix.csv") -NoTypeInformation -Encoding utf8
[pscustomobject]$report | Select-Object function_import_count, registered_body_count, explicit_stub_count,
    registration_not_found_count, review_marker_count, patched_variable_count | Format-List
