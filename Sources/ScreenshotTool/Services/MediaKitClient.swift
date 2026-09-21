import AppKit
import Foundation

/// 火山引擎 AI MediaKit 的公共调用层。
///
/// 「魔法消除」和「提取矢量图」走的是同一套链路 —— 同一把 API Key、同一个
/// 预签名上传协议、同一个同步工具接口风格，差别只在最后调哪个工具接口。
/// 所以把 HTTP、编解码、缩放这些与业务无关的部分收在这里，两边共用一份，
/// 免得改一处漏一处（比如上传时该带什么头）。
///
/// 链路（本地图片没有公网地址，只能这样绕）：
///   1. `POST /tools-sync/request-media-upload-url` —— 申请 `file_id` 和带签名的上传地址
///   2. `PUT {upload_url}` —— 纯二进制上传（**不能用 multipart**）
///   3. `POST /tools-sync/<工具接口>` —— 用 `mediakit://{file_id}` 引用，拿回结果地址
///   4. 下载结果
///
/// 这些方法都是同步阻塞的，调用方必须放在后台队列。
enum MediaKitClient {

    static let baseURL = URL(string: "https://mediakit.cn-beijing.volces.com/api/v1")!

    /// 通用错误。业务侧的专属错误（比如「没框选」）各自留在自己的服务里。
    enum Error: Swift.Error, LocalizedError {
        case missingAPIKey
        case encodeFailed
        case uploadSlotFailed(String)
        case uploadRejected(Int, String)
        case tooLarge(bytes: Int, limit: Int)
        case serviceFailed(code: String, message: String)
        case malformedResponse
        case downloadFailed(String)
        case network(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "还没配置火山引擎 API Key。请到「设置」→「火山 API Key」填入后再试。"
            case .encodeFailed:
                return "图片编码失败。"
            case .uploadSlotFailed(let detail):
                return "申请上传地址失败：\(detail)"
            case .uploadRejected(let status, let detail):
                return "上传被拒绝（HTTP \(status)）：\(detail)"
            case .tooLarge(let bytes, let limit):
                return "图片超过 \(limit / 1024 / 1024)MB 上限（当前 \(bytes / 1024 / 1024)MB）。请缩小选区后重试。"
            case .serviceFailed(let code, let message):
                return "云端处理失败（\(code)）：\(message)"
            case .malformedResponse:
                return "云端返回的数据无法解析。"
            case .downloadFailed(let detail):
                return "结果下载失败：\(detail)"
            case .network(let detail):
                return "网络异常：\(detail)"
            case .cancelled:
                return "已取消。"
            }
        }
    }

    /// 取消令牌。同步方法拿不到 `Task.cancel()` 的好处，所以自己带一个：
    /// UI 点「取消」时把正在跑的请求掐掉，链路下一处检查点也会立刻退出。
    final class CancelToken {
        private let lock = NSLock()
        private var cancelled = false
        private var task: URLSessionTask?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = task
            lock.unlock()
            running?.cancel()
        }

        fileprivate func attach(_ task: URLSessionTask) {
            lock.lock()
            let alreadyCancelled = cancelled
            self.task = task
            lock.unlock()
            if alreadyCancelled { task.cancel() }
        }
    }

    // MARK: - 对外接口

    static func requireKey(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { throw Error.missingAPIKey }
    }

    static func checkCancelled(_ cancel: CancelToken?) throws {
        if cancel?.isCancelled == true { throw Error.cancelled }
    }

    /// 申请上传地址 → PUT 二进制 → 返回 `mediakit://…` 引用。
    ///
    /// 上传走的是预签名地址，`Authorization` 一律不带（带了反而容易 403）；
    /// 这里用独立的 URLRequest，不共享任何公共 header。
    static func upload(
        _ data: Data,
        apiKey: String,
        timeout: TimeInterval,
        cancel: CancelToken? = nil
    ) throws -> String {
        try checkCancelled(cancel)
        let slot = try postJSON(path: "/tools-sync/request-media-upload-url",
                                body: [:], apiKey: apiKey, timeout: timeout, cancel: cancel)
        guard let result = slot["result"] as? [String: Any],
              let fileID = result["file_id"] as? String,
              let uploadURL = result["upload_url"] as? String,
              let url = URL(string: uploadURL) else {
            throw Error.uploadSlotFailed(String(describing: slot).prefix(200).description)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (body, status) = try send(request, timeout: timeout, cancel: cancel)
        guard (200..<300).contains(status) else {
            throw Error.uploadRejected(status, String(data: body, encoding: .utf8) ?? "")
        }
        // file_id 有时自带 mediakit:// 前缀，重复加前缀会 403（FileIdDecryptFailed）——
        // 那时鉴权其实是通的，别去查 Key。
        return fileID.hasPrefix("mediakit://") ? fileID : "mediakit://\(fileID)"
    }

    /// 发一个 JSON POST，返回解析后的字典（业务成败交给 `verify` 判断）。
    static func postJSON(
        path: String,
        body: [String: Any],
        apiKey: String,
        timeout: TimeInterval,
        cancel: CancelToken? = nil
    ) throws -> [String: Any] {
        try checkCancelled(cancel)
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try send(request, timeout: timeout, cancel: cancel)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformedResponse
        }
        return json
    }

    /// 检查响应里的 `success` 字段，失败则带出服务端给的错误详情。
    static func verify(_ response: [String: Any]) throws {
        if response["success"] as? Bool == true { return }
        let error = response["error"] as? [String: Any]
        throw Error.serviceFailed(
            code: error?["code"] as? String ?? "Unknown",
            message: error?["message"] as? String ?? "未提供详情"
        )
    }

    /// 取回结果图（结果地址 24 小时过期，拿到就立刻下载）。
    static func download(
        imageURL urlString: String,
        timeout: TimeInterval,
        cancel: CancelToken? = nil
    ) throws -> CGImage {
        try checkCancelled(cancel)
        guard let url = URL(string: urlString) else { throw Error.malformedResponse }
        let (data, status) = try send(URLRequest(url: url), timeout: timeout, cancel: cancel)
        guard (200..<300).contains(status), !data.isEmpty else {
            throw Error.downloadFailed("HTTP \(status)")
        }
        try checkCancelled(cancel)
        guard let image = decodeImage(data) else { throw Error.malformedResponse }
        return image
    }

    static func checkSize(_ bytes: Int, limit: Int) throws {
        if bytes > limit { throw Error.tooLarge(bytes: bytes, limit: limit) }
    }

    /// 同步发一个请求。只能在后台线程调用。
    static func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        cancel: CancelToken? = nil
    ) throws -> (Data, Int) {
        try checkCancelled(cancel)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            semaphore.signal()
        }
        cancel?.attach(task)
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw Error.network("请求超时")
        }
        if cancel?.isCancelled == true { throw Error.cancelled }
        if let error = box.error {
            if (error as NSError).code == NSURLErrorCancelled { throw Error.cancelled }
            throw Error.network(error.localizedDescription)
        }
        return (box.data ?? Data(), box.status)
    }

    private final class ResponseBox {
        var data: Data?
        var status = 0
        var error: Swift.Error?
    }

    // MARK: - 位图工具

    static func encodePNG(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 把图重画到指定尺寸（factor 只缩小不放大，1 表示原样返回）。
    static func scaled(_ image: CGImage, by factor: CGFloat) throws -> CGImage {
        guard factor < 0.999 else { return image }
        return try scaled(image,
                          toWidth: max(10, Int((CGFloat(image.width) * factor).rounded())),
                          height: max(10, Int((CGFloat(image.height) * factor).rounded())))
    }

    static func scaled(_ image: CGImage, toWidth: Int, height: Int) throws -> CGImage {
        guard toWidth > 0, height > 0 else { throw Error.encodeFailed }
        guard let context = CGContext(
            data: nil, width: toWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Error.encodeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: toWidth, height: height))
        guard let output = context.makeImage() else { throw Error.encodeFailed }
        return output
    }

    /// 把任意 CGImage 归一化成已知的 RGBA 字节（`premultipliedLast`，每像素 4 字节，
    /// alpha 在 offset 3）。解码出来的 PNG 内部格式不固定，直接读 `dataProvider`
    /// 得先猜字节序；先重画一遍就统一了。
    static func rgbaBytes(_ image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw Error.encodeFailed }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Error.encodeFailed }
        return (pixels, width, height)
    }
}
