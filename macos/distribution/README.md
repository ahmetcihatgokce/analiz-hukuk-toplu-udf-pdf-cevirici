# Developer ID imzası ve Apple notarization

Bu akış GitHub veya siteden dağıtılacak Mac uygulamasını Developer ID ile imzalar ve Apple'ın notarization hizmetine gönderir. **Mac App Store gönderimi değildir.** UDF dönüşümünün kurulu UYAP/Java bağımlılığı ve App Sandbox koşulları mağaza için ayrıca çözülmelidir.

## Gerekenler

- Geçerli Developer ID Application sertifikası ve ona ait özel anahtarı içeren parola korumalı P12.
- Apple Team ID ve sertifikanın tam kimliği.
- App Store Connect Team API Key, Key ID, Issuer ID ve P8 özel anahtarı. Individual API key, notarytool için uygun değildir.

Sertifika oluşturma ve GitHub'a imzalama yetkisi verme hesap sahibi tarafından onaylanmalıdır. Anahtarlar, P12/P8 veya parolalar kaynak koda ve indirme paketlerine eklenmez.

`mac-distribution` GitHub ortamındaki secrets:

| Ad | İçerik |
| --- | --- |
| `MAC_CERTIFICATE_P12_BASE64` | P12 dosyasının Base64 hali |
| `MAC_CERTIFICATE_PASSWORD` | P12 parolası |
| `APPLE_TEAM_ID` | 10 karakterli takım kimliği |
| `APPLE_SIGNING_IDENTITY` | Developer ID Application sertifikasının tam adı |
| `ASC_KEY_ID` | Team API key kimliği |
| `ASC_ISSUER_ID` | Team API key issuer UUID |
| `ASC_PRIVATE_KEY_P8` | P8 dosyasının PEM içeriği |

Ortamın gerekli inceleyici ve izinli dal kuralları ayrıca GitHub'dan ayarlanmalıdır. Yalnız workflow'da ortam adını yazmak koruma sağlamaz. Depoya yazma yetkisi olan kişiler workflow'u değiştirebildiğinden, bu yetkiler ve inceleme kuralları önemlidir.

## Çalıştırma

`.github/workflows/macos-notarize.yml` varsayılan dalda yer alır. Yalnız elle `workflow_dispatch` ile başlatılır. PR ve push olayları imzalama başlatmaz. Hazırlanan `mac-distribution` ortamı yalnız `main` dalına izin verir.

Uygulama kaynağı, Intel ve Apple Silicon'da Hardened Runtime testlerini geçmiş `98c996ec72181c0c2aa7704556faf21367386cd8` commit'ine sabitlenmiştir. `APPROVED_SOURCE_SHA` ve form varsayılanı yeni kaynak incelenip test edildikten sonra birlikte değiştirilir. İmzalama araçları ise seçilen workflow commit'inden alınır ve ayrıca incelenmelidir.

Her işlemcide uygulama derlenip sentetik belgelerle test edilir. Bu testler, kimlik bilgileri işleme alınmadan önce çalışır. Ardından geçici keychain'e sertifika alınır; imzada `--options runtime --timestamp` kullanılır. İmza ve takım doğrulanınca özel anahtarı içeren keychain silinir. Kimlik bilgileri varken uygulama veya UYAP işlemi başlatılmaz.

Apple `Accepted` döndürürse notarization günlüğü kontrol edilir. Bilet uygulamaya eklenir; `stapler validate`, imza doğrulama ve Gatekeeper değerlendirmesi geçmeden dağıtım ZIP'i oluşturulmaz. Artifact yalnız onaylanan ZIP, SHA-256 ve gizli bilgi içermeyen sonuç JSON'udur. Release veya site yayını otomatik yapılmaz. Artifact 30 gün tutulur.

Kimlik bilgileri normal çıkışta ve hata/iptalde temizlenir. GitHub'ın geçici Mac makinesi iş sonunda kaldırılır. Gönderim kimliği yükleme biter bitmez kaydedilir. Apple yanıtı 15 dakikayı aşarsa durum ayrıca sorgulanır; hâlâ işleniyorsa bu durum ret olarak değerlendirilmez.

Bekleyen gönderimde tam imzalı ZIP, mevcut P12 parolasından HKDF ile türetilen bir anahtarla AES-256-GCM kullanılarak şifrelenir. Kaynak commit, işlemci, takım, gönderim kimliği ve ZIP özeti kimlik doğrulamalı metaveriye bağlanır. `mac-notary-pending-*` artifact'i kurulum paketi değildir; özel anahtar veya parola içermez. Bu şifreli dosya 30 gün saklanır.

## Bekleyen gönderimi sürdürme

`Resume existing Mac notarization` akışı, şifreli artifact'in bulunduğu `source_run_id` ve işlemci seçilerek elle çalıştırılır. Aynı korumalı ortam kullanılır. Eski gönderimin durumu sorgulanır; yeniden yükleme yapılmaz. Apple kabul etmişse özgün paket çözülür, imza/takım/kaynak ve arşiv yolları doğrulanır; bilet ve Gatekeeper kontrollerinden sonra dağıtım ZIP'i üretilir. Bu akış yalnız şifreli bekleme artifact'i bulunan gönderimlerde kullanılabilir.

## Doğrulama

Hardened Runtime ile uygulamanın Intel ve Apple Silicon dönüşüm/açılış testleri geçti: [çalışma 44486293359](https://github.com/ahmetcihatgokce/analiz-hukuk-toplu-udf-pdf-cevirici/actions/runs/44486293359).

Dağıtım scriptleri kimlik bilgisi olmadan hazırlanmıştır. Sözdizimi kontrolleri gerçek Developer ID imzası veya Apple kabulü anlamına gelmez. Apple doğrulaması standart ilk açılış onayının hiç görünmeyeceğini garanti etmez.

Windows CSR/P12 hazırlığı için [Windows araçlarına](windows/README.md) bakın. Bu bilgisayardaki özel anahtarlar Windows CurrentUser DPAPI ile korunur. Yönetilen ortam ACL kısıtlamasını uygulamadığından açık `-AllowDpapiOnly` seçeneği kullanılır; özel anahtar veya parola düz metin olarak yazılmaz.

## Resmî kaynaklar

- [Apple Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [API anahtarları](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [GitHub sertifika kurulumu](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
