# Toplu UDF PDF Çevirici — macOS önizleme

macOS 13 ve sonrası için yerel AppKit uygulaması. Dosya veya klasör seçerek UDF, görsel, HTML ve arşiv belgelerini PDF’ye dönüştürür. PDF sıralama, birleştirme ve sayfa ayırma araçları PDFKit kullanır.

UDF dönüşümü için işlemcinize uygun güncel resmî UYAP Doküman Editörü kurulu olmalıdır. Editörün kendi Java çalışma ortamı kullanılır. UYAP yazılımı bu pakete dahil edilmez. Belgeler yerel olarak işlenir.

Derleme için macOS ve Xcode komut satırı araçlarıyla `bash macos/build.sh` çalıştırılır. GitHub Actions, Intel ve Apple Silicon üzerinde sentetik evraklarla dönüşüm ve arayüz testlerini çalıştırır. Önizleme paketleri geliştirme imzası taşır. Genel dağıtım için Developer ID imzası ve Apple doğrulaması ayrıca yapılmalıdır.
