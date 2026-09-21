import AppKit

/// Full editor state snapshot. Mosaic and paste-commit bake pixels directly
/// into the tab's base image, so undo must restore both layers — an
/// annotations-only snapshot makes mosaic undo appear to do nothing.
/// 刷子的涂抹痕迹既不是标注、也不改像素，同样得单独带上，否则刷错了退不回去。
struct EditorSnapshot {
    let annotations: [Annotation]
    let baseImage: CGImage
    let eraseStrokes: [EraseStroke]
}

final class UndoStack {
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private let limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Snapshot current state before a mutation.
    func push(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > limit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return prev
    }

    func redo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}

enum ClipboardService {
    /// 复制图片到剪贴板。**必须同时写 PNG 和传统位图两种格式**：
    /// - `public.png`：无损、带 alpha。微信 / Keynote / Pages / Word 优先读它 ——
    ///   「提取矢量图」抠出来的透明底主体就是靠这一份才贴进去还是透明的；
    /// - `public.tiff`：兜底。透明处**填白**：只认传统位图的老应用读不到 PNG
    ///   （粘贴是灰的），而它们直接收到带 alpha 的位图时，半透明会被算成黑块。
    static func writeImage(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()

        let item = NSPasteboardItem()
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let opaque = flattenedOnWhite(image),
           let tiff = NSBitmapImageRep(cgImage: opaque).representation(using: .tiff, properties: [:]) {
            item.setData(tiff, forType: .tiff)
        }

        // 两种格式都没拼出来时退回 NSImage，至少别让剪贴板空着。
        if item.types.isEmpty {
            pb.writeObjects([NSImage(cgImage: image,
                                     size: NSSize(width: image.width, height: image.height))])
        } else {
            pb.writeObjects([item])
        }
    }

    static func readImage() -> CGImage? {
        let pb = NSPasteboard.general
        // 先读 PNG：带 alpha。读 TIFF 那份白底兜底图，会把抠好的透明边填成白色
        // —— 应用内 ⌘C / ⌘V 搬运孤立主体时必须保住透明。
        if let data = pb.data(forType: .png),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        if let items = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = items.first {
            var rect = CGRect(origin: .zero, size: CGSize(width: img.size.width, height: img.size.height))
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    /// 透明处填白的副本（给只认传统位图的老应用兜底）。
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
