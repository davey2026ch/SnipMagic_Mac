import AppKit

/// Fullscreen eyedropper overlay.
///
/// Flow: freeze the screen with a single capture → show that frozen frame in
/// a borderless window above everything → a magnifier loupe follows the
/// cursor → left-click picks the color under the cursor, Esc or right-click
/// cancels. Because pixels are read from the pre-captured frame, the picker
/// sees anything that was on screen when it started: the editor canvas, the
/// desktop wallpaper, other applications.
final class ScreenColorPicker: NSObject {
    static let shared = ScreenColorPicker()

    private var overlayWindow: NSWindow?
    private var keyMonitor: Any?

    /// Present the picker overlay. `onPick` fires with the picked color;
    /// `onCancel` fires when the user cancels. Exactly one of them runs.
    func begin(onPick: @escaping (NSColor) -> Void, onCancel: (() -> Void)? = nil) {
        guard overlayWindow == nil else { return }

        // Small delay lets the color panel finish ordering out so it is not
        // captured into the frozen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.overlayWindow == nil else { return }

            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            guard let screen,
                  let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let capture = CGDisplayCreateImage(CGDirectDisplayID(num.uint32Value)) else {
                onCancel?()
                return
            }

            let overlay = PickerOverlayView(
                capture: capture,
                screenFrame: screen.frame,
                scale: screen.backingScaleFactor,
                onPick: { [weak self] color in self?.finish(picked: color, onPick: onPick, onCancel: onCancel) },
                onCancel: { [weak self] in self?.finish(picked: nil, onPick: onPick, onCancel: onCancel) }
            )

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = overlay
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.acceptsMouseMovedEvents = true
            window.hidesOnDeactivate = false
            window.canHide = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.overlayWindow = window

            // Borderless windows never become key, so route Esc through a
            // local event monitor instead of keyDown.
            self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {  // Esc
                    self?.finish(picked: nil, onPick: onPick, onCancel: onCancel)
                    return nil
                }
                return event
            }

            NSCursor.crosshair.push()
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func finish(picked: NSColor?, onPick: (NSColor) -> Void, onCancel: (() -> Void)?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        NSCursor.pop()
        if let picked { onPick(picked) } else { onCancel?() }
    }
}

/// The fullscreen view that draws the frozen frame plus the loupe.
/// Flipped coordinates (origin top-left) keep the pixel math trivial since
/// the captured bitmap is also top-left-first.
private final class PickerOverlayView: NSView {
    override var isFlipped: Bool { true }

    private let image: NSImage
    private let pixels: [UInt8]
    private let pixelWidth: Int
    private let scale: CGFloat
    private var mouse: NSPoint?
    private let onPick: (NSColor) -> Void
    private let onCancel: () -> Void

    private let loupeRadius: CGFloat = 46
    private let magnification: CGFloat = 10

    init(capture: CGImage, screenFrame: NSRect, scale: CGFloat,
         onPick: @escaping (NSColor) -> Void, onCancel: @escaping () -> Void) {
        self.scale = scale
        self.onPick = onPick
        self.onCancel = onCancel

        // Decode the capture once into a plain RGBA8 buffer → O(1) pixel
        // lookups while the loupe follows the cursor.
        let w = capture.width
        let h = capture.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(
            data: &buffer,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.interpolationQuality = .none
            ctx.draw(capture, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = buffer
        pixelWidth = w
        image = NSImage(cgImage: capture, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))

        super.init(frame: screenFrame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
        // Seed the loupe at the current cursor position.
        if let w = window {
            mouse = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        guard let m = mouse else { return }
        let color = color(at: m) ?? .black

        // Loupe center sits above the cursor (below when near the top edge),
        // clamped to the screen.
        var cx = m.x
        var cy = m.y - loupeRadius - 56
        if cy < loupeRadius { cy = m.y + loupeRadius + 56 }
        cx = min(max(cx, loupeRadius), bounds.width - loupeRadius)
        cy = min(max(cy, loupeRadius), bounds.height - loupeRadius)
        let circle = NSRect(
            x: cx - loupeRadius, y: cy - loupeRadius,
            width: loupeRadius * 2, height: loupeRadius * 2
        )

        // Zoomed frozen frame inside the loupe: the pixel under the cursor
        // lands exactly at the loupe center.
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        image.draw(in: NSRect(
            x: cx - magnification * m.x,
            y: cy - magnification * m.y,
            width: magnification * bounds.width,
            height: magnification * bounds.height
        ))
        NSGraphicsContext.current?.restoreGraphicsState()

        // Ring around the loupe (white + dark hairline, readable on any bg).
        let ringOuter = NSBezierPath(ovalIn: circle.insetBy(dx: -1, dy: -1))
        ringOuter.lineWidth = 1
        NSColor.black.withAlphaComponent(0.6).setStroke()
        ringOuter.stroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 2
        NSColor.white.setStroke()
        ring.stroke()

        // Crosshair at the loupe center marks the exact pixel.
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: cx - 9, y: cy))
        cross.line(to: NSPoint(x: cx + 9, y: cy))
        cross.move(to: NSPoint(x: cx, y: cy - 9))
        cross.line(to: NSPoint(x: cx, y: cy + 9))
        cross.lineWidth = 1.5
        NSColor.white.setStroke()
        cross.stroke()
        let crossShadow = cross.copy() as! NSBezierPath
        crossShadow.lineWidth = 3
        NSColor.black.withAlphaComponent(0.5).setStroke()
        crossShadow.stroke()

        // Hex label under the loupe.
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let hex = String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
        let label = NSAttributedString(string: "  \(hex)  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72),
        ])
        var lp = NSPoint(x: cx - label.size().width / 2, y: cy + loupeRadius + 10)
        lp.x = min(max(lp.x, 4), bounds.width - label.size().width - 4)
        lp.y = min(lp.y, bounds.height - label.size().height - 4)
        label.draw(at: lp)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let c = color(at: p) { onPick(c) } else { onCancel() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel()
    }

    private func color(at p: NSPoint) -> NSColor? {
        let px = Int(p.x * scale)
        let py = Int(p.y * scale)
        guard px >= 0, py >= 0, px < pixelWidth else { return nil }
        let idx = (py * pixelWidth + px) * 4
        guard idx + 2 < pixels.count else { return nil }
        return NSColor(
            srgbRed: CGFloat(pixels[idx]) / 255,
            green: CGFloat(pixels[idx + 1]) / 255,
            blue: CGFloat(pixels[idx + 2]) / 255,
            alpha: 1
        )
    }
}
