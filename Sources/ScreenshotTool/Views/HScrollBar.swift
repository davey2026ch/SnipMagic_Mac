import AppKit

/// 自绘的极细横向滚动条。用在页签条底部、缩略图条底部这些"系统滚动条太丑/太占地方"的位置。
///
/// 交互三种（与 Windows 版一致）：拖滑块、点轨道空白（跳一屏）、以及外部代码 `setOffset`。
/// 只在 `contentWidth > visibleWidth` 时显示，长度不够时完全不画。
final class HScrollBar: NSView {
    /// 内容总宽（像素/点，与 offset 同单位）。
    var contentWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    /// 可视宽。
    var visibleWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    private(set) var offset: CGFloat = 0
    /// 用户拖动/点轨道后的新偏移。**外部设置的 offset 不回调**（避免回环）。
    var onChange: ((CGFloat) -> Void)?

    var knobColor: NSColor = NSColor.labelColor.withAlphaComponent(0.45) {
        didSet { needsDisplay = true }
    }
    var trackColor: NSColor = NSColor.labelColor.withAlphaComponent(0.11) {
        didSet { needsDisplay = true }
    }

    var isNeeded: Bool { contentWidth > visibleWidth + 0.5 }
    private var maxOffset: CGFloat { max(0, contentWidth - visibleWidth) }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), maxOffset)
        guard clamped != offset else { return }
        offset = clamped
        needsDisplay = true
        alphaValue = isNeeded ? 1 : 0
    }

    private var knobWidth: CGFloat {
        guard isNeeded, bounds.width > 0 else { return 0 }
        return max(24, bounds.width * (visibleWidth / contentWidth))
    }

    private var knobRect: CGRect {
        let w = knobWidth
        let travel = max(0, bounds.width - w - 4)
        let x = 2 + (maxOffset > 0 ? travel * (offset / maxOffset) : 0)
        return CGRect(x: x, y: 2, width: w, height: max(2, bounds.height - 4))
    }

    /// 滚动条只有 7pt 高，太难点中。把命中区往**下**多给 3pt（下方只有发丝线，
    /// 不会抢别的控件的点击），拖动/点轨道就容易多了。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isNeeded, !isHidden, alphaValue > 0 else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        var area = bounds
        area.size.height += 3
        return area.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isNeeded, bounds.width > 2 else { return }
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 3, yRadius: 3)
        trackColor.setFill()
        track.fill()
        let knob = NSBezierPath(roundedRect: knobRect, xRadius: 3, yRadius: 3)
        knobColor.setFill()
        knob.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isNeeded else { return }
        let start = convert(event.locationInWindow, from: nil)
        let isOnKnob = knobRect.insetBy(dx: -2, dy: 0).contains(start)
        var lastX = start.x

        if !isOnKnob {
            // 点轨道：跳到让滑块以点击处为中心的位置，然后继续跟手拖。
            let target = start.x - knobWidth / 2
            let travel = max(1, bounds.width - knobWidth - 4)
            let newOffset = (target - 2) / travel * maxOffset
            setOffset(newOffset)
            onChange?(offset)
            lastX = start.x
        }

        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let p = convert(e.locationInWindow, from: nil)
            let dx = p.x - lastX
            lastX = p.x
            let travel = max(1, bounds.width - knobWidth - 4)
            let newOffset = offset + dx / travel * maxOffset
            setOffset(newOffset)
            onChange?(offset)
        }
    }
}
