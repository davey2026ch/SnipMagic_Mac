import AppKit

/// Color panel: HSV color wheel + brightness, RGB/alpha sliders, HEX input,
/// fullscreen eyedropper. Picking a preset or eyedropping a color applies it
/// immediately and closes the panel; wheel/slider/HEX adjustments stay open
/// until 确定.
final class ColorPickerPanel: NSViewController, NSWindowDelegate {
    private let initial: NSColor
    private let onPick: (NSColor) -> Void
    private var current: NSColor
    private var onClose: (() -> Void)?

    private let wheel = ColorWheelView()
    private let vSlider = NSSlider()
    private let rSlider = NSSlider()
    private let gSlider = NSSlider()
    private let bSlider = NSSlider()
    private let aSlider = NSSlider()
    private let rField = NSTextField()
    private let gField = NSTextField()
    private let bField = NSTextField()
    private let aField = NSTextField()
    private let hexField = NSTextField()

    init(initial: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.initial = initial
        self.current = initial
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 540))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        syncUI(from: current)
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let title = NSTextField(labelWithString: "颜色")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        // Classic color wheel: angle = hue, radius = saturation, always vivid.
        // The brightness slider below only darkens the selected color.
        wheel.translatesAutoresizingMaskIntoConstraints = false
        wheel.widthAnchor.constraint(equalToConstant: 210).isActive = true
        wheel.heightAnchor.constraint(equalToConstant: 210).isActive = true
        wheel.onColorChange = { [weak self] color in
            self?.syncUI(from: color)
        }
        stack.addArrangedSubview(wheel)

        // Brightness row.
        let vRow = NSStackView()
        vRow.orientation = .horizontal
        vRow.spacing = 8
        let vl = NSTextField(labelWithString: "明度")
        vl.font = .systemFont(ofSize: 12)
        vl.translatesAutoresizingMaskIntoConstraints = false
        vl.widthAnchor.constraint(equalToConstant: 48).isActive = true
        vSlider.minValue = 0
        vSlider.maxValue = 100
        vSlider.target = self
        vSlider.action = #selector(brightnessChanged)
        vRow.addArrangedSubview(vl)
        vRow.addArrangedSubview(vSlider)
        stack.addArrangedSubview(vRow)

        func row(_ label: String, _ slider: NSSlider, _ field: NSTextField) -> NSView {
            let s = NSStackView()
            s.orientation = .horizontal
            s.spacing = 8
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 48).isActive = true
            slider.minValue = 0
            slider.maxValue = label == "透明度" ? 100 : 255
            slider.target = self
            slider.action = #selector(sliderChanged)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.target = self
            field.action = #selector(fieldChanged)
            s.addArrangedSubview(l)
            s.addArrangedSubview(slider)
            s.addArrangedSubview(field)
            return s
        }

        stack.addArrangedSubview(row("R", rSlider, rField))
        stack.addArrangedSubview(row("G", gSlider, gField))
        stack.addArrangedSubview(row("B", bSlider, bField))
        stack.addArrangedSubview(row("透明度", aSlider, aField))

        let hexRow = NSStackView()
        hexRow.orientation = .horizontal
        hexRow.spacing = 8
        let hl = NSTextField(labelWithString: "HEX")
        hl.font = .systemFont(ofSize: 12)
        hl.translatesAutoresizingMaskIntoConstraints = false
        hl.widthAnchor.constraint(equalToConstant: 48).isActive = true
        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.target = self
        hexField.action = #selector(hexChanged)
        hexRow.addArrangedSubview(hl)
        hexRow.addArrangedSubview(hexField)
        stack.addArrangedSubview(hexRow)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let eyedrop = NSButton(title: "吸管（屏幕任意位置取色）", target: self, action: #selector(startEyedropper))
        eyedrop.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        let ok = NSButton(title: "确定", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        buttons.addArrangedSubview(eyedrop)
        let sp = NSView()
        sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(sp)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(ok)
        stack.addArrangedSubview(buttons)
    }

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
        hexField.stringValue = String(format: "#%02x%02x%02x", r, g, b)
        wheel.setColor(color)
        vSlider.doubleValue = Double(round(rgb.brightnessComponent * 100))
    }

    private func readUI() -> NSColor {
        let r = CGFloat(rSlider.doubleValue / 255)
        let g = CGFloat(gSlider.doubleValue / 255)
        let b = CGFloat(bSlider.doubleValue / 255)
        let a = CGFloat(aSlider.doubleValue / 100)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    @objc private func sliderChanged() {
        syncUI(from: readUI())
    }

    @objc private func brightnessChanged() {
        wheel.setBrightness(CGFloat(vSlider.doubleValue / 100))
        syncUI(from: wheel.currentColor)
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

    /// Apply the current color and close the panel (eyedropper picks).
    /// Wheel/slider/HEX adjustments still need 确定 since users tweak them
    /// repeatedly.
    private func applyCurrentAndClose() {
        onPick(current)
        closePanel()
    }

    private func closePanel() {
        view.window?.close()
    }

    /// Fullscreen eyedropper: freeze the screen (panel hidden), pick any pixel
    /// — current tab image, desktop wallpaper, other apps — then apply the
    /// picked color and close this panel automatically.
    @objc private func startEyedropper() {
        view.window?.orderOut(nil)
        ScreenColorPicker.shared.begin { [weak self] color in
            guard let self else { return }
            self.syncUI(from: color)
            self.applyCurrentAndClose()
        } onCancel: { [weak self] in
            // Canceled → bring the panel back for manual adjustment.
            self?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func okClicked() {
        onPick(current)
        closePanel()
    }

    @objc private func cancelClicked() {
        closePanel()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }

    func show(relativeTo parent: NSView, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "颜色"
        window.contentViewController = self
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let pw = parent.window {
            let pwFrame = pw.frame
            let x = pwFrame.midX - 160
            let y = pwFrame.midY - 270
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

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
