# Windows signing preparation

These PowerShell 5.1 tools prepare a public CSR and combine Apple's downloaded Developer ID Application certificate with the matching private key. They do not contact Apple, create trusted certificates, import keys into a Windows certificate store, or change account permissions.

Choose a private output directory **outside the source tree and any Git checkout**. By default each script requires a verified ACL restricted to the current Windows user and SYSTEM, and stops before writing signing material if Windows does not apply it. Keep the directory on a local Windows filesystem.

```powershell
.\New-AppleSigningRequest.ps1 -OutputDirectory 'C:\private-signing\analiz-mac'
```

Upload only the resulting `.certSigningRequest` to Apple's Developer ID Application certificate form. The `.privatekey.dpapi` file stays on this Windows computer. DPAPI encryption is bound to the current Windows account; it is not a portable key backup. Keep the Windows account and its recovery materials available.

Once Apple has issued the matching `.cer`:

```powershell
.\Export-AppleSigningP12.ps1 `
  -CertificatePath 'C:\path\developerID_application.cer' `
  -ProtectedPrivateKeyPath 'C:\private-signing\analiz-mac\AnalizHukuk-Mac.privatekey.dpapi' `
  -OutputDirectory 'C:\private-signing\analiz-mac'
```

The P12 is password protected; its random password is stored in a separate `.password.dpapi` file. The scripts never print the password or private material. Moving the private key/password to GitHub Actions Secrets is a separate, authorized step. Never commit or upload P12, DPAPI files, P8 files, or their passwords as repository files or build artifacts.

Some managed Windows hosts preserve inherited directory permissions and cannot apply the requested private ACL. An operator may explicitly add `-AllowDpapiOnly` to both commands after assessing that environment. This mode reports a warning instead of claiming ACL restriction: the private PKCS8 and P12 password remain encrypted with integrity protection by Windows DPAPI for the current Windows user, and the P12 itself uses a random 256-bit password. No plaintext private key or password file is created, and existing inherited permissions are never widened. Other users who can read the encrypted files should not be able to decrypt them as a different Windows identity. This mode does not protect against compromise of the same Windows account. Default mode remains strict.

The exporter checks the certificate's name, validity and matching RSA public key. It does not independently establish Apple's certificate chain. macOS signing and Apple notarization must validate trust before distribution.

Developer ID signing and notarization are for distribution outside the Mac App Store. They do not satisfy the separate Mac App Store sandbox and self-contained-app requirements.
