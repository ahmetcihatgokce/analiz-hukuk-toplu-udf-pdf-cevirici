# Analiz Hukuk Toplu UDF PDF Çevirici

**UYAP evraklarını müvekkilinizle paylaşmaya hazırlayın.** Avukatlar ve çok sayıda dosya yöneten hukuk büroları, bir klasördeki UDF evraklarını dosya adlarını koruyarak topluca PDF’ye dönüştürebilir ve paylaşacakları belgeleri tek PDF’de birleştirebilir.

Ücretsiz Windows uygulamasının sade arayüzü dosya seçme, dönüştürme ve PDF’leri birleştirme adımlarına odaklanır. Belgeler bilgisayarınızda işlenir ve internete yüklenmez.

[Windows için 1.03 sürümünü indir (ZIP)](https://github.com/ahmetcihatgokce/analiz-hukuk-toplu-udf-pdf-cevirici/releases/download/v1.03/Analiz-Hukuk-Toplu-UDF-PDF-Cevirici-1.03.zip)

## Kullanım

1. ZIP dosyasını çıkarın ve `Analiz-Hukuk-Toplu-UDF-PDF-Cevirici.exe` dosyasını çalıştırın.
2. **Klasör seç**, **UDF seç** veya **Dosya seç** düğmesiyle girdileri belirleyin. Dosya seçiciler tekli ve çoklu seçimi destekler.
3. **İşlemi başlat** düğmesine basın. Varsayılan çıktı `PDF-UYAP` klasörüdür. Çıktı konumunu değiştirebilirsiniz. Var olan PDF’lerin üzerine yazılmaz.

| İşlem | Destek ve gereksinimler |
| --- | --- |
| UDF → PDF | UYAP Doküman Editörü ve Java 8 |
| Görsel → PDF | TIF/TIFF, JPG/JPEG, PNG, BMP ve GIF. TIFF’in tüm sayfaları, GIF’in ilk karesi aktarılır. |
| Vekâlet pulu makbuzu → PDF | HTML/HTM. Kurulu Edge veya Chrome ile yerel sayfa içeriği kullanılır. Haricî kaynaklar ve betikler yüklenmez. |
| Arşivden PDF ayıkla veya dönüştür | ZIP, RAR ve ZIP tabanlı şifresiz EYP. Arşiv içindeki hedef alt klasörler korunur. RAR için Windows’un `tar.exe` bileşeni gerekir. |
| PDF birleştir / ayır | UYAP Doküman Editörü ve Java 8. Seçili sayfa aralıkları ayrı PDF olarak kaydedilebilir. |

Hazır PDF dosyaları değiştirilmeden ayıklanır. İmzalı UDF ve EYP asıllarını saklayın. Dönüşüm e-imzayı doğrulamaz veya dönüştürülen PDF’ye taşımaz. Şifreli paketler, XML ve Office biçimleri kapsam dışındadır.

**ZIP SHA-256** `5a93065e2a356810e07e66231de4c7e09d393762acf542038b904795e32afc7a`

- [Windows programı gizlilik açıklaması](https://analizhukukburosu.org/uygulamalar/toplu-udf-pdf/gizlilik)
- [Analiz Hukuk uygulamaları](https://analizhukukburosu.org/uygulamalar)
