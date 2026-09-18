import AppKit

/// 更新过程中的小进度面板。
/// 下载阶段显示百分比与字节数，安装阶段切成不确定进度（转圈式等待）。
final class UpdateProgressWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let panel = window else { return }

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let stack = NSStackView(views: [statusLabel, bar, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 不铺 layer 底色：NSPanel 自带的窗口背景会跟着 appearance 走，
        // 亮/暗主题切换无需另行重取颜色。
        let root = NSView()
        root.addSubview(stack)
        panel.contentView = root

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
    }

    func present() {
        guard let panel = window else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(status: String, detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
    }

    func setIndeterminate(_ flag: Bool) {
        if flag {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        } else {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
    }

    func updateProgress(done: Int64, total: Int64) {
        guard total > 0 else { return }
        bar.doubleValue = min(max(Double(done) / Double(total), 0), 1)
    }
}
