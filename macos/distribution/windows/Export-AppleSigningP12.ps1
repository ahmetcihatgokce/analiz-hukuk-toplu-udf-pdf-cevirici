[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][string]$ProtectedPrivateKeyPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$AllowDpapiOnly
)

. (Join-Path $PSScriptRoot 'SigningTools.Common.ps1')
$directory = Initialize-PrivateSigningDirectory -Path $OutputDirectory -AllowDpapiOnly:$AllowDpapiOnly
$p12Path = Join-Path $directory 'AnalizHukuk-Mac-DeveloperID.p12'
$passwordPath = Join-Path $directory 'AnalizHukuk-Mac-DeveloperID.password.dpapi'
foreach ($target in @($p12Path, $passwordPath)) {
    if (Test-Path -LiteralPath $target) { throw 'An output file already exists. Choose a new private output directory.' }
}
$certificate = $null
$privateBytes = $null
$key = $null
$rsa = $null
$publicRsa = $null
$combined = $null
$passwordBytes = $null
$p12Bytes = $null
$protectedPassword = $null
try {
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CertificatePath).Path))
    $name = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if (-not $name.StartsWith('Developer ID Application:', [StringComparison]::Ordinal)) {
        throw 'The certificate is not a Developer ID Application certificate.'
    }
    $now = Get-Date
    if ($now -lt $certificate.NotBefore -or $now -gt $certificate.NotAfter) {
        throw 'The certificate is not currently valid.'
    }
    $privateBytes = Unprotect-SigningBytes -Bytes ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ProtectedPrivateKeyPath).Path))
    $key = [Security.Cryptography.CngKey]::Import($privateBytes, [Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    if (-not $key.IsEphemeral) { throw 'The imported private key must be ephemeral.' }
    $exportPolicy = New-Object Security.Cryptography.CngProperty(
        'Export Policy', ([BitConverter]::GetBytes([int][Security.Cryptography.CngExportPolicies]::AllowPlaintextExport)),
        [Security.Cryptography.CngPropertyOptions]::None)
    $key.SetProperty($exportPolicy)
    $rsa = New-Object Security.Cryptography.RSACng($key)
    $publicRsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    if ($null -eq $publicRsa) { throw 'The certificate does not have an RSA public key.' }
    $expected = $publicRsa.ExportParameters($false)
    $actual = $rsa.ExportParameters($false)
    if ([Convert]::ToBase64String($expected.Modulus) -cne [Convert]::ToBase64String($actual.Modulus) -or
        [Convert]::ToBase64String($expected.Exponent) -cne [Convert]::ToBase64String($actual.Exponent)) {
        throw 'The Apple certificate does not match the private key used for this CSR.'
    }
    $combined = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($certificate, $rsa)
    $passwordBytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($passwordBytes) } finally { $random.Dispose() }
    $password = [Convert]::ToBase64String($passwordBytes)
    $p12Bytes = $combined.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
    $encodedPassword = [Text.Encoding]::UTF8.GetBytes($password)
    try { $protectedPassword = Protect-SigningBytes -Bytes $encodedPassword }
    finally { Clear-SigningBytes $encodedPassword }
    Write-NewSigningFile -Path $passwordPath -Bytes $protectedPassword
    Write-NewSigningFile -Path $p12Path -Bytes $p12Bytes
    [PSCustomObject]@{ P12Path = $p12Path; ProtectedPasswordPath = $passwordPath }
}
finally {
    Clear-SigningBytes $privateBytes
    Clear-SigningBytes $passwordBytes
    Clear-SigningBytes $p12Bytes
    Clear-SigningBytes $protectedPassword
    $password = $null
    foreach ($disposable in @($combined, $publicRsa, $rsa, $key, $certificate)) {
        if ($null -ne $disposable) { $disposable.Dispose() }
    }
}
