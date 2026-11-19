#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Application', 'Installer')][string]$Purpose,
    [Parameter(Mandatory)][ValidatePattern('^[A-Z0-9]{10}$')][string]$TeamId,
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][string]$ProtectedPrivateKeyPath,
    [Parameter(Mandatory)][string]$AppleRootCertificatePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$IntermediateCertificatePaths,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Security.SecureString]$P12Password,
    [switch]$AllowDpapiOnly
)

# Uses only explicitly supplied files when the account holder invokes this script.
# Does not create/install certificates or display/upload any key or password.
. (Join-Path $PSScriptRoot 'SigningTools.Common.ps1')
if (-not $IsWindows) { throw 'CurrentUser DPAPI export requires Windows PowerShell 7.2 or later.' }

function Read-PublicDerCertificate {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 131072) {
        throw 'Expected a regular public DER certificate file smaller than 128 KB.'
    }
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($bytes) -ne [Security.Cryptography.X509Certificates.X509ContentType]::Cert) {
        throw 'Only public certificate files are accepted; P12/PFX files are not inputs.'
    }
    return [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
}

function Get-CertificateSha256 {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($hash.ComputeHash($Certificate.RawData)) }
    finally { $hash.Dispose() }
}

$certificate = $null; $rootCertificate = $null; $chain = $null
$intermediates = [Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]]::new()
$privateBytes = $null; $key = $null; $rsa = $null; $publicRsa = $null; $combined = $null
$passwordBytes = $null; $passwordCharacters = $null; $encodedPassword = $null
$protectedPassword = $null; $p12Bytes = $null; $passwordPointer = [IntPtr]::Zero
$generatedPassword = $null
try {
    $certificate = Read-PublicDerCertificate -Path $CertificatePath
    $rootCertificate = Read-PublicDerCertificate -Path $AppleRootCertificatePath
    foreach ($path in $IntermediateCertificatePaths) { $intermediates.Add((Read-PublicDerCertificate -Path $path)) }
    # Public SHA-256 anchors from Apple's published trusted-root certificate list.
    $approvedRoots = @(
        'B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024',
        'C2B9B042DD57830E7D117DAC55AC8AE19407D38E41D88F3215BC3A890444A050',
        '63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179'
    )
    if ((Get-CertificateSha256 $rootCertificate) -notin $approvedRoots) { throw 'The supplied root is not an approved Apple Root CA.' }
    $now = [DateTime]::UtcNow
    if ($now -lt $certificate.NotBefore.ToUniversalTime() -or $now -gt $certificate.NotAfter.ToUniversalTime()) {
        throw 'The returned certificate is not currently valid.'
    }
    $name = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    $subject = $certificate.SubjectName.Decode([Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines)
    if (-not $name.EndsWith('(' + $TeamId + ')', [StringComparison]::Ordinal) -or
        $subject -notmatch ('(?m)^\s*OU\s*=\s*' + [Regex]::Escape($TeamId) + '\s*$')) {
        throw 'The returned certificate does not match the explicitly selected Apple team.'
    }
    $extensionOids = @($certificate.Extensions | ForEach-Object { $_.Oid.Value })
    if ($Purpose -eq 'Application') {
        if (-not ($name.StartsWith('Apple Distribution:', [StringComparison]::Ordinal) -or
                  $name.StartsWith('3rd Party Mac Developer Application:', [StringComparison]::Ordinal))) {
            throw 'Application requires Apple Distribution or Mac App Distribution, not Developer ID.'
        }
        $requiredMarker = '1.2.840.113635.100.6.1.7'
        $requiredEku = '1.3.6.1.5.5.7.3.3'
    } else {
        if (-not $name.StartsWith('3rd Party Mac Developer Installer:', [StringComparison]::Ordinal)) {
            throw 'Installer requires Mac Installer Distribution, not Developer ID Installer.'
        }
        $requiredMarker = '1.2.840.113635.100.6.1.8'
        $requiredEku = '1.2.840.113635.100.4.9'
    }
    if ($requiredMarker -notin $extensionOids) { throw 'The returned certificate has the wrong Apple submission purpose.' }
    $ekuSource = $certificate.Extensions['2.5.29.37']
    $usageSource = $certificate.Extensions['2.5.29.15']
    $constraintsSource = $certificate.Extensions['2.5.29.19']
    if ($null -eq $ekuSource -or $null -eq $usageSource -or $null -eq $constraintsSource) { throw 'Certificate usage constraints are missing.' }
    $eku = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuSource, $ekuSource.Critical)
    $usage = [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usageSource, $usageSource.Critical)
    $constraints = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($constraintsSource, $constraintsSource.Critical)
    if ($requiredEku -notin @($eku.EnhancedKeyUsages | ForEach-Object { $_.Value }) -or
        ($usage.KeyUsages -band [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature) -eq 0 -or
        $constraints.CertificateAuthority) { throw 'The certificate EKU, key usage or CA constraint does not permit this purpose.' }

    # CustomRootTrust does not modify any Windows certificate store. Online
    # revocation/validity/signature errors fail before the CSR key is decrypted.
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
    [void]$chain.ChainPolicy.CustomTrustStore.Add($rootCertificate)
    foreach ($intermediate in $intermediates) { [void]$chain.ChainPolicy.ExtraStore.Add($intermediate) }
    $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
    $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
    $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(15)
    [void]$chain.Build($certificate)
    if ($chain.ChainElements.Count -lt 3 -or
        (Get-CertificateSha256 $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate) -cne (Get-CertificateSha256 $rootCertificate)) {
        throw 'A complete chain to the selected Apple Root CA could not be verified.'
    }
    # Windows does not implement Apple's purpose markers; validate these exact
    # markers ourselves and reject every other unknown critical extension.
    $knownCritical = @('2.5.29.19', '2.5.29.15', '2.5.29.37', '1.2.840.113635.100.6.1.4', $requiredMarker)
    foreach ($element in $chain.ChainElements) {
        foreach ($extension in $element.Certificate.Extensions) {
            if ($extension.Critical -and $extension.Oid.Value -notin $knownCritical) { throw 'The certificate chain contains an unsupported critical extension.' }
        }
        foreach ($status in $element.ChainElementStatus) {
            if ($status.Status -ne [Security.Cryptography.X509Certificates.X509ChainStatusFlags]::NoError -and
                $status.Status -ne [Security.Cryptography.X509Certificates.X509ChainStatusFlags]::HasNotSupportedCriticalExtension) {
                throw ('Apple certificate chain verification failed: ' + $status.Status.ToString())
            }
        }
    }
    foreach ($status in $chain.ChainStatus) {
        if ($status.Status -ne [Security.Cryptography.X509Certificates.X509ChainStatusFlags]::NoError -and
            $status.Status -ne [Security.Cryptography.X509Certificates.X509ChainStatusFlags]::HasNotSupportedCriticalExtension) {
            throw ('Apple certificate chain verification failed: ' + $status.Status.ToString())
        }
    }
    $publicRsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    if ($null -eq $publicRsa -or $publicRsa.KeySize -lt 2048) { throw 'This helper requires an RSA signing certificate of at least 2048 bits.' }
    $privatePath = (Resolve-Path -LiteralPath $ProtectedPrivateKeyPath).Path
    $privateItem = Get-Item -LiteralPath $privatePath -Force
    if ($privateItem.PSIsContainer -or ($privateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $privateItem.Length -gt 65536) {
        throw 'Expected the explicitly selected regular CSR private-key DPAPI file.'
    }
    $privateBytes = Unprotect-SigningBytes -Bytes ([IO.File]::ReadAllBytes($privatePath))
    $key = [Security.Cryptography.CngKey]::Import($privateBytes, [Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    if (-not $key.IsEphemeral) { throw 'The imported CSR private key must remain ephemeral.' }
    $key.SetProperty([Security.Cryptography.CngProperty]::new(
        'Export Policy', [BitConverter]::GetBytes([int][Security.Cryptography.CngExportPolicies]::AllowPlaintextExport),
        [Security.Cryptography.CngPropertyOptions]::None))
    $rsa = [Security.Cryptography.RSACng]::new($key)
    $expected = $publicRsa.ExportParameters($false); $actual = $rsa.ExportParameters($false)
    if ([Convert]::ToBase64String($expected.Modulus) -cne [Convert]::ToBase64String($actual.Modulus) -or
        [Convert]::ToBase64String($expected.Exponent) -cne [Convert]::ToBase64String($actual.Exponent)) {
        throw 'The returned Apple certificate does not match the private key used for the selected CSR.'
    }
    if ($null -eq $P12Password) {
        $passwordBytes = [byte[]]::new(32)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($passwordBytes) } finally { $random.Dispose() }
        $generatedPassword = [Security.SecureString]::new()
        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
        foreach ($value in $passwordBytes) { $generatedPassword.AppendChar($alphabet[$value -band 63]) }
        $generatedPassword.MakeReadOnly(); $P12Password = $generatedPassword
    }
    if ($P12Password.Length -lt 24) { throw 'Use an explicit P12 password of at least 24 characters, or omit it to generate a random password.' }
    $combined = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($certificate, $rsa)
    $p12Bytes = $combined.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $P12Password)
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($P12Password)
    $passwordCharacters = [char[]]::new($P12Password.Length)
    [Runtime.InteropServices.Marshal]::Copy($passwordPointer, $passwordCharacters, 0, $passwordCharacters.Length)
    $encodedPassword = [Text.Encoding]::UTF8.GetBytes($passwordCharacters)
    $protectedPassword = Protect-SigningBytes -Bytes $encodedPassword
    $directory = Initialize-PrivateSigningDirectory -Path $OutputDirectory -AllowDpapiOnly:$AllowDpapiOnly
    $prefix = 'AnalizHukuk-MacStore-' + $Purpose
    $p12Path = Join-Path $directory ($prefix + '.p12'); $passwordPath = Join-Path $directory ($prefix + '.password.dpapi')
    if ((Test-Path -LiteralPath $p12Path) -or (Test-Path -LiteralPath $passwordPath)) { throw 'The selected purpose output already exists; use a new private output directory.' }
    Write-NewSigningFile -Path $passwordPath -Bytes $protectedPassword
    Write-NewSigningFile -Path $p12Path -Bytes $p12Bytes
    [PSCustomObject]@{ Purpose = $Purpose; TeamId = $TeamId; P12Path = $p12Path; ProtectedPasswordPath = $passwordPath }
}
finally {
    foreach ($bytes in @($privateBytes, $passwordBytes, $encodedPassword, $protectedPassword, $p12Bytes)) { Clear-SigningBytes $bytes }
    if ($null -ne $passwordCharacters) { [Array]::Clear($passwordCharacters, 0, $passwordCharacters.Length) }
    if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
    foreach ($disposable in @($combined, $publicRsa, $rsa, $key, $chain, $certificate, $rootCertificate, $generatedPassword)) {
        if ($null -ne $disposable) { $disposable.Dispose() }
    }
    foreach ($intermediate in $intermediates) { $intermediate.Dispose() }
}
