import AppKit
import Foundation

/// 提取矢量图 —— 走火山引擎 AI MediaKit 的抠图（去背景）能力。
///
/// 用途：把截图里的一小块主体（图标 / 人像 / 商品 / 手绘元素）从背景里"抠"出来，
/// 变成透明底的图层放回画布 —— 可以直接拖动、缩放、复制到别的软件（微信、
/// Keynote、Pages、Word），因为它带的是真 alpha，不是白底方块。
///
/// 链路与「魔法消除」同源（同一把 Key、同一套预签名上传），只换最后调的工具接口：
///   `POST /tools-sync/remove-image-background`
///   body: `{"image_url": "mediakit://<file_id>", "scene": "general", "output_format": "png"}`
///
/// 三个关键设计，别改坏：
/// - **送出去的必须是"所见"的合成图局部**（底图 + 浮动图层），不是底层位图，
///   否则浮动图层里的主体抠不出来。唯一的例外是"选中的浮动图层"这一种输入：
///   它本来就只有自己那一块，直接送图层自身像素（并靠 `anchor` 把坐标平移回画布）。
/// - **选区外扩 16px 上下文**只为了帮模型看清主体边缘；结果只取主体区域，
///   外扩不影响定位（定位靠 alpha 包围盒）。
/// - **`need_crop_background` 绝不开**：它会把结果图裁成主体大小，几何对齐就没了，
///   主体在画布上的位置就算不出来。同理 `need_contour` 也不要。
/// - 几何对齐的前提是"火山默认不裁剪输出"：结果图与我们送出去的图同尺寸、一一对应。
///   万一版本变了导致尺寸不一致，这里按比例映射回去做防御。
///
/// 这些都是同步阻塞的，调用方必须放在后台队列。
enum VolcMattingService {

    // MARK: - 参数

    struct Options {
        /// 选区外额外带上的上下文（像素）。给模型足够的背景参考，帮它认清主体边缘。
        var context: Int = 16
        /// 选区最小边长（像素）。太小接口认不出主体，本地先拦掉，省一次调用。
        var minSelectionSide: CGFloat = 10
        /// 上送前按服务端限制等比缩小（general 场景：长边 ≤10240、短边 ≤6000、总像素 ≤40MP）。
        var maxLongEdge: CGFloat = 10240
        var maxShortEdge: CGFloat = 6000
        var maxPixels: CGFloat = 40_000_000
        /// 单张图片上传上限（服务端 30MB）。
        var maxBytes: Int = 30 * 1024 * 1024
        var timeout: TimeInterval = 180
        var outputFormat = "png"
        /// alpha 高于它才算不透明。
        var alphaThreshold: UInt8 = 8
        /// 不透明像素占比低于它 → 这个场景没认出主体，换下一个场景重试。
        var coverageFloor: Double = 0.002
        /// 不透明像素占比高于它、且包围盒铺满整张 → 恒等于原图（背景没被去掉），
        /// 同样算这个场景没成，换下一个。
        var opaqueCeiling: Double = 0.999
        /// 依次尝试的场景：通用 → 人像 → 商品。
        var scenes: [String] = ["general", "human", "product"]
        /// 落图层时相对原位置错开的量（图像坐标、左上原点，所以负 x/负 y = 往左上）。
        ///
        /// 别设成 `.zero`：新图层如果精确盖在原主体上，看起来跟没生效一样。
        /// 往左上错开几像素，配上选中框的蓝边，一眼就能看出"这块是新抠出来的"。
        /// 哪个轴贴边就自动翻向（见 `placement`），保证能错开就错开。
        var layerOffset = CGPoint(x: -8, y: -8)

        static let `default` = Options()
    }

    /// UI 上的阶段文案（在后台线程回调，调用方负责切主线程）。
    enum Stage: String {
        case uploading = "正在上传图片…"
        case removing = "云端抠图中…"
        case retrying = "换个识别场景重试…"
        case downloading = "正在取回结果…"
    }

    enum MattingError: LocalizedError {
        case noSelection
        case selectionTooSmall(width: Int, height: Int)
        case noSubjectFound(tried: [String])
        case targetChanged

        var errorDescription: String? {
            switch self {
            case .noSelection:
                return "请先框选要抠出的主体（也可以用「框选」工具选中一个浮动图层）。"
            case .selectionTooSmall(let width, let height):
                return "选区太小了（当前 \(width) × \(height) 像素）。请把主体框完整些，至少 10 × 10 像素。"
            case .noSubjectFound(let tried):
                let names = tried.map { VolcMattingService.sceneLabel($0) }.joined(separator: "、")
                return """
                云端没能从这块选区里认出可分离的主体（已依次试过：\(names)）。
                可以试试：把主体连同一圈背景一起框进来、或换个主体更完整的区域重框。
                """
            case .targetChanged:
                return "处理期间切换了页签，结果已丢弃。请在当前页签上重新框选。"
            }
        }
    }

    /// 抠出来的主体。
    struct Subject {
        /// 裁掉透明边后的主体图（真 alpha）。
        var image: CGImage
        /// 主体左上角在画布图像坐标（左上原点）里的位置（已经算进"错开摆放"）。
        var origin: CGPoint
        /// 主体在画布上的显示尺寸。上送时若缩过图，这里已按比例映射回原尺寸。
        var size: CGSize
        /// 实际用的错开量（可能因为贴边被翻向、或被夹回 0）。用于给用户一句准确的反馈。
        var offset: CGPoint
        /// 实际命中的场景（general / human / product）。
        var scene: String
        /// 不透明像素占比（诊断用）。
        var coverage: Double
    }

    static func sceneLabel(_ scene: String) -> String {
        switch scene {
        case "general": return "通用"
        case "human": return "人像"
        case "product": return "商品"
        default: return scene
        }
    }

    // MARK: - 对外接口

    /// 前置校验：只查本地输入（有没有选区、够不够大）。
    /// UI 在弹进度浮窗**之前**先调一次 —— 不满足条件就不该白等一场。
    static func validate(region: CGRect, options: Options = .default) throws {
        let selection = region.standardized.integral
        guard selection.width > 0, selection.height > 0 else { throw MattingError.noSelection }
        guard selection.width >= options.minSelectionSide,
              selection.height >= options.minSelectionSide else {
            throw MattingError.selectionTooSmall(width: Int(selection.width),
                                                 height: Int(selection.height))
        }
    }

    /// 从 `image` 的 `region`（该图自身的左上原点坐标）里抠出主体。
    ///
    /// - Parameters:
    ///   - anchor: `image` 左上角在**画布**坐标里的位置。默认 `.zero`（image 即整张画布）。
    ///     上送"浮动图层自身像素"时传图层的落点，否则结果会被摆到画布左上角。
    ///   - canvasSize: 画布尺寸，供"错开摆放"夹边界用；nil 时按 `image` 尺寸算。
    /// - Returns: 主体图 + 它在画布上的位置（**没有透明边的干净图层**）。
    /// - Throws: `MattingError`（本地输入问题）或 `MediaKitClient.Error`（链路问题）。
    ///   接口级失败（网络 / 参数错）**不重试** —— 避免重复扣费，直接报错。
    static func extractSubject(
        in image: CGImage,
        region: CGRect,
        anchor: CGPoint = .zero,
        canvasSize: CGSize? = nil,
        apiKey: String,
        options: Options = .default,
        cancel: MediaKitClient.CancelToken? = nil,
        onStage: ((Stage) -> Void)? = nil
    ) throws -> Subject {
        try MediaKitClient.requireKey(apiKey)
        try MediaKitClient.checkCancelled(cancel)

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let canvas = canvasSize ?? bounds.size
        let selection = region.standardized.integral.intersection(bounds)
        try validate(region: selection, options: options)

        // 上送的局部图 = 选区 + 一圈上下文，再 clamp 到图边界。
        let margin = CGFloat(options.context)
        let scope = selection.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds)
        guard scope.width >= 4, scope.height >= 4, let patch = image.cropping(to: scope) else {
            throw MediaKitClient.Error.encodeFailed
        }

        // 超限先等比缩小（一般用不上 —— 截图选区通常远小于限制）。
        let factor = uploadScale(width: patch.width, height: patch.height, options: options)
        let working = try MediaKitClient.scaled(patch, by: factor)
        guard let png = MediaKitClient.encodePNG(working) else {
            throw MediaKitClient.Error.encodeFailed
        }
        try MediaKitClient.checkSize(png.count, limit: options.maxBytes)

        onStage?(.uploading)
        let imageRef = try MediaKitClient.upload(png, apiKey: apiKey,
                                                 timeout: options.timeout, cancel: cancel)

        var tried: [String] = []
        for scene in options.scenes {
            tried.append(scene)
            if tried.count > 1 { onStage?(.retrying) }
            onStage?(.removing)

            let result = try removeBackground(imageRef: imageRef, scene: scene,
                                              apiKey: apiKey, options: options,
                                              cancel: cancel, onStage: onStage)

            guard let scan = try scanAlpha(result, threshold: options.alphaThreshold) else {
                continue                    // 整张全透明 → 这个场景没认出主体
            }
            // 整张几乎全不透明、包围盒铺满 → 等于原图返回，背景没去掉，也不算成。
            let full = scan.box.width >= CGFloat(scan.width) - 1 && scan.box.height >= CGFloat(scan.height) - 1
            if scan.coverage > options.opaqueCeiling && full { continue }
            guard scan.coverage >= options.coverageFloor else { continue }

            guard let subject = result.cropping(to: scan.box) else {
                throw MediaKitClient.Error.malformedResponse
            }
            // 结果尺寸与上送尺寸理论上一致（火山默认不裁剪输出）；不一致时按比例映射。
            let ratioX = scope.width / CGFloat(scan.width)
            let ratioY = scope.height / CGFloat(scan.height)
            let size = CGSize(width: scan.box.width * ratioX, height: scan.box.height * ratioY)
            // 先算上送图内部的落点，再加回这张图在画布上的位置（anchor）。
            let raw = CGPoint(x: anchor.x + scope.minX + scan.box.minX * ratioX,
                              y: anchor.y + scope.minY + scan.box.minY * ratioY)
            let placement = placement(for: size, at: raw,
                                      canvas: canvas, options: options)
            return Subject(image: subject, origin: placement.origin, size: size,
                           offset: placement.offset, scene: scene, coverage: scan.coverage)
        }
        throw MattingError.noSubjectFound(tried: tried)
    }

    // MARK: - 内部

    /// 算"错开摆放"的最终落点。
    ///
    /// - **图层比画布还大**（极端）→ 原样放：本来就没地方可挪，硬错开只会把主体推出画面。
    /// - 其余情况**两个轴各自决定方向**：默认往左上，哪个轴贴边（再往左上就出画布了）
    ///   那个轴就翻成往右下；最后再夹一次边界。
    ///
    /// 为什么不整份翻向（左上也放不下就一律改右下）：占满画布宽度的图层贴在底边时，
    /// 一律翻向会让两个轴都被夹回原处 —— 结果"一点都没错开"，正是要避免的那种"看起来没生效"。
    /// 分轴处理能保住能错开的那一轴。
    ///
    /// 返回值里的 `offset` 是**实际生效**的错开量 —— 被夹回时它可能小于 8 甚至为 0，
    /// 如实报给用户比报"我们想错开 8px"更靠谱。
    ///
    /// 非 private：离屏验证会直接调它 —— "图层比画布还大"实跑碰不到（主体必然小于等于画布），
    /// 只能单独验。
    static func placement(
        for size: CGSize,
        at raw: CGPoint,
        canvas: CGSize,
        options: Options
    ) -> (origin: CGPoint, offset: CGPoint) {
        guard size.width <= canvas.width, size.height <= canvas.height else {
            return (raw, .zero)
        }
        /// 单轴求解：先按默认方向，贴边就翻向，最后夹进 [0, 上限]。
        func resolve(preferred: CGFloat, raw: CGFloat, limit: CGFloat) -> CGFloat {
            var wanted = preferred
            if raw + wanted < 0 { wanted = -preferred }
            return max(0, min(raw + wanted, limit)) - raw
        }
        let dx = resolve(preferred: options.layerOffset.x, raw: raw.x, limit: canvas.width - size.width)
        let dy = resolve(preferred: options.layerOffset.y, raw: raw.y, limit: canvas.height - size.height)
        return (CGPoint(x: raw.x + dx, y: raw.y + dy), CGPoint(x: dx, y: dy))
    }

    private static func removeBackground(
        imageRef: String,
        scene: String,
        apiKey: String,
        options: Options,
        cancel: MediaKitClient.CancelToken?,
        onStage: ((Stage) -> Void)?
    ) throws -> CGImage {
        let response = try MediaKitClient.postJSON(
            path: "/tools-sync/remove-image-background",
            body: [
                "image_url": imageRef,
                "scene": scene,
                "output_format": options.outputFormat,
            ],
            apiKey: apiKey,
            timeout: options.timeout,
            cancel: cancel
        )
        try MediaKitClient.verify(response)
        guard let result = response["result"] as? [String: Any],
              let urlString = result["image_url"] as? String else {
            throw MediaKitClient.Error.malformedResponse
        }
        // 结果地址 24 小时过期，拿到就立刻下载。
        onStage?(.downloading)
        return try MediaKitClient.download(imageURL: urlString,
                                           timeout: options.timeout, cancel: cancel)
    }

    private static func uploadScale(width: Int, height: Int, options: Options) -> CGFloat {
        let long = CGFloat(max(width, height))
        let short = CGFloat(min(width, height))
        let pixels = CGFloat(width * height)
        var factor: CGFloat = 1
        if long > options.maxLongEdge { factor = min(factor, options.maxLongEdge / long) }
        if short > options.maxShortEdge { factor = min(factor, options.maxShortEdge / short) }
        if pixels > options.maxPixels { factor = min(factor, (options.maxPixels / pixels).squareRoot()) }
        return factor
    }

    /// 扫 alpha 求主体包围盒 + 不透明像素占比。整张全透明返回 nil。
    private static func scanAlpha(
        _ image: CGImage,
        threshold: UInt8
    ) throws -> (box: CGRect, coverage: Double, width: Int, height: Int)? {
        let (pixels, width, height) = try MediaKitClient.rgbaBytes(image)
        var minX = width, minY = height, maxX = -1, maxY = -1
        var opaque = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[(row + x) * 4 + 3] > threshold {
                opaque += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (box, Double(opaque) / Double(width * height), width, height)
    }
}
