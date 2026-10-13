import AppKit

/// 「当前颜色」预览长条。
///
/// 不只是铺一层色块：**半透明时要能看见底下透出的棋盘格**，否则用户根本分不出
/// "透明度 100" 和 "透明度 30" 在视觉上的区别。
final class AlphaColorPreviewView: NSView {
    var color: NSColor = .white {
        didSet { needsDisplay = true }
    }

    /// 棋盘格边长（点）。
    private let checkSize: CGFloat = 8

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let corner: CGFloat = 4
        let clip = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        // 棋盘格底纹
        let light = CheckerboardColors.light
        let dark = CheckerboardColors.dark
        light.setFill()
        rect.fill()
        dark.setFill()
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var col = 0
            var x = rect.minX
            while x < rect.maxX {
                if (row + col) % 2 == 1 {
                    NSRect(x: x, y: y, width: checkSize, height: checkSize).fill()
                }
                x += checkSize
                col += 1
            }
            y += checkSize
            row += 1
        }

        // 当前色（可能带透明度）
        color.setFill()
        rect.fill()

        NSGraphicsContext.restoreGraphicsState()

        // 描边：浅色主题下白/近白色块需要它才认得出边界。
        NSColor.separatorColor.setStroke()
        clip.lineWidth = 1
        clip.stroke()
    }
}
