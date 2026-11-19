[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryParent)

. (Join-Path $PSScriptRoot 'SigningTools.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetFullPath($TemporaryParent)) ('SigningTools-selftest-' + [Guid]::NewGuid().ToString('N'))
$key = $null
$rsa = $null
$certificate = $null
$roundtrip = $null
$privateBytes = $null
$passwordBytes = $null
$negativeRsa = $null
$negativeCertificate = $null
try {
    $csr = & (Join-Path $PSScriptRoot 'New-AppleSigningRequest.ps1') -OutputDirectory $testRoot -CommonName 'Synthetic Local Signing Test' -KeySize 3072 -AllowDpapiOnly
    if (-not (Test-Path -LiteralPath $csr)) { throw 'The public CSR was not created.' }
    $dump = & certutil.exe -dump $csr 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Windows certutil could not parse the generated CSR.' }
    $privatePath = Join-Path $testRoot 'AnalizHukuk-Mac.privatekey.dpapi'
    $privateBytes = Unprotect-SigningBytes ([IO.File]::ReadAllBytes($privatePath))
    $key = [Security.Cryptography.CngKey]::Import($privateBytes, [Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    $key.SetProperty((New-Object Security.Cryptography.CngProperty(
        'Export Policy', ([BitConverter]::GetBytes([int][Security.Cryptography.CngExportPolicies]::AllowPlaintextExport)),
        [Security.Cryptography.CngPropertyOptions]::None)))
    $rsa = New-Object Security.Cryptography.RSACng($key)
    if ($rsa.KeySize -ne 3072 -or -not $key.IsEphemeral) { throw 'Expected a 3072-bit ephemeral RSA key.' }
    $subject = New-Object Security.Cryptography.X509Certificates.X500DistinguishedName('CN=Developer ID Application: Synthetic Local Test')
    $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
        $subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddDays(1))
    $certPath = Join-Path $testRoot 'synthetic-local-only.cer'
    Write-NewSigningFile -Path $certPath -Bytes ($certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $result = & (Join-Path $PSScriptRoot 'Export-AppleSigningP12.ps1') -CertificatePath $certPath -ProtectedPrivateKeyPath $privatePath -OutputDirectory $testRoot -AllowDpapiOnly
    $passwordBytes = Unprotect-SigningBytes ([IO.File]::ReadAllBytes($result.ProtectedPasswordPath))
    $password = [Text.Encoding]::UTF8.GetString($passwordBytes)
    $roundtrip = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [IO.File]::ReadAllBytes($result.P12Path), $password,
        ([Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet -bor
         [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable))
    if (-not $roundtrip.HasPrivateKey -or $roundtrip.Thumbprint -ne $certificate.Thumbprint) {
        throw 'The password-protected P12 did not round-trip with its private key.'
    }
    $payload = [Text.Encoding]::UTF8.GetBytes('synthetic signing roundtrip')
    $signer = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($roundtrip)
    $verifier = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    try {
        $signature = $signer.SignData($payload, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $verifier.VerifyData($payload, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
            throw 'The exported P12 private key does not match its certificate.'
        }
    } finally { $signer.Dispose(); $verifier.Dispose() }
    Write-Output 'PASS CSR parses and P12 key/password round-trip verifies a signature'

    $blocked = $false
    try { & (Join-Path $PSScriptRoot 'New-AppleSigningRequest.ps1') -OutputDirectory $testRoot | Out-Null }
    catch { $blocked = $true }
    if (-not $blocked) { throw 'Creating a CSR in a non-empty directory was not rejected.' }
    $before = [IO.File]::ReadAllBytes($result.P12Path)
    $blocked = $false
    try { & (Join-Path $PSScriptRoot 'Export-AppleSigningP12.ps1') -CertificatePath $certPath -ProtectedPrivateKeyPath $privatePath -OutputDirectory $testRoot | Out-Null }
    catch { $blocked = $true }
    if (-not $blocked -or [Convert]::ToBase64String($before) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($result.P12Path))) {
        throw 'Existing P12 protection failed.'
    }
    Write-Output 'PASS existing CSR/private files and P12 are not overwritten'

    $negativeRsa = New-Object Security.Cryptography.RSACng(2048)
    $negativeRequest = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
        $subject, $negativeRsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $negativeCertificate = $negativeRequest.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddDays(1))
    $negativeCertPath = Join-Path $testRoot 'synthetic-wrong-key.cer'
    Write-NewSigningFile -Path $negativeCertPath -Bytes ($negativeCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $negativeOutput = Join-Path $testRoot 'mismatch'
    $blocked = $false
    try { & (Join-Path $PSScriptRoot 'Export-AppleSigningP12.ps1') -CertificatePath $negativeCertPath -ProtectedPrivateKeyPath $privatePath -OutputDirectory $negativeOutput -AllowDpapiOnly | Out-Null }
    catch { $blocked = $true }
    if (-not $blocked -or (Test-Path -LiteralPath (Join-Path $negativeOutput 'AnalizHukuk-Mac-DeveloperID.p12'))) {
        throw 'A mismatched certificate was accepted.'
    }
    Write-Output 'PASS certificate/private-key mismatch is rejected'

    $blocked = $false
    try { Initialize-PrivateSigningDirectory -Path (Join-Path $PSScriptRoot 'must-not-exist') | Out-Null }
    catch { $blocked = $true }
    if (-not $blocked) { throw 'Writing private material into the source tree was not rejected.' }
    Write-Output 'PASS source-tree output is blocked'

    $strictOutput = Join-Path $testRoot 'strict'
    $strictFailed = $false
    try { & (Join-Path $PSScriptRoot 'New-AppleSigningRequest.ps1') -OutputDirectory $strictOutput -CommonName 'Synthetic Strict Storage Test' | Out-Null }
    catch { $strictFailed = $true }
    $strictAcl = Get-Acl -LiteralPath $strictOutput
    if (-not $strictAcl.AreAccessRulesProtected) {
        if (-not $strictFailed -or @(Get-ChildItem -LiteralPath $strictOutput -Force).Count -ne 0) {
            throw 'Strict ACL mode did not fail before writing signing material.'
        }
        Write-Output 'PASS strict mode fails before writing keys when private ACL cannot be enforced'
    } elseif ($strictFailed) { throw 'Strict mode failed despite enforced private ACL.' }
    else { Write-Output 'PASS strict mode enforces its private directory ACL' }
}
finally {
    Clear-SigningBytes $privateBytes
    Clear-SigningBytes $passwordBytes
    $password = $null
    foreach ($disposable in @($roundtrip, $negativeCertificate, $negativeRsa, $certificate, $rsa, $key)) {
        if ($null -ne $disposable) { $disposable.Dispose() }
    }
    # Delete only this invocation's verified local synthetic test directory.
    $expectedPrefix = [IO.Path]::GetFullPath($TemporaryParent).TrimEnd('\') + '\SigningTools-selftest-'
    if (-not $testRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the synthetic test directory.'
    }
    if (Test-Path -LiteralPath $testRoot) {
        $files = @(Get-ChildItem -LiteralPath $testRoot -File -Force -Recurse)
        foreach ($file in $files) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not $file.FullName.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing cleanup of an unexpected test path.'
            }
            [IO.File]::Delete($file.FullName)
        }
        $directories = @(Get-ChildItem -LiteralPath $testRoot -Directory -Force -Recurse | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($directory in $directories) { [IO.Directory]::Delete($directory.FullName, $false) }
        [IO.Directory]::Delete($testRoot, $false)
    }
}
