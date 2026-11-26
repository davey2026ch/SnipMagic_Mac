import Foundation

/// 磁盘残留清扫。
///
/// 应用的底线是：**截图 / 长截图 / GIF 的像素只活在内存里**，用户点保存才写到他选的位置。
/// 真正不得不临时落盘的只有两处（都是因为命令行工具只认路径）：
///   1. MinerU 结果包解压（`/usr/bin/unzip`）；
///   2. 导出 docx / xlsx 时给 `/usr/bin/zip` 用的打包目录。
/// 这两处都在 `defer` 里删干净了，但——进程被强杀、崩溃、断电时 `defer` 不会执行，
/// 残渣就留在了 `/var/folders/.../T/` 里直到系统自己回收。所以每次启动再扫一遍。
///
/// 清扫原则：**只认自己写死的前缀**，绝不按时间/大小批量删别人的东西。
enum DiskHygiene {

    /// 本应用在临时目录里创建的目录前缀（和各自 createDirectory 的地方保持一致）。
    private static let tempPrefixes = [
        "mineru-",            // MinerU 结果包解压
        "office-export-",     // docx / xlsx 打包
        "SnipMagic-mount-",   // 更新时挂载 dmg
        "SnipMagic-staged-"   // 更新时暂存新 .app
    ]

    /// 残渣至少这么旧才删。`open -n` 重启会短暂出现两个实例，
    /// 别把另一个实例正在用的临时目录当垃圾扫掉。
    private static let tempMinimumAge: TimeInterval = 10 * 60

    /// 更新目录里的安装包/脚本至少这么旧才删（正在下载的那份绝不能碰）。
    private static let updateMinimumAge: TimeInterval = 60 * 60

    /// 历史上存在过的 bundle id（`com.mimo.screenshottool` 是改名前的）。
    /// 这两个目录下的 `Cache.db` 是 `URLCache.shared` 的磁盘缓存，
    /// 老版本用的正是它 —— 里面可能有版本清单，也可能有 OCR 结果包。
    private static let legacyCacheBundles = ["com.mimo.snipmagic", "com.mimo.screenshottool"]

    /// 启动时调用（后台线程）。只清本应用自己的东西，失败静默。
    static func sweepOnLaunch() {
        DispatchQueue.global(qos: .utility).async {
            sweepTemporaryArtifacts()
            sweepUpdateArtifacts()
            sweepLegacyURLCaches()
        }
    }

    // MARK: - 老版本的磁盘 URL 缓存

    /// 现版本所有网络请求都走 ephemeral 会话 + `URLCache.shared` 已禁用磁盘，
    /// 这个目录不会再被写。老版本升级上来时它可能还躺着东西，启动就清掉；
    /// 只删 URL 缓存的固定几个文件名，不整个目录 rm —— 免得连带删掉别的。
    private static func sweepLegacyURLCaches() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        for bundle in legacyCacheBundles {
            let dir = caches.appendingPathComponent(bundle, isDirectory: true)
            for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - 临时目录

    private static func sweepTemporaryArtifacts() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            let name = url.lastPathComponent
            guard tempPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard isOlderThan(tempMinimumAge, at: url) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - 更新目录

    /// `~/Library/Caches/<app>/updates/` 里的 dmg、替换脚本、暂存目录。
    /// 正常情况下替换脚本跑完会自己删掉，这里兜住"装到一半退出/失败"的残渣。
    private static func sweepUpdateArtifacts() {
        let fm = FileManager.default
        let dir = UpdateService.updateDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            guard isOlderThan(updateMinimumAge, at: url) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - 工具

    private static func isOlderThan(_ interval: TimeInterval, at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(date) >= interval
    }
}
