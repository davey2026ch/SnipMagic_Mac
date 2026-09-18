import AppKit

enum ToolKind: String, CaseIterable {
    case select
    /// 擦除刷：在画布上刷出「要抹掉的区域」，供「魔法消除」使用。
    /// 它不产生标注，只是给云端擦除画选区（比矩形框自由）。
    case eraseBrush
    case view
    case text
    case arrow
    case line
    case pen
    case rect
    case roundedRect
    case ellipse
    case solidRect
    case solidRoundedRect
    case solidEllipse
    case number

    var displayName: String {
        switch self {
        case .select: return "选择"
        case .eraseBrush: return "擦除刷（刷出要抹掉的区域）"
        case .view: return "查看"
        case .text: return "文本"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .pen: return "画笔"
        case .rect: return "矩形"
        case .roundedRect: return "圆角矩形"
        case .ellipse: return "椭圆"
        case .solidRect: return "实心矩形"
        case .solidRoundedRect: return "实心圆角"
        case .solidEllipse: return "实心椭圆"
        case .number: return "序号"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "square.dashed"
        case .eraseBrush: return "paintbrush.pointed"
        case .view: return "eye"
        case .text: return "textformat.alt"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "scribble.variable"
        case .rect: return "rectangle"
        case .roundedRect: return "app.dashed"
        case .ellipse: return "oval"
        case .solidRect: return "rectangle.fill"
        case .solidRoundedRect: return "app.fill"
        case .solidEllipse: return "oval.fill"
        case .number: return "1.circle.fill"
        }
    }

    /// Ultra-short label used when SF Symbol is unavailable.
    var shortLabel: String {
        switch self {
        case .select: return "选"
        case .eraseBrush: return "刷"
        case .view: return "看"
        case .text: return "T"
        case .arrow: return "↗"
        case .line: return "／"
        case .pen: return "笔"
        case .rect: return "□"
        case .roundedRect: return "▢"
        case .ellipse: return "○"
        case .solidRect: return "■"
        case .solidRoundedRect: return "▣"
        case .solidEllipse: return "●"
        case .number: return "①"
        }
    }
}

enum AnnotationKind {
    case arrow(start: CGPoint, end: CGPoint)
    case line(start: CGPoint, end: CGPoint)
    case pen(points: [CGPoint])
    case rect(rect: CGRect, rounded: Bool)
    case ellipse(rect: CGRect)
    case solidRect(rect: CGRect, rounded: Bool)
    case solidEllipse(rect: CGRect)
    case text(origin: CGPoint, content: String, fontSize: CGFloat, bold: Bool, opaqueBackground: Bool)
    case number(center: CGPoint, value: Int)
    case mosaic(rect: CGRect, cellSize: CGFloat, snapshot: CGImage)
    case pastedImage(origin: CGPoint, size: CGSize, image: CGImage)
}

final class Annotation {
    let id: UUID
    var kind: AnnotationKind
    var color: NSColor
    var lineWidth: CGFloat

    init(kind: AnnotationKind, color: NSColor, lineWidth: CGFloat) {
        self.id = UUID()
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    var boundingBox: CGRect {
        switch kind {
        case .arrow(let s, let e), .line(let s, let e):
            return CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                          width: abs(e.x - s.x), height: abs(e.y - s.y))
            .insetBy(dx: -lineWidth, dy: -lineWidth)
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() {
                box = box.union(CGRect(origin: p, size: .zero))
            }
            return box.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        case .rect(let r, _), .ellipse(let r), .solidRect(let r, _), .solidEllipse(let r), .mosaic(let r, _, _):
            return r.standardized.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .text(let origin, let content, let fontSize, let bold, _):
            let font: NSFont = bold ? .boldSystemFont(ofSize: fontSize) : .systemFont(ofSize: fontSize)
            let size = (content as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: origin, size: CGSize(width: size.width + 8, height: size.height + 8))
        case .number(let center, _):
            let r: CGFloat = 22
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        case .pastedImage(let origin, let size, _):
            return CGRect(origin: origin, size: size)
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        switch kind {
        case .arrow(let s, let e), .line(let s, let e):
            return distanceToSegment(point, s, e) <= max(lineWidth + 6, 10)
        case .pen(let points):
            guard points.count > 1 else { return false }
            for i in 0..<(points.count - 1) {
                if distanceToSegment(point, points[i], points[i + 1]) <= max(lineWidth + 6, 10) {
                    return true
                }
            }
            return false
        case .text, .number, .pastedImage:
            return boundingBox.insetBy(dx: -4, dy: -4).contains(point)
        default:
            return boundingBox.contains(point)
        }
    }

    func copyAnnotation() -> Annotation {
        let copy = Annotation(kind: kind, color: color, lineWidth: lineWidth)
        return copy
    }
}

private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x
    let aby = b.y - a.y
    let apx = p.x - a.x
    let apy = p.y - a.y
    let ab2 = abx * abx + aby * aby
    if ab2 < 0.0001 { return hypot(apx, apy) }
    var t = (apx * abx + apy * aby) / ab2
    t = max(0, min(1, t))
    let cx = a.x + abx * t
    let cy = a.y + aby * t
    return hypot(p.x - cx, p.y - cy)
}

struct EditorStyle {
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var mosaicCell: CGFloat = 10
    var numberValue: Int = 1
    var tool: ToolKind = .select
}

/// 一笔刷子涂抹：图像坐标的点串 + 落笔时使用的半径。
///
/// 它不产生标注，只是「魔法消除」要抹掉的区域，所以既不进 `annotations`，
/// 也没法跟着标注一起被画出来 —— 但它**必须进撤销快照**，否则刷错了退不回去。
struct EraseStroke {
    var points: [CGPoint]
    var radius: CGFloat
}

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
    case start, end
    case body
}
