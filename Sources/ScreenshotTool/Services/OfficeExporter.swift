import AppKit
import Foundation

// MARK: - Markdown 解析（用于导出 xlsx / docx）

/// MinerU Markdown 解析后的内容块。
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// 行×列的表格单元格；单元格内可用 \n 表示换行。
    case table([[String]])
    /// 独立成行的图片（如 ![](images/xxx.jpg)）；导出 Word/Excel 时内嵌原图。
    case image(path: String, alt: String)
}

enum MarkdownParser {

    static func blocks(from markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        func isSpecial(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("|") || t.hasPrefix("#") { return true }
            if let lower = t.lowercased() as String?, lower.hasPrefix("<table") { return true }
            return false
        }

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // HTML 表格（MinerU pipeline 模式输出）
            if trimmed.lowercased().hasPrefix("<table") {
                var buf: [String] = []
                var j = i
                while j < lines.count {
                    buf.append(lines[j])
                    if lines[j].lowercased().contains("</table>") { break }
                    j += 1
                }
                if let rows = htmlTableRows(from: buf.joined(separator: "\n")) {
                    result.append(.table(rows))
                }
                i = j + 1
                continue
            }

            // Markdown 管道表格
            if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("|") else { break }
                    if !isSeparatorRow(line) {
                        rows.append(pipeRowCells(line))
                    }
                    i += 1
                }
                if !rows.isEmpty {
                    result.append(.table(rows))
                }
                continue
            }

            // 标题
            if let level = headingLevel(trimmed) {
                let text = cleanInline(String(trimmed.drop(while: { $0 == "#" })))
                result.append(.heading(level: level, text: text.trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }

            // 独立成行的图片：解析为图片块（导出 Word/Excel 时内嵌）
            if let img = standaloneImage(trimmed) {
                result.append(.image(path: img.path, alt: img.alt))
                i += 1
                continue
            }

            // 普通段落：连续非特殊行合并
            var buf: [String] = [cleanInline(trimmed)]
            i += 1
            while i < lines.count, !isSpecial(lines[i]) {
                buf.append(cleanInline(lines[i].trimmingCharacters(in: .whitespaces)))
                i += 1
            }
            let text = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(.paragraph(text))
            }
        }
        return result
    }

    // MARK: 管道表格

    static func pipeRowCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        // 转义竖线 \| 保护起来再切分
        s = s.replacingOccurrences(of: "\\|", with: "\u{1}")
        return s.components(separatedBy: "|").map {
            let raw = $0.replacingOccurrences(of: "\u{1}", with: "|")
            return pipeCellText(raw)
        }
    }

    /// 管道表格单元格清理：HTML 注释、<br> 换行、去行内 HTML 标签、解码实体。
    private static func pipeCellText(_ raw: String) -> String {
        var text = raw
        text = replace(pattern: #"<!--[\s\S]*?-->"#, in: text, with: "")
        text = replace(pattern: #"<br\s*/?>"#, in: text, with: "\n")
        text = replace(pattern: #"</?(?:b|strong|i|em|sub|sup|u|span|font|code|small|mark)[^>]*>"#, in: text, with: "")
        text = decodeHTMLEntities(text)
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func isSeparatorRow(_ line: String) -> Bool {
        let cells = pipeRowCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && Set(cell).isSubset(of: ["-", ":", " "])
        }
    }

    // MARK: HTML 表格

    static func htmlTableRows(from html: String) -> [[String]]? {
        guard let rowRegex = try? NSRegularExpression(pattern: #"<tr[^>]*>[\s\S]*?</tr>"#, options: [.caseInsensitive]),
              let cellRegex = try? NSRegularExpression(pattern: #"<t[dh][^>]*>[\s\S]*?</t[dh]>"#, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = html as NSString
        var rows: [[String]] = []
        for rowMatch in rowRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
            let rowHTML = ns.substring(with: rowMatch.range)
            let rowNS = rowHTML as NSString
            var cells: [String] = []
            for cellMatch in cellRegex.matches(in: rowHTML, options: [], range: NSRange(location: 0, length: rowNS.length)) {
                cells.append(htmlCellText(rowNS.substring(with: cellMatch.range)))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows.isEmpty ? nil : rows
    }

    /// HTML 单元格 → 纯文本：去 HTML 注释、<br> 转换行，去标签，解码实体。
    private static func htmlCellText(_ raw: String) -> String {
        var text = raw
        text = replace(pattern: #"<!--[\s\S]*?-->"#, in: text, with: "")
        text = replace(pattern: #"<br\s*/?>"#, in: text, with: "\n")
        text = replace(pattern: #"</(p|div|li)>"#, in: text, with: "\n")
        text = replace(pattern: #"<[^>]+>"#, in: text, with: "")
        text = decodeHTMLEntities(text)
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 独立图片行

    /// 整行就是一张图片（![alt](path)）时解析出 path / alt。
    private static func standaloneImage(_ line: String) -> (path: String, alt: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("!["),
              let regex = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(\s*([^)\s]+)\s*\)$"#) else {
            return nil
        }
        let ns = t as NSString
        guard let m = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 2 else { return nil }
        return (ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 1)))
    }

    // MARK: 行内清理

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level,
              line[line.index(line.startIndex, offsetBy: level)].isWhitespace else { return nil }
        return level
    }

    /// 去掉行内 Markdown 标记；图片转为「（图片）」占位；<br> 转换行；去 HTML 注释（如轻量结果的 <!-- image--> 占位）。
    static func cleanInline(_ line: String) -> String {
        var text = line
        text = replace(pattern: #"<!--[\s\S]*?-->"#, in: text, with: "")
        text = replace(pattern: #"<br\s*/?>"#, in: text, with: "\n")
        text = replace(pattern: #"!\[([^\]]*)\]\([^)]*\)"#, in: text, with: { m in
            let alt = m.count > 1 ? m[1] : ""
            return alt.isEmpty ? "（图片）" : alt
        })
        text = replace(pattern: #"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
        text = replace(pattern: #"(\*\*|__)(.+?)\1"#, in: text, with: "$2")
        text = replace(pattern: #"(\*|_)([^*_\n]+?)\1"#, in: text, with: "$2")
        text = replace(pattern: #"`{1,3}([^`\n]+)`{1,3}"#, in: text, with: "$1")
        text = replace(pattern: #"^\s{0,3}>\s?"#, in: text, with: "", options: [.anchorsMatchLines])
        text = replace(pattern: #"^\s{0,3}[-*_]\s*\1{2,}\s*$"#, in: text, with: "")
        return text
    }

    // MARK: 小工具

    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let map = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"
        ]
        for (entity, char) in map {
            result = result.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let ns = result as NSString
            for match in regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length)).reversed() {
                if let code = UInt32(ns.substring(with: match.range(at: 1))),
                   let scalar = UnicodeScalar(code) {
                    result = ns.replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return result
    }

    static func replace(
        pattern: String, in text: String, with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text, options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    private static func replace(
        pattern: String, in text: String,
        with builder: ([String]) -> String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var groups = [ns.substring(with: match.range)]
            if match.numberOfRanges > 1 {
                for g in 1..<match.numberOfRanges where match.range(at: g).location != NSNotFound {
                    groups.append(ns.substring(with: match.range(at: g)))
                }
            }
            out += builder(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

// MARK: - Office 导出

enum OfficeExportError: LocalizedError {
    case zipToolFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .zipToolFailed(let msg):
            return "打包文件失败：\(msg)"
        case .writeFailed(let msg):
            return "写入文件失败：\(msg)"
        }
    }
}

/// 待内嵌到 Office 文档中的图片（按 markdown 中出现顺序编号）。
private struct EmbeddedImage {
    let refPath: String    // markdown 中的图片路径（如 images/xxx.jpg）
    let index: Int         // 1 起编号，对应关系 Id rIdImgN 与 media 文件名 imageN.ext
    let mediaName: String  // 如 image1.png
    let ext: String        // 规范化扩展名：png / jpeg / gif
    let data: Data
}

/// 把 MinerU Markdown 导出为 xlsx / docx（纯代码生成 OOXML，无第三方依赖）。
/// 表格单元格内的换行：xlsx 用 wrapText 样式，docx 用 <w:br/>。
/// 图片：markdown 中独立成行的图片块（![](images/xxx.jpg)）会内嵌为原图——
/// docx 用 word/media + wp:inline 行内图片，xlsx 用 xl/media + drawing 锚定到所在行。
enum OfficeExporter {

    // MARK: - 对外接口

    static func exportXlsx(markdown: String, images: [ExtractedImage] = [], to url: URL) throws {
        let blocks = MarkdownParser.blocks(from: markdown)
        try writePackage(files: xlsxPackage(blocks: blocks, images: images), to: url)
    }

    static func exportDocx(markdown: String, images: [ExtractedImage] = [], to url: URL) throws {
        let blocks = MarkdownParser.blocks(from: markdown)
        try writePackage(files: docxPackage(blocks: blocks, images: images), to: url)
    }

    // MARK: - 图片收集与尺寸

    /// 按图片块出现顺序收集可内嵌图片并编号；可按完整路径或文件名兜底匹配。
    private static func collectMedia(
        blocks: [MarkdownBlock], images: [ExtractedImage]
    ) -> (list: [EmbeddedImage], byPath: [String: EmbeddedImage]) {
        var byPath: [String: Data] = [:]
        var byBase: [String: Data] = [:]
        for img in images {
            byPath[img.path] = img.data
            byBase[(img.path as NSString).lastPathComponent] = img.data
        }
        var list: [EmbeddedImage] = []
        var seen: Set<String> = []
        for block in blocks {
            if case .image(let path, _) = block, !seen.contains(path) {
                seen.insert(path)
                guard let data = byPath[path] ?? byBase[(path as NSString).lastPathComponent],
                      NSBitmapImageRep(data: data) != nil else { continue }
                let index = list.count + 1
                let ext = mediaExtension(of: path, data: data)
                let item = EmbeddedImage(
                    refPath: path, index: index,
                    mediaName: "image\(index).\(ext)", ext: ext, data: data
                )
                list.append(item)
            }
        }
        return (list, Dictionary(list.map { ($0.refPath, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// 媒体文件扩展名：优先按文件头嗅探，其次按路径后缀，兜底 png。
    private static func mediaExtension(of path: String, data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "jpeg"
        case "gif": return "gif"
        default: return "png"
        }
    }

    private static func mime(of ext: String) -> String {
        switch ext {
        case "jpeg", "jpg": return "image/jpeg"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    /// 像素尺寸 → EMU（96dpi，1px = 9525 EMU），超宽时等比缩小到 maxEMU 以内。
    private static func imageSizeEMU(_ data: Data, maxEMU: Int) -> (cx: Int, cy: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let w = max(rep.pixelsWide, 1), h = max(rep.pixelsHigh, 1)
        let rawW = Double(w) * 9525.0
        let scale = min(1.0, Double(maxEMU) / rawW)
        return (Int(rawW * scale), Int(Double(h) * 9525.0 * scale))
    }

    /// [Content_Types].xml 中图片用到的 Default 声明（按实际用到的扩展名生成）。
    private static func imageContentTypes(_ media: [EmbeddedImage]) -> String {
        var exts: [String] = []
        for m in media where !exts.contains(m.ext) { exts.append(m.ext) }
        return exts.map { "<Default Extension=\"\($0)\" ContentType=\"\(mime(of: $0))\"/>" }.joined()
    }

    // MARK: - xlsx

    private static func xlsxPackage(blocks: [MarkdownBlock], images: [ExtractedImage]) -> [String: Data] {
        let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let media = collectMedia(blocks: blocks, images: images)
        var files: [String: Data] = [:]

        var contentTypes = """
        \(declaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(imageContentTypes(media.list))
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        """
        if !media.list.isEmpty {
            contentTypes += """
            <Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>
            """
        }
        contentTypes += "</Types>"
        files["[Content_Types].xml"] = xmlData(contentTypes)

        let rootRels = """
        \(declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        files["_rels/.rels"] = xmlData(rootRels)

        let workbook = """
        \(declaration)
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="提取内容" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        files["xl/workbook.xml"] = xmlData(workbook)

        let workbookRels = """
        \(declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        files["xl/_rels/workbook.xml.rels"] = xmlData(workbookRels)

        // s=1 自动换行；s=2 自动换行 + 加粗（表头/标题）
        let styles = """
        \(declaration)
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="3">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """
        files["xl/styles.xml"] = xmlData(styles)

        // 行数据
        var rowsXml: [String] = []
        var columnWidths: [Double] = []
        var rowIndex = 0
        var drawingEntries: [(row: Int, image: EmbeddedImage)] = []

        func noteWidth(_ col: Int, _ text: String) {
            while columnWidths.count <= col { columnWidths.append(8) }
            let w = displayWidth(of: text)
            columnWidths[col] = max(columnWidths[col], w)
        }

        func cell(col: Int, text: String, bold: Bool) -> String {
            noteWidth(col, text)
            return "<c r=\"\(columnRef(col))\(rowIndex)\" s=\"\(bold ? 2 : 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
        }

        for block in blocks {
            switch block {
            case .heading(_, let text):
                rowIndex += 1
                rowsXml.append("<row r=\"\(rowIndex)\">\(cell(col: 0, text: text, bold: true))</row>")
            case .paragraph(let text):
                rowIndex += 1
                rowsXml.append("<row r=\"\(rowIndex)\">\(cell(col: 0, text: text, bold: false))</row>")
            case .table(let rows):
                for (r, row) in rows.enumerated() {
                    rowIndex += 1
                    let cells = row.enumerated().map { c, text in
                        cell(col: c, text: text, bold: r == 0)
                    }.joined()
                    rowsXml.append("<row r=\"\(rowIndex)\">\(cells)</row>")
                }
            case .image(let path, let alt):
                if let img = media.byPath[path] {
                    // 图片锚定到当前空行，浮动显示
                    drawingEntries.append((row: rowIndex, image: img))
                } else {
                    // 无法内嵌（格式不支持/缺数据）退化为占位文本
                    rowIndex += 1
                    rowsXml.append("<row r=\"\(rowIndex)\">\(cell(col: 0, text: alt.isEmpty ? "（图片）" : alt, bold: false))</row>")
                }
            }
            // 块之间留一个空行
            rowIndex += 1
        }

        let colsXml: String
        if !columnWidths.isEmpty {
            let colDefs = columnWidths.enumerated().map { i, w -> String in
                let width = String(format: "%.1f", min(max(w + 2, 8), 60))
                return "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
            }.joined()
            colsXml = "<cols>\(colDefs)</cols>"
        } else {
            colsXml = ""
        }

        let hasImages = !media.list.isEmpty
        let sheet = """
        \(declaration)
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \(colsXml)
        <sheetData>\(rowsXml.joined())</sheetData>
        \(hasImages ? #"<drawing r:id="rIdW1"/>"# : "")
        </worksheet>
        """
        files["xl/worksheets/sheet1.xml"] = xmlData(sheet)

        if hasImages {
            // 图片最大宽度：约 500px（96dpi）
            let maxEMU = 4_762_500
            let anchors = drawingEntries.map { entry -> String in
                let img = entry.image
                let size = imageSizeEMU(img.data, maxEMU: maxEMU) ?? (cx: 9525 * 200, cy: 9525 * 150)
                return """
                <xdr:oneCellAnchor>
                <xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(entry.row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
                <xdr:ext cx="\(size.cx)" cy="\(size.cy)"/>
                <xdr:pic>
                <xdr:nvPicPr><xdr:cNvPr id="\(img.index)" name="\(img.mediaName)"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr></xdr:nvPicPr>
                <xdr:blipFill><a:blip r:embed="rIdImg\(img.index)"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>
                <xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(size.cx)" cy="\(size.cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr>
                </xdr:pic>
                <xdr:clientData/>
                </xdr:oneCellAnchor>
                """
            }.joined()

            let drawing = """
            \(declaration)
            <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            \(anchors)
            </xdr:wsDr>
            """
            files["xl/drawings/drawing1.xml"] = xmlData(drawing)

            let sheetRels = """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdW1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>
            </Relationships>
            """
            files["xl/worksheets/_rels/sheet1.xml.rels"] = xmlData(sheetRels)

            let drawingRels = media.list.map { img -> String in
                "<Relationship Id=\"rIdImg\(img.index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/\(img.mediaName)\"/>"
            }.joined()
            files["xl/drawings/_rels/drawing1.xml.rels"] = xmlData("""
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(drawingRels)</Relationships>
            """)

            for img in media.list {
                files["xl/media/\(img.mediaName)"] = img.data
            }
        }

        return files
    }

    // MARK: - docx

    private static func docxPackage(blocks: [MarkdownBlock], images: [ExtractedImage]) -> [String: Data] {
        let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let media = collectMedia(blocks: blocks, images: images)
        var files: [String: Data] = [:]

        let contentTypes = """
        \(declaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(imageContentTypes(media.list))
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        files["[Content_Types].xml"] = xmlData(contentTypes)

        let rootRels = """
        \(declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        files["_rels/.rels"] = xmlData(rootRels)

        if !media.list.isEmpty {
            let mediaRels = media.list.map { img -> String in
                "<Relationship Id=\"rIdImg\(img.index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(img.mediaName)\"/>"
            }.joined()
            files["word/_rels/document.xml.rels"] = xmlData("""
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(mediaRels)</Relationships>
            """)
        }

        // 内容
        var body: [String] = []
        let headingSizes = [32, 28, 26, 24, 22, 22] // 半磅（half-points）

        func runs(for text: String, bold: Bool, size: Int? = nil) -> String {
            let rpr: String
            if bold || size != nil {
                var props = ""
                if bold { props += "<w:b/>" }
                if let size { props += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>" }
                rpr = "<w:rPr>\(props)</w:rPr>"
            } else {
                rpr = ""
            }
            return text.components(separatedBy: "\n").enumerated().map { i, line in
                let br = i == 0 ? "" : "<w:br/>"
                return "<w:r>\(rpr)\(br)<w:t xml:space=\"preserve\">\(escape(line))</w:t></w:r>"
            }.joined()
        }

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let size = headingSizes[max(0, min(level - 1, 5))]
                let lvl = max(0, min(level - 1, 8))
                body.append("""
                <w:p><w:pPr><w:outlineLvl w:val="\(lvl)"/><w:spacing w:before="240" w:after="120"/></w:pPr>\(runs(for: text, bold: true, size: size))</w:p>
                """)
            case .paragraph(let text):
                body.append("<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>\(runs(for: text, bold: false))</w:p>")
            case .image(let path, let alt):
                if let img = media.byPath[path],
                   let size = imageSizeEMU(img.data, maxEMU: 5_760_000) {
                    // 行内图片，最大宽约 620px（A4 可用宽度）
                    body.append(docxImageParagraph(img, size: size))
                } else {
                    body.append("<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>\(runs(for: alt.isEmpty ? "（图片）" : alt, bold: false))</w:p>")
                }
            case .table(let rows):
                let columnCount = rows.map(\.count).max() ?? 1
                let usableWidth = 9638 // A4 可用宽度（twips）
                let colWidth = usableWidth / columnCount
                let grid = (0..<columnCount).map { _ in "<w:gridCol w:w=\"\(colWidth)\"/>" }.joined()

                let border = "single"
                let borders = """
                <w:tblBorders>
                <w:top w:val="\(border)" w:sz="4" w:space="0" w:color="999999"/>
                <w:left w:val="\(border)" w:sz="4" w:space="0" w:color="999999"/>
                <w:bottom w:val="\(border)" w:sz="4" w:space="0" w:color="999999"/>
                <w:right w:val="\(border)" w:sz="4" w:space="0" w:color="999999"/>
                <w:insideH w:val="\(border)" w:sz="4" w:space="0" w:color="999999"/>
                <w:insideV w:val="\(border)" w:sz="4" w:space="0" w:color="999999"/>
                </w:tblBorders>
                """

                var trs: [String] = []
                for (r, row) in rows.enumerated() {
                    var tcs: [String] = []
                    for c in 0..<columnCount {
                        let text = c < row.count ? row[c] : ""
                        tcs.append("""
                        <w:tc><w:tcPr><w:tcW w:w="\(colWidth)" w:type="dxa"/></w:tcPr><w:p>\(runs(for: text, bold: r == 0))</w:p></w:tc>
                        """)
                    }
                    trs.append("<w:tr>\(tcs.joined())</w:tr>")
                }

                body.append("""
                <w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/>\(borders)</w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(trs.joined())</w:tbl><w:p/>
                """)
            }
        }

        let document = """
        \(declaration)
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>\(body.joined())<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body>
        </w:document>
        """
        files["word/document.xml"] = xmlData(document)

        for img in media.list {
            files["word/media/\(img.mediaName)"] = img.data
        }

        return files
    }

    /// docx 行内图片段落（wp:inline）。
    private static func docxImageParagraph(_ img: EmbeddedImage, size: (cx: Int, cy: Int)) -> String {
        return """
        <w:p><w:pPr><w:spacing w:after="120"/></w:pPr><w:r><w:drawing>
        <wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
        <wp:extent cx="\(size.cx)" cy="\(size.cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>
        <wp:docPr id="\(img.index)" name="Picture \(img.index)"/>
        <wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>
        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <pic:nvPicPr><pic:cNvPr id="0" name="\(img.mediaName)"/><pic:cNvPicPr/></pic:nvPicPr>
        <pic:blipFill><a:blip r:embed="rIdImg\(img.index)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(size.cx)" cy="\(size.cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    // MARK: - 打包

    /// 把文件清单写入临时目录后用 /usr/bin/zip 打包为 OOXML 文件。
    private static func writePackage(files: [String: Data], to output: URL) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        try? FileManager.default.removeItem(at: output)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = dir
        proc.arguments = ["-r", "-X", "-q", output.path, "."]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw OfficeExportError.zipToolFailed("zip 退出码 \(proc.terminationStatus)")
        }
    }

    private static func xmlData(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - 小工具

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// 0 基列号 → Excel 列名（A、B、…、AA…）
    private static func columnRef(_ index: Int) -> String {
        var n = index
        var out = ""
        repeat {
            let scalar = UnicodeScalar(65 + n % 26)! // A...Z，安全
            out = String(Character(scalar)) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    /// 估算显示宽度：CJK 记 2，其余记 1；多行取最长行。
    private static func displayWidth(of text: String) -> Double {
        var width: Double = 0
        for line in text.components(separatedBy: "\n") {
            var w: Double = 0
            for scalar in line.unicodeScalars {
                w += (scalar.value > 0x2E80) ? 2 : 1
            }
            width = max(width, w)
        }
        return width
    }
}
