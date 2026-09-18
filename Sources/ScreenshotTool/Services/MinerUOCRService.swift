import AppKit
import Foundation

/// Cancellation handle for a running extraction. Thread-safe.
final class MinerUExtractTask {
    private let lock = NSLock()
    private var cancelled = false
    private var terminateHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let handler = terminateHandler
        terminateHandler = nil
        lock.unlock()
        handler?()
    }

    func setTerminateHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        terminateHandler = handler
        lock.unlock()
    }
}

/// 提取结果中的图片：精准解析来自结果 zip 的 images/ 目录，
/// 轻量解析来自 markdown 图片引用的下载；path 为相对 markdown 的路径（如 images/xxx.jpg）。
struct ExtractedImage {
    let path: String
    let data: Data
}

/// Which MinerU channel produced a successful extraction.
enum ExtractMode {
    case agent    // 轻量解析（免 token）
    case precise  // 精准解析（vlm，需 token）

    var displayName: String {
        switch self {
        case .agent: return "MinerU 轻量模式"
        case .precise: return "MinerU 精准模式（vlm）"
        }
    }
}

enum MinerUOCRError: LocalizedError {
    case encodeFailed
    case submitFailed(String)
    case uploadFailed(Int)
    case parseFailed(String)
    case timeout
    case emptyResult
    case network(String)
    case cancelled
    case tokenMissing
    case tokenInvalid(String)
    case zipFailed(String)

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
        case .emptyResult:
            return "未识别到内容"
        case .network(let msg):
            return "网络错误：\(msg)"
        case .cancelled:
            return "已取消识别"
        case .tokenMissing:
            return "未配置 MinerU Token"
        case .tokenInvalid(let msg):
            return "MinerU Token 不可用（\(msg)）"
        case .zipFailed(let msg):
            return "解析结果包处理失败：\(msg)"
        }
    }
}

/// MinerU 内容提取：
/// 1. 优先 Agent 轻量解析（免登录免 Token，IP 限频，仅输出 Markdown）；
/// 2. 失败时降级到精准解析 API（vlm 模型，Token 取自 ~/.截图工具，
///    走 /api/v4/file-urls/batch 预签名上传，结果为 zip，取其中 full.md）。
/// 配置文件 ~/.截图工具：token=sk-xxx（vlm 令牌）、agent_timeout=20（轻量等待秒数）、
/// theme=system|light|dark（主题，缺省按跟随系统）。
enum MinerUOCRService {
    private static let agentBaseURL = URL(string: "https://mineru.net/api/v1/agent")!
    private static let v4BaseURL = URL(string: "https://mineru.net/api/v4")!
    private static let pollInterval: TimeInterval = 2.0
    private static let vlmTimeout: TimeInterval = 300.0

    // MARK: - Config（~/.截图工具）

    struct MinerUConfig {
        var token: String?
    /// 轻量级接口等待秒数；超时后降级精准解析（vlm）。默认 10。
    var agentTimeout: TimeInterval = 10
        /// 区域截图快捷键（如 Command+Shift+R）。nil = 使用内置默认。
        var captureHotkey: (keyCode: UInt32, modifiers: UInt32)?
        /// 长截图快捷键。nil = 使用内置默认。
        var longHotkey: (keyCode: UInt32, modifiers: UInt32)?
        /// 马赛克密度（像素/格），默认 10。
        var mosaic: CGFloat = 10
        /// 线条粗细（像素），默认 4。
        var thickness: CGFloat = 4
        /// 主题模式。老配置文件没有 theme 键 → 默认跟随系统。
        var theme: ThemeMode = .system

        /// 与代码内置默认值完全一致的配置。
        static let defaults = MinerUConfig()
    }

    static func configPath() -> String { NSHomeDirectory() + "/.截图工具" }

    /// 启动时调用：~/.截图工具 存在则跳过，不存在则自动创建默认配置。
    static func ensureConfigFile() {
        let path = configPath()
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? configTemplate(config: .defaults)
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 读取 ~/.截图工具（反向带出：设置界面据此回填）。
    static func loadConfig() -> MinerUConfig {
        var config = MinerUConfig()
        guard let text = try? String(contentsOfFile: configPath(), encoding: .utf8) else {
            return config
        }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let key: String
            let value: String
            if let eq = line.firstIndex(of: "=") {
                key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }

            switch key {
            case "token":
                if !value.isEmpty { config.token = value }
            case "agent_timeout", "agenttimeout", "timeout":
                if let seconds = Double(value) {
                    config.agentTimeout = min(max(seconds, 5), 600)
                }
            case "capture_hotkey":
                config.captureHotkey = HotkeyService.parse(value)
            case "long_hotkey":
                config.longHotkey = HotkeyService.parse(value)
            case "mosaic":
                if let v = Double(value) { config.mosaic = CGFloat(min(max(v, 2), 64)) }
            case "line_width", "thickness":
                if let v = Double(value) { config.thickness = CGFloat(min(max(v, 1), 40)) }
            case "theme", "主题":
                // 缺省 / 值无法识别 → 保持默认（跟随系统）
                if let m = ThemeMode.parse(value) { config.theme = m }
            default:
                break
            }
        }
        return config
    }

    /// 设置界面保存（正向生成：一一对应写入 ~/.截图工具）。
    /// 快捷键始终写入当前生效值（未重新录制时即原值）。
    static func saveConfig(
        captureHotkey: (keyCode: UInt32, modifiers: UInt32),
        longHotkey: (keyCode: UInt32, modifiers: UInt32),
        mosaic: CGFloat,
        thickness: CGFloat,
        token: String?,
        agentTimeout: TimeInterval,
        theme: ThemeMode
    ) {
        var config = MinerUConfig()
        config.captureHotkey = captureHotkey
        config.longHotkey = longHotkey
        config.mosaic = min(max(mosaic, 2), 64)
        config.thickness = min(max(thickness, 1), 40)
        config.token = token
        config.agentTimeout = min(max(agentTimeout, 5), 600)
        config.theme = theme
        try? configTemplate(config: config)
            .write(toFile: configPath(), atomically: true, encoding: .utf8)
    }

    private static func configTemplate(config: MinerUConfig) -> String {
        let capture = config.captureHotkey
            .map { HotkeyService.format(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            ?? "Command+Shift+R"
        let long = config.longHotkey
            .map { HotkeyService.format(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            ?? "Command+Shift+E"
        return """
        # 截图工具配置文件
        # 快捷键格式：修饰键+键名，如 Command+Shift+R（修饰键可用 Command/Shift/Option/Control）
        capture_hotkey=\(capture)
        long_hotkey=\(long)
        # 马赛克密度（2–64 像素/格）
        mosaic=\(Int(config.mosaic))
        # 线条粗细（1–40 像素）
        line_width=\(Int(config.thickness))
        # MinerU token：精准解析（vlm）接口所需令牌，在 mineru.net 的「API 管理」页面创建；轻量解析无需 token
        token=\(config.token ?? "")
        # 超时时间：轻量级接口的等待秒数，超时后自动降级到精准解析（vlm）；有效范围 5~600
        agent_timeout=\(Int(config.agentTimeout))
        # 主题：dark=暗色 / light=亮色 / system=跟随系统（默认）；本项缺失或无法识别时按「跟随系统」处理
        theme=\(config.theme.configValue)

        """
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Extract Markdown from an image. `onStage` and `completion` are called on the main thread.
    /// Returns a cancellable task; `completion(.failure(.cancelled))` fires immediately on cancel.
    /// Success carries the Markdown, any extracted images, and the channel (agent / precise) that produced it.
    static func extract(
        imageData: Data,
        fileName: String = "screenshot.png",
        onStage: @escaping (String) -> Void,
        completion: @escaping (Result<(markdown: String, images: [ExtractedImage], mode: ExtractMode), Error>) -> Void
    ) -> MinerUExtractTask {
        let task = MinerUExtractTask()
        let config = loadConfig()

        // Deliver completion exactly once.
        let finishLock = NSLock()
        var finished = false
        func finish(_ result: Result<(markdown: String, images: [ExtractedImage], mode: ExtractMode), Error>) {
            finishLock.lock()
            let already = finished
            finished = true
            finishLock.unlock()
            guard !already else { return }
            DispatchQueue.main.async { completion(result) }
        }

        task.setTerminateHandler { finish(.failure(MinerUOCRError.cancelled)) }

        func stage(_ text: String) {
            DispatchQueue.main.async { onStage(text) }
        }

        // ---- 1. Agent 轻量解析（免 Token，等待时长可配置） ----
        runAgent(task: task, imageData: imageData, fileName: fileName, timeout: config.agentTimeout) { agentResult in
            // Treat an empty lightweight result as failure so we can retry with vlm.
            var effectiveResult = agentResult
            if case .success(let outcome) = agentResult,
               outcome.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                effectiveResult = .failure(MinerUOCRError.emptyResult)
            }

            switch effectiveResult {
            case .success(let outcome):
                // 轻量结果对图片只给 <!-- image--> 占位（拿不到真实图片）。
                // 已配置 token 时改走精准解析以获取可导出的图片；精准失败仍回退轻量结果。
                if outcome.images.isEmpty,
                   outcome.markdown.contains("<!-- image"),
                   let token = config.token, !token.isEmpty {
                    stage("轻量结果含图片占位，改用精准解析（vlm）获取图片…")
                    runPrecise(task: task, token: token, imageData: imageData, fileName: fileName) { preciseResult in
                        switch preciseResult {
                        case .success(let preciseOutcome):
                            finish(.success((preciseOutcome.markdown, preciseOutcome.images, .precise)))
                        case .failure(let preciseError):
                            guard !task.isCancelled else { return }
                            if case MinerUOCRError.cancelled = preciseError { return }
                            stage("精准解析未成功，保留轻量结果")
                            finish(.success((outcome.markdown, outcome.images, .agent)))
                        }
                    }
                } else {
                    finish(.success((outcome.markdown, outcome.images, .agent)))
                }
            case .failure(let error):
                guard !task.isCancelled else { return } // finish already called by terminate handler
                if case MinerUOCRError.cancelled = error { return }
                stage("轻量解析失败，改用精准解析（vlm）…")

                // ---- 2. 精准解析 API（vlm） ----
                runPrecise(task: task, token: config.token, imageData: imageData, fileName: fileName) { preciseResult in
                    switch preciseResult {
                    case .success(let outcome):
                        finish(.success((outcome.markdown, outcome.images, .precise)))
                    case .failure(let preciseError):
                        guard !task.isCancelled else { return }
                        if case MinerUOCRError.cancelled = preciseError { return }
                        if case MinerUOCRError.tokenMissing = preciseError {
                            finish(.failure(preciseError))
                        } else {
                            finish(.failure(MinerUOCRError.parseFailed(
                                "轻量解析失败：\(error.localizedDescription)\n精准解析（vlm）失败：\(preciseError.localizedDescription)"
                            )))
                        }
                    }
                }
            }
        }

        return task
    }

    // MARK: - Agent lightweight path

    private static func runAgent(
        task: MinerUExtractTask,
        imageData: Data,
        fileName: String,
        timeout: TimeInterval,
        completion: @escaping (Result<(markdown: String, images: [ExtractedImage]), Error>) -> Void
    ) {
        let session = URLSession.shared
        agentRequestUploadURL(session: session, fileName: fileName) { result in
            guard !task.isCancelled else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (taskId, uploadURL)):
                agentUpload(session: session, data: imageData, to: uploadURL) { uploadResult in
                    guard !task.isCancelled else { return }
                    switch uploadResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        agentPoll(session: session, task: task, taskId: taskId,
                                  deadline: Date().addingTimeInterval(timeout)) { poll in
                            guard !task.isCancelled else { return }
                            switch poll {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let markdownURL):
                                downloadText(session: session, from: markdownURL) { mdResult in
                                    guard !task.isCancelled else { return }
                                    switch mdResult {
                                    case .failure(let error):
                                        completion(.failure(error))
                                    case .success(let markdown):
                                        // 轻量结果里的图片引用需要另行下载，才能随导出落盘。
                                        resolveImages(
                                            task: task, session: session, markdown: markdown,
                                            baseURL: markdownURL.deletingLastPathComponent(),
                                            completion: completion
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 扫描 markdown 中的图片引用并下载：
    /// 绝对 URL 直接下载，相对路径基于 markdown 所在目录解析。
    /// 成功下载的引用改写为相对路径 images/<文件名>，失败的单张保留原引用（不阻塞整体结果）。
    private static func resolveImages(
        task: MinerUExtractTask,
        session: URLSession,
        markdown: String,
        baseURL: URL,
        completion: @escaping (Result<(markdown: String, images: [ExtractedImage]), Error>) -> Void
    ) {
        guard !task.isCancelled else { return }
        let pattern = #"!\[[^\]]*\]\(\s*([^)\s]+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            completion(.success((markdown, [])))
            return
        }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var refs: [String] = []
        for m in matches where m.numberOfRanges > 1 {
            let ref = ns.substring(with: m.range(at: 1))
            if !refs.contains(ref) { refs.append(ref) }
        }
        guard !refs.isEmpty else {
            completion(.success((markdown, [])))
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var usedNames: Set<String> = []
        var images: [ExtractedImage] = []
        var rewrites: [(from: String, to: String)] = []

        for ref in refs {
            let target: URL?
            if let u = URL(string: ref), u.scheme == "http" || u.scheme == "https" {
                target = u
            } else {
                target = URL(string: ref, relativeTo: baseURL)?.absoluteURL
            }
            guard let url = target else { continue }
            group.enter()
            downloadData(session: session, from: url) { result in
                defer { group.leave() }
                guard case .success(let data) = result, !data.isEmpty else { return }
                // 仅收录 Word/Excel 可内嵌的格式（jpg/png/gif），扩展名优先嗅探、URL 后缀兜底。
                guard let ext = sniffImageExtension(data)
                    ?? sanitizeExtension(url.pathExtension) else { return }
                lock.lock()
                defer { lock.unlock() }
                var base = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                if base.hasSuffix("/") || base.isEmpty { base = "image" }
                let stem = (base as NSString).deletingPathExtension
                let name = usedNames.contains("\(stem).\(ext)")
                    ? "\(stem)-\(usedNames.count + 1).\(ext)"
                    : "\(stem).\(ext)"
                usedNames.insert(name)
                let path = "images/\(name)"
                images.append(ExtractedImage(path: path, data: data))
                rewrites.append((ref, path))
            }
        }

        group.notify(queue: .global()) {
            guard !task.isCancelled else { return }
            var md = markdown
            for r in rewrites {
                md = md.replacingOccurrences(of: "](\(r.from))", with: "](\(r.to))")
            }
            completion(.success((md, images)))
        }
    }

    /// 按文件头嗅探图片格式（仅收录 Office 可内嵌的 jpg/png/gif）。
    private static func sniffImageExtension(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return nil
    }

    private static func sanitizeExtension(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "jpg", "jpeg": return "jpg"
        case "png": return "png"
        case "gif": return "gif"
        default: return nil
        }
    }

    private static func agentRequestUploadURL(
        session: URLSession,
        fileName: String,
        completion: @escaping (Result<(taskId: String, fileURL: URL), Error>) -> Void
    ) {
        var request = URLRequest(url: agentBaseURL.appendingPathComponent("parse/file"))
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

    private static func agentUpload(
        session: URLSession,
        data: Data,
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        // No Content-Type — OSS signed URL is computed without it.

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

    private static func agentPoll(
        session: URLSession,
        task: MinerUExtractTask,
        taskId: String,
        deadline: Date,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !task.isCancelled else { return }
        if Date() > deadline {
            completion(.failure(MinerUOCRError.timeout))
            return
        }

        let url = agentBaseURL.appendingPathComponent("parse/\(taskId)")
        session.dataTask(with: url) { data, _, error in
            guard !task.isCancelled else { return }
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
                    agentPoll(session: session, task: task, taskId: taskId, deadline: deadline, completion: completion)
                }
            }
        }.resume()
    }

    // MARK: - Precise (vlm) path

    private static func runPrecise(
        task: MinerUExtractTask,
        token: String?,
        imageData: Data,
        fileName: String,
        completion: @escaping (Result<(markdown: String, images: [ExtractedImage]), Error>) -> Void
    ) {
        guard let token, !token.isEmpty else {
            completion(.failure(MinerUOCRError.tokenMissing))
            return
        }
        let session = URLSession.shared

        v4RequestBatchUploadURL(session: session, token: token, fileName: fileName) { result in
            guard !task.isCancelled else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (batchId, uploadURL)):
                agentUpload(session: session, data: imageData, to: uploadURL) { uploadResult in
                    guard !task.isCancelled else { return }
                    switch uploadResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        v4PollBatch(session: session, token: token, task: task, batchId: batchId,
                                    deadline: Date().addingTimeInterval(vlmTimeout)) { poll in
                            guard !task.isCancelled else { return }
                            switch poll {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let zipURL):
                                downloadData(session: session, from: zipURL) { zipResult in
                                    guard !task.isCancelled else { return }
                                    switch zipResult {
                                    case .failure(let error):
                                        completion(.failure(error))
                                    case .success(let zipData):
                                        DispatchQueue.global().async {
                                            do {
                                                let outcome = try extractResultFromZip(zipData)
                                                guard !task.isCancelled else { return }
                                                completion(.success(outcome))
                                            } catch {
                                                guard !task.isCancelled else { return }
                                                completion(.failure(error))
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

    /// POST /file-urls/batch → (batch_id, presigned upload URL). vlm model, auto-submits after upload.
    private static func v4RequestBatchUploadURL(
        session: URLSession,
        token: String,
        fileName: String,
        completion: @escaping (Result<(batchId: String, uploadURL: URL), Error>) -> Void
    ) {
        var request = URLRequest(url: v4BaseURL.appendingPathComponent("file-urls/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "files": [
                ["name": fileName, "is_ocr": true]
            ],
            "model_version": "vlm",
            "language": "ch",
            "enable_table": true,
            "enable_formula": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(MinerUOCRError.submitFailed("精准解析响应格式错误（HTTP \(status)）")))
                return
            }
            let code = (json["code"] as? Int) ?? -1
            let msg = (json["msg"] as? String) ?? "未知错误"
            // 错误码字段：成功响应为 code(0)，错误响应实测为 msgCode（如 "A0211" Token 过期）
            let codeText = (json["code"] as? String)
                ?? (json["msgCode"] as? String)
                ?? String(code)
            let tokenProblem = status == 401
                || codeText.hasPrefix("A02")
                || msg.lowercased().contains("token")
            guard code == 0,
                  let payload = json["data"] as? [String: Any],
                  let batchId = payload["batch_id"] as? String,
                  let urls = payload["file_urls"] as? [String],
                  let first = urls.first,
                  let uploadURL = URL(string: first) else {
                if tokenProblem {
                    completion(.failure(MinerUOCRError.tokenInvalid(msg)))
                } else {
                    completion(.failure(MinerUOCRError.submitFailed(msg)))
                }
                return
            }
            completion(.success((batchId, uploadURL)))
        }.resume()
    }

    /// GET /extract-results/batch/{batch_id} → full_zip_url when done.
    private static func v4PollBatch(
        session: URLSession,
        token: String,
        task: MinerUExtractTask,
        batchId: String,
        deadline: Date,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !task.isCancelled else { return }
        if Date() > deadline {
            completion(.failure(MinerUOCRError.timeout))
            return
        }

        var request = URLRequest(url: v4BaseURL.appendingPathComponent("extract-results/batch/\(batchId)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { data, _, error in
            guard !task.isCancelled else { return }
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["data"] as? [String: Any],
                  let results = payload["extract_result"] as? [[String: Any]],
                  let first = results.first else {
                completion(.failure(MinerUOCRError.parseFailed("查询精准解析结果失败")))
                return
            }

            let state = (first["state"] as? String) ?? ""
            switch state {
            case "done":
                if let zip = first["full_zip_url"] as? String, let zipURL = URL(string: zip) {
                    completion(.success(zipURL))
                } else {
                    completion(.failure(MinerUOCRError.parseFailed("缺少解析结果下载链接")))
                }
            case "failed":
                let errMsg = (first["err_msg"] as? String) ?? "未知错误"
                completion(.failure(MinerUOCRError.parseFailed(errMsg)))
            default:
                DispatchQueue.global().asyncAfter(deadline: .now() + pollInterval) {
                    v4PollBatch(session: session, token: token, task: task, batchId: batchId,
                                deadline: deadline, completion: completion)
                }
            }
        }.resume()
    }

    // MARK: - Shared helpers

    private static func downloadText(
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

    private static func downloadData(
        session: URLSession,
        from url: URL,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        session.dataTask(with: url) { data, response, error in
            if let error {
                completion(.failure(MinerUOCRError.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200...299).contains(status) else {
                completion(.failure(MinerUOCRError.parseFailed("结果包下载失败（HTTP \(status)）")))
                return
            }
            completion(.success(data))
        }.resume()
    }

    /// Unzips the v4 result package and returns full.md content plus the images it ships with
    /// (e.g. images/xxx.jpg)，路径以 full.md 所在目录为基准。
    private static func extractResultFromZip(_ zipData: Data) throws
        -> (markdown: String, images: [ExtractedImage]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mineru-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("result.zip")
        try zipData.write(to: zipURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zipURL.path, "-d", dir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw MinerUOCRError.zipFailed("解压失败（exit \(proc.terminationStatus)）")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            throw MinerUOCRError.zipFailed("无法读取结果目录")
        }
        var mdURL: URL?
        var imageFiles: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "full.md" && mdURL == nil {
                mdURL = url
            } else if let ext = sanitizeExtension(url.pathExtension), ext != "" {
                imageFiles.append(url)
            }
        }
        guard let mdURL, let text = try? String(contentsOf: mdURL, encoding: .utf8) else {
            throw MinerUOCRError.zipFailed("结果包中未找到 full.md")
        }

        // 图片路径以 full.md 所在目录为基准，生成相对路径（如 images/xxx.jpg）。
        let baseDir = mdURL.deletingLastPathComponent()
        var images: [ExtractedImage] = []
        for file in imageFiles {
            // 只保留 zip 内基准目录之下的图片
            guard file.path.hasPrefix(baseDir.path) else { continue }
            let rel = String(file.path.dropFirst(baseDir.path.count + 1))
            guard !rel.isEmpty else { continue }
            if let data = try? Data(contentsOf: file) {
                images.append(ExtractedImage(path: rel, data: data))
            }
        }
        return (text, images)
    }
}
