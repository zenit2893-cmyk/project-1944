#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'extract-disc-safety.ps1')
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$analysis = Join-Path $workspace 'analysis'
$fixture = Join-Path $analysis ('disc-safety-fixtures-' + [guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $fixture | Out-Null

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-Check {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $results.Add([pscustomobject]@{ Name = $Name; Passed = $true })
}
function Expect-Refusal {
    param([scriptblock]$Body, [string]$MessagePattern)
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    if (-not $caught) { throw 'Expected a refusal, but the operation succeeded' }
    if ($MessagePattern -and $caught.Exception.Message -notmatch $MessagePattern) { throw $caught }
}

try {
    $image = Join-Path $fixture 'input.iso'
    [IO.File]::WriteAllText($image, 'tiny synthetic disc input')
    $tool = Join-Path $workspace 'tools\xdvdfs\xdvdfs.exe'
    $destination = Join-Path $fixture 'assets'
    $reports = Join-Path $fixture 'reports'
    $reportNames = @('disc-image-tree.txt', 'disc-extraction.json')
    $layout = @{ Image = $image; Tool = $tool; Destination = $destination; ReportDirectory = $reports; ReportNames = $reportNames }

    Invoke-Check 'production scripts parse' {
        foreach ($name in @('extract-cod3.ps1', 'extract-disc-safety.ps1')) {
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$null, [ref]$parseErrors)
            Assert-Check (-not $parseErrors) "Parse errors in $name"
        }
    }
    Invoke-Check 'safe nonexistent layout produces no directories' {
        Assert-DiscOutputLayout @layout
        Assert-Check (-not (Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $reports)) 'Preflight created outputs'
    }
    Invoke-Check 'equal and nested outputs refused without mutation' {
        foreach ($badReports in @($destination, (Join-Path $destination 'reports'), $fixture)) {
            $badLayout = $layout.Clone(); $badLayout.ReportDirectory = $badReports
            Expect-Refusal { Assert-DiscOutputLayout @badLayout } 'must not overlap'
        }
        Assert-Check (-not (Test-Path -LiteralPath $destination)) 'Overlap preflight created an output'
    }
    Invoke-Check 'input inside report tree and drive-root output refused' {
        $badLayout = $layout.Clone(); $badLayout.ReportDirectory = Join-Path $fixture 'input-container'
        $badLayout.Image = Join-Path $badLayout.ReportDirectory 'disc-image-tree.txt'
        Expect-Refusal { Assert-DiscOutputLayout @badLayout } 'outside output directories'
        $badLayout = $layout.Clone(); $badLayout.Destination = [IO.Path]::GetPathRoot($fixture)
        Expect-Refusal { Assert-DiscOutputLayout @badLayout } 'drive root'
    }
    Invoke-Check 'junction in destination and report ancestors refused' {
        $outside = Join-Path $fixture 'redirected-content'
        $junction = Join-Path $fixture 'junction'
        New-Item -ItemType Directory -Path $outside | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $badLayout = $layout.Clone(); $badLayout.Destination = Join-Path $junction 'new-assets'
        Expect-Refusal { Assert-DiscOutputLayout @badLayout } 'reparse point'
        $badLayout = $layout.Clone(); $badLayout.ReportDirectory = Join-Path $junction 'new-reports'
        Expect-Refusal { Assert-DiscOutputLayout @badLayout } 'reparse point'
        Assert-Check (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'Redirected content changed'
    }
    Invoke-Check 'traversal, stream aliases and Windows filename aliases refused' {
        foreach ($path in @('/../outside', '/a/../../outside', '/name:stream', '/CON.txt', '/LPT1', '/a//b', '//server/file', '/trailing.', '/trailing ', '/a\b', '/name?.cod')) {
            Expect-Refusal { Resolve-DiscImageEntry -ImagePath $path -Destination $destination } 'Unsafe|Escaping'
        }
        foreach ($path in @('/default.xex', '/sp/saint_lo/saint_lo.dll', '/$SystemUpdate/', '/movies/Treyarch.wma')) {
            $entry = Resolve-DiscImageEntry -ImagePath $path -Destination $destination
            Assert-Check (Test-DiscPathWithin $entry.Target $destination) "Safe entry resolved outside destination: $path"
        }
    }
    Invoke-Check 'all real disc entry paths accepted without copying files' {
        $count = 0
        foreach ($line in Get-Content -LiteralPath (Join-Path $analysis 'disc-image-tree.txt')) {
            if ($line -match '^(/.+) \((\d+) bytes\)$') {
                [void](Resolve-DiscImageEntry -ImagePath $Matches[1] -Destination $destination)
                $count++
            }
        }
        Assert-Check ($count -eq 594) "Expected 594 real entries, got $count"
    }
    Invoke-Check 'unknown and changed assets refused, correct asset preserved' {
        New-Item -ItemType Directory -Path $destination | Out-Null
        $asset = Join-Path $destination 'default.xex'
        [IO.File]::WriteAllText($asset, 'original tiny asset')
        $before = (Get-Item -LiteralPath $asset).LastWriteTimeUtc
        $known = @{ 'default.xex' = [pscustomobject]@{ Length = (Get-Item -LiteralPath $asset).Length; SourceMD5 = (Get-FileHash -LiteralPath $asset -Algorithm MD5).Hash } }
        Assert-DiscExistingContent -Destination $destination -Files $known -Directories @{}
        Assert-Check ((Get-Item -LiteralPath $asset).LastWriteTimeUtc -eq $before) 'Correct existing file was rewritten'
        $unknown = Join-Path $destination 'user-note.txt'
        [IO.File]::WriteAllText($unknown, 'keep this note')
        Expect-Refusal { Assert-DiscExistingContent -Destination $destination -Files $known -Directories @{} } 'Unknown existing file'
        Assert-Check ([IO.File]::ReadAllText($unknown) -eq 'keep this note') 'Unknown file was changed'
        [IO.File]::Delete($unknown)
        [IO.File]::WriteAllText($asset, 'changed tiny asset')
        Expect-Refusal { Assert-DiscExistingContent -Destination $destination -Files $known -Directories @{} } 'differs from source'
        Assert-Check ([IO.File]::ReadAllText($asset) -eq 'changed tiny asset') 'Changed file was overwritten'
    }
    Invoke-Check 'source read lock denies writes and permits readers' {
        $before = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
        $guard = Open-DiscSourceReadLock $image
        try {
            $reader = [IO.File]::Open($image, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $reader.Dispose()
            Expect-Refusal { [IO.File]::WriteAllText($image, 'must not be written') } ''
        } finally { $guard.Dispose() }
        Assert-Check ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -eq $before) 'Read-locked source changed'
    }
    Invoke-Check 'atomic report replacement preserves a hard-linked source' {
        New-Item -ItemType Directory -Path $reports | Out-Null
        $preserved = Join-Path $fixture 'preserved.txt'
        $report = Join-Path $reports 'disc-image-tree.txt'
        [IO.File]::WriteAllText($preserved, 'preserve original link target')
        New-Item -ItemType HardLink -Path $report -Target $preserved | Out-Null
        Write-DiscReport -Path $report -Lines @('replacement report')
        Assert-Check ([IO.File]::ReadAllText($preserved) -eq 'preserve original link target') 'Report write changed hard-linked source'
        Assert-Check ([IO.File]::ReadAllText($report).Trim() -eq 'replacement report') 'Report replacement did not succeed'
    }
    Invoke-Check 'full script rejects a changed source before creating output' {
        $badDestination = Join-Path $fixture 'hash-reject-assets'
        $badReports = Join-Path $fixture 'hash-reject-reports'
        Expect-Refusal { & (Join-Path $PSScriptRoot 'extract-cod3.ps1') -Image $image -Destination $badDestination -ReportDirectory $badReports -Tool $tool } 'Image SHA256 differs'
        Assert-Check (-not (Test-Path -LiteralPath $badDestination) -and -not (Test-Path -LiteralPath $badReports)) 'Bad source created output directories'
    }
    $result = [ordered]@{
        VerifiedUtc = [datetime]::UtcNow.ToString('o')
        Scope = 'Bounded synthetic filesystem cases plus read-only parsing of the existing 594-entry disc tree; no game extraction or ISO hashing rerun.'
        Passed = $results.Count
        Failed = 0
        Checks = @($results)
    }
    Write-DiscReport -Path (Join-Path $analysis 'disc-safety-checks.json') -Lines @($result | ConvertTo-Json -Depth 6)
    $result | ConvertTo-Json -Depth 6
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($analysis.TrimEnd('\') + '\disc-safety-fixtures-', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing cleanup outside the test fixture: $resolvedFixture"
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
