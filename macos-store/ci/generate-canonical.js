/* CI-only synthetic UDF fixtures serialized by the installed official UYAP writer.
 * No UYAP implementation, runtime or client document is redistributed.
 * Run with the official Java 8 Nashorn shell and UYAP classpath before signing.
 */
var System = Java.type('java.lang.System');
var Class = Java.type('java.lang.Class');
var Thread = Java.type('java.lang.Thread');
var Paths = Java.type('java.nio.file.Paths');
var Files = Java.type('java.nio.file.Files');
var UTF8 = Java.type('java.nio.charset.StandardCharsets').UTF_8;
var ByteArrayOutputStream = Java.type('java.io.ByteArrayOutputStream');
var ByteArrayInputStream = Java.type('java.io.ByteArrayInputStream');
var ZipOutputStream = Java.type('java.util.zip.ZipOutputStream');
var ZipEntry = Java.type('java.util.zip.ZipEntry');
var DocumentEx = Java.type('tr.com.havelsan.uyap.system.editor.common.text.DocumentEx');
var SimpleAttributeSet = Java.type('javax.swing.text.SimpleAttributeSet');
var StyleConstants = Java.type('javax.swing.text.StyleConstants');
var Color = Java.type('java.awt.Color');
var TabSet = Java.type('javax.swing.text.TabSet');
var TabStop = Java.type('javax.swing.text.TabStop');
var Panel = Java.type('tr.com.havelsan.uyap.system.editor.common.gui.WPDocumentPanel');
var EditorPane = Java.type('javax.swing.JEditorPane');
var Container = Java.type('java.awt.Container');
var Action = Java.type('javax.swing.Action');
var ActionEvent = Java.type('java.awt.event.ActionEvent');
var outputDirectory = Paths.get(String(arguments[0]));
Files.createDirectories(outputDirectory);
var serializerType = Class.forName('tr.com.havelsan.uyap.system.editor.common.text.J', false,
    Thread.currentThread().getContextClassLoader());
var serializer = serializerType.getConstructor().newInstance();
var methods = Java.from(serializerType.getMethods());
var writer = methods.filter(function(method) {
    var parameters = method.getParameterTypes();
    return String(method.getName()) === 'a' && String(method.getReturnType().getName()) === 'void'
        && parameters.length === 2
        && String(parameters[0].getName()) === 'tr.com.havelsan.uyap.system.editor.common.text.DocumentEx'
        && String(parameters[1].getName()) === 'java.io.OutputStream';
})[0];
var reader = methods.filter(function(method) {
    var parameters = method.getParameterTypes();
    return String(method.getReturnType().getName()) === 'tr.com.havelsan.uyap.system.editor.common.text.DocumentEx'
        && parameters.length === 2 && String(parameters[0].getName()) === 'java.io.InputStream'
        && String(parameters[1].getName()) === 'int';
})[0];
if (!writer || !reader) throw Error('Official public reader/writer signatures changed. No fixture was blessed.');
var manifest = {schemaVersion: 1, syntheticOnly: true,
    scope: 'Original synthetic inputs serialized by the installed official UYAP public reader/writer and editor actions; not arbitrary-client UDF coverage.',
    fixtures: []};

function font(size, bold, italic, foreground) {
    var attributes = new SimpleAttributeSet();
    StyleConstants.setFontFamily(attributes, 'Times New Roman');
    StyleConstants.setFontSize(attributes, size);
    StyleConstants.setBold(attributes, Boolean(bold));
    StyleConstants.setItalic(attributes, Boolean(italic));
    if (foreground !== null && foreground !== undefined) StyleConstants.setForeground(attributes, foreground);
    return attributes;
}

function save(name, document, phrases, pageCount, origin) {
    var output = new ByteArrayOutputStream();
    writer.invoke(serializer, Java.to([document, output], 'java.lang.Object[]'));
    var xml = output.toByteArray();
    if (xml.length > 1024 * 1024) throw Error('Synthetic fixture exceeds its limit.');
    Files.write(outputDirectory.resolve(name + '.xml'), xml);
    var bytes = new ByteArrayOutputStream();
    var zip = new ZipOutputStream(bytes);
    zip.putNextEntry(new ZipEntry('content.xml'));
    zip.write(xml);
    zip.closeEntry();
    zip.close();
    Files.write(outputDirectory.resolve(name + '.udf'), bytes.toByteArray());
    var item = {file: name + '.udf', result: 'success', phrases: phrases,
        schemaStatus: 'official-writer-serialized', origin: origin};
    if (pageCount !== null && pageCount !== undefined) item.pageCount = pageCount;
    manifest.fixtures.push(item);
    print('CANONICAL_FIXTURE ' + name + ' bytes=' + xml.length);
}

function parse(xml) {
    var bytes = new (Java.type('java.lang.String'))(xml).getBytes(UTF8);
    return reader.invoke(serializer, Java.to([new ByteArrayInputStream(bytes), Java.type('java.lang.Integer').valueOf(0)], 'java.lang.Object[]'));
}

function ownPanel(document) {
    var panel = new Panel();
    var editors = [];
    function visit(component) {
        if (component instanceof EditorPane) editors.push(component);
        if (component instanceof Container) Java.from(component.getComponents()).forEach(visit);
    }
    visit(panel);
    if (editors.length !== 1) throw Error('Unexpected official editor component tree.');
    editors[0].setDocument(document);
    return {panel: panel, editor: editors[0], kit: editors[0].getEditorKit()};
}

function invokeAction(owner, name, position) {
    owner.editor.setCaretPosition(position);
    var matches = Java.from(owner.kit.getActions()).filter(function(action) {
        return String(action.getValue(Action.NAME)) === name;
    });
    if (matches.length !== 1) throw Error('Official editor action is unavailable: ' + name);
    matches[0].actionPerformed(new ActionEvent(owner.editor, ActionEvent.ACTION_PERFORMED, name));
}

var document = new DocumentEx();
document.insertString(0, 'CANONICAL_ALPHA\nT\u00fcrk\u00e7e sentetik test\n', font(12, false, false, null));
save('canonical-baseline', document, ['CANONICAL_ALPHA', 'T\u00fcrk\u00e7e', 'sentetik test'], 1, 'DocumentEx.insertString + official writer');

document = new DocumentEx();
document.insertString(0, 'CANONICAL_NORMAL\n', font(12, false, false, null));
document.insertString(document.getLength(), 'CANONICAL_BOLD\n', font(18, true, false, Color.RED));
document.insertString(document.getLength(), 'CANONICAL_ITALIC\n', font(12, false, true, null));
save('canonical-styles', document, ['CANONICAL_NORMAL', 'CANONICAL_BOLD', 'CANONICAL_ITALIC'], 1, 'Standard Swing character styles serialized by official writer');

document = new DocumentEx();
document.insertString(0, 'TAB_A\tTAB_B\tTAB_C\n', font(12, false, false, null));
var tabs = new SimpleAttributeSet();
StyleConstants.setTabSet(tabs, new TabSet(Java.to([new TabStop(72), new TabStop(144)], 'javax.swing.text.TabStop[]')));
document.setParagraphAttributes(0, document.getLength(), tabs, false);
save('canonical-tabs', document, ['TAB_A', 'TAB_B', 'TAB_C'], 1, 'Standard Swing TabSet serialized by official writer');

var tableText = 'TABLE_START\nCELL_A1\nCELL_B1\nCELL_A2\nCELL_B2\nTABLE_END\n';
var tableXML = '<?xml version="1.0" encoding="UTF-8"?><template format_id="1.8"><content><![CDATA[' + tableText
    + ']]></content><properties><pageFormat mediaSizeName="1" leftMargin="42.5" rightMargin="42.5" topMargin="42.5" bottomMargin="42.5" paperOrientation="1" headerFOffset="20" footerFOffset="20"/></properties>'
    + '<styles><style name="default" description="Default"/><style name="hvl-default" family="Times New Roman" size="12"/></styles><elements resolver="hvl-default">'
    + '<paragraph><content startOffset="0" length="12"/></paragraph>'
    + '<table tableName="Sabit" columnCount="2" columnSpans="120,220" width="340.0" border="borderCell">'
    + '<row rowName="row1" rowType="dataRow" border="borderCell"><cell border="borderCell" borderSpec="15"><paragraph><content startOffset="12" length="8"/></paragraph></cell>'
    + '<cell border="borderCell" borderSpec="15"><paragraph><content startOffset="20" length="8"/></paragraph></cell></row>'
    + '<row rowName="row2" rowType="dataRow" border="borderCell"><cell border="borderCell" borderSpec="15"><paragraph><content startOffset="28" length="8"/></paragraph></cell>'
    + '<cell border="borderCell" borderSpec="15"><paragraph><content startOffset="36" length="8"/></paragraph></cell></row></table>'
    + '<paragraph><content startOffset="44" length="10"/></paragraph></elements></template>';
save('canonical-table', parse(tableXML), ['TABLE_START', 'CELL_A1', 'CELL_B1', 'CELL_A2', 'CELL_B2', 'TABLE_END'], 1,
    'Own declarative table roundtripped by official reader and writer; recognized attributes retained');

var redPNG = 'iVBORw0KGgoAAAANSUhEUgAAAGAAAAAwCAIAAABhdOiYAAAAV0lEQVR42u3QQQkAAAgEsAvh2/7JzGED/8JgCZap5hAFggQJEiRIkCBBCBIkSJAgQYIEIUiQIEGCBAkShCBBggQJEiRIkCAECRIkSJAgQYIQJEiQIEE/LAn6sR5vmE8GAAAAAElFTkSuQmCC';
var imageXML = '<?xml version="1.0" encoding="UTF-8"?><template format_id="1.8"><content><![CDATA[IMAGE_SENTINEL\n\ufffc\n]]></content>'
    + '<properties><pageFormat mediaSizeName="1" leftMargin="42.5" rightMargin="42.5" topMargin="42.5" bottomMargin="42.5" paperOrientation="1" headerFOffset="20" footerFOffset="20"/></properties>'
    + '<styles><style name="default" description="Default"/><style name="hvl-default" family="Times New Roman" size="12"/></styles><elements resolver="hvl-default">'
    + '<paragraph><content startOffset="0" length="15"/></paragraph><paragraph><image width="96" height="48" imageData="' + redPNG
    + '" startOffset="15" length="1"/><content startOffset="16" length="1"/></paragraph></elements></template>';
save('canonical-image', parse(imageXML), ['IMAGE_SENTINEL'], 1,
    'Own red PNG with U+FFFC image placeholder roundtripped by official reader and writer');

document = new DocumentEx();
document.insertString(0, 'BREAK_FIRST\nBREAK_SECOND\n', font(12, false, false, null));
var owner = ownPanel(document);
invokeAction(owner, 'insert-pageBreak', 12);
save('canonical-page-break', document, ['BREAK_FIRST', 'BREAK_SECOND'], 2,
    'Official insert-pageBreak action on own offscreen editor component');

document = new DocumentEx();
document.insertString(0, 'BODY_FIRST\nBODY_SECOND\n', font(12, false, false, null));
owner = ownPanel(document);
invokeAction(owner, 'insert-pageBreak', 11);
invokeAction(owner, 'insert-header', 0);
invokeAction(owner, 'insert-footer', 0);
var root = document.getDefaultRootElement();
for (var i = root.getElementCount() - 1; i >= 0; i--) {
    var element = root.getElement(i);
    var name = String(element.getName());
    if (name === 'header' || name === 'footer') {
        document.insertString(element.getStartOffset(), name === 'header' ? 'CANONICAL_HEADER' : 'CANONICAL_FOOTER', font(12, false, false, null));
    }
}
save('canonical-headers-pagebreak', document, ['BODY_FIRST', 'BODY_SECOND', 'CANONICAL_HEADER', 'CANONICAL_FOOTER'], 2,
    'Official page-break/header/footer actions with own synthetic text');

document = new DocumentEx();
var lines = [];
for (var index = 0; index < 160; index++) {
    var padded = ('000' + index).slice(-3);
    var marker = 'CANONICAL_LINE_' + padded;
    lines.push(marker);
    document.insertString(document.getLength(), marker + ' T\u00fcrk\u00e7e test.\n', font(12, false, false, null));
}
save('canonical-long-pagination', document, lines, 3, '160 own paragraphs inserted into official DocumentEx');

Files.write(outputDirectory.resolve('expectations.json'), new (Java.type('java.lang.String'))(JSON.stringify(manifest, null, 2) + '\n').getBytes(UTF8));
print('CANONICAL_FIXTURE_COUNT ' + manifest.fixtures.length);
System.exit(0);
