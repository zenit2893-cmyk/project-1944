[CmdletBinding()]
param([switch]$Quiet)

# Dot-source this file before CMake, Ninja, clang++, or clang-cl commands.
# Only the current process environment changes; user/system PATH and registry do not.
& {
    param([string]$WorkspaceRoot, [bool]$SuppressMessage)
    $toolchainRoot = Join-Path $WorkspaceRoot 'tools\toolchain'
    $msvcRoot = Join-Path $toolchainRoot 'msvc'
    $envFile = Join-Path $msvcRoot 'env.json'
    $llvmBin = Join-Path $toolchainRoot 'llvm\bin'
    $cmakeBin = Join-Path $WorkspaceRoot 'tools\cmake\bin'
    $ninjaBin = Join-Path $WorkspaceRoot 'tools\ninja'
    $rexSdk = Join-Path $WorkspaceRoot 'win-amd64'

    foreach ($required in @($envFile, (Join-Path $llvmBin 'clang++.exe'),
        (Join-Path $llvmBin 'clang-cl.exe'), (Join-Path $cmakeBin 'cmake.exe'),
        (Join-Path $ninjaBin 'ninja.exe'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Toolchain is incomplete: $required. See docs/reports/toolchain-status.json."
        }
    }

    $spec = Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json
    foreach ($name in @('VSCMD_ARG_HOST_ARCH', 'VCToolsVersion', 'WindowsSDKVersion',
        'PORTABLE_MSVC_TOOLSET_VERSION', 'PORTABLE_MSVC_PACKAGE_VERSION',
        'PORTABLE_MSVC_VCTOOLS_VERSION', 'PORTABLE_SDK_BUILD_NUMBER',
        'PORTABLE_SDK_VERSION', 'VCINSTALLDIR', 'VCToolsInstallDir', 'WindowsSDKDir')) {
        [Environment]::SetEnvironmentVariable($name, [string]$spec.$name, 'Process')
    }
    $env:VSCMD_ARG_TGT_ARCH = 'x64'
    $env:WindowsSDKVersion = ([string]$spec.WindowsSDKVersion).TrimEnd('\') + '\'
    $env:UCRTVersion = ([string]$spec.WindowsSDKVersion).TrimEnd('\')
    $env:UniversalCRTSdkDir = [string]$spec.WindowsSDKDir
    foreach ($name in @('INCLUDE', 'LIB', 'LIBPATH')) {
        [Environment]::SetEnvironmentVariable($name, ($spec.$name -join ';'), 'Process')
    }

    $prepend = @($llvmBin, $cmakeBin, $ninjaBin, $PSHOME, (Join-Path $rexSdk 'bin')) + @($spec.PATH)
    $knownGit = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd'
    if (Test-Path -LiteralPath (Join-Path $knownGit 'git.exe')) { $prepend += $knownGit }
    $env:PATH = (@($prepend + ($env:PATH -split ';')) | Where-Object { $_ } | Select-Object -Unique) -join ';'
    $env:CC = Join-Path $llvmBin 'clang.exe'
    $env:CXX = Join-Path $llvmBin 'clang++.exe'
    $env:AR = Join-Path $llvmBin 'llvm-lib.exe'
    $env:MAKE = Join-Path $ninjaBin 'ninja.exe'
    $env:CMAKE_GENERATOR = 'Ninja'
    $env:COD3_TOOLCHAIN_ROOT = $toolchainRoot
    $env:REXSDK = $rexSdk
    $env:CMAKE_PREFIX_PATH = (@($rexSdk) + @($env:CMAKE_PREFIX_PATH -split ';') |
        Where-Object { $_ } | Select-Object -Unique) -join ';'

    if (-not $SuppressMessage) {
        Write-Host "CoD3 toolchain ready: Clang 22.1.8, MSVC $($spec.VCToolsVersion), Windows SDK $($spec.WindowsSDKVersion)."
        Write-Host 'CMake/Ninja and ReXGlue SDK are available in this shell.'
    }
} (Split-Path -Parent $PSScriptRoot) ([bool]$Quiet)
