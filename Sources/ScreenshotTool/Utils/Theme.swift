import AppKit

/// 主题模式，对应配置文件 ~/.SnipMagic.ini 中的 `theme` 键。
/// 文件里没有这一项（老版本升级上来的配置）或值非法时，一律按 `.system`（跟随系统）处理。
enum ThemeMode: String {
    case system
    case light
    case dark

    /// 解析配置文件取值；兼容大小写、中文写法、"自动/auto" 等常见写法。
    /// 返回 nil 表示无法识别（调用方保持默认值）。
    static func parse(_ raw: String) -> ThemeMode? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "dark", "darkaqua", "暗色", "深色", "黑色":
            return .dark
        case "light", "aqua", "亮色", "浅色", "白色":
            return .light
        case "system", "auto", "follow", "跟随系统", "自动", "系统":
            return .system
        default:
            return nil
        }
    }

    /// 写入配置文件的值（始终使用英文枚举名，便于跨版本稳定解析）。
    var configValue: String { rawValue }

    /// 设置界面里显示的中文名称。
    var displayName: String {
        switch self {
        case .dark: return "暗色"
        case .light: return "亮色"
        case .system: return "跟随系统"
        }
    }

    /// 设置界面下拉框的展示顺序。
    static let displayOrder: [ThemeMode] = [.dark, .light, .system]
}

extension Notification.Name {
    /// 主题切换后广播：用 layer 背景色（`.cgColor` 是取值瞬间的快照）自绘的视图
    /// 需要重新取一次色。
    static let appThemeDidChange = Notification.Name("com.mimo.snipmagic.themeDidChange")
}

enum Theme {
    // MARK: - Mode

    private(set) static var mode: ThemeMode = .system

    /// 当前是否应使用暗色配色。`.system` 时按系统/当前 appearance 判定。
    static var isDark: Bool {
        switch mode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// 应用主题：设置全局 appearance 并广播刷新。
    /// - system → `NSApp.appearance = nil`（跟随系统）
    /// - light  → `.aqua`
    /// - dark   → `.darkAqua`
    static func apply(mode newMode: ThemeMode) {
        mode = newMode
        switch newMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NotificationCenter.default.post(name: .appThemeDidChange, object: nil)
    }

    // MARK: - Colors
    // 亮色沿用原有取值；暗色用偏灰的黑（#212121 一带）而不是纯黑 + 纯白，
    // 对比度够但不刺眼。

    static var windowBackground: NSColor {
        isDark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    static var toolbarBackground: NSColor {
        isDark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)
    }

    static var sidebarBackground: NSColor {
        isDark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
    }

    static var canvasBackground: NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.09, alpha: 1)
            : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    }

    /// Same blue as the active P1/P2 tab.
    static var accent: NSColor { NSColor.systemBlue }
    static var accentPressed: NSColor { NSColor.systemBlue.withAlphaComponent(0.82) }
    static var danger: NSColor { NSColor.systemRed }
    static var mutedText: NSColor { NSColor.secondaryLabelColor }

    // MARK: - 侧栏工具图标

    /// 侧栏工具图标的**常态**颜色。
    ///
    /// 刻意不用 `secondaryLabelColor`：它在亮色下只有约 50% 黑，而侧栏那批图标
    /// （`square.dashed` / `oval` / `rectangle` 这些**细线**符号）本来就笔画轻，
    /// 再降到半透明就成了"灰蒙蒙一片"，看不出画的是什么。这里用 `labelColor`
    /// —— 亮色下约 85% 黑、暗色下接近白，对比度直接拉满。
    /// 返回的是**动态系统色**，随 appearance 自动解析，不必等主题广播重取。
    static var toolIconIdle: NSColor { NSColor.labelColor }

    /// 悬停时的底衬。用 labelColor 的低透明度叠层：亮色是淡灰、暗色是淡白，
    /// 一套取值两种主题都成立。
    ///
    /// 刻意**不给悬停单独配一个更深的图标色** —— 常态已经是 `labelColor`（最实的一档），
    /// 再往上只能动背景。所以"悬停"这件事靠底衬表达，图标本身不变。
    static var toolIconHoverBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.09) }

    /// 按下时的底衬，比悬停略重。
    static var toolIconPressedBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.16) }

    static let cornerRadius: CGFloat = 8

    /// 取「动态系统色」在当前 appearance 下的 CGColor。
    /// `NSColor.cgColor` 是按取值瞬间的 `NSAppearance.current` 解析的，而 layer
    /// 背景不会随后续 appearance 变化自动更新——不在正确的上下文里取值，就会
    /// 拿到旧主题的颜色（切到暗色后分隔线仍是亮色那种）。
    static func resolved(_ color: NSColor) -> CGColor {
        guard let app = NSApp else { return color.cgColor }
        var cg: CGColor?
        app.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        return cg ?? color.cgColor
    }
}

/// 自身 appearance 变化时回调（系统亮/暗切换、全局 appearance 切换都会触发），
/// 供自绘 layer 颜色的视图重新取色。
final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

enum AppInfo {
    /// 产品名：主窗口标题、托盘提示、App 菜单「关于 / 隐藏 / 退出」都用它。
    static let name = "截图大师 SnipMagic"
    static let bundleID = "com.mimo.snipmagic"
    /// Keep in sync with Resources/Info.plist CFBundleShortVersionString.
    static let version = "3.3.0"
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
        layer?.backgroundColor = Theme.resolved(Theme.accent)

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
        layer?.backgroundColor = Theme.resolved(Theme.accentPressed)
        super.mouseDown(with: event)
        layer?.backgroundColor = Theme.resolved(Theme.accent)
    }
}
