[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GeneratedDirectory,
    [string]$WorkspaceRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($GeneratedDirectory)
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Filter 'ppc_recomp.*.cpp' -File)
if (-not $sourceFiles.Count) { throw "No Xenon output in $sourceRoot" }
$imagePath = Join-Path $WorkspaceRoot 'analysis/title-default-image.bin'
$imageSha256 = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($imageSha256 -ne '9771b34a1a981350a24a9c1b0e72a5fbbbe0f2815d448a297b3d2989f32c263c') {
    throw 'The loaded game image differs from the reviewed CoD3 TU0 image'
}
$specs = @(
    @{ Address = '822D0498'; Offset = 0x2D0498; Bytes = '4BFFFC80'; Code = 'PPC_FUNC_PROLOGUE();sub_822D0118(ctx,base);return;' },
    @{ Address = '822D2140'; Offset = 0x2D2140; Bytes = '386300044BFF98E4'; Code = 'PPC_FUNC_PROLOGUE();ctx.r3.s64=ctx.r3.s64+4;sub_822CBA28(ctx,base);return;' }
)
$image = [IO.File]::OpenRead($imagePath)
$selected = @()
try {
    foreach ($spec in $specs) {
        $bytes = [byte[]]::new($spec.Bytes.Length / 2)
        $null = $image.Seek($spec.Offset, [IO.SeekOrigin]::Begin)
        if ($image.Read($bytes, 0, $bytes.Length) -ne $bytes.Length -or [Convert]::ToHexString($bytes) -ne $spec.Bytes) {
            throw "PPC opcode mismatch at 0x$($spec.Address)"
        }
        $pattern = '(?ms)^PPC_FUNC_IMPL\(__imp__sub_' + $spec.Address + '\)\s*\{\s*(.*?)^\}'
        $matchesFound = @()
        foreach ($source in $sourceFiles) {
            $text = Get-Content -LiteralPath $source.FullName -Raw
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $code = [regex]::Replace($match.Groups[1].Value, '(?m)//[^\r\n]*', '')
                $code = [regex]::Replace($code, '\s+', '')
                if ($code -cne $spec.Code) { throw "Unexpected generated body at 0x$($spec.Address); requires a new review" }
                $matchesFound += [pscustomobject]@{
                    guestAddress = "0x$($spec.Address)"
                    instructionBytes = $spec.Bytes
                    sourceFile = $source.FullName
                    sourceSha256 = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    sourceLine = 1 + ([regex]::Matches($text.Substring(0, $match.Index), "`n")).Count
                    body = $match.Value
                }
            }
        }
        if ($matchesFound.Count -ne 1) { throw "Expected exactly one generated body for 0x$($spec.Address), found $($matchesFound.Count)" }
        $selected += $matchesFound[0]
    }
} finally { $image.Dispose() }
$outputRoot = Join-Path $PSScriptRoot 'generated'
$null = New-Item -ItemType Directory -Path $outputRoot -Force
$output = "// Selected verbatim from real XenonRecomp output; do not hand-edit.`n// Provenance: thunks.provenance.json. Only symbols are renamed by the includer.`n`n" + (($selected | ForEach-Object body) -join "`n`n") + "`n"
[IO.File]::WriteAllText((Join-Path $outputRoot 'thunks.generated.inl'), $output, [Text.UTF8Encoding]::new($false))
$receipt = [ordered]@{
    checkedUtc = [DateTime]::UtcNow.ToString('o')
    xenonCommit = 'ddd128bcca99fe8bfbb99bea583c972351fa6ace'
    rexglueCommit = '0c7b01a0ac0479801757507d80533f662fa0815d'
    imageBase = '0x82000000'
    imageSha256 = $imageSha256
    generatedSha256 = (Get-FileHash -LiteralPath (Join-Path $outputRoot 'thunks.generated.inl') -Algorithm SHA256).Hash.ToLowerInvariant()
    functions = @($selected | Select-Object guestAddress,instructionBytes,sourceFile,sourceSha256,sourceLine)
    adaptation = 'Verbatim function bodies; macro-only symbol rename and exact ReXGlue context. Compile with -fwrapv. No general Xenon ABI bridge.'
}
$receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot 'thunks.provenance.json') -Encoding utf8
$receipt | ConvertTo-Json -Depth 6
