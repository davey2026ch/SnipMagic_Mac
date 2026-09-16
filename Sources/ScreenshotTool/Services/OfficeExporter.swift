import AppKit
import Foundation

// MARK: - Markdown 解析（用于导出 xlsx / docx）

/// MinerU Markdown 解析后的内容块。
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// 行×列的表格单元格；单元格内可用 \n 表示换行。
    case table([[String]])
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

    /// 管道表格单元格清理：<br> 换行、去行内 HTML 标签、解码实体。
    private static func pipeCellText(_ raw: String) -> String {
        var text = raw
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

    /// HTML 单元格 → 纯文本：<br> 转换行，去标签，解码实体。
    private static func htmlCellText(_ raw: String) -> String {
        var text = raw
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

    /// 去掉行内 Markdown 标记；图片转为「（图片）」占位；<br> 转换行。
    static func cleanInline(_ line: String) -> String {
        var text = line
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

/// 把 MinerU Markdown 导出为 xlsx / docx（纯代码生成 OOXML，无第三方依赖）。
/// 表格单元格内的换行：xlsx 用 wrapText 样式，docx 用 <w:br/>。
enum OfficeExporter {

    // MARK: - 对外接口

    static func exportXlsx(markdown: String, to url: URL) throws {
        let blocks = MarkdownParser.blocks(from: markdown)
        try writePackage(files: xlsxPackage(blocks: blocks), to: url)
    }

    static func exportDocx(markdown: String, to url: URL) throws {
        let blocks = MarkdownParser.blocks(from: markdown)
        try writePackage(files: docxPackage(blocks: blocks), to: url)
    }

    // MARK: - xlsx

    private static func xlsxPackage(blocks: [MarkdownBlock]) -> [String: String] {
        let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

        let contentTypes = """
        \(declaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """

        let rootRels = """
        \(declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        let workbook = """
        \(declaration)
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="提取内容" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """

        let workbookRels = """
        \(declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

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

        // 行数据
        var rowsXml: [String] = []
        var columnWidths: [Double] = []
        var rowIndex = 0

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

        let sheet = """
        \(declaration)
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \(colsXml)
        <sheetData>\(rowsXml.joined())</sheetData>
        </worksheet>
        """

        return [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rootRels,
            "xl/workbook.xml": workbook,
            "xl/_rels/workbook.xml.rels": workbookRels,
            "xl/styles.xml": styles,
            "xl/worksheets/sheet1.xml": sheet
        ]
    }

    // MARK: - docx

    private static func docxPackage(blocks: [MarkdownBlock]) -> [String: String] {
        let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

        let contentTypes = """
        \(declaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """

        let rootRels = """
        \(declaration)
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

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
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body.joined())<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body>
        </w:document>
        """

        return [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rootRels,
            "word/document.xml": document
        ]
    }

    // MARK: - 打包

    /// 把文件清单写入临时目录后用 /usr/bin/zip 打包为 OOXML 文件。
    private static func writePackage(files: [String: String], to output: URL) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (path, content) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard let data = content.data(using: .utf8) else {
                throw OfficeExportError.writeFailed(path)
            }
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
