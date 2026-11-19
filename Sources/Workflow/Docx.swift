import Foundation
import Support

/// A plain Word document: headings, paragraphs, bullet lists and links. Written without Word (section 3.1).
public struct DocxDocument: Sendable {
    public enum Block: Sendable {
        case title(String)
        case heading(String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case link(String, url: String)
    }

    public var blocks: [Block] = []

    public init() {}

    public mutating func add(_ block: Block) { blocks.append(block) }

    public var data: Data {
        var body = ""
        var links: [(id: String, url: String)] = []
        for block in blocks {
            switch block {
            case .title(let text): body += paragraph(text, style: "Title")
            case .heading(let text): body += paragraph(text, style: "Heading1")
            case .paragraph(let text):
                for line in text.components(separatedBy: "\n") { body += paragraph(line, style: nil) }
            case .bullets(let items): body += items.map { paragraph("• " + $0, style: "ListParagraph") }.joined()
            case .numbered(let items): body += items.enumerated().map { paragraph("\($0.offset + 1). " + $0.element, style: "ListParagraph") }.joined()
            case .link(let text, let url):
                let id = "rLink\(links.count + 1)"
                links.append((id, url))
                body += "<w:p><w:hyperlink r:id=\"\(id)\"><w:r><w:rPr><w:color w:val=\"2F4F7F\"/><w:u w:val=\"single\"/></w:rPr><w:t xml:space=\"preserve\">\(Self.escape(text))</w:t></w:r></w:hyperlink></w:p>"
            }
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1200" w:right="1200" w:bottom="1200" w:left="1200" w:header="600" w:footer="600" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Arial"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="2F3B4F"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="360"/><w:spacing w:after="60"/></w:pPr></w:style>
        </w:styles>
        """
        let types = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(links.map { "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(Self.escape($0.url))\" TargetMode=\"External\"/>" }.joined())</Relationships>
        """
        return ZipWriter.archive([
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
        ])
    }

    private func paragraph(_ text: String, style: String?) -> String {
        let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(properties)<w:r><w:t xml:space=\"preserve\">\(Self.escape(text))</w:t></w:r></w:p>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .filter { $0 == "\t" || $0 == "\n" || $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }
    }
}
