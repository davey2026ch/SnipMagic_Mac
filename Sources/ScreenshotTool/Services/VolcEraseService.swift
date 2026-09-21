import AppKit
import Foundation

/// 魔法消除 —— 走火山引擎 AI MediaKit 的图像擦除修复。
///
/// 把擦除与重建交给云端的图像修复模型：相比自己写 inpaint，它能真正把背景的
/// 纹理和结构重建出来（渐变、丝线、字母轮廓都能还原），代价是图片会上传到
/// 火山引擎、需要 API Key、且依赖网络。
///
/// HTTP 链路（预签名上传 → 工具接口 → 取回结果）都在 `MediaKitClient` 里，
/// 与「提取矢量图」共用一份；这里只管擦除业务本身。
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

    /// 「魔法消除」自己的前置校验错误（选区类）。
    /// 链路错误统一用 `MediaKitClient.Error`。
    enum EraseError: LocalizedError {
        case noSelection

        var errorDescription: String? {
            "请先框选区域，或用刷子涂出要擦掉的范围。"
        }
    }

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
        let plan = try prepare(image: image, area: region, options: options)
        return try run(
            image: image, plan: plan, apiKey: apiKey, options: options,
            maskSource: nil, onStage: onStage
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
        guard mask.count == image.width * image.height else { throw MediaKitClient.Error.encodeFailed }
        guard let area = maskBounds(mask, width: image.width, height: image.height) else {
            throw MediaKitClient.Error.encodeFailed
        }
        let plan = try prepare(image: image, area: area, options: options)
        return try run(
            image: image, plan: plan, apiKey: apiKey, options: options,
            maskSource: mask, onStage: onStage
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

    private static func prepare(image: CGImage, area: CGRect, options: Options) throws -> Plan {
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let margin = CGFloat(options.context)
        let scope = area.integral
            .insetBy(dx: -margin, dy: -margin)
            .integral
            .intersection(imageBounds)
        guard scope.width >= 4, scope.height >= 4 else { throw MediaKitClient.Error.encodeFailed }

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
        onStage: ((Stage) -> Void)?
    ) throws -> CGImage {
        try MediaKitClient.requireKey(apiKey)

        // 局部裁剪，并按服务端分辨率上限等比缩放
        guard let patch = image.cropping(to: plan.scope) else { throw MediaKitClient.Error.encodeFailed }
        let scale = min(1.0, min(options.maxWidth / CGFloat(patch.width),
                                 options.maxHeight / CGFloat(patch.height)))
        let working = try MediaKitClient.scaled(patch, by: scale)

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
        guard let imagePNG = MediaKitClient.encodePNG(working) else {
            throw MediaKitClient.Error.encodeFailed
        }
        try MediaKitClient.checkSize(imagePNG.count, limit: options.maxBytes)
        let imageRef = try MediaKitClient.upload(imagePNG, apiKey: apiKey, timeout: options.timeout)

        // ② 上传遮罩（如果有）
        var maskRef: String?
        if let localMask {
            onStage?(.uploadingMask)
            guard let maskPNG = encodeMaskPNG(localMask) else {
                throw MediaKitClient.Error.encodeFailed
            }
            try MediaKitClient.checkSize(maskPNG.count, limit: options.maxBytes)
            maskRef = try MediaKitClient.upload(maskPNG, apiKey: apiKey, timeout: options.timeout)
        }

        // ③ 提交擦除任务
        onStage?(.erasing)
        var body: [String: Any] = [
            "image_url": imageRef,
            "standard_scene": "selected_area_erase",
            "output_format": options.outputFormat,
        ]
        if let maskRef {
            body["mask_url"] = maskRef
        } else if let normalized = plan.normalizedArea {
            body["selected_area"] = normalized
        }

        let response = try MediaKitClient.postJSON(path: "/tools-sync/erase-image", body: body,
                                                   apiKey: apiKey, timeout: options.timeout)
        try MediaKitClient.verify(response)

        guard let result = response["result"] as? [String: Any],
              let urlString = result["image_url"] as? String else {
            throw MediaKitClient.Error.malformedResponse
        }

        // ④ 取回结果
        onStage?(.downloading)
        let resultImage = try MediaKitClient.download(imageURL: urlString, timeout: options.timeout)

        // ⑤ 缩放回局部尺寸 → 贴回原图原位
        let restored = try MediaKitClient.scaled(resultImage, toWidth: Int(plan.scope.width),
                                                 height: Int(plan.scope.height))
        return try compose(base: image, patch: restored, at: plan.scope)
    }

    // MARK: - 遮罩工具

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

    /// 把处理好的局部贴回原图。矩形坐标是左上原点，这里转成 CG 的下原点。
    private static func compose(base: CGImage, patch: CGImage, at rect: CGRect) throws -> CGImage {
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MediaKitClient.Error.encodeFailed }

        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(patch, in: CGRect(
            x: rect.minX,
            y: CGFloat(height) - rect.maxY,
            width: rect.width,
            height: rect.height
        ))
        guard let output = context.makeImage() else { throw MediaKitClient.Error.encodeFailed }
        return output
    }
}
