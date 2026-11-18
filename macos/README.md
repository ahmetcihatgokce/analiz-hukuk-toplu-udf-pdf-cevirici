# Analiz Hukuk Toplu UDF PDF Çevirici — macOS 1.04 önizleme

macOS 13 ve sonrası için yerel AppKit uygulaması. Intel ve Apple Silicon için ayrı paketler GitHub Actions tarafından derlenir.

## Özellikler

- Dosya, UDF dosyası veya klasör seçerek toplu dönüşüm.
- UDF, HTML/HTM, TIFF/TIF, JPG/JPEG, PNG, BMP ve GIF desteği.
- ZIP, RAR ve ZIP tabanlı EYP arşivlerindeki desteklenen belgeleri dönüştürme veya yalnız hazır PDF'leri çıkarma.
- Çok sayfalı TIFF desteği; Türkçe dosya adları ve arşiv alt klasörleri korunur.
- PDF'leri seçilen sırayla birleştirme, sayfa çıkarma ve ayırma.
- Aynı isimli mevcut çıktıları koruyarak yeni ada kaydetme.
- HTML dönüşümünde JavaScript ve uzak içerik engellenir. Belgeler bir dönüşüm sunucusuna yüklenmez.

UDF dönüşümü için işlemcinize uygun güncel resmî **UYAP Doküman Editörü** kurulmalıdır. Editörün kendi Java çalışma ortamı kullanılır. UYAP yazılımı ve Java çalışma ortamı bu pakete dahil edilmez. Diğer dönüşümler, PDF birleştirme ve ayırma yerel macOS araçlarını kullanır.

## Test paketini indirme

Bu dalın [Actions sayfasındaki](https://github.com/ahmetcihatgokce/analiz-hukuk-toplu-udf-pdf-cevirici/actions?query=branch%3Amacos-port) son başarılı çalışmasının Artifacts bölümünü açın. İndirme için GitHub oturumu gerekebilir.

- `macos-15`: Apple Silicon.
- `macos-15-intel`: Intel.

Artifact ZIP'ini, ardından içindeki uygulama ZIP'ini açın. Uygulama paketi test amaçlı **ad-hoc** imzalıdır. Apple Developer ID imzası ve noter onayı (notarization) henüz yoktur. Gatekeeper uyarısı verebilir. Bu bir Mac App Store yayını değildir.

## Derleme ve doğrulama

Mac üzerinde Xcode komut satırı araçları, Homebrew ve Java derleyicisi gereklidir:

```sh
bash macos/build.sh
```

Libarchive başlıkları Homebrew'den alınır, uygulama macOS sistem libarchive kütüphanesine bağlanır. Kullanıcıya Homebrew veya Python kurdurulmaz.

GitHub Actions her iki işlemcide sentetik evraklarla UDF, HTML/CP1254, görseller, çok sayfalı TIFF, ZIP/EYP/RAR, PDF sıralama ve ayırma, hatalı belge izolasyonu, güvenli arşiv yolları ve mevcut dosyaları koruma senaryolarını çalıştırır. Açılış penceresinin PNG görüntüsü test raporuna eklenir. Gerçek müvekkil evrakı CI'a eklenmez. Test başarısı her UDF belgesinin aynı görüneceği garantisi değildir.

## Apple dağıtımı

Mevcut aktif Apple Developer Program üyeliği Mac dağıtımını da kapsar. Ayrı üyelik gerekmez.

- GitHub/site üzerinden genel dağıtım için Developer ID imzası ve Apple notarization tamamlanmalıdır.
- Mac App Store için uygulama sandbox ve kendi başına çalışma koşullarını sağlamalıdır. Mevcut UDF yolu ayrıca kurulu UYAP/Java'ya bağımlıdır ve bu haliyle mağazaya gönderilmeye hazır değildir. UDF motoru için ayrı uyarlama gereklidir.

[Apple üyelik kapsamı](https://developer.apple.com/programs/whats-included/) · [Mac App Store koşulları, 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
