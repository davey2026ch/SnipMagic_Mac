import AppKit

/// 把 MinerU 返回的 Markdown 渲染成「查看模式」用的富文本。
///
/// 为什么不用系统的 `AttributedString(markdown:)`：
/// 1. 它只处理行内标记，标题 / 列表 / 表格 / 代码块都要自己排版；
/// 2. 它没法把 `images/xxx.jpg` 换成真实图片 —— 提取结果的图片在内存里（`ExtractedImage`），
///    根本没落过盘。
///
/// 所以这里手写一遍，规则少而明确：标题、段落、无序/有序列表、引用、代码块、
/// 分隔线、表格、图片。不追求完整 CommonMark，只求 MinerU 的输出能看得舒服。
enum MarkdownRenderer {

    /// 渲染结果。`attributed` 用来显示；`plain` 用来写剪贴板的纯文本槽
    /// —— 附件在 attributed 里是 U+FFFC 占位符，直接拿去当纯文本会粘出一串怪字符。
    struct Rendered {
        let attributed: NSAttributedString

        var plain: String { Self.plainText(of: attributed) }

        /// 富文本 → 可读纯文本。两处特意处理：
        /// - **图片附件**换成「［图片］」（附件在字符串里只是 U+FFFC 占位符）；
        /// - **表格**重新拼回一行：渲染时"一个单元格 = 一个段落"（见 `table(_:)`），
        ///   这里按 `NSTextTableBlock.startingRow` 把同一行的单元格用 `Tab` 接起来，
        ///   粘到 Excel 就能直接分列，而不是变成"一列一行"的天书。
        static func plainText(of attributed: NSAttributedString) -> String {
            let full = attributed.string as NSString
            guard full.length > 0 else { return "" }

            var output: [String] = []
            var rowKey: (table: ObjectIdentifier, row: Int)?
            var rowCells: [String] = []

            func flushRow() {
                guard !rowCells.isEmpty else { return }
                output.append(rowCells.joined(separator: "\t"))
                rowCells.removeAll()
            }

            var location = 0
            while location < full.length {
                let lineRange = full.lineRange(for: NSRange(location: location, length: 0))
                var text = full.substring(with: lineRange)
                if text.hasSuffix("\n") { text.removeLast() }

                var hasAttachment = false
                attributed.enumerateAttribute(.attachment, in: lineRange, options: []) { value, _, _ in
                    if value != nil { hasAttachment = true }
                }
                if hasAttachment { text = "［图片］" }

                let style = attributed.attribute(.paragraphStyle, at: lineRange.location,
                                                 effectiveRange: nil) as? NSParagraphStyle
                if let block = style?.textBlocks.first as? NSTextTableBlock {
                    let key = (table: ObjectIdentifier(block.table), row: block.startingRow)
                    if rowKey == nil || rowKey! != key {
                        flushRow()
                        rowKey = key
                    }
                    rowCells.append(text)
                } else {
                    flushRow()
                    rowKey = nil
                    output.append(text)
                }
                location = lineRange.location + lineRange.length
            }
            flushRow()
            return output.joined(separator: "\n")
        }
    }

    // MARK: - 排版参数

    private static let bodySize: CGFloat = 13
    private static let codeSize: CGFloat = 12
    /// 图片最大显示尺寸（点）—— 截图往往比窗口宽、竖图还特别高，
    /// 不夹一下会顶破版面（一张竖版人像能把整页占满）。等比缩放，不放大。
    private static let maxImageWidth: CGFloat = 430
    private static let maxImageHeight: CGFloat = 340
    /// 表格单元格内边距 / 边框宽度。
    private static let cellPadding: CGFloat = 5

    static func render(markdown: String, images: [ExtractedImage] = []) -> Rendered {
        let imageMap = imageLookup(images)
        let out = NSMutableAttributedString()

        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let text = paragraphBuffer.joined(separator: "\n")
            paragraphBuffer.removeAll()
            out.append(inline(text, font: bodyFont, color: .labelColor))
            out.append(NSAttributedString(string: "\n", attributes: paragraphStyle(lineSpacing: 4)))
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 代码块 ```lang … ```
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1  // 吃掉收尾的 ```
                out.append(codeBlock(code.joined(separator: "\n")))
                continue
            }

            // 表格：本行以 | 开头，且下一行是分隔行
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                var rows: [[String]] = []
                rows.append(tableCells(trimmed))
                i += 2  // 跳过分隔行
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    if isTableSeparator(line) { i += 1; continue }
                    rows.append(tableCells(line))
                    i += 1
                }
                out.append(table(rows))
                continue
            }

            // 标题
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(heading.markerLength))
                    .trimmingCharacters(in: .whitespaces)
                out.append(inline(text, font: headingFont(heading.level), color: .labelColor))
                out.append(NSAttributedString(
                    string: "\n",
                    attributes: paragraphStyle(spacingBefore: heading.level == 1 ? 14 : 10,
                                               spacingAfter: 4,
                                               lineSpacing: 3)
                ))
                i += 1
                continue
            }

            // 分隔线
            if isHorizontalRule(trimmed) {
                flushParagraph()
                var attrs = paragraphStyle(spacingBefore: 8, spacingAfter: 8)
                attrs[.font] = NSFont.systemFont(ofSize: bodySize)
                attrs[.foregroundColor] = NSColor.separatorColor
                out.append(NSAttributedString(string: String(repeating: "─", count: 60) + "\n", attributes: attrs))
                i += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                var attrs = paragraphStyle(indent: 18, spacingBefore: 4, spacingAfter: 6, lineSpacing: 3)
                attrs[.font] = NSFont.systemFont(ofSize: bodySize)
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                let bullet = NSMutableAttributedString(string: "▎", attributes: attrs)
                bullet.append(inline(quoted.joined(separator: "\n"),
                                     font: NSFont.systemFont(ofSize: bodySize),
                                     color: .secondaryLabelColor))
                bullet.append(NSAttributedString(string: "\n", attributes: attrs))
                out.append(bullet)
                continue
            }

            // 列表（- / * / + / 1. ) —— 传原始行，缩进层级要靠前导空格判断
            if let item = listItem(raw) {
                flushParagraph()
                var attrs = paragraphStyle(indent: 18 + CGFloat(item.indent) * 16,
                                           spacingBefore: 1, spacingAfter: 1, lineSpacing: 2)
                attrs[.font] = NSFont.systemFont(ofSize: bodySize)
                attrs[.foregroundColor] = NSColor.labelColor
                let marker = item.ordered ? "\(item.number). " : "• "
                let line = NSMutableAttributedString(string: marker, attributes: attrs)
                line.append(inline(item.text, font: NSFont.systemFont(ofSize: bodySize), color: .labelColor))
                line.append(NSAttributedString(string: "\n", attributes: attrs))
                out.append(line)
                i += 1
                continue
            }

            // 独占一行的图片：直接在查看模式里把图贴出来
            if let image = standaloneImage(trimmed), let attachment = imageAttachment(image, map: imageMap) {
                flushParagraph()
                out.append(attachment)
                out.append(NSAttributedString(string: "\n", attributes: paragraphStyle(spacingAfter: 6)))
                i += 1
                continue
            }

            paragraphBuffer.append(raw)
            i += 1
        }
        flushParagraph()
        return Rendered(attributed: out)
    }

    // MARK: - 字体与段落

    private static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }

    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return .boldSystemFont(ofSize: 20)
        case 2: return .boldSystemFont(ofSize: 17)
        case 3: return .boldSystemFont(ofSize: 15)
        case 4: return .boldSystemFont(ofSize: 14)
        default: return .boldSystemFont(ofSize: 13)
        }
    }

    private static func paragraphStyle(
        indent: CGFloat = 0,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 6,
        lineSpacing: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = lineSpacing
        return [.paragraphStyle: style]
    }

    private static func codeBlock(_ code: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 10
        style.headIndent = 10
        style.paragraphSpacing = 8
        style.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
            .paragraphStyle: style,
        ]
        return NSAttributedString(string: code + "\n", attributes: attributes)
    }

    // MARK: - 表格

    private static func tableCells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") || line.hasPrefix(":") || line.hasPrefix("-") else { return false }
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty && line.contains("-")
    }

    /// 用 `NSTextTable` 画真表格（带边框、有内边距）。
    ///
    /// 写法：**一个单元格 = 一个段落**，每段挂一个 `NSTextTableBlock`。
    /// 纯文本里"一列一行"的问题不在这里解决 —— 由 `plainText(of:)` 按
    /// `startingRow` 把同一行的单元格重新拼回 `Tab` 分隔（粘到 Excel 能直接分列）。
    ///
    /// 试过但**不行**的写法（别再试）：一行一个段落、单元格之间用 `\t` 分隔。
    /// 那样布局器会抛
    /// `NSTableTypesetter Exception *** table … has block … rather than … at index N`，
    /// 结果是整张表直接不排版（`usedRect` 高度 0，表格消失）。
    ///
    /// ⚠️ `NSTextTable` 只有 **TextKit 1** 支持，所以结果窗里那个 `NSTextView`
    /// 被刻意拉回 TextKit 1（见 `ExtractResultPanel`）—— 那一步别删，删了表格会整块消失。
    private static func table(_ rows: [[String]]) -> NSAttributedString {
        guard !rows.isEmpty else { return NSAttributedString() }
        let columns = rows.map(\.count).max() ?? 1
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table,
                                             startingRow: r, rowSpan: 1,
                                             startingColumn: c, columnSpan: 1)
                block.setBorderColor(.separatorColor)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(cellPadding, type: .absoluteValueType, for: .padding)
                if r == 0 {
                    block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05)
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let font = r == 0
                    ? NSFont.boldSystemFont(ofSize: bodySize)
                    : NSFont.systemFont(ofSize: bodySize)
                let cellText = inline(c < row.count ? row[c] : "", font: font, color: .labelColor)
                let paragraph = NSMutableAttributedString(attributedString: cellText)
                paragraph.append(NSAttributedString(string: "\n",
                                                    attributes: [.paragraphStyle: style, .font: font]))
                paragraph.addAttribute(.paragraphStyle, value: style,
                                       range: NSRange(location: 0, length: paragraph.length))
                out.append(paragraph)
            }
        }
        // 表格后补一个空行，免得紧贴下一段。
        out.append(NSAttributedString(string: "\n", attributes: paragraphStyle()))
        return out
    }

    // MARK: - 图片

    private static func imageLookup(_ images: [ExtractedImage]) -> [String: NSImage] {
        var map: [String: NSImage] = [:]
        for item in images {
            if let image = NSImage(data: item.data) {
                map[item.path] = image
                map[(item.path as NSString).lastPathComponent] = image
            }
        }
        return map
    }

    private static func imageAttachment(_ image: (alt: String, path: String),
                                        map: [String: NSImage]) -> NSAttributedString? {
        let key = image.path.removingPercentEncoding ?? image.path
        guard let nsImage = map[key] ?? map[(key as NSString).lastPathComponent] else { return nil }
        let natural = nsImage.size
        guard natural.width > 1, natural.height > 1 else { return nil }
        let scale = min(1, maxImageWidth / natural.width, maxImageHeight / natural.height)
        let attachment = NSTextAttachment()
        attachment.image = nsImage
        attachment.bounds = CGRect(x: 0, y: 0,
                                   width: natural.width * scale,
                                   height: natural.height * scale)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.paragraphSpacingBefore = 4
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes([.paragraphStyle: style],
                          range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - 行内标记

    private struct InlineRule {
        let regex: NSRegularExpression
        let build: (NSString, NSTextCheckingResult, NSFont, NSColor) -> NSAttributedString
    }

    private static let rules: [InlineRule] = {
        func make(_ pattern: String, _ build: @escaping (NSString, NSTextCheckingResult, NSFont, NSColor) -> NSAttributedString) -> InlineRule? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return InlineRule(regex: regex, build: build)
        }
        func group(_ ns: NSString, _ m: NSTextCheckingResult, _ index: Int) -> String {
            let r = m.range(at: index)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        return [
            // 行内图片要排在链接前面，否则 `![alt](x)` 会被链接规则先吃掉。
            make(#"!\[([^\]]*)\]\(\s*([^)\s]+)\s*\)"#) { ns, m, font, color in
                NSAttributedString(string: group(ns, m, 1).isEmpty ? "［图片］" : "［图片：\(group(ns, m, 1))］",
                                   attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            },
            make(#"\[([^\]]*)\]\(\s*([^)\s]+)\s*\)"#) { ns, m, font, color in
                let text = group(ns, m, 1).isEmpty ? group(ns, m, 2) : group(ns, m, 1)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
                if let url = URL(string: group(ns, m, 2)) { attrs[.link] = url }
                return NSAttributedString(string: text, attributes: attrs)
            },
            make(#"`([^`]+)`"#) { ns, m, font, color in
                NSAttributedString(string: group(ns, m, 1), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular),
                    .foregroundColor: color,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                ])
            },
            make(#"\*\*([^*]+)\*\*"#) { ns, m, font, color in
                NSAttributedString(string: group(ns, m, 1),
                                   attributes: [.font: NSFont.boldSystemFont(ofSize: font.pointSize),
                                                .foregroundColor: color])
            },
            make(#"~~([^~]+)~~"#) { ns, m, font, color in
                NSAttributedString(string: group(ns, m, 1), attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ])
            },
            make(#"\*([^*]+)\*"#) { ns, m, font, color in
                NSAttributedString(string: group(ns, m, 1),
                                   attributes: [.font: italic(font), .foregroundColor: color])
            },
        ].compactMap { $0 }
    }()

    private static func italic(_ font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        guard manager.traits(of: font).contains(.italicFontMask) == false else { return font }
        // 中文字体常常没有斜体，转换失败就退回原字体（不要造一个假斜体）。
        return manager.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let ns = text as NSString
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var location = 0
        while location < ns.length {
            let remaining = NSRange(location: location, length: ns.length - location)
            var matched = false
            for rule in rules {
                guard let match = rule.regex.firstMatch(in: text, options: [], range: remaining),
                      match.range.location == location else { continue }
                out.append(rule.build(ns, match, font, color))
                location = match.range.location + match.range.length
                matched = true
                break
            }
            if !matched {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: location, length: 1)),
                                              attributes: base))
                location += 1
            }
        }
        return out
    }

    // MARK: - 行结构识别

    private static func headingLevel(_ line: String) -> (level: Int, markerLength: Int)? {
        var count = 0
        for character in line {
            if character == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6, line.count > count else { return nil }
        let after = line[line.index(line.startIndex, offsetBy: count)]
        guard after == " " || after == "\t" || after == "#" else { return nil }
        return (count, count)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int, indent: Int, text: String)? {
        let indent = (line.prefix { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let rest = String(trimmed.dropFirst())
        if ["-", "*", "+"].contains(first), rest.hasPrefix(" ") || rest.hasPrefix("\t") {
            return (false, 0, indent, rest.trimmingCharacters(in: .whitespaces))
        }
        // 有序：1. / 1)
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, let number = Int(digits) {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let mark = afterDigits.first, mark == "." || mark == ")",
               afterDigits.dropFirst().hasPrefix(" ") {
                return (true, number, indent, String(afterDigits.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func standaloneImage(_ line: String) -> (alt: String, path: String)? {
        let pattern = #"^!\[([^\]]*)\]\(\s*([^)\s]+)\s*\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        let ns = line as NSString
        let alt = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
        return (alt, ns.substring(with: match.range(at: 2)))
    }
}
