import AppKit

// MARK: - Draggable tab button

/// Tab button that behaves like a normal click when released in place, and
/// enters a manual drag-tracking mode when the mouse moves more than a few
/// points while held down. The drag is tracked entirely in the event loop —
/// no NSDraggingSession / pasteboard machinery, so the owner gets deterministic
/// callbacks for every phase (all points in window coordinates).
final class DraggableTabButton: NSButton {
    enum DragPhase {
        case began    // threshold passed, drag tracking started
        case moved    // mouse moved while dragging
        case ended    // mouse released while dragging
        case cancelled
    }

    var onDrag: ((DragPhase, NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        var dragging = false

        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                if dragging {
                    alphaValue = 1
                    onDrag?(.cancelled, start)
                } else {
                    performClick(nil)
                }
                return
            }
            if e.type == .leftMouseUp {
                if dragging {
                    alphaValue = 1
                    onDrag?(.ended, e.locationInWindow)
                } else {
                    performClick(nil)
                }
                return
            }
            let p = e.locationInWindow
            if !dragging {
                guard hypot(p.x - start.x, p.y - start.y) > 6 else { continue }
                dragging = true
                alphaValue = 0.4
                onDrag?(.began, p)
            } else {
                onDrag?(.moved, p)
            }
        }
    }
}

// MARK: - Tab chip

/// A tightly-packed Excel-style tab chip: a flat rectangular button filling the
/// whole chip (active = accent background + white label, inactive = light gray
/// with a hairline border), plus a small ✕ overlaid at the top-right corner of
/// the *active* chip only (it does not consume layout width).
final class TabChipView: NSView {
    let tabButton: DraggableTabButton
    let closeButton = NSButton(title: "✕", target: nil, action: nil)

    init(title: String, index: Int, active: Bool, comparing: Bool) {
        let highlighted = active || comparing
        tabButton = DraggableTabButton(title: "  \(title)  ", target: nil, action: nil)
        tabButton.tag = index
        tabButton.isBordered = false
        tabButton.wantsLayer = true
        tabButton.layer?.backgroundColor = (highlighted ? Theme.accent : NSColor.controlBackgroundColor).cgColor
        tabButton.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        tabButton.layer?.borderWidth = 0.5
        tabButton.contentTintColor = highlighted ? .white : .labelColor
        tabButton.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabButton)

        closeButton.tag = index
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10, weight: .bold)
        closeButton.contentTintColor = highlighted ? .white : .secondaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !active
        closeButton.toolTip = "关闭页签"
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // Button fills the whole chip so neighbouring chips touch edge-to-edge.
            tabButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabButton.topAnchor.constraint(equalTo: topAnchor),
            tabButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            // ✕ overlays the button's top-right corner (no layout width).
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            closeButton.widthAnchor.constraint(equalToConstant: 15),
            closeButton.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
