import CoreGraphics
import Foundation

/// 动图的一帧。内存里存的是**压缩态**：索引像素 + 局部调色板 + 停留时长，
/// 15 秒 24fps 的 700×400 录制约 10–20MB，播放时按需解出当前帧。
struct GifFrame {
    /// 索引像素，长度 = width × height。
    var indices: [UInt8]
    /// 0xRRGGBB，长度 = 1 << minCodeSize（不足补 0）。
    var palette: [UInt32]
    /// 2…8。
    var minCodeSize: Int
    /// 该帧停留时长（毫秒）。
    var delayMs: Int
    /// 这一帧上的标注（与普通页签同一套 `Annotation`，坐标是图像像素）。
    /// 只在内存里，导出 GIF / 存帧 / 存为页签时才烘进像素。
    var annotations: [Annotation] = []

    var colorCount: Int { 1 << minCodeSize }

    /// 索引 + 调色板 → 8 位索引色 CGImage（不解压、不做色彩转换，很快）。
    func makeImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, indices.count >= width * height else { return nil }
        let count = 1 << minCodeSize
        var table = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            let rgb = i < palette.count ? palette[i] : 0
            table[i * 3] = UInt8((rgb >> 16) & 0xFF)
            table[i * 3 + 1] = UInt8((rgb >> 8) & 0xFF)
            table[i * 3 + 2] = UInt8(rgb & 0xFF)
        }
        let space: CGColorSpace? = table.withUnsafeBufferPointer { buf in
            CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(),
                         last: count - 1,
                         colorTable: buf.baseAddress!)
        }
        guard let space else { return nil }
        let data = Data(indices.prefix(width * height))
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// 一段录好的动图（页签内数据）。所有尺寸都是**物理像素**。
final class GifAnimation {
    let width: Int
    let height: Int
    /// 导出文件是否写无限循环（GIF89a 的 NETSCAPE 块）。
    var loop: Bool
    private(set) var frames: [GifFrame]

    /// 解出来的帧只缓存最近几帧 —— 长时间录制全缓存会吃掉几百 MB。
    private var imageCache: [Int: CGImage] = [:]
    /// 带标注的合成图缓存（改标注 / 删帧时整体清掉）
    private var compositeCache: [Int: CGImage] = [:]
    private var thumbnailCache: [Int: CGImage] = [:]
    private let cacheQueue = DispatchQueue(label: "com.mimo.snipmagic.gif-cache")

    init(width: Int, height: Int, frames: [GifFrame], loop: Bool = true) {
        self.width = width
        self.height = height
        self.frames = frames
        self.loop = loop
    }

    var count: Int { frames.count }
    var pixelSize: CGSize { CGSize(width: width, height: height) }
    /// 一帧都没录到时仍能给出尺寸（= 录制区大小）。
    var durationMs: Int { frames.reduce(0) { $0 + $1.delayMs } }

    /// 只解出这一帧的像素（**不含**标注）。编辑当前帧时用它当画布底图，
    /// 否则标注会被烘进底图、再叠一次 = 画两遍。
    func rawImage(at index: Int) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        if let cached = imageCache[index] { return cached }
        guard let image = frames[index].makeImage(width: width, height: height) else { return nil }
        if imageCache.count >= 6 { imageCache.removeAll(keepingCapacity: true) }
        imageCache[index] = image
        return image
    }

    /// 这一帧最终长什么样（像素 + 标注）。预览、缩略图、存帧、存页签、导出 GIF 全用它。
    func image(at index: Int) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        if frames[index].annotations.isEmpty { return rawImage(at: index) }
        if let cached = compositeCache[index] { return cached }
        guard let base = rawImage(at: index),
              let composed = EditorTab.composite(baseImage: base, annotations: frames[index].annotations) else {
            return rawImage(at: index)
        }
        if compositeCache.count >= 8 { compositeCache.removeAll(keepingCapacity: true) }
        compositeCache[index] = composed
        return composed
    }

    /// 缩略图（尽量填满 cell，不裁切）。
    func thumbnail(at index: Int, cell: CGSize) -> CGImage? {
        guard frames.indices.contains(index), cell.width >= 1, cell.height >= 1 else { return nil }
        if let cached = thumbnailCache[index] { return cached }
        guard let full = image(at: index) else { return nil }

        let w = Int(cell.width.rounded())
        let h = Int(cell.height.rounded())
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        // 缩放比 = min(cell / 源)，保证完整显示、不裁切。
        let scale = min(CGFloat(w) / CGFloat(width), CGFloat(h) / CGFloat(height))
        let dw = CGFloat(width) * scale
        let dh = CGFloat(height) * scale
        ctx.draw(full, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
        guard let image = ctx.makeImage() else { return nil }
        if thumbnailCache.count >= 240 { thumbnailCache.removeAll(keepingCapacity: true) }
        thumbnailCache[index] = image
        return image
    }

    func invalidateCaches() {
        imageCache.removeAll(keepingCapacity: true)
        thumbnailCache.removeAll(keepingCapacity: true)
        compositeCache.removeAll(keepingCapacity: true)
    }

    // MARK: - 标注（每帧独立）

    func annotations(at index: Int) -> [Annotation] {
        guard frames.indices.contains(index) else { return [] }
        return frames[index].annotations
    }

    /// 用一张新像素替换某一帧（马赛克 / 魔法消除 / 定版这类"把改动烘进画面"的操作）。
    /// 停留时长和已有标注保持不变。
    func replaceFrameImage(at index: Int, with image: CGImage) {
        guard frames.indices.contains(index) else { return }
        guard let q = GifCodec.quantize(image: image, width: width, height: height) else { return }
        frames[index].indices = q.indices
        frames[index].palette = q.palette
        frames[index].minCodeSize = q.minCodeSize
        imageCache[index] = image
        compositeCache[index] = nil
        thumbnailCache[index] = nil
    }

    func setAnnotations(_ annotations: [Annotation], at index: Int) {
        guard frames.indices.contains(index) else { return }
        frames[index].annotations = annotations
        compositeCache[index] = nil
        thumbnailCache[index] = nil
    }

    /// 有没有哪一帧被标注过（导出时据此决定要不要重新量化）。
    var hasAnnotations: Bool { frames.contains { !$0.annotations.isEmpty } }

    // MARK: - 删帧

    /// 删除某一帧。至少保留 1 帧。
    @discardableResult
    func removeFrame(at index: Int) -> Bool {
        guard frames.count > 1, frames.indices.contains(index) else { return false }
        frames.remove(at: index)
        invalidateCaches()
        return true
    }

    /// 删除 index **左侧**的全部帧（index 这一帧变成第 0 帧）。
    @discardableResult
    func removeFrames(before index: Int) -> Bool {
        guard frames.count > 1, index > 0 else { return false }
        let cut = min(index, frames.count - 1)
        frames.removeFirst(cut)
        invalidateCaches()
        return true
    }

    /// 删除 index **右侧**的全部帧（index 这一帧变成最后一帧）。
    @discardableResult
    func removeFrames(after index: Int) -> Bool {
        guard frames.count > 1, index < frames.count - 1 else { return false }
        let cut = max(0, index)
        frames.removeSubrange((cut + 1)...)
        invalidateCaches()
        return true
    }

    /// 导出用：带标注的帧解码 → 叠标注 → 重新量化；没标注的帧原样返回（省时间）。
    func framesForExport() -> [GifFrame] {
        guard hasAnnotations else { return frames }
        return frames.enumerated().map { index, frame in
            guard !frame.annotations.isEmpty,
                  let composed = image(at: index),
                  let q = GifCodec.quantize(image: composed, width: width, height: height) else {
                return frame
            }
            return GifFrame(indices: q.indices, palette: q.palette,
                            minCodeSize: q.minCodeSize, delayMs: frame.delayMs)
        }
    }

    /// 全部帧的总像素（自检/日志用）。
    var totalPixels: Int { width * height * count }
}
