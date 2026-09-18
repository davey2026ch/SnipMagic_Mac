import AppKit
import Foundation

/// 魔法消除 —— 走火山引擎 AI MediaKit 的图像擦除修复。
///
/// 把擦除与重建交给云端的图像修复模型：相比自己写 inpaint，它能真正把背景的
/// 纹理和结构重建出来（渐变、丝线、字母轮廓都能还原），代价是图片会上传到
/// 火山引擎、需要 API Key、且依赖网络。
///
/// 本地图片没有公网地址，所以链路是三步：
///   1. `POST /tools-sync/request-media-upload-url` —— 申请 `file_id` 和带签名的上传地址
///   2. `PUT {upload_url}` —— 纯二进制上传（**不能用 multipart**）
///   3. `POST /tools-sync/erase-image` —— 用 `mediakit://{file_id}` 引用，拿回结果地址
///   4. 下载结果
///
/// 踩过的两个坑，别改回去：
/// - **遮罩图必须是三通道 RGB**。单通道灰度 PNG 会让服务端直接 500
///   （`fail to do image_delogo`），文档里没写。
/// - **遮罩必须完整盖住要擦的东西**。只盖一半的话，露出的一半会被当成"要保留的
///   内容"原样留下，看起来就是块状残影 —— 这不是算法波动，是输入本身的问题。
///
/// 这些方法都是同步阻塞的，调用方必须放在后台队列。
enum VolcEraseService {

    // MARK: - 参数

    struct Options {
        /// 选区外额外带上的上下文（像素）。给模型足够的背景参考。
        var context: Int = 48
        /// 单边上限。服务端硬限制是 2560×1440，超了就等比缩小再传。
        var maxWidth: CGFloat = 2560
        var maxHeight: CGFloat = 1440
        /// 单张图片的上传上限（服务端限制 10MB）。
        var maxBytes: Int = 10 * 1024 * 1024
        var timeout: TimeInterval = 120
        var outputFormat = "png"

        static let `default` = Options()
    }

    /// UI 上的阶段文案（在后台线程回调，调用方负责切主线程）。
    enum Stage: String {
        case uploadingImage = "正在上传图片…"
        case uploadingMask = "正在上传擦除范围…"
        case erasing = "云端重建中…"
        case downloading = "正在取回结果…"
    }

    enum EraseError: LocalizedError {
        case missingAPIKey
        case noSelection
        case encodeFailed
        case uploadSlotFailed(String)
        case uploadRejected(Int, String)
        case tooLarge(Int)
        case serviceFailed(code: String, message: String)
        case malformedResponse
        case downloadFailed(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "还没配置火山引擎 API Key。打开「设置」填入后再试，或改用本地的「魔法消除」。"
            case .noSelection:
                return "请先框选区域，或用刷子涂出要擦掉的范围。"
            case .encodeFailed:
                return "图片编码失败。"
            case .uploadSlotFailed(let detail):
                return "申请上传地址失败：\(detail)"
            case .uploadRejected(let status, let detail):
                return "上传被拒绝（HTTP \(status)）：\(detail)"
            case .tooLarge(let bytes):
                return "图片超过 10MB 上限（当前 \(bytes / 1024 / 1024)MB）。请缩小选区后重试。"
            case .serviceFailed(let code, let message):
                return "云端处理失败（\(code)）：\(message)"
            case .malformedResponse:
                return "云端返回的数据无法解析。"
            case .downloadFailed(let detail):
                return "结果下载失败：\(detail)"
            case .network(let detail):
                return "网络异常：\(detail)"
            }
        }
    }

    private static let baseURL = URL(string: "https://mediakit.cn-beijing.volces.com/api/v1")!

    // MARK: - 对外接口

    /// 擦除 `region` 圈定的矩形区域（图像坐标、左上原点）。
    ///
    /// 只把「选区 + 一圈上下文」上传，不传整图 —— 尺寸小、传得快，也基本不会
    /// 撞上服务端的 2560×1440 / 10MB 限制。处理完贴回原图对应位置。
    static func eraseRect(
        in image: CGImage,
        region: CGRect,
        apiKey: String,
        options: Options = .default,
        onStage: ((Stage) -> Void)? = nil
    ) throws -> CGImage {
        let plan = try prepare(image: image, area: region, apiKey: apiKey, options: options)
        return try run(
            image: image, plan: plan, apiKey: apiKey, options: options,
            maskSource: nil, scopeRect: region, onStage: onStage
        )
    }

    /// 擦除 `mask` 标记的任意形状区域。`mask` 与 `image` 同尺寸，非 0 像素表示要擦。
    static func eraseMask(
        in image: CGImage,
        mask: [UInt8],
        apiKey: String,
        options: Options = .default,
        onStage: ((Stage) -> Void)? = nil
    ) throws -> CGImage {
        guard mask.count == image.width * image.height else { throw EraseError.encodeFailed }
        guard let area = maskBounds(mask, width: image.width, height: image.height) else {
            throw EraseError.encodeFailed
        }
        let plan = try prepare(image: image, area: area, apiKey: apiKey, options: options)
        return try run(
            image: image, plan: plan, apiKey: apiKey, options: options,
            maskSource: mask, scopeRect: nil, onStage: onStage
        )
    }

    // MARK: - 内部

    /// 上传前的准备：算出要上传的局部范围，以及该范围内的擦除定义。
    private struct Plan {
        /// 要上传的局部区域（原图坐标）
        var scope: CGRect
        /// 矩形模式下：擦除框在局部图中的归一化坐标
        var normalizedArea: [String: Double]?
        /// 遮罩模式下：局部裁剪出来的遮罩位图
        var localMask: MaskBitmap?
    }

    private struct MaskBitmap {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    private static func prepare(image: CGImage, area: CGRect, apiKey: String, options: Options) throws -> Plan {
        guard !apiKey.isEmpty else { throw EraseError.missingAPIKey }

        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let margin = CGFloat(options.context)
        let scope = area.integral
            .insetBy(dx: -margin, dy: -margin)
            .integral
            .intersection(imageBounds)
        guard scope.width >= 4, scope.height >= 4 else { throw EraseError.encodeFailed }

        // 归一化是相对「上传出去的那张局部图」而言的，必须先减去 scope 原点，
        // 否则算出来的比例会大于 1（服务端会直接拒绝）。
        let local = area.integral.intersection(scope)
        let normalized: [String: Double] = [
            "top_left_x": Double((local.minX - scope.minX) / scope.width),
            "top_left_y": Double((local.minY - scope.minY) / scope.height),
            "bottom_right_x": Double((local.maxX - scope.minX) / scope.width),
            "bottom_right_y": Double((local.maxY - scope.minY) / scope.height),
        ]
        return Plan(scope: scope, normalizedArea: normalized, localMask: nil)
    }

    private static func run(
        image: CGImage,
        plan: Plan,
        apiKey: String,
        options: Options,
        maskSource: [UInt8]?,
        scopeRect: CGRect?,
        onStage: ((Stage) -> Void)?
    ) throws -> CGImage {
        // 局部裁剪，并按服务端分辨率上限等比缩放
        guard let patch = image.cropping(to: plan.scope) else { throw EraseError.encodeFailed }
        let scale = min(1.0, min(options.maxWidth / CGFloat(patch.width),
                                 options.maxHeight / CGFloat(patch.height)))
        let working = try scaled(patch, by: scale)

        // 遮罩模式下，把整图遮罩裁成局部并同步缩放
        var localMask: MaskBitmap?
        if let maskSource {
            let cropped = cropMask(maskSource, width: image.width, height: image.height, to: plan.scope)
            localMask = scale > 0.999
                ? cropped
                : MaskBitmap(pixels: resampleMask(cropped, factor: scale),
                             width: max(1, Int((CGFloat(cropped.width) * scale).rounded())),
                             height: max(1, Int((CGFloat(cropped.height) * scale).rounded())))
        }

        // ① 上传原图局部
        onStage?(.uploadingImage)
        guard let imagePNG = encodePNG(working) else { throw EraseError.encodeFailed }
        try checkSize(imagePNG.count, limit: options.maxBytes)
        let imageID = try upload(imagePNG, contentType: "image/png",
                                 apiKey: apiKey, timeout: options.timeout)

        // ② 上传遮罩（如果有）
        var maskID: String?
        if let localMask {
            onStage?(.uploadingMask)
            guard let maskPNG = encodeMaskPNG(localMask) else { throw EraseError.encodeFailed }
            try checkSize(maskPNG.count, limit: options.maxBytes)
            maskID = try upload(maskPNG, contentType: "image/png",
                                apiKey: apiKey, timeout: options.timeout)
        }

        // ③ 提交擦除任务
        onStage?(.erasing)
        var body: [String: Any] = [
            "image_url": imageID,
            "standard_scene": "selected_area_erase",
            "output_format": options.outputFormat,
        ]
        if let maskID {
            body["mask_url"] = maskID
        } else if let normalized = plan.normalizedArea {
            body["selected_area"] = normalized
        }

        let response = try postJSON(path: "/tools-sync/erase-image", body: body,
                                    apiKey: apiKey, timeout: options.timeout)
        try verify(response)

        guard let result = response["result"] as? [String: Any],
              let urlString = result["image_url"] as? String,
              let resultURL = URL(string: urlString) else { throw EraseError.malformedResponse }

        // ④ 取回结果
        onStage?(.downloading)
        let (data, status) = try send(URLRequest(url: resultURL), timeout: options.timeout)
        guard (200..<300).contains(status), !data.isEmpty else {
            throw EraseError.downloadFailed("HTTP \(status)")
        }
        guard let resultImage = decodeImage(data) else { throw EraseError.malformedResponse }

        // ⑤ 缩放回局部尺寸 → 贴回原图原位
        let restored = try scaled(resultImage, toWidth: Int(plan.scope.width),
                                  height: Int(plan.scope.height))
        return try compose(base: image, patch: restored, at: plan.scope)
    }

    // MARK: - HTTP

    private static func checkSize(_ bytes: Int, limit: Int) throws {
        if bytes > limit { throw EraseError.tooLarge(bytes) }
    }

    /// 申请上传地址 → PUT 二进制 → 返回 `mediakit://…` 引用。
    private static func upload(
        _ data: Data,
        contentType: String,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> String {
        let slot = try postJSON(path: "/tools-sync/request-media-upload-url",
                                body: [:], apiKey: apiKey, timeout: timeout)
        guard let result = slot["result"] as? [String: Any],
              let fileID = result["file_id"] as? String,
              let uploadURL = result["upload_url"] as? String,
              let url = URL(string: uploadURL) else {
            throw EraseError.uploadSlotFailed(String(describing: slot).prefix(200).description)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (body, status) = try send(request, timeout: timeout)
        guard (200..<300).contains(status) else {
            throw EraseError.uploadRejected(status, String(data: body, encoding: .utf8) ?? "")
        }
        return fileID
    }

    private static func postJSON(
        path: String,
        body: [String: Any],
        apiKey: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try send(request, timeout: timeout)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EraseError.malformedResponse
        }
        // 业务失败也走 HTTP 200 之外的形态，这里统一交给 verify 判断，所以先原样返回
        return json
    }

    /// 检查响应中的 `success` 字段，失败则抛出服务端给的错误详情。
    private static func verify(_ response: [String: Any]) throws {
        if response["success"] as? Bool == true { return }
        let error = response["error"] as? [String: Any]
        throw EraseError.serviceFailed(
            code: error?["code"] as? String ?? "Unknown",
            message: error?["message"] as? String ?? "未提供详情"
        )
    }

    /// 同步发一个请求。只能在后台线程调用。
    private static func send(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            throw EraseError.network("请求超时")
        }
        if let error = box.error { throw EraseError.network(error.localizedDescription) }
        return (box.data ?? Data(), box.status)
    }

    private final class ResponseBox {
        var data: Data?
        var status = 0
        var error: Error?
    }

    // MARK: - 位图工具

    private static func encodePNG(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// 编码遮罩 PNG。**必须三通道 RGB**，单通道灰度会被服务端拒绝。
    private static func encodeMaskPNG(_ mask: MaskBitmap) -> Data? {
        let width = mask.width
        let height = mask.height
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24
        ), let destination = rep.bitmapData else { return nil }

        for index in 0..<(width * height) {
            let value: UInt8 = mask.pixels[index] > 127 ? 255 : 0
            destination[index * 3] = value
            destination[index * 3 + 1] = value
            destination[index * 3 + 2] = value
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 从 RGBA 位图里裁出局部遮罩。
    private static func cropMask(_ mask: [UInt8], width: Int, height: Int, to rect: CGRect) -> MaskBitmap {
        let x0 = max(0, Int(rect.minX))
        let y0 = max(0, Int(rect.minY))
        let w = min(width - x0, Int(rect.width))
        let h = min(height - y0, Int(rect.height))
        var output = [UInt8](repeating: 0, count: max(1, w * h))
        guard w > 0, h > 0 else { return MaskBitmap(pixels: output, width: 1, height: 1) }

        for y in 0..<h {
            let sourceRow = (y0 + y) * width + x0
            let targetRow = y * w
            for x in 0..<w { output[targetRow + x] = mask[sourceRow + x] }
        }
        return MaskBitmap(pixels: output, width: w, height: h)
    }

    /// 最近邻重采样遮罩。
    private static func resampleMask(_ mask: MaskBitmap, factor: CGFloat) -> [UInt8] {
        let width = max(1, Int((CGFloat(mask.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(mask.height) * factor).rounded()))
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = min(mask.height - 1, Int(CGFloat(y) / factor))
            for x in 0..<width {
                let sourceX = min(mask.width - 1, Int(CGFloat(x) / factor))
                output[y * width + x] = mask.pixels[sourceY * mask.width + sourceX]
            }
        }
        return output
    }

    private static func maskBounds(_ mask: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] > 127 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func scaled(_ image: CGImage, by factor: CGFloat) throws -> CGImage {
        guard factor < 0.999 else { return image }
        return try scaled(image,
                          toWidth: max(10, Int((CGFloat(image.width) * factor).rounded())),
                          height: max(10, Int((CGFloat(image.height) * factor).rounded())))
    }

    private static func scaled(_ image: CGImage, toWidth: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: toWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EraseError.encodeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: toWidth, height: height))
        guard let output = context.makeImage() else { throw EraseError.encodeFailed }
        return output
    }

    /// 把处理好的局部贴回原图。矩形坐标是左上原点，这里转成 CG 的下原点。
    private static func compose(base: CGImage, patch: CGImage, at rect: CGRect) throws -> CGImage {
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EraseError.encodeFailed }

        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(patch, in: CGRect(
            x: rect.minX,
            y: CGFloat(height) - rect.maxY,
            width: rect.width,
            height: rect.height
        ))
        guard let output = context.makeImage() else { throw EraseError.encodeFailed }
        return output
    }
}
