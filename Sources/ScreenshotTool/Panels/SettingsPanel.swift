import AppKit
import Carbon.HIToolbox

/// Toolbar settings sheet: capture/long-capture hotkeys, mosaic density, stroke
/// thickness, MinerU extract timeout & token (persisted to ~/.截图工具).
final class SettingsPanel: NSViewController {
    private let onApply: (
        _ hotkey: (UInt32, UInt32)?,
        _ longHotkey: (UInt32, UInt32)?,
        _ mosaic: CGFloat,
        _ thickness: CGFloat,
        _ minerUToken: String,
        _ minerUTimeout: TimeInterval,
        _ theme: ThemeMode
    ) -> Void

    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let longHotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let mosaicField = NSTextField()
    private let thicknessField = NSTextField()
    private let timeoutField = NSTextField()
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// token 输入：密码框（默认）与明文框叠放，用小眼睛按钮切换。
    private let tokenSecureField = NSSecureTextField()
    private let tokenPlainField = NSTextField()
    private let tokenEyeButton = NSButton()
    private let recorder = HotkeyRecorderMonitor()
    private var currentHotkeyText: String
    private var currentLongHotkeyText: String
    private var pendingHotkey: (UInt32, UInt32)?
    private var pendingLongHotkey: (UInt32, UInt32)?

    private enum RecordTarget { case capture, longCapture }
    private var recordingTarget: RecordTarget?

    private let mosaicSeed: CGFloat
    private let thicknessSeed: CGFloat
    private let themeSeed: ThemeMode
    private let previousHotkey: (keyCode: UInt32, modifiers: UInt32)
    private let previousLongHotkey: (keyCode: UInt32, modifiers: UInt32)

    init(
        hotkeyDisplay: String,
        longHotkeyDisplay: String,
        hotkey: (UInt32, UInt32)?,
        longHotkey: (UInt32, UInt32)?,
        mosaic: CGFloat,
        thickness: CGFloat,
        minerUToken: String,
        minerUTimeout: TimeInterval,
        theme: ThemeMode,
        onApply: @escaping (
            _ hotkey: (UInt32, UInt32)?,
            _ longHotkey: (UInt32, UInt32)?,
            _ mosaic: CGFloat,
            _ thickness: CGFloat,
            _ minerUToken: String,
            _ minerUTimeout: TimeInterval,
            _ theme: ThemeMode
        ) -> Void
    ) {
        self.currentHotkeyText = hotkeyDisplay
        self.currentLongHotkeyText = longHotkeyDisplay
        self.mosaicSeed = mosaic
        self.thicknessSeed = thickness
        self.themeSeed = theme
        self.previousHotkey = HotkeyService.shared.currentHotkey
        self.previousLongHotkey = HotkeyService.shared.currentLongHotkey
        // 配置文件中的快捷键作为初始待生效值：
        // 用户未重新录制时点「确定」，也会按文件值注册（运行中改文件后无需重启）。
        self.pendingHotkey = hotkey
        self.pendingLongHotkey = longHotkey
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
        timeoutFieldSeed = minerUTimeout
        tokenFieldSeed = minerUToken
    }

    private var timeoutFieldSeed: TimeInterval = 10
    private var tokenFieldSeed: String = ""

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Packaging timestamp = the app executable's modification date. In a
    /// distributed .app this is exactly when the bundle was built/signed.
    private static var buildTimestamp: String {
        if let url = Bundle.main.executableURL,
           let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            return df.string(from: date)
        }
        return "—"
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 466))
        // 显式铺主题底色：sheet 的窗口背景在暗色下才有保证，不依赖系统默认。
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.windowBackground.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 720, height: 466)

        configureHotkeyButton(hotkeyButton, action: #selector(hotkeyButtonClicked))
        configureHotkeyButton(longHotkeyButton, action: #selector(longHotkeyButtonClicked))
        configureNumberField(mosaicField, value: mosaicSeed)
        configureNumberField(thicknessField, value: thicknessSeed)
        configureNumberField(timeoutField, value: timeoutFieldSeed)
        configureTokenField(tokenSecureField, value: tokenFieldSeed)
        configureTokenField(tokenPlainField, value: tokenFieldSeed)
        tokenPlainField.isHidden = true
        configureEyeButton()
        configureThemePopup()

        let title = NSTextField(labelWithString: "设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Equal-height form rows. Unit hints stay single-line so no row
        // gets taller than the others.
        // Token row: 密码框/明文框二选一显示 + 小眼睛切换按钮。
        let tokenRow = NSStackView(views: [tokenSecureField, tokenPlainField, tokenEyeButton])
        tokenRow.orientation = .horizontal
        tokenRow.spacing = 4
        tokenRow.alignment = .centerY
        let grid = NSGridView(views: [
            [makeFieldLabel("区域截图快捷键"), hotkeyButton, makeUnitLabel("")],
            [makeFieldLabel("长截图快捷键"), longHotkeyButton, makeUnitLabel("")],
            [makeFieldLabel("主题"), themePopup, makeUnitLabel("默认跟随系统")],
            [makeFieldLabel("马赛克密度"), mosaicField, makeUnitLabel("2–64 像素/格")],
            [makeFieldLabel("线条粗细"), thicknessField, makeUnitLabel("1–40 像素")],
            [makeFieldLabel("超时时间"), timeoutField, makeUnitLabel("5–600 秒")],
            [makeFieldLabel("MinerU token"), tokenRow, makeUnitLabel("精准解析用")]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.xPlacement = .leading
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        // Force every row to the same height so vertical rhythm stays even.
        for row in 0..<grid.numberOfRows {
            grid.row(at: row).height = 28
        }

        let tip = NSTextField(wrappingLabelWithString: "点「录制」后按下新组合键（如 ⌘⇧A），至少含一个修饰键。超时时间是「提取内容」轻量解析的等待秒数，超时后自动改用精准解析（vlm）；MinerU token 在 mineru.net 的「API 管理」页面创建。「主题」调整软件整体背景色，点「确定」后立即生效并存到配置文件。")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetHotkey))
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        let ok = NSButton(title: "确定", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [reset, NSView(), cancel, ok])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        // Version / build-time footer.
        let versionLine = NSTextField(labelWithString: "版本 \(AppInfo.version)　·　打包于 \(Self.buildTimestamp)")
        versionLine.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLine.textColor = .tertiaryLabelColor
        versionLine.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [title, grid, tip, buttonRow, versionLine])
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Do not pin bottom — avoid the stack stretching rows to fill leftover height.
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            tip.widthAnchor.constraint(lessThanOrEqualToConstant: 670),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20)
        ])

        updateHotkeyButtonTitles()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(mosaicField)
    }

    // MARK: - Controls

    private func configureHotkeyButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func configureNumberField(_ field: NSTextField, value: CGFloat) {
        field.stringValue = "\(Int(value))"
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .right
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        field.target = self
        field.action = #selector(numberFieldChanged)
        field.delegate = self
    }

    /// 密码输入框（掩码显示），用于 MinerU token。
    /// token 输入框统一样式（密码框与明文框共用）。
    private func configureTokenField(_ field: NSTextField, value: String) {
        field.stringValue = value
        field.toolTip = "MinerU API Token：精准模式（vlm）解析时使用，在 mineru.net 的「API 管理」页面创建"
        field.setAccessibilityLabel("MinerU token")
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.alignment = .left
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        // 460px 可容纳约 65 个字符的 token 一行显示（含输入框内边距）
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        field.delegate = self
    }

    /// 小眼睛按钮：切换 token 明文/掩码显示。
    private func configureEyeButton() {
        tokenEyeButton.bezelStyle = .inline
        tokenEyeButton.isBordered = false
        tokenEyeButton.controlSize = .small
        tokenEyeButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示明文")
        tokenEyeButton.contentTintColor = .secondaryLabelColor
        tokenEyeButton.toolTip = "显示 / 隐藏明文"
        tokenEyeButton.target = self
        tokenEyeButton.action = #selector(toggleTokenVisibility)
        tokenEyeButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// 当前可见的 token 输入框的值（明文框隐藏时取密码框，反之亦然）。
    private var tokenFieldValue: String {
        tokenPlainField.isHidden ? tokenSecureField.stringValue : tokenPlainField.stringValue
    }

    @objc private func toggleTokenVisibility() {
        if tokenPlainField.isHidden {
            tokenPlainField.stringValue = tokenSecureField.stringValue
            tokenPlainField.isHidden = false
            tokenSecureField.isHidden = true
            tokenEyeButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏明文")
        } else {
            tokenSecureField.stringValue = tokenPlainField.stringValue
            tokenSecureField.isHidden = false
            tokenPlainField.isHidden = true
            tokenEyeButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示明文")
        }
    }

    /// 主题下拉框：暗色 / 亮色 / 跟随系统（默认）。
    private func configureThemePopup() {
        themePopup.removeAllItems()
        // 菜单顺序按 displayOrder，选中项由 themeSeed 决定（缺省即「跟随系统」）。
        for mode in ThemeMode.displayOrder {
            themePopup.addItem(withTitle: mode.displayName)
            themePopup.lastItem?.representedObject = mode.rawValue
        }
        let index = ThemeMode.displayOrder.firstIndex(of: themeSeed) ?? ThemeMode.displayOrder.count - 1
        themePopup.selectItem(at: index)
        themePopup.font = .systemFont(ofSize: 13)
        themePopup.controlSize = .regular
        themePopup.toolTip = "调整软件整体背景色：暗色 / 亮色 / 跟随系统（默认）"
        themePopup.translatesAutoresizingMaskIntoConstraints = false
        themePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        themePopup.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// 当前选中的主题（取不到时回落到「跟随系统」）。
    private var selectedTheme: ThemeMode {
        guard let raw = themePopup.selectedItem?.representedObject as? String,
              let mode = ThemeMode(rawValue: raw) else {
            return .system
        }
        return mode
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return l
    }

    private func makeUnitLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func updateHotkeyButtonTitles() {
        if recordingTarget == .capture {
            hotkeyButton.title = "请按下组合键…"
            hotkeyButton.contentTintColor = .systemRed
        } else {
            hotkeyButton.title = "录制：\(currentHotkeyText)"
            hotkeyButton.contentTintColor = nil
        }
        if recordingTarget == .longCapture {
            longHotkeyButton.title = "请按下组合键…"
            longHotkeyButton.contentTintColor = .systemRed
        } else {
            longHotkeyButton.title = "录制：\(currentLongHotkeyText)"
            longHotkeyButton.contentTintColor = nil
        }
    }

    // MARK: - Actions

    @objc private func numberFieldChanged() {
        view.window?.makeFirstResponder(nil)
    }

    @objc private func hotkeyButtonClicked() {
        recordingTarget == .capture
            ? stopRecording(restoreGlobalHotkeys: true)
            : startRecording(.capture)
    }

    @objc private func longHotkeyButtonClicked() {
        recordingTarget == .longCapture
            ? stopRecording(restoreGlobalHotkeys: true)
            : startRecording(.longCapture)
    }

    private func startRecording(_ target: RecordTarget) {
        stopRecording(restoreGlobalHotkeys: false)
        // Suspend both hotkeys so recording either one can't trigger captures.
        HotkeyService.shared.unregister()
        recordingTarget = target
        updateHotkeyButtonTitles()
        view.window?.makeFirstResponder(target == .capture ? hotkeyButton : longHotkeyButton)
        recorder.start { [weak self] keyCode, mods, event -> Bool in
            guard let self else { return false }
            if event.keyCode == 53 { // Esc
                self.stopRecording(restoreGlobalHotkeys: true)
                return true
            }
            guard mods != 0 else { return false }
            let text = HotkeyService.format(keyCode: keyCode, modifiers: mods)
            switch target {
            case .capture:
                self.pendingHotkey = (keyCode, mods)
                self.currentHotkeyText = text
            case .longCapture:
                self.pendingLongHotkey = (keyCode, mods)
                self.currentLongHotkeyText = text
            }
            self.stopRecording(restoreGlobalHotkeys: false)
            return true
        }
    }

    private func stopRecording(restoreGlobalHotkeys: Bool) {
        recorder.stop()
        let wasRecording = recordingTarget != nil
        recordingTarget = nil
        if wasRecording {
            updateHotkeyButtonTitles()
        }
        if restoreGlobalHotkeys {
            HotkeyService.shared.register(
                keyCode: previousHotkey.keyCode,
                modifiers: previousHotkey.modifiers
            )
            HotkeyService.shared.registerLong(
                keyCode: previousLongHotkey.keyCode,
                modifiers: previousLongHotkey.modifiers
            )
        }
    }

    @objc private func resetHotkey() {
        stopRecording(restoreGlobalHotkeys: false)
        pendingHotkey = (UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey))
        pendingLongHotkey = (UInt32(kVK_ANSI_E), UInt32(cmdKey | shiftKey))
        currentHotkeyText = HotkeyService.displayStringDefault
        currentLongHotkeyText = HotkeyService.displayStringDefaultLong
        updateHotkeyButtonTitles()
    }

    @objc private func okClicked() {
        stopRecording(restoreGlobalHotkeys: pendingHotkey == nil && pendingLongHotkey == nil)
        view.window?.makeFirstResponder(nil)
        let mosaic = max(2, min(64, mosaicField.doubleValue))
        let thickness = max(1, min(40, thicknessField.doubleValue))
        let timeout = max(5, min(600, timeoutField.doubleValue))
        let token = tokenFieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onApply(
            pendingHotkey,
            pendingLongHotkey,
            CGFloat(mosaic),
            CGFloat(thickness),
            token,
            timeout,
            selectedTheme
        )
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        stopRecording(restoreGlobalHotkeys: true)
        dismiss(nil)
    }

    deinit {
        recorder.stop()
        if recordingTarget != nil {
            HotkeyService.shared.register(
                keyCode: previousHotkey.keyCode,
                modifiers: previousHotkey.modifiers
            )
            HotkeyService.shared.registerLong(
                keyCode: previousLongHotkey.keyCode,
                modifiers: previousLongHotkey.modifiers
            )
        }
    }
}

extension SettingsPanel: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        if recordingTarget != nil {
            stopRecording(restoreGlobalHotkeys: true)
        }
    }
}
