import AppKit

/// 设置面板里的「透明」复选框。
///
/// 为什么不用系统 `NSButton(checkboxWithTitle:)`：系统复选框在暗色下**未选中态带一块浅灰填充**，
/// 放在深色面板上像贴了个亮色方块；开关同理（圆点接近纯白）。这里改成：
/// - 未选中：只画 1.2pt 细边框，**不填任何底色**（就是"透明"）；
/// - 选中：填主题色 + 白色对勾；
/// - 文字用 `labelColor`，跟随深浅色自动变。
final class FlatCheckbox: NSButton {
    private let boxSide: CGFloat = 14
    private let gap: CGFloat = 6

    init(title: String, checked: Bool) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.toggle)
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12)
        state = checked ? .on : .off
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 12)])
        return NSSize(width: boxSide + gap + ceil(size.width) + 2, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 故意不调用 super：系统绘制会带底色。
        let box = NSRect(
            x: 0.5,
            y: ((bounds.height - boxSide) / 2).rounded() + 0.5,
            width: boxSide - 1,
            height: boxSide - 1
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)

        if state == .on {
            Theme.accent.setFill()
            path.fill()

            // ⚠️ NSButton 的坐标系是**向下**的（y 越大越靠下）：
            // 对勾的折点要放在框的偏下位置，否则会画成一个倒过来的 "^"。
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + 3.4, y: box.midY - 0.6))
            tick.line(to: NSPoint(x: box.midX - 0.4, y: box.maxY - 3.8))
            tick.line(to: NSPoint(x: box.maxX - 3.0, y: box.minY + 3.6))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            // 只有描边，没有任何填充 —— 深色面板上不会再出现亮块。
            (isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: NSPoint(x: boxSide + gap, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }
}
