import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var editorWindow: EditorWindowController!
    private var captureOverlay: CaptureOverlayController?
    private var longSession: LongCaptureSessionController?
    private var permissionGuide: PermissionGuideWindowController?
    private var launchAtLoginObserver: DefaultsObserver?

    private let defaultsKeyLogin = "launchAtLogin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        MinerUOCRService.ensureConfigFile() // ~/.截图工具 不存在则自动创建
        // 主题：配置里没有 theme 键（老版本升级上来的文件）时按「跟随系统」处理。
        // 必须在建窗之前应用，否则首帧会用旧配色。
        let persisted = MinerUOCRService.loadConfig()
        Theme.apply(mode: persisted.theme)
        setupMenu()

        editorWindow = EditorWindowController()

        TrayService.shared.onCapture = { [weak self] in
            self?.beginCapture()
        }
        TrayService.shared.onLongCapture = { [weak self] in
            self?.beginLongCapture()
        }
        TrayService.shared.onOpenEditor = { [weak self] in
            self?.editorWindow.showAndActivate()
        }
        TrayService.shared.onQuit = {
            NSApp.terminate(nil)
        }
        TrayService.shared.install()

        HotkeyService.shared.onHotkey = { [weak self] in
            self?.beginCapture()
        }
        HotkeyService.shared.registerDefault()
        // 配置文件里保存过快捷键则覆盖默认值（设置界面保存时写入）
        if let hk = persisted.captureHotkey {
            HotkeyService.shared.register(keyCode: hk.keyCode, modifiers: hk.modifiers)
        }
        if let lk = persisted.longHotkey {
            HotkeyService.shared.registerLong(keyCode: lk.keyCode, modifiers: lk.modifiers)
        }

        editorWindow.editorVC.onCaptureRequest = { [weak self] in
            self?.beginCapture()
        }
        editorWindow.editorVC.onLongCaptureRequest = { [weak self] in
            self?.beginLongCapture()
        }

        // Show editor on launch
        editorWindow.showAndActivate()

        // Permission: must actively request so macOS registers us in
        // System Settings → Privacy & Security → Screen Recording.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let ok = await ScreenCaptureService.shared.probePermissionNow()
            if !ok {
                self.requestScreenPermissionAndGuide()
            }
        }

        // 启动后静默检查更新：只有「发现新版本」才会弹窗征求同意后再下载安装；
        // 网络不通、已是最新、不是以 .app 运行，都保持安静不打扰。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(UpdateService.launchCheckDelay * 1_000_000_000))
            UpdateService.shared.checkOnLaunch()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.unregister()
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 \(AppInfo.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = UserDefaults.standard.bool(forKey: defaultsKeyLogin) ? .on : .off
        appMenu.addItem(loginItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: #selector(UndoManager.redo), keyEquivalent: "y")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenuItem.submenu = editMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        let captureItem = NSMenuItem(title: "区域截图", action: #selector(menuCapture), keyEquivalent: "r")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        fileMenu.addItem(captureItem)
        let longCaptureItem = NSMenuItem(title: "长截图（滚动拼接）", action: #selector(menuLongCapture), keyEquivalent: "e")
        longCaptureItem.keyEquivalentModifierMask = [.command, .shift]
        longCaptureItem.target = self
        fileMenu.addItem(longCaptureItem)
        let saveItem = NSMenuItem(title: "保存…", action: #selector(menuSave), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuCapture() {
        beginCapture()
    }

    @objc private func menuLongCapture() {
        beginLongCapture()
    }

    @objc private func menuSave() {
        editorWindow.showAndActivate()
        editorWindow.editorVC.saveCurrentTab()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(enable, forKey: defaultsKeyLogin)
            sender.state = enable ? .on : .off
        } catch {
            let a = NSAlert()
            a.messageText = "开机自启设置失败"
            a.informativeText = error.localizedDescription + "\n（需要将 App 安装到「应用程序」文件夹后才可使用）"
            a.runModal()
        }
    }

    // MARK: - Capture flow

    /// Triggers the system TCC prompt so the app appears in Screen Recording list.
    private func requestScreenPermissionAndGuide() {
        ScreenCaptureService.shared.requestPermission()
        // Also poke ScreenCaptureKit — on newer macOS this also registers the app.
        Task { @MainActor in
            _ = try? await ScreenCaptureService.shared.probeShareableContent()
            let ok = await ScreenCaptureService.shared.probePermissionNow()
            if !ok {
                self.showPermissionGuide()
            }
        }
    }

    private func showPermissionGuide() {
        permissionGuide?.close()
        permissionGuide = PermissionGuideWindowController(
            onRequest: { [weak self] in
                self?.requestScreenPermissionAndGuide()
            },
            onDone: { [weak self] in
                self?.beginCapture()
            }
        )
        permissionGuide?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func beginCapture() {
        // Re-entry guard: cancel existing overlay
        if let existing = captureOverlay {
            existing.cancel()
            captureOverlay = nil
        }

        // Instant check first — do not wait on ScreenCaptureKit before giving feedback.
        guard ScreenCaptureService.shared.hasScreenPermission else {
            requestScreenPermissionAndGuide()
            return
        }

        let mouse = NSEvent.mouseLocation
        let editorVisible = editorWindow.window?.isVisible == true
            && !(editorWindow.window?.isMiniaturized ?? true)
        editorWindow.window?.orderOut(nil)

        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
                // 区域截图同样不含鼠标箭头：overlay 用这张冻结帧当背景，光标不入画，
                // 系统绘制的真实光标仍叠在 overlay 之上，用户照样看得见鼠标位置。
                let image = try await ScreenCaptureService.shared.capture(screen: screen)

                let overlay = CaptureOverlayController(screen: screen, image: image)
                overlay.overlayDelegate = self
                self.captureOverlay = overlay
                overlay.present()
            } catch {
                if editorVisible {
                    self.editorWindow.showAndActivate()
                }
                let a = NSAlert()
                a.messageText = "截图失败"
                switch error {
                case CaptureError.permissionDenied:
                    a.informativeText = """
                    缺少屏幕录制权限，或权限尚未在当前进程生效。

                    在系统设置里打开开关后，必须完全退出本软件再重新打开。
                    （重新打包 / 更换启动路径后，也可能需要重新授权）
                    """
                    self.showPermissionGuide()
                default:
                    a.informativeText = error.localizedDescription
                }
                a.runModal()
            }
        }
    }

    private func restoreEditorIfNeeded() {
        editorWindow.showAndActivate()
    }

    // MARK: - Long capture flow

    func beginLongCapture() {
        // Re-entry guards
        if let existing = captureOverlay {
            existing.cancel()
            captureOverlay = nil
        }
        if let session = longSession {
            session.cancel()
            longSession = nil
        }

        guard ScreenCaptureService.shared.hasScreenPermission else {
            requestScreenPermissionAndGuide()
            return
        }

        let mouse = NSEvent.mouseLocation
        editorWindow.window?.orderOut(nil)

        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
                // No cursor: the overlay shows this frame as its backdrop and a
                // frozen cursor would be misleading.
                let image = try await ScreenCaptureService.shared.capture(
                    screen: screen,
                    excludingWindowNumbers: [],
                    showsCursor: false
                )

                let overlay = CaptureOverlayController(screen: screen, image: image, mode: .longScreenshot)
                overlay.overlayDelegate = self
                self.captureOverlay = overlay
                overlay.present()
            } catch {
                self.editorWindow.showAndActivate()
                let a = NSAlert()
                a.messageText = "长截图启动失败"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }
}

extension AppDelegate: CaptureOverlayDelegate {
    func captureOverlayDidCancel(_ overlay: CaptureOverlayController) {
        captureOverlay = nil
        // Restore editor
        if editorWindow.window?.isVisible != true {
            // Only show if it was open before; default show
            editorWindow.showAndActivate()
        }
    }

    func captureOverlay(_ overlay: CaptureOverlayController, didCapture image: CGImage, on screen: NSScreen) {
        captureOverlay = nil
        editorWindow.showAndActivate()
        editorWindow.editorVC.addCapturedImage(image)
    }

    func captureOverlay(_ overlay: CaptureOverlayController, didSelectRegion region: CGRect, on screen: NSScreen) {
        captureOverlay = nil
        let session = LongCaptureSessionController(screen: screen, region: region)
        longSession = session
        session.start(delegate: self)
    }
}

extension AppDelegate: LongCaptureSessionDelegate {
    func longCaptureSession(_ session: LongCaptureSessionController, didFinish image: CGImage) {
        longSession = nil
        editorWindow.showAndActivate()
        editorWindow.editorVC.addCapturedImage(image, title: "长截图")
    }

    func longCaptureSessionDidCancel(_ session: LongCaptureSessionController) {
        longSession = nil
        if editorWindow.window?.isVisible != true {
            editorWindow.showAndActivate()
        }
    }
}

// Unused helper placeholder
final class DefaultsObserver {}
