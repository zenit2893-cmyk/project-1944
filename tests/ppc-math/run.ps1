[CmdletBinding()]
param([switch]$SkipInventory)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $workspaceRoot 'scripts\toolchain-env.ps1') -Quiet

$pythonPath = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "Python runtime not found: $pythonPath"
}

$extractArgs = @((Join-Path $PSScriptRoot 'extract_blocks.py'))
if (-not $SkipInventory) { $extractArgs += '--inventory' }
& $pythonPath @extractArgs
if ($LASTEXITCODE -ne 0) { throw 'Exact generated CoD3 block extraction failed.' }

$binary = Join-Path $PSScriptRoot 'ppc_math_precision_test.exe'
$compileFlags = @(
    '-std=c++23', '-O2', '-ffp-model=strict', '-ffp-contract=off',
    '-fno-strict-aliasing', '-fwrapv', '-mavx2', '-mfma',
    '-Wno-ignored-attributes'
)
& $env:CXX @compileFlags '-I' (Join-Path $workspaceRoot 'win-amd64\include') `
    (Join-Path $PSScriptRoot 'precision_test.cpp') '-o' $binary
if ($LASTEXITCODE -ne 0) { throw 'PPC/VMX precision harness compilation failed.' }

$lines = & $binary
$testExitCode = $LASTEXITCODE
$records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
$summary = $records | Where-Object { $_.summary } | Select-Object -Last 1
$xeniaFiles = @(
    'tools\Xenia-source\src\xenia\cpu\ppc\ppc_emit_altivec.cc',
    'tools\Xenia-source\src\xenia\cpu\backend\x64\x64_sequences.cc',
    'tools\Xenia-source\src\xenia\cpu\backend\x64\x64_seq_vector.cc',
    'tools\Xenia-source\src\xenia\base\math.h'
)
$xeniaSourceHashes = [ordered]@{}
foreach ($relative in $xeniaFiles) {
    $path = Join-Path $workspaceRoot $relative
    $xeniaSourceHashes[$relative.Replace('\', '/')] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

$reportPath = Join-Path $workspaceRoot 'docs\reports\ppc-math-precision.json'
$report = [ordered]@{
    schema_version = 1
    checked_at_utc = [DateTime]::UtcNow.ToString('o')
    workspace = $workspaceRoot
    target = 'native Windows x64 AVX2/FMA PPC/VMX differential harness'
    compiler = (& $env:CXX '--version' | Select-Object -First 1)
    compile_flags = $compileFlags
    cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    xenia_commit = '0e1307bd2e6bfeeff29635a6b823e72e61c97ce9'
    rexglue_commit = '0c7b01a0ac0479801757507d80533f662fa0815d'
    xenia_source_sha256 = $xeniaSourceHashes
    rexglue_context_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workspaceRoot 'win-amd64\include\rex\ppc\context.h')).Hash.ToLowerInvariant()
    candidate_header_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workspaceRoot 'integration\ppc-math\vmx_semantics.h')).Hash.ToLowerInvariant()
    test_binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash.ToLowerInvariant()
    generated_blocks = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'actual_blocks.json') -Raw | ConvertFrom-Json)
    results = $records
    summary = $summary
    exit_code = $testExitCode
    guarded_patch = [ordered]@{
        enabled = $false
        default_macro = 'COD3_PPC_MATH_ENABLE_GUARDED_PATCH=0'
        integrated_into_game = $false
        sdk_modified = $false
        game_assets_modified = $false
        abi_checked = $true
    }
    game_executed = $false
    fps_or_physics_validation = $false
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
$records | Where-Object { $_.summary -or $_.candidate_pass -eq $false } | ConvertTo-Json -Depth 8
Write-Host "PPC/VMX precision report: $reportPath"
if ($testExitCode -ne 0) { throw "PPC/VMX precision test exit code $testExitCode (see report)." }
