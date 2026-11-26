import AppKit

/// 保存规则（同名二选一、自动编号、全部保存的时间文件夹）集中在这里，
/// 单张保存 / 保存帧 / 保存GIF / 全部保存 共用同一套，避免各处行为不一致。
enum SaveSupport {

    // MARK: - 同名文件

    /// `P1.png` → `P1_001.png`（取第一个不存在的号，最多 999）。
    static func numberedURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for i in 1...999 {
            let name = String(format: "%@_%03d", stem, i)
            let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(String(format: "%@_%03d", stem, 999))
            .appendingPathExtension(ext)
    }

    /// 上一次保存到的目录（首次是「下载」）。保存面板默认开在这里，
    /// 这样"默认文件名是否同名"的判断与实际落盘目录一致。
    static var lastSaveDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "LastSaveDirectory") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return downloadsDirectory()
    }

    static func rememberSaveDirectory(_ url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "LastSaveDirectory")
    }

    /// 保存面板的**默认文件名**：同名已存在时自动变成 `P1_001.png`。
    ///
    /// 为什么不弹「替换 / 追加序号」二选一：macOS 的 `NSSavePanel` **自带**一个
    /// 「已存在，要替换吗？」确认框，而且没有 API 能关掉它。若我们再弹一次，
    /// 用户会连着被问两遍。所以改成：默认名自动避开同名（等价于「追加序号」这个
    /// 安全默认），用户若手动改成一个已存在的名字，就由系统那一次确认来决定是否覆盖。
    /// 这样始终"不会静默覆盖"，但只会问一次。
    static func uniqueDefaultName(for name: String, in dir: URL? = nil) -> String {
        let folder = dir ?? lastSaveDirectory
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return name }
        return numberedURL(for: url).lastPathComponent
    }

    // MARK: - 全部保存

    /// 「下载」目录（取不到时退回桌面）。
    static func downloadsDirectory() -> URL {
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// `截图大师_yyyyMMddHHmm`，例 `截图大师_202611260858`。
    /// 「截图大师」是固定前缀：全部保存会在「下载」里建这个文件夹，一眼能认出是谁生成的。
    static func timestampName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmm"
        return "截图大师_" + f.string(from: date)
    }

    /// 在 parent 下建 name 文件夹；同名已存在则加 `_2`…`_99`（还不成就用 `_<时间戳>`）。
    static func uniqueDirectory(in parent: URL, name: String) -> URL? {
        let fm = FileManager.default
        for i in 1...99 {
            let candidate = parent.appendingPathComponent(i == 1 ? name : "\(name)_\(i)")
            if !fm.fileExists(atPath: candidate.path) {
                do {
                    try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
                    return candidate
                } catch {
                    return nil
                }
            }
        }
        let fallback = parent.appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970))")
        do {
            try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        } catch {
            return nil
        }
    }

    /// 目录内取一个不冲突的文件名：`stem.ext` → `stem_001.ext` → …
    static func uniqueFile(in dir: URL, stem: String, ext: String) -> URL {
        let base = dir.appendingPathComponent(stem).appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        for i in 1...999 {
            let candidate = dir.appendingPathComponent(String(format: "%@_%03d", stem, i))
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return base
    }
}
