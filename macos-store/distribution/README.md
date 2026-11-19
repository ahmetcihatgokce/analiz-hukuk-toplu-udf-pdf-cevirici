# Mac App Store paketleme ve yükleme

Bu dizin yerel Swift UDF işleyicisini kullanan Mac App Store adayı içindir. Uygulama belgeleri cihazda işler; Java veya kurulu UYAP uygulamasını çalıştırmaz. App Sandbox açıktır ve kullanıcının seçtiği dosya/klasörlere okuma-yazma izni ister. Mağaza dışı Developer ID dağıtımının ayrı belgeleri [macos/distribution](../../macos/distribution/README.md) altındadır. O notarization işleminin bitmesi mağaza başvurusunun ön koşulu değildir.

## Sürüm ve doğrulama akışı

- Bundle ID `org.analizhukuk.udfpdf.mac`; sürüm `1.0.4`, build `2`; minimum macOS `13.0`.
- `build-store.sh`, Java veya test belgelerini uygulamaya eklemez. `MAC_STORE_TESTING=1` yalnızca CI test girişlerini açar; dağıtım adayı varsayılan `0` ile derlenir.
- `.github/workflows/macos-store.yml`, Intel ve Apple Silicon sandbox/sentetik dönüşüm testlerini yürütür. Resmî UYAP karşılaştırması yalnızca test ortamında çalışır; resmî uygulama veya Java dağıtım paketine konulmaz.
- Başarılı iki native adayın kaynakları ve Info.plist'i karşılaştırılır; test edilen binary dilimleri `lipo` ile universal adaya birleştirilir. `Store-universal-candidate` artifact'i ad-hoc imzalı CI adayıdır.
- Elle başlatılan yükleme akışı, sabit kaynak commit'ini ve başarılı CI run/artifact kaynağını doğrular. `package-store.sh`, doğru Store sertifikalarıyla uygulamayı ve `.pkg` yükleyicisini imzalar, Apple doğrulamasını çalıştırır ve `MAC_STORE_UPLOAD=1` ise build'i yükler.

İmzalama anahtarları içe aktarıldıktan sonra uygulama kodu çalıştırılmaz. Apple'a build yüklemek; build'in işlenmesi, mağaza bilgileri, App Review gönderimi ve yayımdan ayrı bir adımdır. Bu script App Review onayı veya yayın yapıldığını iddia etmez.

## İmzalama varlıkları ve korumalı ortam

Uygulama için **Apple Distribution** veya **Mac App Distribution**; yükleyici için ayrı **Mac Installer Distribution** sertifikası ve her birinin eşleşen özel anahtarı gerekir. Developer ID sertifikaları bu kanal için kullanılmaz. Public `.cer` dosyası eşleşen özel anahtar olmadan imzalama yapamaz. Mevcut iOS sertifikalarını iptal etmeyin.

`mac-distribution` korumalı GitHub ortamında beklenen secret adları:

| Secret | İçerik |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Uygulama Store sertifikası ve özel anahtarının parola korumalı P12'si, Base64 |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Uygulama P12 parolası |
| `INSTALLER_DISTRIBUTION_P12_BASE64` | Mac Installer Distribution sertifikası ve özel anahtarının P12'si, Base64 |
| `INSTALLER_DISTRIBUTION_P12_PASSWORD` | Yükleyici P12 parolası |
| `APPLE_TEAM_ID` | Apple takım kimliği |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_P8` | Build yükleme yetkili App Store Connect Team API anahtarı |
| `MAC_STORE_PROFILE_BASE64` | Gerektiğinde App Store provisioning profile, Base64 |

Özel anahtar, P12/P8, parola ve DPAPI dosyaları depoya, rapor artifact'lerine veya uygulama paketine konulmaz. Ortamın mevcut gerekli inceleyici ve yalnızca `main` dalı kuralları korunur. Yükleme workflow'undaki kaynak SHA yer tutucuları, ilgili kaynak incelenip CI başarılı olmadan doldurulmaz.

## Provisioning profile

Mevcut sürüm yalnızca App Sandbox ve kullanıcı seçimi dosya erişimi entitlement'larını kullanır. Apple TN3125'e göre kısıtlı entitlement kullanmayan Mac uygulamalarında App Store dağıtımı için profil gerekmez; **TestFlight her zaman profil gerektirir**. Profil verilirse paketleme script'i takım, uygulama kimliği, süre ve sertifika eşleşmesini kontrol ederek gömer ve ilgili uygulama/takım entitlement'larını ekler. Kısıtlı capability eklenirse uygun profil de sağlanmalıdır.

## Windows'ta public sertifikadan P12 hazırlama

`windows/Export-MacStoreSigningP12.ps1`, PowerShell 7.2+ üzerinde yalnızca açıkça verilen public Apple `.cer`, CSR'nin CurrentUser DPAPI korumalı RSA özel anahtarı ve public Apple root/intermediate dosyalarıyla çalışır. Sertifika oluşturmaz, Windows sertifika deposuna kurulum yapmaz, anahtar/parola göstermez veya yüklemez.

Önce Apple root SHA-256 pin'i, imza zinciri, çevrimiçi iptal durumu, geçerlilik süresi, takım, EKU ve Store amacını doğrular. Ardından DPAPI anahtarını bellekte açıp sertifika RSA anahtarıyla eşleştirir. İsteğe bağlı `-P12Password` bir `SecureString` kabul eder; verilmezse güçlü rastgele parola oluşturulur. P12 parola korumalı, parola dosyası CurrentUser DPAPI korumalı olarak saklanır. Bellekteki anahtar/parola tamponları işlem sonunda temizlenir.

Generic `New-AppleSigningRequest.ps1` ile her amaç için ayrı özel dizinde CSR hazırlanabilir. Application ve Installer için doğru CSR/anahtar çifti açıkça seçilmelidir. Aşağıdaki örnek gerçek anahtar veya parola içermez:

```powershell
.\windows\Export-MacStoreSigningP12.ps1 `
  -Purpose Application -TeamId 'TEAMIDHERE' `
  -CertificatePath 'C:\PrivateSigning\application.cer' `
  -ProtectedPrivateKeyPath 'C:\PrivateSigning\application\AnalizHukuk-Mac.privatekey.dpapi' `
  -AppleRootCertificatePath 'C:\PublicAppleCertificates\AppleIncRootCertificate.cer' `
  -IntermediateCertificatePaths 'C:\PublicAppleCertificates\AppleWWDRCAG3.cer' `
  -OutputDirectory 'C:\PrivateSigning\application-export'
```

Installer için `-Purpose Installer` ve o sertifikanın CSR/anahtar çifti kullanılır. Açık parola gerekiyorsa `-P12Password (Read-Host -AsSecureString 'P12 parolası')` verilir; düz metin komut satırı parolası kullanılmaz. ACL kısıtlaması uygulanamayan yönetilen ortamda yalnızca açıkça seçilen `-AllowDpapiOnly` modu kullanılabilir. Mevcut çıktıların üzerine yazılmaz.

## Hesapta tamamlanacak adımlar

Kaynak kod ve başarılı CI, Apple hesabında uygulama kaydı veya Store imzalama varlıklarının oluşturulduğunu kanıtlamaz. Yükleme için:

1. App Store Connect web sitesinde bu bundle ID için macOS uygulama kaydı bulunmalıdır. Apple Apps API yeni uygulama kaydı oluşturmak için kullanılmaz.
2. İki Store imzalama sertifikası ve eşleşen özel anahtarlar sağlanmalı; korumalı ortam secret'ları yapılandırılmalıdır. Yeni sertifika/yetki oluşturma ayrıca hesap sahibi tarafından tamamlanır.
3. Başarılı universal CI run'ı ve incelenen SHA sabitlenmeli; yükleme paketi Apple doğrulamasını geçmelidir.
4. Build işlendikten sonra açıklamalar, ekran görüntüleri, gizlilik, yaş derecelendirmesi ve App Review bilgileri tamamlanıp incelemeye gönderilmelidir.

Store dağıtım sertifikalı uygulama normal yerel test için çalıştırılmaz; fonksiyon testleri önce sandbox test derlemesiyle yapılır. Upload veya App Review onayı, bir yayın gerçekleşmeden önce ayrı ayrı doğrulanır.

## Resmî kaynaklar

- [Apple sertifika türleri](https://developer.apple.com/help/account/certificates/certificates-overview/)
- [Mac paketleme](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Build yükleme](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [App Store Connect Apps API](https://developer.apple.com/documentation/appstoreconnectapi/apps)
- [TN3125: entitlement ve provisioning profile](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple public CA dosyaları](https://www.apple.com/certificateauthority/)
- [Apple WWDR sertifika profilleri](https://images.apple.com/certificateauthority/pdf/Apple_WWDR_CPS_v3.0.pdf)
