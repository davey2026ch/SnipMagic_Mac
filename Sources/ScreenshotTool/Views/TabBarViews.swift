import AppKit

// MARK: - Draggable tab button

/// Tab button that behaves like a normal click when released in place, and
/// starts a drag session (for side-by-side compare) when the mouse moves
/// more than a few points while held down.
final class DraggableTabButton: NSButton, NSDraggingSource, NSPasteboardWriting {
    static let dragType = NSPasteboard.PasteboardType("com.mimo.screenshottool.tab-drag")

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        var dragged = false
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if e.type == .leftMouseUp { break }
            let dx = e.locationInWindow.x - start.x
            let dy = e.locationInWindow.y - start.y
            if !dragged && hypot(dx, dy) > 6 {
                dragged = true
                let item = NSDraggingItem(pasteboardWriter: self)
                item.setDraggingFrame(bounds, contents: dragSnapshot())
                beginDraggingSession(with: [item], event: event, source: self)
                break
            }
        }
        if !dragged {
            performClick(nil)
        }
    }

    private func dragSnapshot() -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(bounds.width) * 2),
            pixelsHigh: max(1, Int(bounds.height) * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) ?? NSBitmapImageRep()
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage()
        img.addRepresentation(rep)
        return img
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        alphaValue = 0.35
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
    }

    // MARK: NSPasteboardWriting

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [Self.dragType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        "\(tag)"
    }
}

// MARK: - Tab chip

/// A tab-strip chip: draggable title button + small close ✕ at the top-right
/// corner (visible only on the active tab). Clicking ✕ asks to save when the
/// tab has unsaved changes (handled by the owner via requestCloseTab).
final class TabChipView: NSView {
    let tabButton: DraggableTabButton
    let closeButton = NSButton(title: "✕", target: nil, action: nil)

    init(title: String, index: Int, active: Bool, comparing: Bool) {
        tabButton = DraggableTabButton(title: title, target: nil, action: nil)
        tabButton.bezelStyle = .rounded
        tabButton.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        tabButton.tag = index
        if active || comparing {
            tabButton.bezelColor = Theme.accent
            tabButton.contentTintColor = .white
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabButton)

        closeButton.tag = index
        closeButton.isBordered = false
        closeButton.isTransparent = false
        closeButton.font = .systemFont(ofSize: 10, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !active
        closeButton.toolTip = "关闭页签"
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            tabButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabButton.topAnchor.constraint(equalTo: topAnchor),
            tabButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: tabButton.trailingAnchor, constant: 0),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Drop-target scroll view

/// NSScrollView that forwards drag-and-drop callbacks so the editor VC can
/// implement "drag a tab to the right half to compare" without subclassing
/// the canvas.
final class EditorScrollView: NSScrollView {
    var dragFeedback: ((NSDraggingInfo) -> NSDragOperation)?
    var dragExited: ((NSDraggingInfo) -> Void)?
    var dropHandler: ((NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragFeedback?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragFeedback?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender { dragExited?(sender) }
    }

    /// Recent SDKs no longer expose performDrop as an overridable Swift method
    /// on NSView; declaring it @objc still implements the NSDraggingDestination
    /// optional method (ObjC dispatches by selector).
    @objc func performDrop(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?(sender) ?? false
    }
}
