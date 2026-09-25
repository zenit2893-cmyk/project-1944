#requires -Version 5.1
<#
.SYNOPSIS
    Signs the launcher scripts and the built binaries with an Authenticode
    certificate.

.DESCRIPTION
    Antivirus engines, SmartScreen and Smart App Control judge an unsigned
    executable by its reputation, and a file built minutes ago on one machine
    has none. A valid Authenticode signature is the only thing that changes
    that answer at the root instead of adding an exception on top of it.

    This script signs every PowerShell script and every PE file under a tree
    with a certificate you supply, timestamps the signature so it stays valid
    after the certificate expires, and records what it signed.

    Which certificate to use:

      * A code-signing certificate from a public CA is what SmartScreen and
        Defender build reputation against. An EV certificate gets that
        reputation immediately; a standard one earns it as copies circulate.
      * A self-signed certificate (New-Cod3CodeSigningCertificate.ps1) only
        counts on machines that trust it. It is enough to run the launcher
        under an AllSigned execution policy and to stop "unknown publisher"
        prompts locally; it does not help SmartScreen or Smart App Control.

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My.
    This is the recommended route: no password ever passes through a script.

.PARAMETER PfxPath
    A .pfx file instead. You will be prompted for its password by Windows; the
    password is never stored, logged or passed on a command line.

.PARAMETER Root
    Directory to sign. Defaults to the workspace or package root.

.PARAMETER TimestampServer
    RFC 3161 timestamp server. Signing without one means the signature stops
    validating the day the certificate expires.
#>
[CmdletBinding(DefaultParameterSetName = 'Store')]
param(
    [Parameter(ParameterSetName = 'Store')]
    [string]$CertificateThumbprint,

    [Parameter(ParameterSetName = 'Pfx', Mandatory = $true)]
    [string]$PfxPath,

    [string]$Root,
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [switch]$IncludeBinaries,
    [switch]$WhatIfOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $here '..\..')) }
$Root = [IO.Path]::GetFullPath($Root)

function Resolve-Certificate {
    if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
        if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "Certificate file not found: $PfxPath" }
        # Windows prompts for the password itself; nothing is echoed or kept.
        $password = Read-Host -Prompt "Password for $([IO.Path]::GetFileName($PfxPath))" -AsSecureString
        return [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $password)
    }

    $candidates = @()
    foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        $candidates += @(Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue)
    }
    if ($CertificateThumbprint) {
        $wanted = $CertificateThumbprint -replace '[^0-9A-Fa-f]', ''
        $match = @($candidates | Where-Object { $_.Thumbprint -ieq $wanted })
        if ($match.Count -eq 0) { throw "No code-signing certificate with thumbprint $CertificateThumbprint in the personal stores." }
        return $match[0]
    }
    $usable = @($candidates | Where-Object { $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey })
    if ($usable.Count -eq 0) {
        throw @'
No usable code-signing certificate was found.

Use one of:
  * a certificate from a public CA, imported into Cert:\CurrentUser\My, then
    pass -CertificateThumbprint;
  * a .pfx file, passed with -PfxPath;
  * for local use only, create one with
    tools/signing/New-Cod3CodeSigningCertificate.ps1.
'@
    }
    if ($usable.Count -gt 1) {
        Write-Host 'Several code-signing certificates are available:'
        foreach ($certificate in $usable) {
            Write-Host ("  {0}  {1}  expires {2:yyyy-MM-dd}" -f $certificate.Thumbprint, $certificate.Subject, $certificate.NotAfter)
        }
        throw 'Pass -CertificateThumbprint to choose one.'
    }
    return $usable[0]
}

$scriptExtensions = @('.ps1', '.psm1', '.psd1')
$binaryExtensions = @('.exe', '.dll')

function Get-RelativePathCompat([string]$Base, [string]$Path) {
    # Windows PowerShell 5.1 has no [IO.Path]::GetRelativePath.
    $baseUri = New-Object Uri(($Base.TrimEnd('\', '/') + '\'))
    $pathUri = New-Object Uri($Path)
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Test-SignablePath([IO.FileInfo]$File) {
    $relative = (Get-RelativePathCompat $Root $File.FullName).Replace('\', '/').ToLowerInvariant()
    foreach ($segment in ($relative -split '/')) {
        # Never touch third-party source trees or build scratch.
        if ($segment -in @('.git', 'node_modules', '__pycache__', 'sdk-source', 'lgpl-sources', 'staging', 'downloads')) { return $false }
    }
    $extension = $File.Extension.ToLowerInvariant()
    if ($scriptExtensions -contains $extension) { return $true }
    if ($IncludeBinaries -and $binaryExtensions -contains $extension) { return $true }
    return $false
}

$certificate = $null
if (-not $WhatIfOnly) { $certificate = Resolve-Certificate }

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { Test-SignablePath $_ } | Sort-Object FullName)
if ($files.Count -eq 0) { throw "Nothing to sign under $Root" }

if ($WhatIfOnly) {
    Write-Host "Would sign $($files.Count) files under ${Root}:"
    foreach ($file in $files) { Write-Host ('  ' + (Get-RelativePathCompat $Root $file.FullName)) }
    return
}

Write-Host "Certificate: $($certificate.Subject)"
Write-Host "Thumbprint : $($certificate.Thumbprint)"
Write-Host "Expires    : $($certificate.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "Files      : $($files.Count)"
Write-Host ''

$signed = New-Object System.Collections.Generic.List[object]
$untrusted = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[object]
foreach ($file in $files) {
    $relative = (Get-RelativePathCompat $Root $file.FullName).Replace('\', '/')
    try {
        $result = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $certificate `
            -TimestampServer $TimestampServer -HashAlgorithm SHA256 -ErrorAction Stop
        $status = [string]$result.Status
        $row = [ordered]@{
            path = $relative
            status = $status
            timestamped = ($null -ne $result.TimeStamperCertificate)
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        if ($status -eq 'Valid') {
            $signed.Add($row)
            Write-Host ("  ok        {0}" -f $relative)
        } elseif ($null -ne $result.SignerCertificate) {
            # The signature was written and is intact; the chain just does not
            # end in a root this machine trusts. That is the normal outcome for
            # a self-signed certificate and is not a signing failure.
            $untrusted.Add($row)
            Write-Host ("  signed    {0}   (certificate not trusted here)" -f $relative)
        } else {
            $row['message'] = $result.StatusMessage
            $failed.Add($row)
            Write-Host ("  FAIL      {0}  {1}" -f $relative, $status)
        }
    } catch {
        $failed.Add([ordered]@{ path = $relative; status = 'Exception'; message = $_.Exception.Message })
        Write-Host ("  FAIL      {0}  {1}" -f $relative, $_.Exception.Message)
    }
}

$receipt = [ordered]@{
    schema_version = 1
    root = $Root
    certificate_subject = $certificate.Subject
    certificate_thumbprint = $certificate.Thumbprint
    certificate_not_after = $certificate.NotAfter.ToString('o')
    self_signed = ($certificate.Subject -eq $certificate.Issuer)
    timestamp_server = $TimestampServer
    binaries_included = [bool]$IncludeBinaries
    signed_count = ($signed.Count + $untrusted.Count)
    trusted_count = $signed.Count
    untrusted_count = $untrusted.Count
    failed_count = $failed.Count
    signed = $signed.ToArray()
    signed_untrusted = $untrusted.ToArray()
    failed = $failed.ToArray()
}
$receiptPath = Join-Path $Root 'signing-receipt.json'
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`r`n"), (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Signed $($signed.Count + $untrusted.Count) files, $($failed.Count) failed."
if ($untrusted.Count -gt 0) {
    Write-Host "$($untrusted.Count) of them carry a signature this machine does not trust yet."
}
Write-Host "Receipt: $receiptPath"
if ($receipt.self_signed) {
    Write-Host ''
    Write-Host 'This is a self-signed certificate. It satisfies an AllSigned execution'
    Write-Host 'policy and stops unknown-publisher prompts on machines that trust it.'
    Write-Host 'SmartScreen and Smart App Control judge reputation, not trust, so they'
    Write-Host 'are unaffected - only a certificate from a public CA changes that.'
}
if ($failed.Count -gt 0) { exit 1 }

