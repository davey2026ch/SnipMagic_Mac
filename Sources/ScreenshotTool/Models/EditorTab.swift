import AppKit

final class EditorTab {
    let id: UUID
    private(set) var title: String
    var baseImage: CGImage
    var annotations: [Annotation]
    var isSaved: Bool
    var savedURL: URL?
    private(set) var sequence: Int

    init(sequence: Int, image: CGImage, title: String? = nil) {
        self.id = UUID()
        self.sequence = sequence
        self.title = title ?? "P\(sequence)"
        self.baseImage = image
        self.annotations = []
        self.isSaved = false
        self.savedURL = nil
    }

    var pixelSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    var displayTitle: String {
        title
    }

    var hasUnsavedChanges: Bool {
        !isSaved || !annotations.isEmpty && !isSaved
    }

    func markUnsaved() {
        isSaved = false
    }

    func markSaved(url: URL) {
        isSaved = true
        savedURL = url
        title = url.deletingPathExtension().lastPathComponent
    }

    func renameForSave(_ name: String, url: URL) {
        savedURL = url
        title = name
        isSaved = true
    }

    /// Flatten base image + annotations into a single CGImage at original pixel size.
    func renderComposite(includeCursorArea: Bool = true) -> CGImage? {
        let size = pixelSize
        guard size.width > 0, size.height > 0 else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw base image in unflipped CG coords (image top == bitmap top).
        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))

        // Bitmap annotations (paste / mosaic) must be drawn in unflipped space —
        // CGContext.draw after a y-flip would invert them.
        var vectorAnnotations: [Annotation] = []
        for ann in annotations {
            switch ann.kind {
            case .pastedImage(let origin, let imgSize, let image):
                let cgRect = CGRect(
                    x: origin.x,
                    y: size.height - origin.y - imgSize.height,
                    width: imgSize.width,
                    height: imgSize.height
                )
                ctx.interpolationQuality = .high
                ctx.draw(image, in: cgRect)
            case .mosaic(let rect, _, let snapshot):
                let r = rect.standardized
                let cgRect = CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
                ctx.interpolationQuality = .none
                ctx.draw(snapshot, in: cgRect)
            default:
                vectorAnnotations.append(ann)
            }
        }

        // Flip to top-left origin so vector annotation coordinates match the editor canvas.
        if !vectorAnnotations.isEmpty {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsctx
            for ann in vectorAnnotations {
                AnnotationRenderer.draw(ann, in: ctx, flipped: true)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        return ctx.makeImage()
    }

    func renderRegion(_ rect: CGRect) -> CGImage? {
        guard let full = renderComposite() else { return nil }
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        // CGImage.cropping uses top-left origin — matches annotation coords.
        return full.cropping(to: clamped)
    }
}

enum AnnotationRenderer {
    static func draw(_ ann: Annotation, in ctx: CGContext, flipped: Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        if flipped {
            // ctx already has top-left origin via caller's flip.
        }

        let color = ann.color
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch ann.kind {
        case .arrow(let start, let end):
            drawArrow(ctx: ctx, start: start, end: end, color: color, lineWidth: ann.lineWidth)
        case .line(let start, let end):
            ctx.beginPath()
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        case .pen(let points):
            guard let first = points.first else { break }
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()
        case .rect(let rect, let rounded):
            let path = rounded
                ? CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) * 0.15,
                         cornerHeight: min(rect.width, rect.height) * 0.15, transform: nil)
                : CGPath(rect: rect, transform: nil)
            ctx.addPath(path)
            ctx.strokePath()
        case .ellipse(let rect):
            ctx.strokeEllipse(in: rect)
        case .solidRect(let rect, let rounded):
            if rounded {
                let r = min(rect.width, rect.height) * 0.15
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            } else {
                ctx.fill(rect)
            }
        case .solidEllipse(let rect):
            ctx.fillEllipse(in: rect)
        case .text(let origin, let content, let fontSize, let bold, let opaqueBackground):
            let font: NSFont = bold ? .boldSystemFont(ofSize: fontSize) : .systemFont(ofSize: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let ns = content as NSString
            let size = ns.size(withAttributes: attrs)
            let drawRect = CGRect(x: origin.x, y: origin.y, width: size.width + 8, height: size.height + 8)
            if opaqueBackground {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(drawRect)
            }
            // Draw text via NSGraphicsContext for correct baseline handling.
            let point = CGPoint(x: origin.x + 4, y: origin.y + 4)
            ns.draw(at: point, withAttributes: attrs)
        case .number(let center, let value):
            let r: CGFloat = 22
            let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: circle)
            let text = "\(value)"
            let font = NSFont.boldSystemFont(ofSize: 20)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let ns = text as NSString
            let sz = ns.size(withAttributes: attrs)
            ns.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        case .mosaic(let rect, _, let snapshot):
            let imgRect = rect.standardized
            NSImage(cgImage: snapshot, size: imgRect.size).draw(in: imgRect)
        case .pastedImage(let origin, let size, let image):
            NSImage(cgImage: image, size: size).draw(in: CGRect(origin: origin, size: size))
        }
    }

    private static func drawArrow(ctx: CGContext, start: CGPoint, end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len
        let uy = dy / len

        // WeChat-style: thick round shaft + large solid triangular head.
        let shaft = max(lineWidth, 5)
        let headWidth = max(shaft * 2.6, 14)
        let headLength = max(shaft * 3.2, 18)

        let headBase = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let px = -uy
        let py = ux

        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Shaft
        ctx.setLineWidth(shaft)
        ctx.beginPath()
        ctx.move(to: start)
        ctx.addLine(to: headBase)
        ctx.strokePath()

        // Solid arrow head
        let left = CGPoint(x: headBase.x + px * headWidth / 2, y: headBase.y + py * headWidth / 2)
        let right = CGPoint(x: headBase.x - px * headWidth / 2, y: headBase.y - py * headWidth / 2)
        ctx.beginPath()
        ctx.move(to: end)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    static func numberString(_ value: Int) -> String {
        let circled = ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩",
                       "⑪","⑫","⑬","⑭","⑮","⑯","⑰","⑱","⑲","⑳"]
        if value >= 1 && value <= circled.count {
            return circled[value - 1]
        }
        return "\(value)"
    }
}
