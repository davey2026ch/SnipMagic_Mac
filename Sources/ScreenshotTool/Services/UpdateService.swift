import AppKit
import Foundation

// MARK: - 模型

/// Release 里的一个附件。
struct UpdateAsset {
    let name: String
    let url: URL
    let size: Int64
}

/// 云端可用的、比本机更新的版本。
struct UpdateRelease {
    let tag: String          // v2.4.0
    let version: String      // 2.4.0
    let notes: String        // Release 正文（原始 Markdown）
    let pageURL: URL?
    let asset: UpdateAsset   // 已按本机芯片挑好的安装包

    /// 弹窗里展示用的纯文本说明。
    var summary: String { UpdateService.plainText(fromMarkdown: notes) }
}

enum UpdateCheckOutcome {
    case upToDate(current: String)
    case available(UpdateRelease)
    case failure(String)
}

enum UpdateError: LocalizedError {
    case notRunningFromApp
    case busy
    case downloadFailed(String)
    case mountFailed(String)
    case payloadMissing
    case stageFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunningFromApp:
            return "当前不是以 .app 形式运行，无法自动替换。请用下载好的 dmg 手动安装。"
        case .busy:
            return "已经有一个更新任务在进行中。"
        case .downloadFailed(let detail):
            return "下载安装包失败：\(detail)"
        case .mountFailed(let detail):
            return "安装包挂载失败：\(detail)"
        case .payloadMissing:
            return "安装包里没有找到应用程序。"
        case .stageFailed(let detail):
            return "复制新版本失败：\(detail)"
        }
    }
}

// MARK: - 服务

/// 从 Gitee Release 自动更新。
///
/// 三个约定，改代码前先看：
/// 1. **匿名读取，绝不内置令牌**。分发的 App 里带 access_token 等于把仓库写权限
///    发给每个下载者；`/releases` 是公开接口，匿名限频 60 次/小时/IP，
///    启动检测一次完全够用。
/// 2. **按本机真实芯片挑包，不按当前进程架构**。M 芯片上跑着 Rosetta 的 Intel 版时
///    `hw.optional.arm64` 仍为 1，应该给它 arm64 原生包（换过去是升级不是降级）；
///    Intel 机器拿 arm64 包则根本跑不起来。
/// 3. **先问再做**。检测到新版本只弹窗，用户点「立即更新」才开始下载安装，
///    全程不静默替换用户的 App。
///
/// 附件命名约定（与 build_app.sh 一致）：
///   `截图大师SnipMagic-v3.1.0.dmg`            → arm64
///   `截图大师SnipMagic-v3.1.0-x86_64.dmg`     → Intel
///   `截图大师SnipMagic-v3.1.0-universal.dmg`  → 通用，兜底
final class UpdateService: NSObject {
    static let shared = UpdateService()

    // MARK: - 常量

    private static let owner = "mrpu2020"
    private static let repo = "SnipMagic_Mac"
    private static let apiRoot = "https://gitee.com/api/v5/repos/mrpu2020/SnipMagic_Mac"
    /// 启动后延迟多久做首次静默检测，避开首帧渲染与权限弹窗。
    static let launchCheckDelay: TimeInterval = 3.0

    /// 下载与安装都跑在这个 session 上，进度回调统一切到主线程。
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue.main
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private var downloadCompletion: ((Result<URL, Error>) -> Void)?
    private var downloadProgress: ((Int64, Int64) -> Void)?
    private var downloadDestination: URL?
    /// 进度面板由 promptAndInstall 持有，下载/安装结束后关闭。
    private var progressWindow: UpdateProgressWindowController?

    // MARK: - 本机信息

    /// 当前版本。打包后即 Info.plist 的 CFBundleShortVersionString；
    /// 开发时（裸二进制）回落到代码里的 AppInfo.version。
    static var currentVersion: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return AppInfo.version
    }

    /// 本机真实芯片架构：arm64 / x86_64。
    /// 用 `hw.optional.arm64` 而不是 `uname -m` —— 后者反映的是**当前进程**的架构，
    /// Rosetta 下会报 x86_64，从而把 M 芯片误判成 Intel。
    static var currentArchitecture: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return "arm64"
        }
        return "x86_64"
    }

    /// 给用户看的芯片名。
    static func architectureDisplayName(for architecture: String) -> String {
        architecture == "arm64" ? "Apple 芯片（M 系列）" : "Intel 芯片"
    }

    static var architectureDisplayName: String {
        architectureDisplayName(for: currentArchitecture)
    }

    /// 是否以 .app 运行。开发时 `swift run` 跑的是裸二进制，自动替换没有意义。
    static var isRunningFromAppBundle: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Info.plist").path
        )
    }

    // MARK: - 检查更新

    /// 查询云端最新版本，回调在主线程。
    func check(completion: @escaping (UpdateCheckOutcome) -> Void) {
        guard let url = URL(string: Self.apiRoot + "/releases?per_page=50&page=1") else {
            completion(.failure("接口地址拼装失败"))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("SnipMagic/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            let outcome = Self.evaluate(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    /// 启动时静默检测：只有「发现新版本」才会打扰用户，其余情况一律保持安静。
    func checkOnLaunch() {
        guard Self.isRunningFromAppBundle else { return }
        check { [weak self] outcome in
            if case .available(let release) = outcome {
                self?.promptAndInstall(release)
            }
        }
    }

    // MARK: - 网络响应解析（可单独测试）

    static func evaluate(data: Data?, response: URLResponse?, error: Error?) -> UpdateCheckOutcome {
        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain,
               [NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDataNotAllowed].contains(error.code) {
                return .failure("网络不可用")
            }
            return .failure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure("服务器没有响应")
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            return .failure("请求过于频繁，请稍后再试")
        case 404:
            return .failure("找不到发布仓库")
        default:
            return .failure("服务器返回 HTTP \(http.statusCode)")
        }
        guard let data = data,
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return .failure("返回内容无法解析")
        }
        return pickLatest(from: items)
    }

    /// 在所有 Release 里挑出「比本机新且版本号最大」的那个，再挑出适配本机芯片的 dmg。
    /// 不直接用 /releases/latest：它按创建时间取，补发旧版本补丁时会给错包。
    /// `current` / `architecture` 参数只为可测试，默认即本机实际值。
    static func pickLatest(
        from items: [[String: Any]],
        current: String = currentVersion,
        architecture: String = currentArchitecture
    ) -> UpdateCheckOutcome {
        var best: (version: String, tag: String, notes: String, page: URL?, assets: [UpdateAsset])?

        for item in items {
            if (item["prerelease"] as? Bool) == true { continue }
            guard let tag = item["tag_name"] as? String else { continue }
            let version = normalizedVersion(tag)
            guard !version.isEmpty, compareVersions(version, current) > 0 else { continue }
            if let best = best, compareVersions(version, best.version) <= 0 { continue }

            let assets = (item["assets"] as? [[String: Any]] ?? []).compactMap { raw -> UpdateAsset? in
                guard let name = raw["name"] as? String,
                      let link = raw["browser_download_url"] as? String,
                      let url = URL(string: link) else { return nil }
                let size = (raw["size"] as? NSNumber)?.int64Value ?? 0
                return UpdateAsset(name: name, url: url, size: size)
            }
            let page = (item["html_url"] as? String).flatMap { URL(string: $0) }
            best = (version, tag, (item["body"] as? String) ?? "", page, assets)
        }

        guard let best = best else { return .upToDate(current: current) }
        guard let asset = pickAsset(from: best.assets, version: best.version, for: architecture) else {
            let chip = architectureDisplayName(for: architecture)
            return .failure("v\(best.version) 已发布，但没有找到适配\(chip)的安装包")
        }
        return .available(UpdateRelease(
            tag: best.tag,
            version: best.version,
            notes: best.notes,
            pageURL: best.page,
            asset: asset
        ))
    }

    /// 从附件里挑出与当前芯片匹配的 dmg。
    ///
    /// Gitee 会自动附带 `v2.4.0.zip` / `v2.4.0.tar.gz` 源码包，必须排除；
    /// 命名不带架构标识的那个 dmg 按约定就是 arm64。
    static func pickAsset(
        from assets: [UpdateAsset],
        version: String,
        for architecture: String = currentArchitecture
    ) -> UpdateAsset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !dmgs.isEmpty else { return nil }

        // 多版本共存（同一份 release 里放了别的版本的包）时先按版本号收敛
        let sameVersion = dmgs.filter { $0.name.contains(version) }
        let pool = sameVersion.isEmpty ? dmgs : sameVersion

        func contains(_ words: [String], _ name: String) -> Bool {
            let lowered = name.lowercased()
            return words.contains { lowered.contains($0) }
        }
        let intelWords = ["x86_64", "x86-64", "amd64", "intel"]
        let armWords = ["arm64", "aarch64", "apple-silicon"]
        let universalWords = ["universal", "unified"]

        if architecture == "x86_64" {
            if let direct = pool.first(where: { contains(intelWords, $0.name) }) { return direct }
            if let universal = pool.first(where: { contains(universalWords, $0.name) }) { return universal }
        } else {
            if let direct = pool.first(where: { contains(armWords, $0.name) }) { return direct }
            // 无架构标识的 dmg = arm64（build_app.sh 的约定）
            if let plain = pool.first(where: {
                !contains(intelWords, $0.name) && !contains(universalWords, $0.name)
            }) { return plain }
            if let universal = pool.first(where: { contains(universalWords, $0.name) }) { return universal }
        }
        // 兜底：真没有可辨认的标识时，至少给出一个包，由用户自行判断
        return pool.first
    }

    // MARK: - 版本号工具

    /// "v2.4.0" → "2.4.0"（去掉 v 前缀与 -beta 之类的预发布后缀）。
    static func normalizedVersion(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        var digits = ""
        for character in text {
            guard character.isNumber || character == "." else { break }
            digits.append(character)
        }
        while digits.hasSuffix(".") { digits.removeLast() }
        return digits
    }

    /// 语义化版本比较：a 比 b 新返回 1，旧返回 -1，相同返回 0。
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right ? 1 : -1 }
        }
        return 0
    }

    private static let linkPattern = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\(([^)]*)\\)")

    /// 把 Release 正文（Markdown）洗成弹窗里能看的纯文本。
    static func plainText(fromMarkdown text: String, limit: Int = 700) -> String {
        var lines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                continue
            }
            while line.hasPrefix("#") || line.hasPrefix(">") {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = "· " + line.dropFirst(2)
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if let pattern = linkPattern {
                line = pattern.stringByReplacingMatches(
                    in: line,
                    range: NSRange(line.startIndex..<line.endIndex, in: line),
                    withTemplate: "$1"
                )
            }
            if line.isEmpty { continue }
            lines.append(line)
        }
        var result = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > limit {
            result = String(result.prefix(limit))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return result
    }

    // MARK: - 弹窗：先问，再做

    /// 弹出「发现新版本」提示。用户点「立即更新」才下载并安装。
    func promptAndInstall(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(release.version)"
        var body = """
        当前版本 v\(Self.currentVersion)（\(Self.currentArchitecture)）
        即将下载 \(release.asset.name)（适配\(Self.architectureDisplayName)）
        """
        let summary = release.summary
        if !summary.isEmpty {
            body += "\n\n\(summary)"
        }
        alert.informativeText = body
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        beginDownloadAndInstall(release)
    }

    func beginDownloadAndInstall(_ release: UpdateRelease) {
        guard progressWindow == nil else { return }

        let panel = UpdateProgressWindowController(title: "正在更新到 v\(release.version)")
        progressWindow = panel
        panel.present()
        panel.update(status: "正在下载安装包…", detail: release.asset.name)
        panel.setIndeterminate(true)

        download(release.asset, progress: { [weak panel] done, total in
            guard let panel = panel else { return }
            if total > 0 {
                panel.setIndeterminate(false)
                panel.updateProgress(done: done, total: total)
                panel.update(
                    status: "正在下载安装包…",
                    detail: "\(Self.byteText(done)) / \(Self.byteText(total))"
                )
            } else {
                panel.update(status: "正在下载安装包…", detail: Self.byteText(done))
            }
        }, completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let dmgURL):
                panel.update(status: "正在安装…", detail: "替换当前应用后会自动重启")
                panel.setIndeterminate(true)
                self.install(dmgURL: dmgURL) { installResult in
                    switch installResult {
                    case .success:
                        panel.update(status: "更新完成，正在重启…", detail: "")
                        // 交棒给后台脚本：它等本进程退出后替换 .app 并重新打开
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            NSApp.terminate(nil)
                        }
                    case .failure(let error):
                        self.finishProgressWindow()
                        self.presentFailure(error, release: release, dmgURL: dmgURL)
                    }
                }
            case .failure(let error):
                self.finishProgressWindow()
                self.presentFailure(error, release: release, dmgURL: nil)
            }
        })
    }

    private func finishProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
    }

    /// 更新失败后的兜底：能打开已下好的 dmg 就打开，其次跳发布页。
    private func presentFailure(_ error: Error, release: UpdateRelease, dmgURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "更新失败"
        var text = error.localizedDescription
        if dmgURL != nil {
            text += "\n\n安装包已经下载好了，可以打开它手动拖进「应用程序」。"
        }
        alert.informativeText = text

        let canOpenDMG = dmgURL != nil
        if canOpenDMG { alert.addButton(withTitle: "打开安装包") }
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        // 按钮顺序随 canOpenDMG 变化，换算成从 0 开始的索引再判断
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if canOpenDMG, index == 0, let dmgURL = dmgURL {
            NSWorkspace.shared.open(dmgURL)
        } else if index == (canOpenDMG ? 1 : 0), let page = release.pageURL {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: - 下载

    func download(
        _ asset: UpdateAsset,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard downloadCompletion == nil else {
            completion(.failure(UpdateError.busy))
            return
        }
        let destination = Self.updateDirectory.appendingPathComponent(asset.name)
        downloadDestination = destination
        downloadProgress = progress
        downloadCompletion = completion

        var request = URLRequest(url: asset.url)
        request.setValue("SnipMagic/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        downloadSession.downloadTask(with: request).resume()
    }

    /// 下载目录：~/Library/Caches/截图大师SnipMagic/updates/
    static var updateDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("截图大师SnipMagic/updates", isDirectory: true)
    }

    private func finishDownload(_ result: Result<URL, Error>) {
        guard let completion = downloadCompletion else { return }
        downloadCompletion = nil
        downloadProgress = nil
        downloadDestination = nil
        completion(result)
    }

    // MARK: - 安装（挂载 → 取出 .app → 交给后台脚本替换）

    /// 挂载 dmg、把里面的 .app 复制到缓存目录，然后启动替换脚本。
    /// 真正的替换在本进程退出后进行，因此调用方在成功后应立即退出 App。
    /// `targetApp` 默认就是当前运行的 App 本身，参数化只为可测试。
    func install(
        dmgURL: URL,
        targetApp: URL? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let target = targetApp ?? Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            completion(.failure(UpdateError.notRunningFromApp))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let staged: Result<URL, Error>
            do {
                staged = .success(try Self.stageApp(fromDMG: dmgURL))
            } catch {
                staged = .failure(error)
            }

            DispatchQueue.main.async {
                switch staged {
                case .success(let stagedApp):
                    do {
                        try Self.launchSwapScript(targetApp: target, stagedApp: stagedApp, dmgURL: dmgURL)
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// 同步执行命令行工具，返回退出码与合并后的输出。
    private static func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 挂载 dmg 并把其中的 .app 复制到缓存目录（正在运行的 .app 不能就地替换）。
    private static func stageApp(fromDMG dmgURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnipMagic-mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: mountPoint) }

        let attach = runTool("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-noverify", "-readonly",
            "-mountpoint", mountPoint.path, dmgURL.path
        ])
        guard attach.status == 0 else {
            throw UpdateError.mountFailed(attach.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // detach 必须早于上面那个 removeItem，defer 是后进先出，顺序刚好
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let entries = (try? fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let sourceApp = entries.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.payloadMissing
        }

        let stagingRoot = updateDirectory.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagedApp = stagingRoot.appendingPathComponent(sourceApp.lastPathComponent, isDirectory: true)

        // ditto 保留代码签名与扩展属性，cp -R 不保证
        let copy = runTool("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
        guard copy.status == 0 else {
            throw UpdateError.stageFailed(copy.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stagedApp
    }

    /// 单引号包裹，供 shell 使用（路径里有中文和空格）。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 生成并启动替换脚本。脚本先等本进程退出，再替换 .app，最后重新打开；
    /// 替换失败会回滚并至少把 dmg 打开，保证不会把用户的应用弄丢。
    private static func launchSwapScript(targetApp: URL, stagedApp: URL, dmgURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: updateDirectory, withIntermediateDirectories: true)

        let scriptURL = updateDirectory.appendingPathComponent("apply-update.sh")
        let backupPath = targetApp.path + ".update-backup"
        let stagingRoot = stagedApp.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/bash
        # 由「截图大师 SnipMagic」自动更新生成：等旧进程退出 → 替换 .app → 重新打开。
        # 失败时一律回滚，最差情况也只是弹出 dmg 让用户手动安装。
        APP=\(shellQuoted(targetApp.path))
        NEW=\(shellQuoted(stagedApp.path))
        BACKUP=\(shellQuoted(backupPath))
        STAGE=\(shellQuoted(stagingRoot.path))
        DMG=\(shellQuoted(dmgURL.path))
        PID=\(pid)

        for _ in {1..240}; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.5
        done
        sleep 0.4

        # 旧版本先改名留着（同卷内几乎瞬间完成），替换成功才删除
        if ! mv "$APP" "$BACKUP" 2>/dev/null; then
            chmod -R u+w "$APP" 2>/dev/null
            mv "$APP" "$BACKUP" 2>/dev/null
        fi

        if [ -d "$BACKUP" ]; then
            if /usr/bin/ditto "$NEW" "$APP"; then
                /usr/bin/xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1
                rm -rf "$BACKUP"
                /usr/bin/open "$APP"
            else
                rm -rf "$APP"
                mv "$BACKUP" "$APP"
                /usr/bin/open "$APP"
            fi
        else
            # 没有写权限（例如装在只读位置）：把安装包打开，交给用户手动拖
            /usr/bin/open "$DMG"
        fi
        rm -rf "$STAGE"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // nohup + & 让脚本脱离本进程：App 退出后它还要继续跑完替换
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "nohup /bin/bash \(shellQuoted(scriptURL.path)) >/dev/null 2>&1 &"]
        try launcher.run()
        launcher.waitUntilExit()
    }

    // MARK: - 小工具

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

// MARK: - 下载进度

extension UpdateService: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        downloadProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 必须在这个回调返回前把临时文件挪走，否则系统会删掉它
        guard let destination = downloadDestination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: destination)
            finishDownload(.success(destination))
        } catch {
            finishDownload(.failure(UpdateError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard downloadCompletion != nil else { return }
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finishDownload(.failure(UpdateError.downloadFailed("服务器返回 HTTP \(http.statusCode)")))
            return
        }
        guard let error = error else { return }   // 成功路径已由 didFinishDownloadingTo 处理
        finishDownload(.failure(UpdateError.downloadFailed(error.localizedDescription)))
    }
}
