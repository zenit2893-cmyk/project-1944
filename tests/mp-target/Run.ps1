[CmdletBinding()]
param(
    [switch]$Build,
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string]$Configuration = 'RelWithDebInfo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mpXex = Join-Path $workspace 'game\cod3\codmp_xenonf.xex'
$metadataPath = Join-Path $workspace 'integration\mp-target\mp-title-metadata.json'
$imageMetadataPath = Join-Path $workspace 'integration\mp-target\mp-image.json'
$imagePath = Join-Path $workspace 'integration\mp-target\mp-image.bin'
$xenonConfig = Join-Path $workspace 'integration\mp-target\mp-xenon.toml'
$xenonLog = Join-Path $workspace 'integration\mp-target\xenonrecomp.log'
$xenonOutput = Join-Path $workspace 'integration\mp-target\xenon-generated'
$project = Join-Path $workspace 'integration\mp-target\rexglue'
$manifest = Join-Path $project 'cod3_mp_manifest.toml'
$cmakeFile = Join-Path $project 'CMakeLists.txt'
$pathAdapter = Join-Path $project 'cmake\ReXGlueProject.cmake'
$appFile = Join-Path $project 'src\cod3_mp_app.h'
$generated = Join-Path $project 'generated\codmp_xenonf'
$buildDir = Join-Path $project ('out\build\win-amd64-' + $Configuration.ToLowerInvariant())

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Id, [bool]$Passed, [string]$Details) {
    $checks.Add([ordered]@{
        id = $Id
        status = if ($Passed) { 'PASS' } else { 'FAIL' }
        details = $Details
    })
}
function Read-Required([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required MP artifact is missing: $Path"
    }
    return [IO.File]::ReadAllText($Path)
}
function Hash-Required([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required MP artifact is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$expectedXexHash = 'bd57d0df66172ed58163fcfb8a814640dddda3dac07ce2d6b79bf226b20982f6'
$actualXexHash = Hash-Required $mpXex
Add-Check 'mp-xex-hash' ($actualXexHash -eq $expectedXexHash) "codmp_xenonf.xex SHA256=$actualXexHash"

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$imageMetadata = Get-Content -LiteralPath $imageMetadataPath -Raw | ConvertFrom-Json
Add-Check 'mp-container-identity' (
    $metadata.source.sha256 -eq $expectedXexHash -and
    $metadata.entry_point -eq '0x823140C8' -and
    $metadata.image_base -eq '0x82000000' -and
    $metadata.original_pe_name -eq 'codmp_xenonf.pe' -and
    $metadata.file_format.encryption -eq 'normal' -and
    $metadata.file_format.compression -eq 'basic'
) 'XEX2 headers record the MP entrypoint, image base, PE name, and normal/basic format.'
Add-Check 'mp-image-layout' (
    $imageMetadata.source_xex_sha256 -eq $expectedXexHash -and
    $imageMetadata.image_size -eq 14811136 -and
    $imageMetadata.pe.base -eq '0x82000000' -and
    $imageMetadata.pe.entry_point -eq '0x823140C8' -and
    $imageMetadata.pe.sections[2].address -eq '0x820B0000' -and
    $imageMetadata.pe.sections[2].virtual_size -eq 5186004
) 'Reconstructed MP image is 14,811,136 bytes with .text at 0x820B0000.'
Add-Check 'mp-image-hash' ((Hash-Required $imagePath) -eq $imageMetadata.image_sha256.ToLowerInvariant()) 'Reconstructed image matches its analysis receipt.'

$manifestText = Read-Required $manifest
$manifestIsSeparate = (
    $manifestText -match '(?m)^name\s*=\s*"cod3_mp"' -and
    $manifestText -match '(?m)^file_path\s*=\s*"\.\./\.\./\.\./game/cod3/codmp_xenonf\.xex"' -and
    $manifestText -match '(?m)^0x82298D38\s*=\s*\{\s*size\s*=\s*8\s*\}' -and
    $manifestText -notmatch '(?i)default\.xex|cod3-pc|generated/default'
)
Add-Check 'mp-manifest-isolated' $manifestIsSeparate 'cod3_mp manifest points only at codmp_xenonf.xex and its own generated directory.'

$xenonConfigText = Read-Required $xenonConfig
$xenonConfigIsolated = (
    $xenonConfigText -match '(?m)^file_path\s*=\s*"\.\./\.\./game/cod3/codmp_xenonf\.xex"' -and
    $xenonConfigText -match '(?m)^out_directory_path\s*=\s*"xenon-generated"' -and
    $xenonConfigText -match '(?m)^restgprlr_14_address\s*=\s*0x8231E710' -and
    $xenonConfigText -notmatch '(?i)default\.xex|cod3-pc|generated/default'
)
Add-Check 'xenon-config-isolated' $xenonConfigIsolated 'XenonRecomp has a separate MP input and output path with MP helper addresses.'

$cmakeText = Read-Required $cmakeFile
$appText = Read-Required $appFile
$adapterText = Read-Required $pathAdapter
Add-Check 'mp-native-launcher-path' (
    $appText -match '(?m)^\s*xex_image\s*=\s*"game:\\\\codmp_xenonf\.xex";'
) 'Cod3MpApp overrides ReXApp default loading to game:\\codmp_xenonf.xex.'
Add-Check 'mp-native-cmake-target' (
    $cmakeText -match '(?m)^project\(cod3_mp LANGUAGES CXX\)' -and
    $cmakeText -match '(?m)^rexglue_setup_target\(cod3_mp GPU_PLUGINS xenos\)' -and
    $cmakeText -match '(?m)^include\(cmake/ReXGlueProject\.cmake\)'
) 'Native cod3_mp uses the installed ReXGlue runtime and the shared Xenos GPU plugin.'
Add-Check 'mp-path-parser-adapter' (
    $adapterText -match '(?m)^\s*"COMMAND \$<TARGET_FILE:rex::rexglue> codegen cod3_mp_manifest\.toml"'
) 'The local adapter keeps the manifest relative to avoid the SDK narrow-path bug.'

$generatedPch = Read-Required (Join-Path $generated 'cod3_mp_pch.h')
$generatedInit = Read-Required (Join-Path $generated 'cod3_mp_init.cpp')
$generatedFuncs = Read-Required (Join-Path $generated 'cod3_mp_funcs.h')
$sourcesText = Read-Required (Join-Path $generated 'sources.cmake')
$depText = Read-Required (Join-Path $generated 'codegen.d')
$partition = Get-Content -LiteralPath (Join-Path $generated 'codegen.partition.json') -Raw | ConvertFrom-Json
$recompCount = @([regex]::Matches($sourcesText, 'cod3_mp_recomp\.\d+\.cpp')).Count
$headerCount = @(Get-ChildItem -LiteralPath $generated -File -Filter 'cod3_mp_funcs.*.h').Count
Add-Check 'mp-generated-image-map' (
    $generatedPch -match '(?m)^#define REX_IMAGE_BASE 0x82000000ull$' -and
    $generatedPch -match '(?m)^#define REX_IMAGE_SIZE 0xE20000ull$' -and
    $generatedPch -match '(?m)^#define REX_CODE_BASE 0x820B0000ull$' -and
    $generatedPch -match '(?m)^#define REX_CODE_SIZE 0x4F21D4ull$' -and
    $generatedInit -match '(?m)\{ 0x823140C8, xstart \}'
) 'Generated PPCImageInfo and mapping use the MP image span and MP entrypoint.'
$spPchPath = Join-Path $workspace 'cod3-pc\generated\default\cod3_pc_pch.h'
$spPch = Read-Required $spPchPath
Add-Check 'mp-sp-map-separated' (
    $spPch -match '(?m)^#define REX_IMAGE_SIZE 0xC30000ull$' -and
    $spPch -match '(?m)^#define REX_CODE_BASE 0x820A0000ull$' -and
    $generatedPch -match '(?m)^#define REX_IMAGE_SIZE 0xE20000ull$' -and
    $generatedPch -match '(?m)^#define REX_CODE_BASE 0x820B0000ull$'
) 'SP and MP have distinct generated image/code spans even though both load at 0x82000000.'
Add-Check 'mp-network-import-surface' (
    $generatedFuncs -match '__imp__NetDll_XNetStartup' -and
    $generatedFuncs -match '__imp__NetDll_socket' -and
    $generatedFuncs -match '__imp__NetDll_sendto' -and
    $generatedFuncs -match '__imp__XamSessionCreateHandle'
) 'MP generated imports include XNet socket/QoS and XAM session surfaces; implementation still needs runtime testing.'
Add-Check 'mp-generated-complete-set' (
    $partition.file_count -eq 88 -and $recompCount -eq 88 -and $headerCount -eq 88 -and
    $depText -match 'codmp_xenonf\.xex' -and $depText -notmatch '(?i)default\.xex|cod3-pc'
) "ReXGlue generated 88 recompilation units and 88 per-file declaration headers ($recompCount/$headerCount)."

$xenonLogText = Read-Required $xenonLog
$xenonOutputCount = @(Get-ChildItem -LiteralPath $xenonOutput -File -ErrorAction Stop).Count
Add-Check 'xenon-codegen-completed' (
    $xenonLogText -match 'Recompiling functions\.\.\. 100%' -and
    $xenonOutputCount -ge 100
) "XenonRecomp completed its isolated MP pass with $xenonOutputCount output files."

$initialCodegenLog = Join-Path $workspace 'integration\mp-target\rexglue-codegen.log'
$finalCodegenLog = Join-Path $workspace 'integration\mp-target\rexglue-codegen-after-boundary.log'
$initialText = Read-Required $initialCodegenLog
$finalText = Read-Required $finalCodegenLog
Add-Check 'mp-initial-blocker-recorded' (
    $initialText -match 'UnresolvedCall' -and $initialText -match '0x82298D38' -and
    $initialText -match '0x822990E4'
) 'The first strict ReXGlue pass recorded the single unresolved 8-byte tail thunk.'
Add-Check 'mp-rexglue-codegen' (
    $finalText -match 'Codegen summary: 183 written' -and
    $finalText -notmatch '(?m)^Failed:'
) 'The isolated ReXGlue pass completed after the evidence-backed boundary declaration.'

if ($Build) {
    . (Join-Path $workspace 'scripts\toolchain-env.ps1') -Quiet
    $sdk = (Resolve-Path (Join-Path $workspace 'win-amd64')).Path.Replace('\', '/')
    Push-Location $project
    try {
        & cmake --preset ("win-amd64-" + $Configuration.ToLowerInvariant()) "-DCMAKE_PREFIX_PATH=$sdk" "-DREXSDK_VERSION=0.10.0.5"
        if ($LASTEXITCODE -ne 0) { throw "MP CMake configure failed: $LASTEXITCODE" }
        & cmake --build --preset ("win-amd64-" + $Configuration.ToLowerInvariant()) --parallel 4
        if ($LASTEXITCODE -ne 0) { throw "MP native build failed: $LASTEXITCODE" }
    }
    finally { Pop-Location }
}

$executable = Join-Path $buildDir 'cod3_mp.exe'
$nativePresent = Test-Path -LiteralPath $executable -PathType Leaf
$nativeDetails = if ($nativePresent) {
    "cod3_mp.exe bytes=$((Get-Item -LiteralPath $executable).Length) SHA256=$(Hash-Required $executable)"
} else {
    'Native executable is not present; pass -Build to compile the isolated target.'
}
Add-Check 'mp-native-build' ($nativePresent -or -not $Build) $nativeDetails

$failed = @($checks | Where-Object { $_.status -eq 'FAIL' })
$receipt = [ordered]@{
    schema_version = 1
    checked_utc = [DateTime]::UtcNow.ToString('o')
    target = 'cod3_mp'
    source_xex = $mpXex
    source_xex_sha256 = $actualXexHash
    configuration = $Configuration
    build_requested = [bool]$Build
    checks = @($checks.ToArray())
    passed = ($failed.Count -eq 0)
    gameplay_verified = $false
    multiplayer_verified = $false
    fps_120_verified = $false
    scope = 'Separate MP XEX identity, strict XenonRecomp/ReXGlue codegen, native target wiring, and build-only checks. No SP map reuse, emulator launch, network session, MP gameplay, or 120 FPS claim.'
}
$resultPath = Join-Path $PSScriptRoot 'results.json'
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$xenonUnrecognized = @([regex]::Matches($xenonLogText, '(?m)^Unrecognized instruction at')).Count
$xenonSwitchErrors = @([regex]::Matches($xenonLogText, '(?m)^ERROR: Switch case')).Count
$xenonFiles = @(Get-ChildItem -LiteralPath $xenonOutput -File)
$rexFiles = @(Get-ChildItem -LiteralPath $generated -File)
$rexCppUnits = @([regex]::Matches($sourcesText, 'cod3_mp_recomp\.\d+\.cpp')).Count
$codegenReport = [ordered]@{
    schema_version = 1
    checked_utc = [DateTime]::UtcNow.ToString('o')
    target = 'cod3_mp'
    source_xex = $mpXex
    source_xex_sha256 = $actualXexHash
    title_id = $metadata.execution_info.title_id
    media_id = $metadata.execution_info.media_id
    entry_point = $metadata.entry_point
    image_base = $metadata.image_base
    reconstructed_image_size = $imageMetadata.image_size
    reconstructed_image_sha256 = $imageMetadata.image_sha256
    mp_code_base = '0x820B0000'
    mp_code_size = '0x4F21D4'
    sp_code_base = '0x820A0000'
    sp_image_size = '0xC30000'
    boundary_fix = [ordered]@{
        address = '0x82298D38'
        size_bytes = 8
        instruction_bytes = '386300044BFF72E4'
        operation = 'addi r3,r3,4; b 0x82290020'
        next_function = '0x82298D40'
        initial_rexglue_error = 'UnresolvedCall from 0x822990E4'
    }
    xenon_helpers = [ordered]@{
        restgprlr_14 = '0x8231E710'
        savegprlr_14 = '0x8231E6C0'
        restfpr_14 = '0x8231EE7C'
        savefpr_14 = '0x8231EE30'
        restvmx_14 = '0x8231F168'
        savevmx_14 = '0x8231EED0'
        restvmx_64 = '0x8231F1FC'
        savevmx_64 = '0x8231EF64'
    }
    xenonrecomp = [ordered]@{
        exit_code = 0
        output_directory = $xenonOutput
        output_file_count = $xenonFiles.Count
        output_bytes = [int64](($xenonFiles | Measure-Object -Property Length -Sum).Sum)
        unrecognized_instruction_occurrences = $xenonUnrecognized
        switch_outside_function_diagnostics = $xenonSwitchErrors
        status = 'completed_with_diagnostics_not_linked'
    }
    rexglue = [ordered]@{
        sdk = '0.10.0.5-dev.g0c7b01a'
        source_commit = '0c7b01a0ac0479801757507d80533f662fa0815d'
        manifest = $manifest
        generated_directory = $generated
        generated_file_count = $rexFiles.Count
        generated_cpp_units = $rexCppUnits
        generated_function_headers = $headerCount
        codegen_log = $finalCodegenLog
        status = 'validated_and_written'
    }
    observed_network_imports = @(
        'NetDll_XNetStartup', 'NetDll_XNetConnect', 'NetDll_XNetGetConnectStatus',
        'NetDll_socket', 'NetDll_sendto', 'NetDll_recvfrom',
        'NetDll_XNetQosListen', 'NetDll_XNetQosLookup', 'XamSessionCreateHandle'
    )
    native_build = [ordered]@{
        configuration = $Configuration
        executable = $executable
        present = $nativePresent
        size_bytes = if ($nativePresent) { (Get-Item -LiteralPath $executable).Length } else { $null }
        sha256 = if ($nativePresent) { Hash-Required $executable } else { $null }
    }
    claims = [ordered]@{
        gameplay_verified = $false
        multiplayer_verified = $false
        network_services_verified = $false
        fps_120_verified = $false
        physics_preservation_verified = $false
    }
    scope = 'AOT code generation, separate PPC image map, launcher path, and native build only. No SP-to-MP in-process handoff, emulator launch, GUI run, network session, gameplay, or timing changes.'
}
$codegenReportPath = Join-Path $workspace 'docs\reports\mp-native-codegen.json'
$codegenReport | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $codegenReportPath -Encoding utf8
$checks | ForEach-Object { "{0}`t{1}`t{2}" -f $_.status, $_.id, $_.details }
Write-Host "MP target verification receipt: $resultPath"
Write-Host "MP native codegen report: $codegenReportPath"
if ($failed.Count -ne 0) {
    throw "MP target verification failed: $($failed.id -join ', ')"
}
