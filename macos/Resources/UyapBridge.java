import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import javax.xml.XMLConstants;
import javax.xml.parsers.SAXParserFactory;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;
import org.xml.sax.XMLReader;
import org.xml.sax.helpers.DefaultHandler;

/** Runs the user's installed UYAP exporter using its installed Java runtime. */
public final class UyapBridge {
    private static final long MAX_UDF_BYTES = 128L * 1024 * 1024;

    public static void main(String[] arguments) {
        try {
            if (arguments.length != 2) {
                throw new IllegalArgumentException("Expected input.udf output.pdf");
            }
            File input = new File(arguments[0]);
            File output = new File(arguments[1]);
            try {
                validateUdf(input);
            } catch (Exception validationError) {
                throw new IllegalArgumentException("UDF validation failed: "
                    + validationError.getClass().getSimpleName() + ": "
                    + validationError.getMessage(), validationError);
            }
            System.out.println("UDF_VALIDATION_OK");
            Class<?> trayClass = Class.forName(
                "tr.com.havelsan.uyap.system.editor.utils.tray.TrayUtils");
            Object tray = trayClass.getMethod("getInstance").invoke(null);
            Method exporter = null;
            for (Method method : trayClass.getMethods()) {
                if (method.getName().equals("udfToPdf") && method.getParameterTypes().length == 2) {
                    Class<?>[] parameters = method.getParameterTypes();
                    if (parameters[0].isAssignableFrom(FileOutputStream.class)
                        && parameters[1].isAssignableFrom(ByteArrayInputStream.class)) {
                        exporter = method;
                    }
                }
            }
            if (exporter == null) {
                throw new NoSuchMethodException("Compatible udfToPdf exporter unavailable");
            }
            try (FileOutputStream destination = new FileOutputStream(output);
                 ByteArrayInputStream source = new ByteArrayInputStream(Files.readAllBytes(input.toPath()))) {
                exporter.invoke(tray, destination, source);
            }
            byte[] bytes = Files.readAllBytes(output.toPath());
            if (bytes.length < 100 || !new String(bytes, 0, 5, StandardCharsets.US_ASCII).equals("%PDF-")) {
                throw new IllegalStateException("Exporter did not create a PDF");
            }
            System.out.println("UYAP_EXPORT_OK bytes=" + bytes.length);
            System.exit(0);
        } catch (Throwable error) {
            if (error instanceof InvocationTargetException) {
                error = ((InvocationTargetException) error).getTargetException();
            }
            error.printStackTrace();
            System.exit(1);
        }
    }

    private static void validateUdf(File input) throws Exception {
        if (!input.isFile() || input.length() > MAX_UDF_BYTES) {
            throw new IllegalArgumentException("UDF archive is missing or exceeds 128 MB");
        }
        try (ZipFile archive = new ZipFile(input)) {
            long expandedBytes = 0;
            byte[] buffer = new byte[8192];
            Enumeration<? extends ZipEntry> entries = archive.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (entry.getSize() > MAX_UDF_BYTES - expandedBytes) {
                    throw new IllegalArgumentException("Expanded UDF archive exceeds 128 MB");
                }
                try (InputStream stream = archive.getInputStream(entry)) {
                    int count;
                    while ((count = stream.read(buffer)) != -1) {
                        if (count > MAX_UDF_BYTES - expandedBytes) {
                            throw new IllegalArgumentException("Expanded UDF archive exceeds 128 MB");
                        }
                        expandedBytes += count;
                    }
                }
            }
            ZipEntry content = archive.getEntry("content.xml");
            if (content == null) {
                throw new IllegalArgumentException("UDF archive does not contain content.xml");
            }
            // UYAP includes its own older XML provider. Validate with the JDK's
            // parser so the required external-resource controls stay effective.
            SAXParserFactory factory = SAXParserFactory.newInstance(
                "com.sun.org.apache.xerces.internal.jaxp.SAXParserFactoryImpl", null);
            factory.setNamespaceAware(true);
            factory.setXIncludeAware(false);
            factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
            XMLReader reader = factory.newSAXParser().getXMLReader();
            reader.setProperty(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            reader.setProperty(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
            reader.setEntityResolver((publicId, systemId) -> {
                throw new SAXException("External XML resources are disabled");
            });
            reader.setContentHandler(new DefaultHandler() {
                private int depth;

                @Override
                public void startElement(String uri, String localName, String qualifiedName,
                                         org.xml.sax.Attributes attributes) throws SAXException {
                    if (depth == 0 && !localName.equals("template")) {
                        throw new SAXException("UDF content root must be template");
                    }
                    depth++;
                    if (depth > 128) {
                        throw new SAXException("UDF XML nesting exceeds 128 levels");
                    }
                }

                @Override
                public void endElement(String uri, String localName, String qualifiedName) {
                    depth--;
                }
            });
            try (InputStream stream = archive.getInputStream(content)) {
                reader.parse(new InputSource(stream));
            }
        }
    }
}
