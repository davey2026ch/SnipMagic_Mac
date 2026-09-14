import AppKit
import Foundation

enum OCRMode {
    case text
    case table

    var buttonTitle: String {
        switch self {
        case .text: return "T 提取文字"
        case .table: return "⊞ 提取表格"
        }
    }

    var resultTitle: String {
        switch self {
        case .text: return "提取文字"
        case .table: return "提取表格"
        }
    }
}

enum MinerUOCRError: LocalizedError {
    case encodeFailed
    case submitFailed(String)
    case uploadFailed(Int)
    case parseFailed(String)
    case timeout
    case emptyResult(OCRMode)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "图片编码失败"
        case .submitFailed(let msg):
            return "提交解析任务失败：\(msg)"
        case .uploadFailed(let code):
            return "图片上传失败（HTTP \(code)）"
        case .parseFailed(let msg):
            return "解析失败：\(msg)"
        case .timeout:
            return "解析超时，请稍后重试"
        case .emptyResult(let mode):
            return mode == .table ? "未识别到表格" : "未识别到文字"
        case .network(let msg):
            return "网络错误：\(msg)"
        }
    }
}

/// MinerU Agent 轻量解析：免 Token，IP 限频；截图场景单文件小图，走文件签名上传。
enum MinerUOCRService {
    private static let baseURL = URL(string: "https://mineru.net/api/v1/agent")!
    private static let pollInterval: TimeInterval = 2.0
    private static let pollTimeout: TimeInterval = 120.0

    static func encodePNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Submit → PUT upload → poll → download Markdown → post-process by mode.
    static func parse(
        imageData: Data,
        fileName: String = "screenshot.png",
        mode: OCRMode,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let session = URLSession.shared

        requestUploadURL(session: session, fileName: fileName) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let (taskId, uploadURL)):
                upload(session: session, data: imageData, to: uploadURL) { uploadResult in
                    switch uploadResult {
                    case .failure(let error):
                        DispatchQueue.main.async { completion(.failure(error)) }
                    case .success:
                        pollResult(session: session, taskId: taskId, deadline: Date().addingTimeInterval(pollTimeout)) { poll in
                            switch poll {
                            case .failure(let error):
                                DispatchQueue.main.async { completion(.failure(error)) }
                            case .success(let markdownURL):
                                downloadMarkdown(session: session, from: markdownURL) { mdResult in
                                    DispatchQueue.main.async {
                                        switch mdResult {
                                        case .failure(let error):
                                            completion(.failure(error))
                                        case .success(let markdown):
                                            let processed = postProcess(markdown: markdown, mode: mode)
                                            if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                completion(.failure(MinerUOCRError.emptyResult(mode)))
                                            } else {
                                                completion(.success(processed))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Network steps

    private static func requestUploadURL(
        session: URLSession,
        fileName: String,
        completion: @escaping (Result<(taskId: String, fileURL: URL), Error>) -> Void
    ) {
        var request = URLRequest(url: baseURL.appendingPathComponent("parse/file"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "file_name": fileName,
            "language": "ch",
            "enable_table": true,
            "is_ocr": true,
            "enable_formula": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(MinerUOCRError.submitFailed("响应格式错误")))
                return
            }
            let code = (json["code"] as? Int) ?? -1
            let msg = (json["msg"] as? String) ?? "未知错误"
            guard code == 0,
                  let payload = json["data"] as? [String: Any],
                  let taskId = payload["task_id"] as? String,
                  let fileURLString = payload["file_url"] as? String,
                  let fileURL = URL(string: fileURLString) else {
                completion(.failure(MinerUOCRError.submitFailed(msg)))
                return
            }
            completion(.success((taskId, fileURL)))
        }.resume()
    }

    private static func upload(
        session: URLSession,
        data: Data,
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        // Do not set Content-Type — OSS signed URL is computed without it.

        session.uploadTask(with: request, from: data) { _, response, error in
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                completion(.failure(MinerUOCRError.uploadFailed(status)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    private static func pollResult(
        session: URLSession,
        taskId: String,
        deadline: Date,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if Date() > deadline {
            completion(.failure(MinerUOCRError.timeout))
            return
        }

        let url = baseURL.appendingPathComponent("parse/\(taskId)")
        session.dataTask(with: url) { data, _, error in
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["data"] as? [String: Any],
                  let state = payload["state"] as? String else {
                completion(.failure(MinerUOCRError.parseFailed("查询响应格式错误")))
                return
            }

            switch state {
            case "done":
                if let md = payload["markdown_url"] as? String, let mdURL = URL(string: md) {
                    completion(.success(mdURL))
                } else {
                    completion(.failure(MinerUOCRError.parseFailed("缺少 Markdown 结果链接")))
                }
            case "failed":
                let errMsg = (payload["err_msg"] as? String) ?? "未知错误"
                completion(.failure(MinerUOCRError.parseFailed(errMsg)))
            default:
                DispatchQueue.global().asyncAfter(deadline: .now() + pollInterval) {
                    pollResult(session: session, taskId: taskId, deadline: deadline, completion: completion)
                }
            }
        }.resume()
    }

    private static func downloadMarkdown(
        session: URLSession,
        from url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        session.dataTask(with: url) { data, _, error in
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                completion(.failure(MinerUOCRError.parseFailed("Markdown 下载失败")))
                return
            }
            completion(.success(text))
        }.resume()
    }

    // MARK: - Post-process

    /// text: plain readable text (no HTML/Markdown markers). table: HTML <table> and/or Markdown pipe tables.
    static func postProcess(markdown: String, mode: OCRMode) -> String {
        switch mode {
        case .text:
            return plainText(from: markdown)
        case .table:
            return extractTables(from: markdown)
        }
    }

    /// Keep HTML tables and Markdown tables; drop everything else.
    static func extractTables(from markdown: String) -> String {
        var blocks: [String] = []
        blocks.append(contentsOf: htmlTables(from: markdown))
        blocks.append(contentsOf: markdownPipeTables(from: markdown))
        if blocks.isEmpty { return "" }
        return blocks.enumerated().map { index, table in
            index == 0 ? table : "\n\n\(table)"
        }.joined()
    }

    /// Convert MinerU Markdown/HTML into plain text: tables → TSV rows, strip tags and MD markers.
    static func plainText(from markdown: String) -> String {
        var text = markdown

        // HTML tables → tab-separated rows
        for table in htmlTables(from: text) {
            let tsv = htmlTableToTSV(table)
            text = text.replacingOccurrences(of: table, with: "\n\(tsv)\n")
        }

        // Markdown pipe tables → tab-separated rows (skip |---| separator lines)
        for table in markdownPipeTables(from: text) {
            let rows = table.components(separatedBy: .newlines).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return nil }
                let cells = trimmed
                    .dropFirst()
                    .dropLast(trimmed.hasSuffix("|") ? 1 : 0)
                    .components(separatedBy: "|")
                    .map { cell -> String in
                        cell.trimmingCharacters(in: .whitespaces)
                    }
                if cells.allSatisfy({ $0.isEmpty || Set($0).isSubset(of: ["-", ":"]) }) {
                    return nil
                }
                return cells.joined(separator: "\t")
            }
            let tsv = rows.joined(separator: "\n")
            text = text.replacingOccurrences(of: table, with: "\n\(tsv)\n")
        }

        // Line breaks / block ends
        text = replacing(pattern: #"<br\s*/?>"#, in: text, with: "\n")
        text = replacing(pattern: #"</(p|div|h[1-6]|li|tr|table|section|article)>"#, in: text, with: "\n")
        text = replacing(pattern: #"<(p|div|h[1-6]|li|tr|table|section|article)[^>]*>"#, in: text, with: "")
        // Cell separators if any raw tags remain
        text = replacing(pattern: #"</(td|th)>"#, in: text, with: "\t")
        // Drop remaining tags
        text = replacing(pattern: #"<[^>]+>"#, in: text, with: "")

        // HTML entities
        text = decodeHTMLEntities(text)

        // Markdown markers
        text = replacing(pattern: #"^\s{0,3}#{1,6}\s+"#, in: text, with: "", options: [.anchorsMatchLines])
        text = replacing(pattern: #"^\s{0,3}>\s?"#, in: text, with: "", options: [.anchorsMatchLines])
        text = replacing(pattern: #"^\s{0,3}([-*_])\1{2,}\s*$"#, in: text, with: "", options: [.anchorsMatchLines])
        text = replacing(pattern: #"!\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(pattern: #"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(pattern: #"(\*\*|__)(.+?)\1"#, in: text, with: "$2")
        text = replacing(pattern: #"(\*|_)([^*_\n]+?)\1"#, in: text, with: "$2")
        text = replacing(pattern: #"`{1,3}([^`\n]+)`{1,3}"#, in: text, with: "$1")
        text = replacing(pattern: #"^\s{0,3}[-*+]\s+"#, in: text, with: "• ", options: [.anchorsMatchLines])
        text = replacing(pattern: #"^\s{0,3}\d+\.\s+"#, in: text, with: "", options: [.anchorsMatchLines])

        // Normalize whitespace: trim lines, collapse 3+ blank lines
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML / Markdown helpers

    private static func htmlTables(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<table[\s\S]*?</table>"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, options: [], range: range).map {
            ns.substring(with: $0.range)
        }
    }

    private static func markdownPipeTables(from text: String) -> [String] {
        var tables: [String] = []
        var current: [String] = []

        func flush() {
            let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty, block.contains("|") {
                tables.append(block)
            }
            current.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                current.append(line)
            } else {
                flush()
            }
        }
        flush()
        return tables
    }

    /// <table>...</table> → one TSV line per row (cells joined by tab).
    static func htmlTableToTSV(_ html: String) -> String {
        guard let rowRegex = try? NSRegularExpression(
            pattern: #"<tr[\s\S]*?</tr>"#,
            options: [.caseInsensitive]
        ),
        let cellRegex = try? NSRegularExpression(
            pattern: #"<t[dh][\s\S]*?</t[dh]>"#,
            options: [.caseInsensitive]
        ),
        let tagRegex = try? NSRegularExpression(
            pattern: #"<[^>]+>"#,
            options: []
        ) else { return stripTags(html) }

        let ns = html as NSString
        let rowRange = NSRange(location: 0, length: ns.length)
        var rows: [String] = []

        for rowMatch in rowRegex.matches(in: html, options: [], range: rowRange) {
            let rowHTML = ns.substring(with: rowMatch.range)
            let rowNS = rowHTML as NSString
            let cellRange = NSRange(location: 0, length: rowNS.length)
            var cells: [String] = []
            for cellMatch in cellRegex.matches(in: rowHTML, options: [], range: cellRange) {
                var cell = rowNS.substring(with: cellMatch.range)
                cell = replacing(pattern: #"<br\s*/?>"#, in: cell, with: " ")
                cell = tagRegex.stringByReplacingMatches(
                    in: cell, options: [], range: NSRange(location: 0, length: (cell as NSString).length), withTemplate: ""
                )
                cell = decodeHTMLEntities(cell)
                cell = cell
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                cells.append(cell.trimmingCharacters(in: .whitespaces))
            }
            if !cells.isEmpty {
                rows.append(cells.joined(separator: "\t"))
            }
        }
        return rows.joined(separator: "\n")
    }

    private static func stripTags(_ text: String) -> String {
        replacing(pattern: #"<[^>]+>"#, in: text, with: "")
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let map = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&hellip;": "…",
            "&mdash;": "—",
            "&ndash;": "–"
        ]
        for (entity, char) in map {
            result = result.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        // &#123; numeric
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#, options: []) {
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            // replace from the end so ranges stay valid
            for match in matches.reversed() {
                let numStr = ns.substring(with: match.range(at: 1))
                if let code = UInt32(numStr), let scalar = UnicodeScalar(code) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return result
    }

    private static func replacing(
        pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }
}
