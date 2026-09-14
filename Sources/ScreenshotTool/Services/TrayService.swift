import AppKit

final class TrayService {
    static let shared = TrayService()

    private var statusItem: NSStatusItem?
    var onCapture: (() -> Void)?
    var onLongCapture: (() -> Void)?
    var onOpenEditor: (() -> Void)?
    var onQuit: (() -> Void)?

    private init() {}

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // Use SF Symbol so we don't need a custom asset.
            let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "截图工具")
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppInfo.name
        }

        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "区域截图", action: #selector(handleCapture), keyEquivalent: "r")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        let longItem = NSMenuItem(title: "长截图（滚动拼接）", action: #selector(handleLongCapture), keyEquivalent: "l")
        longItem.keyEquivalentModifierMask = [.command, .shift]
        longItem.target = self
        menu.addItem(longItem)

        let openItem = NSMenuItem(title: "打开编辑窗口", action: #selector(handleOpen), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func handleCapture() { onCapture?() }
    @objc private func handleLongCapture() { onLongCapture?() }
    @objc private func handleOpen() { onOpenEditor?() }
    @objc private func handleQuit() { onQuit?() }
}
