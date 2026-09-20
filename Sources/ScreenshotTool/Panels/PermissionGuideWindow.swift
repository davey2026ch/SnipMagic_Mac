import AppKit

/// First-run guide for Screen Recording permission.
final class PermissionGuideWindowController: NSWindowController {
    private let onRequest: () -> Void
    private let onDone: () -> Void
    private var becomeActiveObserver: NSObjectProtocol?
    private var isChecking = false

    init(onRequest: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.onRequest = onRequest
        self.onDone = onDone
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "需要屏幕录制权限"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        observeAppActivation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    private func observeAppActivation() {
        // User often flips the switch in System Settings then switches back —
        // recheck automatically instead of making them click blindly.
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.autoRecheckAfterActivation()
        }
    }

    private func autoRecheckAfterActivation() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            // Small delay so TCC finishes settling after the Settings toggle.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let ok = await ScreenCaptureService.shared.probePermissionNow()
            self.isChecking = false
            if ok {
                self.finishSuccessfully()
            }
        }
    }

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 430))
        window?.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        let title = NSTextField(labelWithString: "首次使用需要开启「屏幕录制」权限")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        let body = NSTextField(wrappingLabelWithString: """
        1. 点「申请录屏权限」，系统会弹出授权提示（若已弹过可忽略）
        2. 打开 系统设置 → 隐私与安全性 → 屏幕录制
        3. 在列表中找到「截图大师 SnipMagic」并打开开关
           若列表没有本软件：点左下角「+」，选择 应用程序 里的「截图大师SnipMagic」
        4. 开启后请点下方「退出并重新打开」——macOS 要求完全重启进程，权限才会生效
        """)
        body.font = .systemFont(ofSize: 13)
        body.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(body)

        let pathHint = NSTextField(wrappingLabelWithString: """
        提示：请始终从「应用程序」里的「截图大师SnipMagic」启动。路径变动或每次重新打包（代码签名变化）后，系统可能要求重新授权。
        """)
        pathHint.font = .systemFont(ofSize: 12)
        pathHint.textColor = .secondaryLabelColor
        pathHint.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(pathHint)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let request = NSButton(title: "申请录屏权限", target: self, action: #selector(requestClicked))
        request.bezelStyle = .rounded
        let open = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        open.bezelStyle = .rounded
        let restart = NSButton(title: "退出并重新打开", target: self, action: #selector(restartClicked))
        restart.bezelStyle = .rounded
        let recheck = NSButton(title: "我已开启，继续", target: self, action: #selector(recheck))
        recheck.bezelStyle = .rounded
        recheck.keyEquivalent = "\r"
        buttons.addArrangedSubview(request)
        buttons.addArrangedSubview(open)
        buttons.addArrangedSubview(restart)
        buttons.addArrangedSubview(recheck)
        stack.addArrangedSubview(buttons)
    }

    private func finishSuccessfully() {
        window?.close()
        onDone()
    }

    @objc private func requestClicked() {
        onRequest()
    }

    @objc private func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for s in urls {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                break
            }
        }
    }

    @objc private func restartClicked() {
        ScreenCaptureService.relaunchApp()
    }

    @objc private func recheck() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            let ok = await ScreenCaptureService.shared.probePermissionNow()
            self.isChecking = false
            if ok {
                self.finishSuccessfully()
            } else {
                let a = NSAlert()
                a.messageText = "权限仍未生效"
                a.informativeText = """
                macOS 对「屏幕录制」的要求是：在系统设置里打开开关后，必须完全退出本软件再重新打开，当前进程才会拿到权限。

                请确认：
                1. 「屏幕录制」列表里能看到「截图大师 SnipMagic」且开关已打开
                2. 若列表没有：点「+」添加 应用程序/截图大师SnipMagic
                3. 点下方「退出并重新打开」后再试

                若开关是打开的但仍无效：多半是重新打包后代码签名变了，可先关掉开关再打开，或删除列表项后重新添加。
                """
                a.addButton(withTitle: "退出并重新打开")
                a.addButton(withTitle: "再检查一次")
                a.addButton(withTitle: "取消")
                let resp = a.runModal()
                if resp == .alertFirstButtonReturn {
                    ScreenCaptureService.relaunchApp()
                } else if resp == .alertSecondButtonReturn {
                    self.recheck()
                }
            }
        }
    }
}
