<#
.SYNOPSIS
    Refuses anything a public repository of Project 1944 must never contain.

.DESCRIPTION
    Checks the files git would commit (tracked plus untracked-not-ignored, run
    from the repository root) or, with -Path, every file under a folder:

      * game content by checksum: every file is hashed and compared with the
        SHA-256 of all 553 files of the supported disc
        (analysis/disc-file-manifest.csv) and of default.xex
        (analysis/disc-source-lock.json) - catches a renamed game file too;
      * game formats and dumps by extension (.iso .xex .cod .wbk .wma .wmv
        .bin ...), binaries (.exe .dll .lib .obj .pdb) and archives;
      * code generated from the game (cod3-pc/generated except the SDK
        scaffold and the partition sidecars, the Xenon and coroutine bridge
        outputs, analysis/title-*), logs, user data, caches, build output and
        toolchains;
      * the local launcher icon picture (a game box is the publisher's art);
      * files over 25 MB (GitHub refuses 100 MB and warns at 50 MB);
      * personal paths (C:\Users\<name>\) in text files - reported, and with
        -StrictPersonalPaths refused.

    Exit code 0 when clean, 1 with a list otherwise. Nothing is changed.

.EXAMPLE
    pwsh scripts/repo/Test-RepoContent.ps1
    pwsh scripts/repo/Test-RepoContent.ps1 -Path D:\staging\project-1944
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$StrictPersonalPaths
)

$ErrorActionPreference = 'Stop'
$root = if ($Path) { [IO.Path]::GetFullPath($Path) } else { (Get-Location).Path }

# ---- which files
if ($Path) {
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        ForEach-Object { $_.FullName.Substring($root.TrimEnd('\').Length + 1).Replace('\', '/') })
} else {
    $listed = & git -C $root ls-files --cached --others --exclude-standard -z
    if ($LASTEXITCODE -ne 0) { throw 'Not a git repository; pass -Path <folder>.' }
    $files = @(($listed -join '') -split "`0" | Where-Object { $_ })
}

# ---- rules
$bannedExtensions = @(
    '.iso', '.xex', '.cod', '.wbk', '.wma', '.wmv', '.bik', '.xma', '.xpr', '.xvd', '.god', '.stfs',   # game and console formats
    '.bin', '.dmp', '.xsh', '.xpso', '.kwj', '.dxil', '.spv',                                           # dumps and shader binaries
    '.exe', '.dll', '.lib', '.obj', '.o', '.pdb', '.ilk', '.exp', '.a', '.pch', '.ico',                 # build products
    '.zip', '.7z', '.rar', '.cab', '.msi', '.vsix')                                                     # archives
$bannedPaths = @(
    '^game/', '^cod3/', '(^|/)logs/', '(^|/)userdata/', '(^|/)cache/', '(^|/)out/', '(^|/)build/',
    '(^|/)staging/', '(^|/)artifacts/', '(^|/)__pycache__/',
    '^tools/toolchain/', '^tools/toolchain-bundle/', '^tools/(cmake|ninja|pwsh|uv|xdvdfs)/',
    '^integration/xenon/generated/', '^integration/coroutines/generated/', '^integration/coroutines/templates/codegen/',
    '^analysis/title-', '^analysis/dev-python/', '^analysis/.*-generated/',
    '^launcher/exe/icon-source\.', '^launcher/exe/bin/')
$allowedGenerated = @('^cod3-pc/generated/rexglue\.cmake$', '^cod3-pc/generated/[a-z0-9_]+/codegen\.partition\.json$')
$maxBytes = 25MB

# The disc, file by file.
$gameHashes = @{}
$manifest = Join-Path $root 'analysis/disc-file-manifest.csv'
if (Test-Path -LiteralPath $manifest) {
    foreach ($row in Import-Csv -LiteralPath $manifest) { $gameHashes[$row.SHA256.ToUpperInvariant()] = $row.Path }
}
$lock = Join-Path $root 'analysis/disc-source-lock.json'
if (Test-Path -LiteralPath $lock) {
    $lockData = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json
    $gameHashes[([string]$lockData.expected_default_xex.sha256).ToUpperInvariant()] = 'default.xex'
    $gameHashes[([string]$lockData.expected_iso.sha256).ToUpperInvariant()] = 'the disc image'
}
if ($gameHashes.Count -eq 0) { Write-Warning 'No disc checksums found (analysis/disc-file-manifest.csv); the content check is skipped.' }

$problems = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$textExtensions = @('.md', '.txt', '.ps1', '.psm1', '.py', '.json', '.toml', '.cmake', '.yml', '.yaml', '.cmd', '.bat', '.cpp', '.h', '.cs', '.inja', '.csv')

foreach ($relative in $files) {
    $full = Join-Path $root ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $lower = $relative.ToLowerInvariant()
    $item = Get-Item -LiteralPath $full -Force

    if ($lower -match '^cod3-pc/generated/') {
        if (-not ($allowedGenerated | Where-Object { $lower -match $_ })) { $problems.Add("generated from the game: $relative"); continue }
    }
    $pathRule = $bannedPaths | Where-Object { $lower -match $_ } | Select-Object -First 1
    if ($pathRule) { $problems.Add("not for the repository ($pathRule): $relative"); continue }
    $extension = [IO.Path]::GetExtension($lower)
    if ($extension -in $bannedExtensions) { $problems.Add("banned file type ${extension}: $relative"); continue }
    if ($item.Length -gt $maxBytes) { $problems.Add(("too large ({0:n0} MB): {1}" -f ($item.Length / 1MB), $relative)); continue }

    if ($gameHashes.Count -gt 0 -and $item.Length -gt 0) {
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($gameHashes.ContainsKey($hash)) { $problems.Add("identical to the game's $($gameHashes[$hash]): $relative"); continue }
    }
    if ($extension -in $textExtensions -and $item.Length -lt 5MB) {
        $hit = Select-String -LiteralPath $full -Pattern '[A-Za-z]:\\+Users\\+(?!Public\\|<)[^\\/"''\s]+' -List -ErrorAction SilentlyContinue
        if ($hit) {
            $message = "personal path in ${relative}:$($hit.LineNumber): $($hit.Matches[0].Value)"
            if ($StrictPersonalPaths) { $problems.Add($message) } else { $warnings.Add($message) }
        }
    }
}

Write-Host ("Checked {0} files under {1}" -f $files.Count, $root)
foreach ($warning in $warnings) { Write-Host "  warning: $warning" }
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host "  REFUSED: $problem" }
    Write-Host "$($problems.Count) file(s) must not be published."
    exit 1
}
Write-Host 'Clean: nothing from the game, no build products, no oversized files.'
exit 0
