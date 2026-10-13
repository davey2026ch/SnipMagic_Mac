import AppKit

/// 「全屏取色」的吸管图标按钮。
///
/// 造型（照参考图）：整体 45° 斜置，**吸嘴朝左下、胶头朝右上**；
/// 细长管身是描边风格、两端圆头；顶端贴一个实心圆角胶头，根部一道小横杆
/// （比胶头略宽，两侧各露一点，像手指挡片）。单色绘制、无高光、无渐变，
/// 颜色跟主题走（浅色用深灰墨色，深色用浅灰）。
///
/// 用自绘而不是 SF Symbol，是因为系统那套符号里没有"胶头 + 挡片"的吸管；
/// 自绘还能随主题取墨色，不必准备两套位图。
final class EyedropperButton: NSButton {
    /// 鼠标悬停时的淡底衬，跟侧栏工具按钮同一套观感。
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        toolTip = "全屏取色（吸管）"
        setAccessibilityLabel("全屏取色（吸管）")
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 26) }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            let bg = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: Theme.cornerRadius - 2,
                yRadius: Theme.cornerRadius - 2
            )
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            bg.fill()
        }

        // 24 × 24 的设计盒，等比缩放进按钮后居中。
        // ⚠️ NSButton 是 **flipped**（y 向下），而设计稿是按"y 向上"写的 ——
        // 落笔前把 y 翻一次，否则画出来整个上下颠倒（吸嘴跑到右上、胶头跑到左下）。
        let side = min(bounds.width, bounds.height)
        let scale = side / 24.0
        let dx = (bounds.width - side) / 2
        let dy = (bounds.height - side) / 2
        let designSide: CGFloat = 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: dx + x * scale, y: dy + (designSide - y) * scale)
        }

        // 墨色：跟主题走，且是动态系统色，切主题后自动重解。
        let ink = NSColor.labelColor
        ink.setStroke()
        ink.setFill()

        // 设计稿方向：吸嘴在左下、胶头在右上，所以基准方向指向右上。
        let u = NSPoint(x: 0.7071, y: 0.7071)
        let perp = NSPoint(x: -u.y, y: u.x)

        // 管身：细长描边、两端圆头。
        let tube = NSBezierPath()
        tube.move(to: pt(4.8, 4.8))
        tube.line(to: pt(14.2, 14.2))
        tube.lineWidth = 2.6 * scale
        tube.lineCapStyle = .round
        tube.stroke()

        // 小横杆（挡片）：垂直于管身，两侧各露出一点。
        let barHalf = 4.4
        let barCenter = NSPoint(x: 14.2, y: 14.2)
        let bar = NSBezierPath()
        bar.move(to: pt(barCenter.x + perp.x * barHalf, barCenter.y + perp.y * barHalf))
        bar.line(to: pt(barCenter.x - perp.x * barHalf, barCenter.y - perp.y * barHalf))
        bar.lineWidth = 1.7 * scale
        bar.lineCapStyle = .round
        bar.stroke()

        // 实心圆角胶头：直径约为管身的 2 倍。
        let bulbR = 3.1 * scale
        let bulbCenter = pt(16.7, 16.7)
        let bulb = NSBezierPath(ovalIn: NSRect(
            x: bulbCenter.x - bulbR,
            y: bulbCenter.y - bulbR,
            width: bulbR * 2,
            height: bulbR * 2
        ))
        bulb.fill()
    }

    override func mouseDown(with event: NSEvent) {
        isHovering = false
        super.mouseDown(with: event)
    }
}
