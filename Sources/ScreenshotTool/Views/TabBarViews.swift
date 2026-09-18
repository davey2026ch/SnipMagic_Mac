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

/// Label that never intercepts mouse events, so the drag/click handling of
/// the button underneath keeps working.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A tightly-packed, Excel-style tab chip rendered at a comfortable size:
/// a flat button filling a fixed-height chip with only the top corners
/// rounded (like a browser/Excel tab), active = accent + white semibold
/// label. Name-only, perfectly centered both horizontally and vertically
/// (closing lives in the right-click menu).
final class TabChipView: NSView {
    let tabButton: DraggableTabButton

    init(title: String, index: Int, active: Bool, comparing: Bool) {
        let highlighted = active || comparing
        // The button itself carries no title — NSButton's cell-based title
        // layout refuses to center reliably at this chip size, so the text
        // is drawn by a pass-through label constrained to dead center.
        tabButton = DraggableTabButton(title: "", target: nil, action: nil)
        tabButton.tag = index
        tabButton.isBordered = false
        tabButton.wantsLayer = true
        tabButton.layer?.backgroundColor = Theme.resolved(active
            ? Theme.accent
            : (comparing ? Theme.accent.withAlphaComponent(0.82) : NSColor.controlBackgroundColor))
        // Top-corners-only rounding → adjacent chips form a tab strip,
        // visually "rooted" in the strip's bottom hairline.
        tabButton.layer?.cornerRadius = 6
        tabButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tabButton.layer?.borderColor = Theme.resolved(NSColor.separatorColor.withAlphaComponent(0.5))
        tabButton.layer?.borderWidth = 0.5

        let label = PassThroughLabel(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        label.textColor = highlighted ? .white : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabButton)
        addSubview(label)

        NSLayoutConstraint.activate([
            // Fixed chip height — NSStackView alone would keep the tiny
            // intrinsic button height, which looked cramped.
            heightAnchor.constraint(equalToConstant: 28),

            // Button fills the whole chip so neighbouring chips touch edge-to-edge.
            tabButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabButton.topAnchor.constraint(equalTo: topAnchor),
            tabButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Title: dead-center both axes, with symmetric padding driving the
            // chip's width (label hugs → chip = label + 2 × padding).
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Flipped views

/// NSImageView anchored at the top-left (flipped). The left pane's CanvasView
/// is flipped too, so during compare mode both panes share the same anchor —
/// without this the right image hugs the bottom of its scroll view and looks
/// vertically misaligned.
final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
}

/// Plain flipped container used as the compare pane's document view. It wraps
/// the image with the same 28pt padding the left canvas uses, so the right
/// image lines up with the left one (top margin included) and scroll-sync
/// math stays symmetric.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
