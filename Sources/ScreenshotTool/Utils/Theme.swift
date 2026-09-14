import AppKit

enum Theme {
    static let windowBackground = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let toolbarBackground = NSColor(calibratedWhite: 0.98, alpha: 1)
    static let sidebarBackground = NSColor(calibratedWhite: 0.97, alpha: 1)
    static let canvasBackground = NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    /// Same blue as the active P1/P2 tab.
    static let accent = NSColor.systemBlue
    static let accentPressed = NSColor.systemBlue.withAlphaComponent(0.82)
    static let danger = NSColor.systemRed
    static let mutedText = NSColor.secondaryLabelColor

    static let cornerRadius: CGFloat = 8

    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}

enum AppInfo {
    static let name = "截图工具"
    static let bundleID = "com.mimo.screenshottool"
    /// Keep in sync with Resources/Info.plist CFBundleShortVersionString.
    static let version = "1.5.5"
}

/// Borderless color swatch: flat rounded fill in the current brush color, no
/// frame. Replaces NSColorWell, whose black border looked harsh against the
/// light sidebar. A click opens the custom color panel (not NSColorPanel).
final class ColorSwatchButton: NSButton {
    var color: NSColor = .systemRed {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Primary toolbar action: system-blue fill (matches active tab), white icon + text, tight gap.
final class CapturePrimaryButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init(title: String, icon: String = "viewfinder", target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        configure(title: title, icon: icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(title: String, icon: String) {
        // Clear NSButton's own title — otherwise the default "Button"/「按钮」
        // is still drawn under our custom icon+label stack.
        self.title = ""
        self.attributedTitle = NSAttributedString(string: "")
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.accent.cgColor

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        }

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.backgroundColor = .clear
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        addSubview(stack)

        // Center icon+label; equal padding on all sides (no extra gap after the text).
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = Theme.accentPressed.cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = Theme.accent.cgColor
    }
}
