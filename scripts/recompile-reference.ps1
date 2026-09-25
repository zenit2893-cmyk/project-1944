# What a recompilation produces and what it is compiled with - shared by the
# packager, which records it for the build it ships, and by
# complete-recompile.ps1, which compares a fresh recompilation against it.
#
# generated  the C++ code generation writes from the game's own code
#            (default.xex and the level modules), the two Xenon bridge thunks
#            and the coroutine bridge - everything derived from the game that
#            the compiler reads. Bookkeeping next to it (stamps, depfiles,
#            JSON notes with local paths) is left out.
# sources    the port's own code and the SDK it links: what the compiler reads
#            besides the generated code, as the package ships it.
#
# Only SHA-256 hashes of these files are recorded; no code travels.

$script:RecompileGeneratedRules = @(
    @{ Root = 'cod3-pc/generated'; Extensions = @('.cpp', '.h', '.cmake') },
    @{ Root = 'integration/xenon/generated'; Extensions = @('.inl') },
    @{ Root = 'integration/coroutines/generated'; Extensions = @('.cpp', '.cmake') },
    @{ Root = 'integration/coroutines/templates/codegen'; Extensions = @('.inja') }
)
$script:RecompileSourceRoots = @('cod3-pc', 'integration', 'win-amd64')
$script:RecompileSourceFiles = @('scripts/build-cod3.ps1', 'scripts/toolchain-env.ps1')

function Get-RecompileRelativePath([string]$Root, [string]$Path) {
    return $Path.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
}

function Get-RecompileGeneratedFiles([string]$Root) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($rule in $script:RecompileGeneratedRules) {
        $folder = Join-Path $Root ($rule.Root -replace '/', '\')
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -Recurse -File -Force) {
            if ([IO.Path]::GetExtension($file.Name).ToLowerInvariant() -in $rule.Extensions) {
                $list.Add((Get-RecompileRelativePath $Root $file.FullName))
            }
        }
    }
    return @($list | Sort-Object -Unique)
}

function Test-RecompileSourcePath([string]$Relative) {
    # Generated code, build output and per-user folders are not sources; nor
    # are documents, which the compiler never reads.
    $lower = $Relative.ToLowerInvariant()
    foreach ($segment in ($lower -split '/')) {
        if ($segment -in @('generated', 'out', 'build', 'userdata', 'cache', '__pycache__')) { return $false }
    }
    if ($lower.StartsWith('integration/coroutines/templates/codegen/')) { return $false }
    # The coroutine bridge's own receipt, rewritten on every preparation.
    if ($lower -eq 'integration/coroutines/prepared.json') { return $false }
    if ($lower.StartsWith('win-amd64/bin/') -and $lower.EndsWith('.exe')) { return $false }
    return [IO.Path]::GetExtension($lower) -notin @('.md', '.txt', '.png', '.jpg')
}

function Get-RecompileSourceFiles([string]$Root) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($sourceRoot in $script:RecompileSourceRoots) {
        $folder = Join-Path $Root ($sourceRoot -replace '/', '\')
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -Recurse -File -Force) {
            $relative = Get-RecompileRelativePath $Root $file.FullName
            if (Test-RecompileSourcePath $relative) { $list.Add($relative) }
        }
    }
    foreach ($relative in $script:RecompileSourceFiles) {
        if (Test-Path -LiteralPath (Join-Path $Root ($relative -replace '/', '\')) -PathType Leaf) { $list.Add($relative) }
    }
    return @($list | Sort-Object -Unique)
}

function Get-RecompileHashes([string]$Root, [string[]]$Relative) {
    $hashes = [ordered]@{}
    foreach ($path in $Relative) {
        $hashes[$path] = (Get-FileHash -LiteralPath (Join-Path $Root ($path -replace '/', '\')) -Algorithm SHA256).Hash
    }
    return $hashes
}
