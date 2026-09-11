import AppKit

protocol CaptureOverlayDelegate: AnyObject {
    func captureOverlayDidCancel(_ overlay: CaptureOverlayController)
    func captureOverlay(_ overlay: CaptureOverlayController, didCapture image: CGImage, on screen: NSScreen)
}

final class CaptureOverlayController: NSWindowController {
    private let screen: NSScreen
    private var screenImage: CGImage?
    private var selectionRect: CGRect = .zero
    private var dragOrigin: CGPoint?
    private var localMonitor: Any?

    weak var overlayDelegate: CaptureOverlayDelegate?

    private var overlayView: OverlayView {
        window!.contentView as! OverlayView
    }

    init(screen: NSScreen, image: CGImage) {
        self.screen = screen
        self.screenImage = image
        let frame = screen.frame
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)

        let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.screenImage = image
        view.onMouseDown = { [weak self] p in self?.handleDown(p) }
        view.onMouseDrag = { [weak self] p in self?.handleDrag(p) }
        view.onMouseUp = { [weak self] p in self?.handleUp(p) }
        view.onCancel = { [weak self] in self?.cancel() }
        window.contentView = view
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
    }

    func cancel() {
        cleanup()
        overlayDelegate?.captureOverlayDidCancel(self)
        close()
    }

    private func cleanup() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleDown(_ point: CGPoint) {
        dragOrigin = point
        selectionRect = .zero
        overlayView.selection = .zero
    }

    private func handleDrag(_ point: CGPoint) {
        guard let origin = dragOrigin else { return }
        selectionRect = CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
        overlayView.selection = selectionRect
    }

    private func handleUp(_ point: CGPoint) {
        defer {
            dragOrigin = nil
        }
        guard let origin = dragOrigin else { return }
        let rect = CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
        // < 3px invalid → cancel selection (stay in overlay)
        if rect.width < 3 || rect.height < 3 {
            selectionRect = .zero
            overlayView.selection = .zero
            return
        }
        finalize(rect)
    }

    private func finalize(_ viewRect: CGRect) {
        guard let screenImage else {
            cancel()
            return
        }
        let scale = CGFloat(screenImage.width) / max(screen.frame.width, 1)
        let pw = viewRect.width * scale
        let ph = viewRect.height * scale
        let px = viewRect.origin.x * scale
        let imageH = CGFloat(screenImage.height)
        let py = imageH - (viewRect.origin.y * scale) - ph
        let crop = CGRect(x: px.rounded(), y: py.rounded(), width: pw.rounded(), height: ph.rounded())
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(screenImage.width), height: imageH))

        guard crop.width >= 3, crop.height >= 3, let cropped = screenImage.cropping(to: crop) else {
            cancel()
            return
        }
        cleanup()
        overlayDelegate?.captureOverlay(self, didCapture: cropped, on: screen)
        close()
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    var screenImage: CGImage?
    var selection: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDrag: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDrag?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let screenImage {
            NSImage(cgImage: screenImage, size: bounds.size).draw(in: bounds)
        } else {
            NSColor.black.setFill()
            bounds.fill()
        }

        if selection.width > 0.5 && selection.height > 0.5 {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: selection).reversed)
            path.windingRule = .evenOdd
            path.fill()

            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            NSColor.systemBlue.setStroke()
            border.stroke()

            NSColor.white.setFill()
            NSColor.systemBlue.setStroke()
            for p in handlePoints(selection) {
                let h = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                let hp = NSBezierPath(ovalIn: h)
                hp.lineWidth = 1
                hp.fill()
                hp.stroke()
            }

            drawLabel(pixelLabel(selection), at: selection)
        } else {
            let hint = "拖动框选要截取的区域 · Esc 取消"
            drawBadge(hint, at: CGPoint(x: bounds.midX, y: bounds.midY + 50))
        }
    }

    private func pixelLabel(_ sel: CGRect) -> String {
        let backing = window?.backingScaleFactor ?? 2.0
        let w = Int((sel.width * backing).rounded())
        let h = Int((sel.height * backing).rounded())
        return "\(w) × \(h)"
    }

    private func drawLabel(_ text: String, at rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var x = rect.minX
        var y = rect.maxY + 8
        if y + size.height + 10 > bounds.maxY {
            y = rect.minY - size.height - 14
        }
        if x + size.width + 16 > bounds.maxX {
            x = bounds.maxX - size.width - 16
        }
        let bg = NSRect(x: x, y: y - 4, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: x + 8, y: y), withAttributes: attrs)
    }

    private func drawBadge(_ text: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let bg = NSRect(x: origin.x - 12, y: origin.y - 6, width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }
}
