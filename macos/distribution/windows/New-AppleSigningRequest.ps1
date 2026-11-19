[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidatePattern('^[\p{L}\p{N} ._()\-:]{1,100}$')][string]$CommonName = 'Analiz Hukuk Mac Signing',
    [ValidateSet(2048, 3072)][int]$KeySize = 2048,
    [switch]$AllowDpapiOnly
)

. (Join-Path $PSScriptRoot 'SigningTools.Common.ps1')
$directory = Initialize-PrivateSigningDirectory -Path $OutputDirectory -RequireEmpty -AllowDpapiOnly:$AllowDpapiOnly
$csrPath = Join-Path $directory 'AnalizHukuk-Mac.certSigningRequest'
$privatePath = Join-Path $directory 'AnalizHukuk-Mac.privatekey.dpapi'
$rsa = New-Object Security.Cryptography.RSACng($KeySize)
$privateBytes = $null
$protectedBytes = $null
try {
    if (-not $rsa.Key.IsEphemeral) { throw 'The RSA key must be ephemeral.' }
    $subject = New-Object Security.Cryptography.X509Certificates.X500DistinguishedName('CN=' + $CommonName)
    $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
        $subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $der = $request.CreateSigningRequest()
    $base64 = [Convert]::ToBase64String($der)
    $lines = for ($offset = 0; $offset -lt $base64.Length; $offset += 64) {
        $base64.Substring($offset, [Math]::Min(64, $base64.Length - $offset))
    }
    $pem = "-----BEGIN CERTIFICATE REQUEST-----`r`n" + ($lines -join "`r`n") + "`r`n-----END CERTIFICATE REQUEST-----`r`n"
    $privateBytes = $rsa.Key.Export([Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    $protectedBytes = Protect-SigningBytes -Bytes $privateBytes
    Write-NewSigningFile -Path $privatePath -Bytes $protectedBytes
    Write-NewSigningFile -Path $csrPath -Bytes ([Text.Encoding]::ASCII.GetBytes($pem))
    Write-Output $csrPath
}
finally {
    Clear-SigningBytes $privateBytes
    Clear-SigningBytes $protectedBytes
    $rsa.Dispose()
}
