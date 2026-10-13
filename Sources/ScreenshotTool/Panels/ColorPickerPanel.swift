import AppKit

/// 取色面板 —— **三处入口共用同一套**：左侧工具栏的颜色按钮、文字弹窗里的
/// 「文字颜色」、文字弹窗里的「背景颜色」。布局照参考图：
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │  ╭───────╮   最近使用                         │
/// │  │ 色轮  │   ▦▦▦│▦▦▦▦▦                        │
/// │  ╰───────╯   ▦▦▦▦▦▦▦▦                        │
/// │              ▦▦▦▦▦▦▦▦                        │
/// │              当前颜色                          │
/// │  ████████████████████████████████████████    │
/// │  明度 ──────────●───────────── [ 100 ]        │
/// │  R    ──────────●───────────── [ 255 ]        │
/// │  G / B / 透明度 …                             │
/// │  HEX  [ #FF0000            ] [吸管]           │
/// │                          [取消] [确定]        │
/// └──────────────────────────────────────────────┘
/// ```
///
/// 交互约定：面板里怎么调都只是改"当前颜色"，**点「确定」才应用**（并记入
/// 「最近使用」），点「取消」直接丢弃；只有吸管是"取完回到面板继续调"。
final class ColorPickerPanel: NSViewController, NSWindowDelegate {
    /// 版面尺寸。参考图客户区是 600×600（Windows），Mac 按同一套比例与层级换算：
    /// 色轮占宽约 1/3、颜色格边长 ≈ 面板宽的 1/18。
    private enum M {
        static let width: CGFloat = 540
        static let inset: CGFloat = 18
        static var innerWidth: CGFloat { width - inset * 2 }   // 504
        static let wheelSide: CGFloat = 186
        static let cellSide: CGFloat = 30
        static let cellGap: CGFloat = 8
        static let columnGap: CGFloat = 22       // 色轮 与 颜色格 之间的间距
        static let sectionGap: CGFloat = 14
        static let sliderRowHeight: CGFloat = 24
        static let labelWidth: CGFloat = 56
    }

    private let onPick: (NSColor) -> Void
    private var current: NSColor
    /// 历史色（`#RRGGBB`，不含固定 3 色），最新在前，最多 21 条。
    private var recentHexes: [String] = []
    private var onClose: (() -> Void)?

    private let wheel = ColorWheelView()
    private let grid = ColorSwatchGridView()
    private let preview = AlphaColorPreviewView()
    private let vSlider = NSSlider()
    private let rSlider = NSSlider()
    private let gSlider = NSSlider()
    private let bSlider = NSSlider()
    private let aSlider = NSSlider()
    private let vField = NSTextField()
    private let rField = NSTextField()
    private let gField = NSTextField()
    private let bField = NSTextField()
    private let aField = NSTextField()
    private let hexField = NSTextField()
    private var eyedropper: EyedropperButton!

    init(initial: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.current = initial
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // 显式铺主题底色：自绘的颜色格 / 图标 / 棋盘格全靠它才有稳定对比度
        // （暗色下别再指望"窗口底色碰巧是深的"）。
        let root = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: M.width, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.windowBackground.cgColor
        root.onAppearanceChange = { [weak root] in
            root?.layer?.backgroundColor = Theme.windowBackground.cgColor
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        recentHexes = RecentColorStore.load()
        build()
        syncUI(from: current)
        // 真实高度交给 Auto Layout 算，别手写常数（改一行版面就会对不上）。
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        preferredContentSize = size
        view.setFrameSize(size)
    }

    // MARK: - Build

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = M.sectionGap
        root.edgeInsets = NSEdgeInsets(top: M.inset, left: M.inset, bottom: M.inset, right: M.inset)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: M.width)
        ])

        // 行序 = 界面从上到下的顺序（色轮色格 → 当前色 → 明度 → RGB → 透明度 → HEX → 按钮）。
        let topRow = makeTopRow()
        let previewLabelRow = makePreviewLabelRow()
        let previewBar = makePreviewBar()
        let vRow = makeSliderRow("明度", vSlider, vField, max: 100, action: #selector(brightnessChanged))
        let rRow = makeSliderRow("R", rSlider, rField, max: 255)
        let gRow = makeSliderRow("G", gSlider, gField, max: 255)
        let bRow = makeSliderRow("B", bSlider, bField, max: 255)
        let aRow = makeSliderRow("透明度", aSlider, aField, max: 100)
        let hexRow = makeHexRow()
        let buttonRow = makeButtonRow()

        for row in [topRow, previewLabelRow, previewBar, vRow, rRow, gRow, bRow, aRow, hexRow, buttonRow] {
            root.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: M.innerWidth).isActive = true
        }
        // RGB 三个通道与「透明度」在视觉上分一段，别糊成一坨。
        root.setCustomSpacing(10, after: bRow)
        // 明度 / HEX 值都要走各自的取色路径，单独挂 action。
        vField.target = self
        vField.action = #selector(brightnessFieldChanged)
    }

    /// 色轮（左） + 「最近使用」颜色格（右）。
    private func makeTopRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = M.columnGap
        row.distribution = .fill

        wheel.translatesAutoresizingMaskIntoConstraints = false
        wheel.widthAnchor.constraint(equalToConstant: M.wheelSide).isActive = true
        wheel.heightAnchor.constraint(equalToConstant: M.wheelSide).isActive = true
        wheel.onColorChange = { [weak self] color in
            self?.syncUI(from: color)
        }

        grid.cellSide = M.cellSide
        grid.cellGap = M.cellGap
        grid.recentColors = recentHexes.compactMap { NSColor.fromHexRGB($0) }
        grid.onSelect = { [weak self] color in
            guard let self else { return }
            // 只切 RGB，透明度滑杆的值不动。
            self.syncUI(from: color.withAlphaComponent(self.current.alphaComponent))
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: grid.gridSize.width).isActive = true
        grid.heightAnchor.constraint(equalToConstant: grid.gridSize.height).isActive = true

        let caption = NSTextField(labelWithString: "最近使用")
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor

        let right = NSStackView(views: [caption, grid])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6

        row.addArrangedSubview(wheel)
        row.addArrangedSubview(right)
        return row
    }

    /// 「当前颜色」四个字：按参考图对齐在**颜色格那一列**的左边缘。
    private func makePreviewLabelRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        let lead = NSView()
        lead.translatesAutoresizingMaskIntoConstraints = false
        lead.widthAnchor.constraint(equalToConstant: M.wheelSide + M.columnGap).isActive = true
        let label = NSTextField(labelWithString: "当前颜色")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let tail = NSView()
        tail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(lead)
        row.addArrangedSubview(label)
        row.addArrangedSubview(tail)
        return row
    }

    private func makePreviewBar() -> NSView {
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return preview
    }

    private func makeSliderRow(
        _ label: String,
        _ slider: NSSlider,
        _ field: NSTextField,
        max: Double,
        action: Selector = #selector(sliderChanged)
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: M.labelWidth).isActive = true

        slider.minValue = 0
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.translatesAutoresizingMaskIntoConstraints = false

        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .center
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(fieldChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: M.labelWidth).isActive = true
        field.heightAnchor.constraint(equalToConstant: M.sliderRowHeight).isActive = true

        row.addArrangedSubview(l)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(field)
        row.heightAnchor.constraint(equalToConstant: M.sliderRowHeight).isActive = true
        return row
    }

    /// HEX 输入框 + 右侧的吸管图标按钮（全屏取色）。
    private func makeHexRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let l = NSTextField(labelWithString: "HEX")
        l.font = .systemFont(ofSize: 12)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: M.labelWidth).isActive = true

        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.isBordered = true
        hexField.bezelStyle = .roundedBezel
        hexField.target = self
        hexField.action = #selector(hexChanged)
        hexField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.heightAnchor.constraint(equalToConstant: M.sliderRowHeight).isActive = true

        eyedropper = EyedropperButton(target: self, action: #selector(startEyedropper))
        eyedropper.widthAnchor.constraint(equalToConstant: 32).isActive = true
        eyedropper.heightAnchor.constraint(equalToConstant: M.sliderRowHeight).isActive = true

        row.addArrangedSubview(l)
        row.addArrangedSubview(hexField)
        row.addArrangedSubview(eyedropper)
        row.heightAnchor.constraint(equalToConstant: M.sliderRowHeight).isActive = true
        return row
    }

    /// 底部只剩「取消 / 确定」（红黑白那三个快捷按钮已并入颜色格的固定格）。
    /// 按 Mac 惯例取消在左、确定在右。
    private func makeButtonRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "确定", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(cancel)
        row.addArrangedSubview(ok)
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    // MARK: - 同步

    private func syncUI(from color: NSColor) {
        current = color
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 100))
        rSlider.doubleValue = Double(r)
        gSlider.doubleValue = Double(g)
        bSlider.doubleValue = Double(b)
        aSlider.doubleValue = Double(a)
        rField.stringValue = "\(r)"
        gField.stringValue = "\(g)"
        bField.stringValue = "\(b)"
        aField.stringValue = "\(a)"
        vField.stringValue = "\(Int(round(rgb.brightnessComponent * 100)))"
        hexField.stringValue = color.hexRGB
        wheel.setColor(color)
        vSlider.doubleValue = Double(round(rgb.brightnessComponent * 100))
        preview.color = color
        grid.currentColor = color
    }

    private func readUI() -> NSColor {
        let r = CGFloat(rSlider.doubleValue / 255)
        let g = CGFloat(gSlider.doubleValue / 255)
        let b = CGFloat(bSlider.doubleValue / 255)
        let a = CGFloat(aSlider.doubleValue / 100)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Actions

    @objc private func sliderChanged() {
        syncUI(from: readUI())
    }

    /// 明度滑杆：色轮盘面永远是鲜艳的，明度只压暗"被选中的那个颜色"。
    @objc private func brightnessChanged() {
        wheel.setBrightness(CGFloat(vSlider.doubleValue / 100))
        syncUI(from: wheel.currentColor)
    }

    /// 明度输入框：同上，走色轮 HSB 而不是 RGB 滑杆。
    @objc private func brightnessFieldChanged() {
        vSlider.doubleValue = max(0, min(100, vField.doubleValue))
        brightnessChanged()
    }

    @objc private func fieldChanged() {
        rSlider.doubleValue = rField.doubleValue
        gSlider.doubleValue = gField.doubleValue
        bSlider.doubleValue = bField.doubleValue
        aSlider.doubleValue = aField.doubleValue
        syncUI(from: readUI())
    }

    @objc private func hexChanged() {
        var s = hexField.stringValue.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        syncUI(from: NSColor(srgbRed: r, green: g, blue: b, alpha: CGFloat(aSlider.doubleValue / 100)))
    }

    /// 全屏取色：面板临时隐藏 → 全屏取色层 → 取到像素后**面板恢复并显示该颜色**。
    /// 和颜色格一样只改"当前颜色"，要不要用还得按「确定」——取完常常还要调透明度。
    @objc private func startEyedropper() {
        view.window?.orderOut(nil)
        ScreenColorPicker.shared.begin { [weak self] color in
            guard let self else { return }
            self.view.window?.makeKeyAndOrderFront(nil)
            self.syncUI(from: color.withAlphaComponent(self.current.alphaComponent))
        } onCancel: { [weak self] in
            // 取消了就把面板原样还回来，颜色不动。
            self?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func okClicked() {
        recentHexes = RecentColorStore.record(current)
        grid.recentColors = recentHexes.compactMap { NSColor.fromHexRGB($0) }
        grid.currentColor = current
        onPick(current)
        closePanel()
    }

    @objc private func cancelClicked() {
        closePanel()
    }

    private func closePanel() {
        view.window?.close()
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }

    func show(relativeTo parent: NSView, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        loadViewIfNeeded()   // 触发 viewDidLoad，先把真实版面尺寸算出来
        let size = preferredContentSize
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "颜色"
        window.contentViewController = self
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(size)
        if let pw = parent.window {
            let pwFrame = pw.frame
            window.setFrameOrigin(NSPoint(
                x: pwFrame.midX - size.width / 2,
                y: pwFrame.midY - size.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 色轮

/// HSV color wheel: angle = hue, radius = saturation, always rendered vivid.
/// Click or drag anywhere on the disc to pick the vivid color shown there —
/// the brightness slider only darkens the picked color afterwards.
final class ColorWheelView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onColorChange: ((NSColor) -> Void)?

    private(set) var hue: CGFloat = 0
    private(set) var saturation: CGFloat = 0
    private(set) var brightness: CGFloat = 1

    private var wheelImage: CGImage?

    var currentColor: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    func setColor(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
        brightness = b
        needsDisplay = true
    }

    func setBrightness(_ v: CGFloat) {
        brightness = min(1, max(0, v))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if wheelImage == nil {
            renderWheel()
        }
        if let wheelImage {
            NSImage(cgImage: wheelImage, size: bounds.size).draw(in: bounds)
        }

        // Subtle outer hairline so the disc reads against the panel background.
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1
        NSColor.separatorColor.setStroke()
        ring.stroke()

        // Indicator dot at (hue angle, saturation radius).
        let r = bounds.width / 2 - 2
        let theta = hue * 2 * .pi
        let px = bounds.midX + saturation * r * cos(theta)
        let py = bounds.midY + saturation * r * sin(theta)

        let shadow = NSBezierPath(ovalIn: NSRect(x: px - 7, y: py - 7, width: 14, height: 14))
        shadow.lineWidth = 2
        NSColor.black.withAlphaComponent(0.35).setStroke()
        shadow.stroke()
        let halo = NSBezierPath(ovalIn: NSRect(x: px - 6, y: py - 6, width: 12, height: 12))
        halo.lineWidth = 2
        NSColor.white.setStroke()
        halo.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: px - 3, y: py - 3, width: 6, height: 6))
        currentColor.setFill()
        dot.fill()
    }

    override func mouseDown(with event: NSEvent) { pick(at: event) }
    override func mouseDragged(with event: NSEvent) { pick(at: event) }

    private func pick(at event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = bounds.width / 2 - 2
        let dx = (p.x - bounds.midX) / r
        let dy = (p.y - bounds.midY) / r
        let dist = min(1, sqrt(dx * dx + dy * dy))
        var h = atan2(dy, dx) / (2 * .pi)
        if h < 0 { h += 1 }
        hue = h
        saturation = dist
        // WYSIWYG: the disc is always rendered vivid (full brightness), so a
        // click must pick the vivid color shown at that spot — NOT keep the
        // previous brightness (e.g. black picked by the eyedropper would
        // otherwise keep every wheel pick black). syncUI syncs the brightness
        // slider back to 100.
        brightness = 1
        needsDisplay = true
        onColorChange?(currentColor)
    }

    /// Render the wheel bitmap once @2x, always at FULL brightness — the
    /// disc itself stays vivid like the classic system wheel; the brightness
    /// slider only darkens the selected color (the dot), never the disc.
    /// Flipped coords both here and in the dot math keep angle/radius
    /// consistent.
    private func renderWheel() {
        let scale: CGFloat = 2
        let dim = Int(bounds.width * scale)
        guard dim > 4 else { return }
        let c = CGFloat(dim) / 2
        let r = c - 2
        var buf = [UInt8](repeating: 0, count: dim * dim * 4)
        for y in 0..<dim {
            for x in 0..<dim {
                let dx = (CGFloat(x) + 0.5 - c) / r
                let dy = (CGFloat(y) + 0.5 - c) / r
                let dist = sqrt(dx * dx + dy * dy)
                let idx = (y * dim + x) * 4
                guard dist <= 1 else { continue }
                var h = atan2(dy, dx) / (2 * .pi)
                if h < 0 { h += 1 }
                let (rr, gg, bb) = Self.hsvToRGB(h, dist, 1)
                // ~1.5-device-pixel alpha falloff at the rim to avoid jaggies.
                let alpha = min(1, (1 - dist) * r / 1.5)
                // hsvToRGB returns 0…1 floats — scale to 0…255 for the byte
                // buffer (UInt8(1.0) == 1, not 255!).
                buf[idx] = UInt8(rr * 255)
                buf[idx + 1] = UInt8(gg * 255)
                buf[idx + 2] = UInt8(bb * 255)
                buf[idx + 3] = UInt8(alpha * 255)
            }
        }
        // withUnsafeMutableBytes keeps the buffer pointer valid for the whole
        // context lifetime (a bare `&buf` is only guaranteed for the init call).
        wheelImage = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: dim, height: dim,
                bitsPerComponent: 8, bytesPerRow: dim * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    private static func hsvToRGB(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
