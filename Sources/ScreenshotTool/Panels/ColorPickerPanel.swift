import AppKit

/// Color panel: presets + RGB/alpha + eyedropper.
final class ColorPickerPanel: NSViewController {
    private let initial: NSColor
    private let onPick: (NSColor) -> Void
    private var current: NSColor

    private let preview = NSButton()
    private let rSlider = NSSlider()
    private let gSlider = NSSlider()
    private let bSlider = NSSlider()
    private let aSlider = NSSlider()
    private let rField = NSTextField()
    private let gField = NSTextField()
    private let bField = NSTextField()
    private let aField = NSTextField()
    private let hexField = NSTextField()

    private let presets: [NSColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange, .black,
        .white, .systemPurple, .systemTeal, .systemGray, .systemYellow
    ]

    private var eyedropperMonitor: Any?

    init(initial: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.initial = initial
        self.current = initial
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))
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

        // Presets
        let presetStack = NSStackView()
        presetStack.orientation = .horizontal
        presetStack.spacing = 8
        for c in presets {
            let b = NSButton()
            b.bezelStyle = .smallSquare
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 4
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            b.target = self
            b.action = #selector(presetClicked(_:))
            b.identifier = NSUserInterfaceItemIdentifier("\(c.description)")
            // store color via representedObject not available on NSButton - use tag index
            b.tag = presets.firstIndex(where: { $0 == c }) ?? 0
            presetStack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(presetStack)

        preview.title = "颜色预览"
        preview.bezelStyle = .rounded
        preview.wantsLayer = true
        preview.isBordered = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 36).isActive = true
        stack.addArrangedSubview(preview)

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
        let eyedrop = NSButton(title: "吸管（从图上取色）", target: self, action: #selector(startEyedropper))
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

        preview.wantsLayer = true
        preview.layer?.backgroundColor = color.cgColor
    }

    private func readUI() -> NSColor {
        let r = CGFloat(rSlider.doubleValue / 255)
        let g = CGFloat(gSlider.doubleValue / 255)
        let b = CGFloat(bSlider.doubleValue / 255)
        let a = CGFloat(aSlider.doubleValue / 100)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    @objc private func presetClicked(_ sender: NSButton) {
        guard sender.tag >= 0 && sender.tag < presets.count else { return }
        syncUI(from: presets[sender.tag])
    }

    @objc private func sliderChanged() {
        syncUI(from: readUI())
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

    @objc private func startEyedropper() {
        view.window?.orderOut(nil)
        NSCursor.crosshair.push()
        eyedropperMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) { [weak self] event in
            guard let self else { return }
            if event.type == .mouseMoved {
                return
            }
            if let color = Self.screenColor(at: NSEvent.mouseLocation) {
                self.syncUI(from: color)
            }
            self.stopEyedropper()
            self.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func stopEyedropper() {
        if let eyedropperMonitor {
            NSEvent.removeMonitor(eyedropperMonitor)
            self.eyedropperMonitor = nil
        }
        NSCursor.pop()
    }

    static func screenColor(at globalPoint: NSPoint) -> NSColor? {
        // Convert to CG global (top-left origin)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(globalPoint) }) else {
            return nil
        }
        let scale = screen.backingScaleFactor
        let sx = (globalPoint.x - screen.frame.origin.x) * scale
        let syFromTop = (screen.frame.maxY - globalPoint.y) * scale
        // Capture 1x1
        let rect = CGRect(x: sx, y: syFromTop, width: 1, height: 1)
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        guard let image = CGDisplayCreateImage(displayID) else { return nil }
        guard let cropped = image.cropping(to: rect.integral.offsetBy(dx: 0, dy: 0)) else { return nil }

        // Read pixel
        let w = 1, h = 1
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    @objc private func okClicked() {
        stopEyedropper()
        onPick(current)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        stopEyedropper()
        dismiss(nil)
    }

    func show(relativeTo parent: NSView) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "颜色"
        window.contentViewController = self
        window.isReleasedWhenClosed = false
        if let pw = parent.window, let screen = pw.screen ?? NSScreen.main {
            let pwFrame = pw.frame
            let x = pwFrame.midX - 160
            let y = pwFrame.midY - 210
            window.setFrameOrigin(NSPoint(x: x, y: y))
            _ = screen
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
