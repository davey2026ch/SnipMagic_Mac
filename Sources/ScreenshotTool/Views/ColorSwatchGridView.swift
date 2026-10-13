import AppKit

/// 取色面板右上角的「颜色格」：8 列 × 3 行 = 24 格。
///
/// 前 3 格是**固定常用色** 红 / 黑 / 白（永远不可被替换），第 3 格与第 4 格之间
/// 在第一行画一道淡竖线提示"前 3 格是固定的"；第 4 格起是「最近使用」，
/// 最多 21 个，最新用的排在最前，按从左到右、从上到下填，空格是浅色占位格。
///
/// 绘制与点击判定**共用同一个 `cellRect(_:)`** —— 否则很容易出现"看着点在格子上、
/// 实际点偏一格"。
final class ColorSwatchGridView: NSView {
    static let columns = 8
    static let rows = 3
    static let total = columns * rows

    var cellSide: CGFloat = 30
    var cellGap: CGFloat = 8

    /// 历史色（不含固定 3 色），最多 21 个。
    var recentColors: [NSColor] = [] {
        didSet { needsDisplay = true }
    }

    /// 当前颜色：与某一格 RGB 相同时，那一格用主题色描边高亮。
    var currentColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    /// 点中某格（只在格子有颜色时回调）。
    var onSelect: ((NSColor) -> Void)?

    private var hoverIndex: Int?
    private var hoverArea: NSTrackingArea?

    var gridSize: NSSize {
        NSSize(
            width: CGFloat(Self.columns) * cellSide + CGFloat(Self.columns - 1) * cellGap,
            height: CGFloat(Self.rows) * cellSide + CGFloat(Self.rows - 1) * cellGap
        )
    }

    override var intrinsicContentSize: NSSize { gridSize }

    /// 行号 0 在最上面（截图里的顺序），所以翻转坐标。
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 几何（绘制与命中判定共用）

    /// 第 `index` 格的矩形（局部坐标）。
    func cellRect(_ index: Int) -> NSRect {
        guard index >= 0, index < Self.total else { return .zero }
        let col = index % Self.columns
        let row = index / Self.columns
        return NSRect(
            x: CGFloat(col) * (cellSide + cellGap),
            y: CGFloat(row) * (cellSide + cellGap),
            width: cellSide,
            height: cellSide
        )
    }

    /// 命中哪一格（不在格子上返回 nil）。
    private func index(at point: NSPoint) -> Int? {
        for i in 0..<Self.total {
            if cellRect(i).insetBy(dx: -cellGap / 2, dy: -cellGap / 2).contains(point) {
                return i
            }
        }
        return nil
    }

    /// 第 `index` 格应有的颜色：固定色 → 历史色 → nil（空占位格）。
    private func color(at index: Int) -> NSColor? {
        let fixed = RecentColorStore.fixedColors
        if index < fixed.count { return fixed[index] }
        let i = index - fixed.count
        return i < recentColors.count ? recentColors[i] : nil
    }

    // MARK: - 交互

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let newIndex = index(at: p)
        if newIndex != hoverIndex {
            hoverIndex = newIndex
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil {
            hoverIndex = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p), let c = color(at: i) else { return }  // 空占位格点了不生效
        onSelect?(c)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let baseBorder = NSColor.separatorColor
        // 占位格：只是一层很淡的浅色，暗色下用 labelColor（白）自然就淡了。
        let placeholderFill = NSColor.labelColor.withAlphaComponent(0.08)
        let highlight = Theme.accent
        let currentHex = currentColor.hexRGB

        for i in 0..<Self.total {
            let r = cellRect(i)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            let swatch = color(at: i)

            if let swatch {
                swatch.setFill()
                path.fill()
            } else {
                placeholderFill.setFill()
                path.fill()
            }

            // 基础描边：白格 / 占位格在浅色背景上全靠它认边界。
            baseBorder.setStroke()
            path.lineWidth = 1
            path.stroke()

            // 当前色对应的格子 → 主题色高亮；悬停 → 稍细的描边提示。
            if let swatch, swatch.hexRGB == currentHex {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), xRadius: 4.5, yRadius: 4.5)
                highlight.setStroke()
                ring.lineWidth = 2
                ring.stroke()
            } else if hoverIndex == i {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), xRadius: 4.5, yRadius: 4.5)
                NSColor.labelColor.withAlphaComponent(0.45).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }

        // 第 3 格与第 4 格之间：只在第一行画一道淡竖线，提示"前 3 格是固定的"。
        // 刻意比格子边框稍重一点，否则和描边糊在一起看不出是一道"分界"。
        let third = cellRect(2)
        let fourth = cellRect(3)
        let divider = NSBezierPath()
        let x = (third.maxX + fourth.minX) / 2
        divider.move(to: NSPoint(x: x, y: third.minY))
        divider.line(to: NSPoint(x: x, y: third.maxY))
        divider.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        divider.stroke()
    }
}
