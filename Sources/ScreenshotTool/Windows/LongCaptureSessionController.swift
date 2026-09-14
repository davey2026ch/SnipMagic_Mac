import AppKit

protocol LongCaptureSessionDelegate: AnyObject {
    func longCaptureSession(_ session: LongCaptureSessionController, didFinish image: CGImage)
    func longCaptureSessionDidCancel(_ session: LongCaptureSessionController)
}

/// Drives an interactive long ("scrolling") screenshot:
/// locks a screen region, polls ScreenCaptureKit while the user scrolls the
/// target window, stitches frames via `LongScreenshotBuilder`, and shows a
/// live control bar + preview. All of the app's own windows are excluded
/// from every capture so the UI never leaks into the stitched pixels.
final class LongCaptureSessionController {
    private let screen: NSScreen
    private let region: CGRect          // global (bottom-left origin) coords
    private weak var delegate: LongCaptureSessionDelegate?

    private var borderWindow: NSWindow?
    private var controlPanel: ControlPanel?
    private var previewPanel: NSPanel?
    private var previewImageView: NSImageView?

    private var timer: Timer?
    private var captureInFlight = false
    private var state: SessionState = .idle
    private var consecutiveErrors = 0
    private var lastPreviewAt: CFTimeInterval = 0

    private let stitchQueue = DispatchQueue(label: "com.mimo.screenshottool.longcapture", qos: .userInitiated)
    private var builder: LongScreenshotBuilder?
    private var lastFrame: FrameData?
    private var activityToken: NSObjectProtocol?

    private let pollInterval: TimeInterval = 0.25
    private let firstDelay: TimeInterval = 0.35

    private enum SessionState {
        case idle, running, finishing, done
    }

    // MARK: - UI references (built in start())

    private var statusLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var warningLabel: NSTextField!

    init(screen: NSScreen, region: CGRect) {
        self.screen = screen
        self.region = region
    }

    deinit {
        activityToken.map { ProcessInfo.processInfo.endActivity($0) }
    }

    // MARK: - Lifecycle

    func start(delegate: LongCaptureSessionDelegate) {
        self.delegate = delegate
        guard state == .idle else { return }
        state = .running

        // Keep the timer honest while the user scrolls inside another app.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "长截图拼接进行中"
        )

        buildBorderWindow()
        buildControlPanel()
        buildPreviewPanel()

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Give the just-closed overlay a moment so its dimming doesn't appear
        // in the first (anchor) frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay - pollInterval) { [weak self] in
            self?.tick()
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        controlPanel?.orderOut(nil)
        controlPanel = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
        activityToken.map { ProcessInfo.processInfo.endActivity($0) }
        activityToken = nil
    }

    @objc func cancel() {
        guard state == .running else { return }
        state = .done
        teardown()
        delegate?.longCaptureSessionDidCancel(self)
    }

    @objc func finish() {
        guard state == .running else { return }
        state = .finishing
        timer?.invalidate()
        timer = nil
        statusLabel?.stringValue = "正在生成长截图…"

        // One last capture so the very latest content (and footer) is included.
        Task { @MainActor in
            if let image = try? await Self.captureFrame(screen: self.screen, excluding: self.ownWindowNumbers()) {
                self.enqueueFrame(image, thenFinish: true)
            } else {
                self.enqueueFinish()
            }
        }
    }

    // MARK: - Capture loop

    @objc private func tick() {
        guard state == .running, !captureInFlight else { return }
        captureInFlight = true
        let screen = self.screen
        let excluded = ownWindowNumbers()
        Task { @MainActor in
            do {
                let image = try await ScreenCaptureService.shared.capture(
                    screen: screen,
                    excludingWindowNumbers: excluded,
                    showsCursor: false
                )
                self.enqueueFrame(image, thenFinish: false)
            } catch {
                self.captureInFlight = false
                self.consecutiveErrors += 1
                if self.consecutiveErrors >= 3 {
                    self.cancel()
                }
            }
        }
    }

    private static func captureFrame(screen: NSScreen, excluding: [Int]) async throws -> CGImage {
        try await ScreenCaptureService.shared.capture(
            screen: screen,
            excludingWindowNumbers: excluding,
            showsCursor: false
        )
    }

    private func pixelRect(for image: CGImage) -> CGRect? {
        let f = screen.frame
        guard f.width > 0, f.height > 0 else { return nil }
        let sx = CGFloat(image.width) / f.width
        let sy = CGFloat(image.height) / f.height
        let px = (region.minX - f.minX) * sx
        let pw = region.width * sx
        let ph = region.height * sy
        let py = CGFloat(image.height) - (region.maxY - f.minY) * sy
        let rect = CGRect(x: px.rounded(), y: py.rounded(), width: pw.rounded(), height: ph.rounded())
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return rect
    }

    private func ownWindowNumbers() -> [Int] {
        var numbers: [Int] = []
        if let n = borderWindow?.windowNumber { numbers.append(n) }
        if let n = controlPanel?.windowNumber { numbers.append(n) }
        if let n = previewPanel?.windowNumber { numbers.append(n) }
        return numbers
    }

    // MARK: - Stitching

    private func enqueueFrame(_ fullImage: CGImage, thenFinish: Bool) {
        guard let rect = pixelRect(for: fullImage), let crop = fullImage.cropping(to: rect),
              let buffer = PixelBuffer(image: crop) else {
            captureInFlight = false
            if thenFinish { enqueueFinish() }
            return
        }
        let time = CFAbsoluteTimeGetCurrent()
        let finishAfter = thenFinish
        stitchQueue.async { [weak self] in
            guard let self else { return }
            if self.builder == nil {
                self.builder = LongScreenshotBuilder(width: buffer.width)
            }
            let frame = FrameData(buffer: buffer)
            let event = self.builder?.process(frame: frame, at: time) ?? .skipped
            self.lastFrame = frame
            let rows = self.builder?.canvasRows ?? 0
            let gaps = self.builder?.gapCount ?? 0
            let capped = (self.builder?.capped ?? false)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.captureInFlight = false
                self.apply(event: event, rows: rows, gaps: gaps)
                if capped, self.state == .running {
                    self.finish()
                } else if finishAfter, self.state == .finishing {
                    self.enqueueFinish()
                }
            }
        }
    }

    private func enqueueFinish() {
        stitchQueue.async { [weak self] in
            guard let self else { return }
            let image = self.builder?.finish(with: self.lastFrame)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = .done
                let hadContent = self.builder != nil
                self.teardown()
                if let image, hadContent {
                    self.delegate?.longCaptureSession(self, didFinish: image)
                } else {
                    self.delegate?.longCaptureSessionDidCancel(self)
                }
            }
        }
    }

    private func apply(event: LongScreenshotBuilder.Event, rows: Int, gaps: Int) {
        guard state == .running || state == .finishing else { return }
        switch event {
        case .started:
            statusLabel.stringValue = "已拼接 \(Self.fmt(rows)) px"
        case .appended:
            statusLabel.stringValue = "已拼接 \(Self.fmt(rows)) px"
            refreshPreviewThrottled()
        case .gap:
            statusLabel.stringValue = "已拼接 \(Self.fmt(rows)) px · ⚠️ 滚动过快"
            refreshPreviewThrottled()
        default:
            break
        }
        if gaps > 0 {
            warningLabel.stringValue = "⚠️ \(gaps) 处可能缺失（滚动过快）"
            warningLabel.isHidden = false
        }
    }

    private func refreshPreviewThrottled() {
        guard let previewImageView else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewAt >= 1.0 else { return }
        lastPreviewAt = now
        stitchQueue.async { [weak self] in
            guard let self, let preview = self.builder?.makePreviewImage(maxPixelWidth: 360) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.previewImageView?.image = NSImage(cgImage: preview, size: NSSize(
                    width: preview.width,
                    height: preview.height
                ))
            }
        }
    }

    private static func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - UI construction

    private func buildBorderWindow() {
        let border: CGFloat = 2
        let frame = region.insetBy(dx: -border, dy: -border)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = BorderView(frame: NSRect(origin: .zero, size: frame.size))
        view.borderColor = Theme.accent
        view.borderWidth = border
        window.contentView = view
        window.orderFrontRegardless()
        borderWindow = window
    }

    private func buildControlPanel() {
        let panel = ControlPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.onEnter = { [weak self] in self?.finish() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 64))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 10

        let doneBtn = Self.makePanelButton(title: "✓ 完成", bg: Theme.accent, fg: .white)
        doneBtn.action = #selector(finish)
        doneBtn.target = self
        let cancelBtn = Self.makePanelButton(title: "✕ 取消", bg: NSColor(calibratedWhite: 0.28, alpha: 1), fg: .white)
        cancelBtn.action = #selector(cancel)
        cancelBtn.target = self

        statusLabel = NSTextField(labelWithString: "已拼接 0 px")
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .white

        hintLabel = NSTextField(labelWithString: "在目标窗口中滚动，自动拼接")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)

        warningLabel = NSTextField(labelWithString: "")
        warningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        warningLabel.textColor = NSColor.systemOrange
        warningLabel.isHidden = true

        let textStack = NSStackView(views: [statusLabel, hintLabel, warningLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let stack = NSStackView(views: [doneBtn, cancelBtn, textStack])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        panel.contentView = container

        // Place below the region (above if it would fall off-screen).
        let vf = screen.visibleFrame
        var origin = NSPoint(
            x: region.midX - panel.frame.width / 2,
            y: region.minY - panel.frame.height - 12
        )
        if origin.y < vf.minY {
            origin.y = region.maxY + 12
        }
        if origin.y + panel.frame.height > vf.maxY {
            origin.y = vf.minY + 8
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        controlPanel = panel
    }

    private func buildPreviewPanel() {
        let vf = screen.visibleFrame
        let width: CGFloat = 200
        let height = min(max(region.height, 200), 520)

        var origin: NSPoint?
        if region.maxX + 14 + width <= vf.maxX {
            origin = NSPoint(x: region.maxX + 14, y: region.midY - height / 2)
        } else if region.minX - 14 - width >= vf.minX {
            origin = NSPoint(x: region.minX - 14 - width, y: region.midY - height / 2)
        }
        guard var o = origin else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 0.8, alpha: 1).cgColor

        let caption = NSTextField(labelWithString: "拼接预览")
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = .white
        caption.alignment = .center
        caption.wantsLayer = true
        caption.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        caption.layer?.cornerRadius = 4

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        imageView.imageScaling = .scaleProportionallyDown
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        caption.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(caption)
        NSLayoutConstraint.activate([
            caption.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])

        panel.contentView = container
        o.y = min(max(o.y, vf.minY + 8), vf.maxY - height - 8)
        panel.setFrameOrigin(o)
        panel.orderFrontRegardless()
        previewPanel = panel
        previewImageView = imageView
    }

    private static func makePanelButton(title: String, bg: NSColor, fg: NSColor) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = bg.cgColor
        b.layer?.cornerRadius = 6
        b.font = .systemFont(ofSize: 13, weight: .semibold)
        b.contentTintColor = fg
        // Bordered buttons ignore textColor; use attributed title for FG color.
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: fg
        ])
        b.widthAnchor.constraint(equalToConstant: 72).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }
}

// MARK: - Helper views

final class BorderView: NSView {
    var borderColor: NSColor = .systemBlue
    var borderWidth: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
        path.lineWidth = borderWidth
        borderColor.setStroke()
        path.stroke()
    }
}

/// Floating, non-activating panel: Esc cancels, Return finishes (when key).
final class ControlPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onEnter: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onEscape?()
        case 36: // Return
            onEnter?()
        default:
            super.keyDown(with: event)
        }
    }
}
