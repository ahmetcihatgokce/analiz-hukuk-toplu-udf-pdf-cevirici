import java.awt.Font;
import java.awt.FontMetrics;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.font.LineMetrics;
import java.awt.image.BufferedImage;
import java.util.Locale;

/** CI-only measurements from the official runtime; not an app resource. */
public final class FontMetricsProbe {
    public static void main(String[] arguments) throws Exception {
        // Match the official exporter's font initialization when its classpath
        // is supplied. This creates no editor window or document.
        Class<?> tray = Class.forName("tr.com.havelsan.uyap.system.editor.utils.tray.TrayUtils");
        tray.getMethod("getInstance").invoke(null);
        BufferedImage image = new BufferedImage(8, 8, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = image.createGraphics();
        try {
            graphics.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
            graphics.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_ON);
            for (String requested : new String[] {"Arial", "Times New Roman", "Helvetica", "Courier New"}) {
                for (int size : new int[] {12, 18, 20}) {
                    for (int style : new int[] {Font.PLAIN, Font.BOLD}) {
                        Font font = new Font(requested, style, size);
                        graphics.setFont(font);
                        FontMetrics fm = graphics.getFontMetrics(font);
                        LineMetrics lm = font.getLineMetrics("Hgç", graphics.getFontRenderContext());
                        System.out.printf(Locale.ROOT,
                            "FONT_METRICS {\"requested\":\"%s\",\"resolvedFamily\":\"%s\",\"fontName\":\"%s\",\"size\":%d,\"bold\":%s,\"ascent\":%d,\"descent\":%d,\"leading\":%d,\"height\":%d,\"floatAscent\":%.6f,\"floatDescent\":%.6f,\"floatLeading\":%.6f,\"floatHeight\":%.6f,\"sampleWidth\":%.6f}%n",
                            requested, font.getFamily(Locale.ROOT), font.getFontName(Locale.ROOT), size,
                            style == Font.BOLD ? "true" : "false", fm.getAscent(), fm.getDescent(), fm.getLeading(), fm.getHeight(),
                            lm.getAscent(), lm.getDescent(), lm.getLeading(), lm.getHeight(),
                            font.getStringBounds("LONG_LINE_000", graphics.getFontRenderContext()).getWidth());
                    }
                }
            }
        } finally {
            graphics.dispose();
        }
    }
}
