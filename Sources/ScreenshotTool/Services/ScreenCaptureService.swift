import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case noDisplay
    case captureFailed
    case permissionDenied
}

/// Captures the full screen (with cursor) at native pixel resolution.
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    private init() {}

    var hasScreenPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Force a ScreenCaptureKit content query; on first call macOS shows the
    /// Screen Recording prompt and registers this bundle in System Settings.
    func probeShareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    /// Secondary check via ScreenCaptureKit — useful after the user toggles the
    /// switch in System Settings while this process is still running.
    func probePermissionNow() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return hasScreenPermission
        }
    }

    /// Fully quit and relaunch so TCC grants actually take effect.
    static func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4 && open -n \"\(path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    /// Full-screen capture of the display containing the given point (global coords, top-left origin from NSEvent).
    func captureDisplay(at screenPoint: CGPoint) async throws -> CGImage {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw CaptureError.noDisplay }

        // NSEvent locationInWindow / global mouse uses bottom-left origin.
        // Convert to top-left for easier matching with CGDisplay bounds later if needed.
        var target = screens.first { NSMouseInRect(screenPoint, $0.frame, false) }
        if target == nil {
            // Fallback: nearest screen
            target = screens.min(by: { s1, s2 in
                let c1 = NSPoint(x: s1.frame.midX, y: s1.frame.midY)
                let c2 = NSPoint(x: s2.frame.midX, y: s2.frame.midY)
                return dist(screenPoint, c1) < dist(screenPoint, c2)
            })
        }
        guard let screen = target else { throw CaptureError.noDisplay }
        return try await capture(screen: screen)
    }

    func capture(screen: NSScreen) async throws -> CGImage {
        guard hasScreenPermission else { throw CaptureError.permissionDenied }

        let filter = try await contentFilter(for: screen)
        let config = SCStreamConfiguration()
        // Native pixel size of the display
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return image
    }

    private func contentFilter(for screen: NSScreen) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = display(for: screen, in: content.displays) else {
            throw CaptureError.noDisplay
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private func display(for screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return displays.first
        }
        let cgID = CGDirectDisplayID(screenNumber.uint32Value)
        return displays.first { $0.displayID == cgID } ?? displays.first
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Build a solid white-backed JPEG/PNG CGImage from any CGImage (fills transparency).
    static func flatten(_ image: CGImage, fillWhite: Bool) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if fillWhite {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

enum ImageIOExporter {
    static func save(_ image: CGImage, to url: URL, as type: NSBitmapImageRep.FileType) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        let data: Data
        if type == .jpeg {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) ?? Data()
        } else {
            data = rep.representation(using: .png, properties: [:]) ?? Data()
        }
        try data.write(to: url)
    }
}
