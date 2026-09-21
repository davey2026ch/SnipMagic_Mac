import AppKit

/// 侧栏工具按钮。
///
/// 原生 `.smallSquare` 切换按钮的按下态太轻，亮色主题下几乎看不出
/// "接下来画什么"，所以这三件事自己画：
/// - **激活态**：底色铺主题蓝 + 图标转白（与顶部「开始截图」、活动页签同一套配色）；
/// - **悬停态**：淡色底衬，鼠标指到哪个一眼可见（纯图标列没有底衬会显得很"死"）；
/// - **锁定态**：右下角挂一个小锁角标（双击本按钮锁定 → 连续绘制，再单击解除）。
///
/// 用 unbordered + 自绘 layer，是照 `CapturePrimaryButton` 的路子来的：
/// 系统 bezel 的配色在不同主题下不好统一，自绘反而更稳。
///
/// ⚠️ **常态图标色不要改回 `secondaryLabelColor`**。那一档在亮色下只有约 50% 黑，
/// 而这批符号（`square.dashed` / `oval` / `rectangle`…）笔画本来就细，
/// 再压一半透明度就是用户说的"灰蒙蒙"。现在走 `Theme.toolIconIdle`（= labelColor），
/// 同时把符号字重从 `.regular` 提到 `.medium`、字号 14 → 15 —— 三处一起才够精神。
final class ToolButton: NSButton {
    let tool: ToolKind

    /// 当前是否为此工具（铺蓝底）。由 `EditorViewController` 统一同步。
    var isActiveTool = false { didSet { applyAppearance() } }
    /// 是否已锁定（右下角小锁）。
    var isLocked = false { didSet { applyAppearance() } }

    private let lockBadge = NSImageView()
    /// 无 SF Symbol 时退化成文字（如「T」），要把文字留一份自己上色 ——
    /// `title` 走系统配色，在蓝底上会变成黑字看不见。
    private var labelText = ""
    /// 符号图标的显示规格：字号 / 字重。
    private static let symbolPointSize: CGFloat = 15
    private static let symbolWeight: NSFont.Weight = .medium

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            applyAppearance()
        }
    }
    private var trackingArea: NSTrackingArea?

    init(tool: ToolKind, target: AnyObject?, action: Selector?) {
        self.tool = tool
        super.init(frame: .zero)
        self.toolTip = tool.tooltip
        self.target = target
        self.action = action
        // 点一下就要"选上"，不做任何拖拽 / 长按语义，所以是普通按下式按钮。
        setButtonType(.momentaryPushIn)
        identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
        // 图标按钮没有文字标题，读屏会念成"按钮"，补一个无障碍名。
        setAccessibilityLabel(tool.displayName)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .none
        configureContent()
        configureLockBadge()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureContent() {
        title = ""
        imagePosition = .imageOnly
        if tool == .text {
            // 文本工具用加粗「T」，比 SF Symbol 更好认
            labelText = "T"
            font = .systemFont(ofSize: 16, weight: .semibold)
            imagePosition = .noImage
        } else if let image = NSImage(systemSymbolName: tool.systemImage,
                                      accessibilityDescription: tool.displayName)?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize,
                                           weight: Self.symbolWeight)) {
            self.image = image
        } else {
            labelText = tool.shortLabel
            font = .systemFont(ofSize: 10, weight: .semibold)
            imagePosition = .noImage
        }
    }

    private func configureLockBadge() {
        lockBadge.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "已锁定")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        lockBadge.imageScaling = .scaleProportionallyUpOrDown
        lockBadge.isHidden = true
        lockBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lockBadge)
        NSLayoutConstraint.activate([
            lockBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            lockBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            lockBadge.widthAnchor.constraint(equalToConstant: 11),
            lockBadge.heightAnchor.constraint(equalToConstant: 11)
        ])
    }

    /// 重新取色。layer 的 `.cgColor` 是取值瞬间的快照，切主题（或系统亮/暗切换）
    /// 后必须重来一次，否则蓝底会停在旧配色上。
    private func applyAppearance() {
        let active = isActiveTool
        if active {
            layer?.backgroundColor = Theme.resolved(Theme.accent)
        } else if isHovered {
            layer?.backgroundColor = Theme.resolved(Theme.toolIconHoverBackground)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        // 常态图标色见类注释：不用 secondaryLabelColor。悬停不改图标色，
        // 区别全在底衬上（常态已经是 labelColor，没有更实的一档可用了）。
        let tint: NSColor = active ? .white : Theme.toolIconIdle
        contentTintColor = tint
        if !labelText.isEmpty {
            attributedTitle = NSAttributedString(string: labelText, attributes: [
                .font: font ?? .systemFont(ofSize: 12),
                .foregroundColor: tint
            ])
        }
        lockBadge.isHidden = !isLocked
        // 蓝底上用白锁，浅底上用主题蓝 —— 两种状态下都看得清
        lockBadge.contentTintColor = active ? .white : Theme.accent
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    /// 按下时给一点即时反馈（未激活态才需要：激活态本来就是蓝底）。
    override func mouseDown(with event: NSEvent) {
        if !isActiveTool {
            layer?.backgroundColor = Theme.resolved(Theme.toolIconPressedBackground)
        }
        super.mouseDown(with: event)
        applyAppearance()
    }
}
