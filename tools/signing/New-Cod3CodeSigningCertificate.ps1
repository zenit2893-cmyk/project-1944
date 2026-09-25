#requires -Version 5.1
<#
.SYNOPSIS
    Creates a self-signed code-signing certificate for signing this project
    locally.

.DESCRIPTION
    A self-signed certificate is useful for exactly one thing: making the
    launcher and the tools you build run without "unknown publisher" prompts on
    machines that trust the certificate, and letting PowerShell run under an
    AllSigned execution policy instead of Bypass.

    It does not help SmartScreen or Smart App Control. Those judge reputation,
    which only a certificate from a public certificate authority accumulates -
    an EV certificate has it immediately, a standard one earns it as copies of
    your signed files circulate. If you plan to hand this build to other people,
    a real certificate is the only route that removes the warnings for them too.

    By default this only creates the certificate. Trusting it is a separate,
    deliberate step, because it changes what your machine accepts as signed
    code: -TrustLocally installs the public part into the current user's
    Trusted Root and Trusted Publishers stores. Read that sentence again before
    passing the switch, and only ever pass it for a certificate you created
    yourself on this machine.

.PARAMETER Subject
    Certificate subject. Use your own name or organisation.

.PARAMETER Years
    Validity in years.

.PARAMETER TrustLocally
    Also install the public certificate into the current user's Trusted Root
    and Trusted Publishers stores, so this machine treats files signed with it
    as signed by a known publisher.

.PARAMETER ExportPath
    Where to write the public .cer, so the certificate can be inspected or
    trusted on another machine deliberately.
#>
[CmdletBinding()]
param(
    [string]$Subject = "CN=Call of Duty 3 native port (local build)",
    [ValidateRange(1, 10)][int]$Years = 3,
    [switch]$TrustLocally,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
    throw 'New-SelfSignedCertificate is unavailable. It ships with Windows 8/Server 2012 and newer.'
}

$existing = @(Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) })
if ($existing.Count -gt 0) {
    Write-Host 'A certificate with this subject already exists:'
    foreach ($certificate in $existing) {
        Write-Host ("  {0}  expires {1:yyyy-MM-dd}" -f $certificate.Thumbprint, $certificate.NotAfter)
    }
    Write-Host ''
    Write-Host 'Sign with it:'
    Write-Host ("  tools\signing\Set-Cod3Signature.ps1 -CertificateThumbprint {0}" -f $existing[0].Thumbprint)
    return
}

$certificate = New-SelfSignedCertificate `
    -Subject $Subject `
    -Type CodeSigningCert `
    -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -CertStoreLocation Cert:\CurrentUser\My `
    -NotAfter (Get-Date).AddYears($Years)

Write-Host 'Created a code-signing certificate:'
Write-Host ("  Subject   : {0}" -f $certificate.Subject)
Write-Host ("  Thumbprint: {0}" -f $certificate.Thumbprint)
Write-Host ("  Expires   : {0:yyyy-MM-dd}" -f $certificate.NotAfter)
Write-Host ("  Store     : Cert:\CurrentUser\My")

if (-not $ExportPath) {
    $ExportPath = Join-Path $PSScriptRoot 'cod3-code-signing.cer'
}
Export-Certificate -Cert $certificate -FilePath $ExportPath -Type CERT | Out-Null
Write-Host ("  Public key: {0}" -f $ExportPath)

if ($TrustLocally) {
    Write-Host ''
    Write-Host 'Installing the public certificate into this user''s Trusted Root and'
    Write-Host 'Trusted Publishers stores. From now on this machine treats anything'
    Write-Host 'signed with it as coming from a known publisher.'
    foreach ($store in @('Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher')) {
        Import-Certificate -FilePath $ExportPath -CertStoreLocation $store | Out-Null
        Write-Host ("  installed into {0}" -f $store)
    }
    Write-Host ''
    Write-Host 'To undo later:'
    Write-Host ("  Get-ChildItem Cert:\CurrentUser\Root, Cert:\CurrentUser\TrustedPublisher |")
    Write-Host ("    Where-Object Thumbprint -eq '{0}' | Remove-Item" -f $certificate.Thumbprint)
} else {
    Write-Host ''
    Write-Host 'The certificate is not trusted by this machine yet, so signatures made'
    Write-Host 'with it will still read as "unknown publisher". Re-run with -TrustLocally'
    Write-Host 'if that is what you want; it changes what this machine accepts as signed'
    Write-Host 'code, so it is deliberately not the default.'
}

Write-Host ''
Write-Host 'Next:'
Write-Host ("  tools\signing\Set-Cod3Signature.ps1 -CertificateThumbprint {0} -IncludeBinaries" -f $certificate.Thumbprint)
