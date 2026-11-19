# Mac App Store signing preparation on Windows

`Export-MacStoreSigningP12.ps1` requires **PowerShell 7.2 or later on Windows**. Invoke it with `pwsh`, not the Windows PowerShell 5.1 console. It does not create certificates, change account permissions, install certificates in a Windows store, print secrets, or upload anything.

Use the generic `New-AppleSigningRequest.ps1` to prepare a public CSR and its CurrentUser DPAPI-protected RSA private key in a private directory outside source trees and Git checkouts. Use separate clearly named directories for application and installer requests. Only the public CSR is submitted to Apple, using the corresponding Store certificate form.

The Store application needs Apple Distribution or Mac App Distribution. The Store package needs Mac Installer Distribution. A public `.cer` alone does not contain its private key. The copied `Export-AppleSigningP12.ps1` is a Developer ID helper and is **not** the Store exporter; use `Export-MacStoreSigningP12.ps1` here.

After the account holder obtains the returned public certificate, call the Store exporter with the explicit `-Purpose Application` or `-Purpose Installer`, expected `-TeamId`, returned `-CertificatePath`, matching CSR `-ProtectedPrivateKeyPath`, public `-AppleRootCertificatePath` and `-IntermediateCertificatePaths`, and a new `-OutputDirectory`. See [the Store distribution instructions](../README.md) for a complete public example and the GitHub secret contract.

The script verifies the pinned Apple root, certificate chain and online revocation status, current validity, team, EKU and developer-issued Store purpose before decrypting the selected CSR key. It stops if verification or certificate/key matching fails. It supports RSA CSR keys created by the existing helper.

`-P12Password` accepts an optional `SecureString`; if omitted, the script generates a strong random password. It writes a password-protected P12 and a CurrentUser DPAPI-protected password file. Do not place plaintext passwords in command arguments or print/export the protected password to logs. DPAPI is tied to the current Windows account and is not a portable backup.

Private-directory ACL protection is required by default. `-AllowDpapiOnly` is an explicit fallback for managed environments where a verified restrictive ACL cannot be applied; it does not write an unencrypted key or plaintext password. Existing output files are never overwritten.

The helper must be reviewed before it is used with real signing material. Static parsing and supported-runtime checks do not prove a real Apple certificate has been issued, exported or uploaded.
