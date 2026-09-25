#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Inventory', 'Events', 'SymbolizeOffset')]
    [string]$Mode = 'Inventory',
    [string]$ReceiptPath,
    [string]$Executable,
    [uint32]$TargetProcessId = 0,
    [datetime]$Since = (Get-Date).AddMinutes(-20),
    [string]$ModulePath,
    [string]$RelativeOffset,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$llvmBin = Join-Path $workspace 'tools\toolchain\llvm\bin'
$symbolizer = Join-Path $llvmBin 'llvm-symbolizer.exe'
$cdb = Join-Path $workspace 'tools\toolchain\windbg\amd64\cdb.exe'

if ($ReceiptPath) {
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
    if (-not $Executable) { $Executable = [string]$receipt.executable }
    if ($TargetProcessId -eq 0 -and $receipt.process_id) { $TargetProcessId = [uint32]$receipt.process_id }
    if ($receipt.started_utc) {
        # Recent PowerShell versions deserialize ISO dates as DateTime objects.
        # Do not stringify them through the current locale before parsing again.
        if ($receipt.started_utc -is [datetime]) {
            $Since = $receipt.started_utc.ToUniversalTime()
        } elseif ($receipt.started_utc -is [datetimeoffset]) {
            $Since = $receipt.started_utc.UtcDateTime
        } else {
            $Since = [datetimeoffset]::Parse([string]$receipt.started_utc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
        }
    }
}

function Invoke-LocalDiagnosticTool {
    param([string]$FileName, [string[]]$ToolArguments, [int]$TimeoutSeconds = 30)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName
    $info.WorkingDirectory = $workspace
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($value in $ToolArguments) { $info.ArgumentList.Add($value) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $info
    try {
        if (-not $child.Start()) { throw "Could not start diagnostic tool: $FileName" }
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        $timedOut = -not $child.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) { $child.Kill(); $child.WaitForExit() }
        [ordered]@{
            executable = $FileName
            arguments = $ToolArguments
            exit_code = $child.ExitCode
            timed_out = $timedOut
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $child.Dispose() }
}

function Resolve-LocalOffset {
    param([string]$ImagePath, [string]$Offset)
    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        return [ordered]@{ status = 'module-file-unavailable'; module = $ImagePath; offset = $Offset }
    }
    if ($Offset -notmatch '^(0x)?[0-9a-fA-F]+$') { throw "Invalid module-relative hexadecimal offset: $Offset" }
    $normalized = '0x' + ($Offset -replace '^0x', '')
    Invoke-LocalDiagnosticTool $symbolizer @('--no-debuginfod', '--relative-address',
        '--inlines', '--demangle', '--output-style=JSON', "--obj=$ImagePath", $normalized)
}

if ($Mode -eq 'Inventory') {
    [ordered]@{
        cdb = $cdb
        cdb_available = (Test-Path -LiteralPath $cdb -PathType Leaf)
        symbolizer = $symbolizer
        symbolizer_available = (Test-Path -LiteralPath $symbolizer -PathType Leaf)
        lldb_available = (Test-Path -LiteralPath (Join-Path $llvmBin 'lldb.exe') -PathType Leaf)
        event_provider = 'Application Error'
        event_id = 1000
        scope = 'Exact target image path, optional process ID, and start time; no global registry or WER changes.'
    }
    return
}

if (-not $OutputDirectory) {
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $OutputDirectory = Join-Path $workspace "docs\reports\toolchain-diagnostics-$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

if ($Mode -eq 'SymbolizeOffset') {
    if (-not $ModulePath -or -not $RelativeOffset) { throw 'SymbolizeOffset requires -ModulePath and -RelativeOffset.' }
    $result = Resolve-LocalOffset $ModulePath $RelativeOffset
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'symbols.json') -Encoding utf8
    $result
    return
}

if ($Mode -eq 'Events') {
    if (-not $Executable) { throw 'Events requires an exact -Executable path or a native -ReceiptPath.' }
    $Executable = [IO.Path]::GetFullPath($Executable)
    # Named EventData filtering happens in the event query, before anything is returned.
    $filter = @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000;
        StartTime = $Since; AppPath = $Executable }
    $events = @()
    try { $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 8 -ErrorAction Stop) }
    catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
    $records = @()
    foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $fields = @{}
        foreach ($entry in $xml.Event.EventData.Data) { $fields[[string]$entry.Name] = [string]$entry.'#text' }
        $eventPidText = [string]$fields.ProcessId
        $eventPid = if ($eventPidText -match '^0x') {
            [Convert]::ToUInt32($eventPidText.Substring(2), 16)
        } else { [uint32]$eventPidText }
        if ($TargetProcessId -ne 0 -and $eventPid -ne $TargetProcessId) { continue }
        if (-not [string]::Equals($fields.AppPath, $Executable, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $record = [ordered]@{
            recorded_utc = $event.TimeCreated.ToUniversalTime().ToString('o')
            event_record_id = $event.RecordId
            process_id = $eventPid
            executable = $fields.AppPath
            module_path = $fields.ModulePath
            exception_code = $fields.ExceptionCode
            module_relative_fault_offset = $fields.FaultingOffset
            symbols = $null
        }
        if ($fields.ModulePath -and $fields.FaultingOffset) {
            $record.symbols = Resolve-LocalOffset $fields.ModulePath $fields.FaultingOffset
        }
        $event.ToXml() | Set-Content -LiteralPath (Join-Path $OutputDirectory "event-$($event.RecordId).xml") -Encoding utf8
        $records += $record
    }
    $report = [ordered]@{
        executable = $Executable
        target_process_id = $TargetProcessId
        since_utc = $Since.ToUniversalTime().ToString('o')
        matched_events = $records.Count
        events = $records
        limitation = 'No matching event does not prove a clean exit. Event 1000 provides a fault offset, not a complete stack.'
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'events.json') -Encoding utf8
    $report
    return
}
