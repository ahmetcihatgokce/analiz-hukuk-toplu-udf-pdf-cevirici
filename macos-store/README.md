# Analiz Hukuk UDF PDF — Mac App Store çalışması

Bu dizin Mac App Store için hazırlanan bağımsız yerel sürümdür. GitHub’daki Developer ID/notarization dağıtımından ayrı hazırlanır. Mağazaya yüklenmiş veya Apple tarafından onaylanmış değildir.

UDF ZIP/XML okuma ve PDF çizimi Swift/AppKit ile yapılır. Kurulu UYAP, Java veya indirilen çalıştırılabilir koda ihtiyaç duymaz. Tanınmayan belge özellikleri başarılı ama eksik bir PDF olarak sunulmaz; işlem açık bir hata ile durur. Bu yaklaşım bütün UDF belgelerinde UYAP ile aynı sayfa düzeninin kanıtlandığı anlamına gelmez. Yayın öncesinde farklı belge düzenleri ve resmî sentetik karşılaştırmalarla doğrulama gereklidir.

PDF birleştirme/ayırma, TIFF/görsel ve HTML dönüşümü ile ZIP/RAR/EYP ayıklama yerel çalışır. Dosya veya klasör seçimi sistem penceresi üzerinden yapılır. Tek dosya seçiminde çıktı için ayrıca klasör seçilir. Kalıcı dosya erişim izinleri veya belge kayıtları tutulmaz. Belgeler sunucuya aktarılmaz; App Sandbox ağ istemcisi izni verilmez.

## Derleme ve doğrulama

macOS 13 veya üstü hedeflenir. Yerel Mac GitHub runner üzerinde `MAC_STORE_TESTING=1 bash macos-store/build-store.sh "$RUNNER_TEMP/test" --no-zip` sandbox test sürümünü üretir. Üretim sürümü için `MAC_STORE_TESTING` verilmez. Gerçek belge/kişisel veri içermeyen sentetik testler kullanılır. Testler imzalama kimlikleri yüklenmeden önce çalışır.

Store paketi için uygulama dağıtım sertifikası ve eşleşen özel anahtarı, ayrı Mac Installer Distribution sertifikası ve özel anahtarı, gerekli App ID/profil ve App Store Connect macOS uygulama kaydı gerekir. `distribution/package-store.sh` yalnızca test edilmiş universal uygulama üzerinden paket doğrular; `MAC_STORE_UPLOAD=1` açıkça verildiğinde Apple'a derleme yükler. Derleme yüklemek mağaza onayı veya yayın değildir.

App Store'un mevcut UYAP/Java kullanan sürümü doğrudan kabul edeceği varsayılmamalıdır. Mevcut Windows ve doğrudan Mac dağıtım kodu bu dizinden bağımsız kalır.
