import AppKit

/// 「最近使用颜色」的存取与清洗。
///
/// 三处入口（侧栏工具色 / 文字颜色 / 文字背景色）共用同一份历史，写在
/// `~/.SnipMagic.ini` 的 `RecentColors` 键里，逗号分隔的 `#RRGGBB`，最新在前。
///
/// **写文件时只动 `RecentColors` 这一行**：配置文件里还躺着用户填的 MinerU token
/// 与火山 API Key，任何"整份重写"都可能把它们弄丢，所以这里走逐行改写，
/// 其它行原样保留（连缩进、注释、空行都不碰）。
enum RecentColorStore {
    /// 颜色格前 3 格的固定色：红 / 黑 / 白。它们**永远固定**，也不记进历史
    /// ——再记一遍就是重复（固定格子已经常驻在最前面）。
    static let fixedHex: [String] = ["#FF0000", "#000000", "#FFFFFF"]

    /// 固定色对应的 NSColor（顺序与 `fixedHex` 一致）。
    static var fixedColors: [NSColor] {
        fixedHex.compactMap { NSColor.fromHexRGB($0) }
    }

    /// 历史色上限 = 24 格 - 3 个固定格。
    static let maxCount = 21

    // MARK: - 规则

    /// 规范成 `#RRGGBB`（大写）；非法返回 nil。
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s
    }

    /// 逗号分隔的原始值 → 数组（只做 trim，不判合法性）。
    static func parseList(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 清洗：规范大小写 → 丢掉非法项 → 踢掉红/黑/白 → 去重（保留首次出现）→ 截到 21 条。
    /// 「保留首次出现」就是"最新在前"：写进去的顺序本来就是最新在前。
    static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            guard let hex = normalize(item) else { continue }
            guard !fixedHex.contains(hex) else { continue }
            guard seen.insert(hex).inserted else { continue }
            out.append(hex)
            if out.count >= maxCount { break }
        }
        return out
    }

    // MARK: - 读

    /// 读配置 + 清洗；**发现被清理过（老配置里有固定色/重复/超量）就立刻写回**。
    /// 返回值即"当前有效的历史"。
    static func load() -> [String] {
        let (rawValue, cleaned) = readAndClean()
        if cleaned.joined(separator: ",") != rawValue {
            write(cleaned)
        }
        return cleaned
    }

    /// 只读不写：给设置保存（`saveConfig` 走整份模板重写）用，免得顺手触发一次写盘。
    static func currentSilently() -> [String] {
        readAndClean().1
    }

    private static func readAndClean() -> (rawValue: String, cleaned: [String]) {
        guard let text = try? String(contentsOfFile: MinerUOCRService.configPath(), encoding: .utf8) else {
            return ("", [])
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "recentcolors" || key == "recent_colors" else { continue }
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return (value, sanitize(parseList(value)))
        }
        return ("", [])
    }

    // MARK: - 写

    /// 把新用过的颜色记进历史：去重、最新排最前、超过 21 条挤掉最旧的。
    /// 固定色（红/黑/白）不记 —— 它们常驻前 3 格。
    @discardableResult
    static func record(_ color: NSColor) -> [String] {
        let hex = color.hexRGB
        var list = load()
        guard !fixedHex.contains(hex) else { return list }
        list.removeAll { $0 == hex }
        list.insert(hex, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        write(list)
        return list
    }

    /// 只改 `RecentColors` 一行；没有这一行就追加到文件末尾（带一行说明注释）。
    /// 多余的重复同名行会被丢掉，避免配置里出现重复段落。
    static func write(_ list: [String]) {
        let path = MinerUOCRService.configPath()
        let value = sanitize(list).joined(separator: ",")

        var lines: [String] = []
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            lines = text.components(separatedBy: "\n")
        }

        var out: [String] = []
        var replaced = false
        for line in lines {
            let key = Self.key(of: line)
            if key == "recentcolors" || key == "recent_colors" {
                if replaced { continue }         // 重复段直接丢掉
                out.append("RecentColors=\(value)")
                replaced = true
                continue
            }
            out.append(line)
        }

        if !replaced {
            // 追加：去掉文件末尾多余空行，再补注释 + 键 + 一个换行。
            while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                out.removeLast()
            }
            out.append("")
            out.append("# 最近使用颜色（逗号分隔 #RRGGBB，最新在前，最多 \(maxCount) 条；红/黑/白是固定格，不记在这里）")
            out.append("RecentColors=\(value)")
            out.append("")
        }

        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 取出 `key=` 前面的键名（小写）；不是键值行返回 nil。
    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 写进配置模板的整行文本（首启生成 / 设置保存时用）。
    static func templateLine(_ list: [String]) -> String {
        "RecentColors=\(sanitize(list).joined(separator: ","))"
    }
}
