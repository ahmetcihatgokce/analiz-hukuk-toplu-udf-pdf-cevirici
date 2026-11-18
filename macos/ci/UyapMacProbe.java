import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Locale;
import javax.imageio.ImageIO;

/** Tests the installed UYAP engine without redistributing its binaries. */
public final class UyapMacProbe {
    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 3) {
            throw new IllegalArgumentException("Expected input.udf output.pdf report-directory");
        }
        File input = new File(arguments[0]);
        File output = new File(arguments[1]);
        File report = new File(arguments[2]);
        Class<?> trayClass = Class.forName(
            "tr.com.havelsan.uyap.system.editor.utils.tray.TrayUtils");
        Object tray = trayClass.getMethod("getInstance").invoke(null);
        Method exporter = null;
        for (Method method : trayClass.getMethods()) {
            System.out.println("TRAY_API " + method.toString());
            if (method.getName().equals("udfToPdf") && method.getParameterTypes().length == 2) {
                Class<?>[] parameters = method.getParameterTypes();
                if (parameters[0].isAssignableFrom(FileOutputStream.class)
                    && parameters[1].isAssignableFrom(ByteArrayInputStream.class)) {
                    exporter = method;
                }
            }
        }
        if (exporter == null) {
            throw new NoSuchMethodException("Compatible udfToPdf(OutputStream, ByteArrayInputStream)");
        }
        try (FileOutputStream destination = new FileOutputStream(output);
             ByteArrayInputStream source = new ByteArrayInputStream(Files.readAllBytes(input.toPath()))) {
            try {
                exporter.invoke(tray, destination, source);
            } catch (InvocationTargetException error) {
                error.getTargetException().printStackTrace();
                throw error;
            }
        }
        byte[] bytes = Files.readAllBytes(output.toPath());
        if (bytes.length < 100 || !new String(bytes, 0, 5, StandardCharsets.US_ASCII).equals("%PDF-")) {
            throw new IllegalStateException("Exporter did not create a PDF");
        }
        verifyPdf(output, report);
        System.out.println("UYAP_MAC_EXPORT_OK bytes=" + bytes.length);
        System.exit(0);
    }

    private static void verifyPdf(File pdf, File report) throws Exception {
        Class<?> documentClass = Class.forName("org.apache.pdfbox.pdmodel.PDDocument");
        Object document;
        try {
            document = documentClass.getMethod("load", File.class).invoke(null, pdf);
        } catch (NoSuchMethodException newerPdfBox) {
            Class<?> loader = Class.forName("org.apache.pdfbox.Loader");
            document = loader.getMethod("loadPDF", File.class).invoke(null, pdf);
        }
        try {
            int pages = (Integer) documentClass.getMethod("getNumberOfPages").invoke(document);
            if (pages != 1) {
                throw new IllegalStateException("Expected one synthetic page, received " + pages);
            }
            Object firstPage = documentClass.getMethod("getPage", int.class).invoke(document, 0);
            Object mediaBox = firstPage.getClass().getMethod("getMediaBox").invoke(firstPage);
            float width = (Float) mediaBox.getClass().getMethod("getWidth").invoke(mediaBox);
            float height = (Float) mediaBox.getClass().getMethod("getHeight").invoke(mediaBox);
            if (Math.abs(width - 595.28f) > 3 || Math.abs(height - 841.89f) > 3) {
                throw new IllegalStateException("Expected A4 page, received " + width + " x " + height);
            }
            Class<?> stripperClass = Class.forName("org.apache.pdfbox.text.PDFTextStripper");
            Object stripper = stripperClass.getConstructor().newInstance();
            String text = (String) stripperClass.getMethod("getText", documentClass).invoke(stripper, document);
            Files.write(new File(report, "extracted-text.txt").toPath(), text.getBytes(StandardCharsets.UTF_8));
            for (String expected : new String[] {"Analiz Hukuk", "Türkçe", "sentetik test"}) {
                if (!text.contains(expected)) {
                    throw new IllegalStateException("PDF text is missing expected phrase: " + expected);
                }
            }
            Class<?> rendererClass = Class.forName("org.apache.pdfbox.rendering.PDFRenderer");
            Object renderer = rendererClass.getConstructor(documentClass).newInstance(document);
            BufferedImage image = (BufferedImage) rendererClass.getMethod(
                "renderImageWithDPI", int.class, float.class).invoke(renderer, 0, 96f);
            if (!ImageIO.write(image, "png", new File(report, "rendered-page.png"))) {
                throw new IllegalStateException("PNG writer unavailable");
            }
            String summary = String.format(Locale.ROOT,
                "pages=%d\nwidth=%.2f\nheight=%.2f\ntextCharacters=%d\n",
                pages, width, height, text.length());
            Files.write(new File(report, "pdf-summary.txt").toPath(), summary.getBytes(StandardCharsets.UTF_8));
            System.out.print(summary);
        } finally {
            documentClass.getMethod("close").invoke(document);
        }
    }
}
