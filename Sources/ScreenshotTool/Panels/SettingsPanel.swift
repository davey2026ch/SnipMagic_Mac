import AppKit
import Carbon.HIToolbox

/// Toolbar settings sheet: capture/long-capture hotkeys, mosaic density, stroke
/// thickness, MinerU extract timeout & token, theme, and the Volcengine API Key
/// used by 魔法消除 (persisted to ~/.截图工具).
final class SettingsPanel: NSViewController {
    private let onApply: (
        _ hotkey: (UInt32, UInt32)?,
        _ longHotkey: (UInt32, UInt32)?,
        _ mosaic: CGFloat,
        _ thickness: CGFloat,
        _ minerUToken: String,
        _ minerUTimeout: TimeInterval,
        _ theme: ThemeMode,
        _ volcKey: String,
        _ eraseBrush: CGFloat
    ) -> Void

    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let longHotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let mosaicField = NSTextField()
    private let thicknessField = NSTextField()
    private let eraseBrushField = NSTextField()
    private let timeoutField = NSTextField()
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 版本更新行：手动检查按钮 + 状态文字。
    private let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let updateStatus = NSTextField(labelWithString: "")
    /// 按钮 + 状态文字一行。刻意放在表格第二列（和快捷键按钮同一列），
    /// 而不是第三列：第三列宽由该列最宽的一格决定，状态文案一长就会把整张表单顶宽。
    private let updateRow = NSStackView()
    private var isCheckingUpdate = false
    /// 两处密钥输入共用同一套「密码框 + 明文框 + 小眼睛」。
    private let tokenRow = SecretFieldRow(
        tooltip: "MinerU API Token：精准模式（vlm）解析时使用，在 mineru.net 的「API 管理」页面创建",
        accessibilityLabel: "MinerU token")
    private let volcRow = SecretFieldRow(
        tooltip: "火山引擎 AI MediaKit 的 API Key：「魔法消除」用它做云端擦除重建，在 console.volcengine.com/imp/ai-mediakit/settings 创建",
        accessibilityLabel: "火山引擎 API Key")
    private let recorder = HotkeyRecorderMonitor()
    private var currentHotkeyText: String
    private var currentLongHotkeyText: String
    private var pendingHotkey: (UInt32, UInt32)?
    private var pendingLongHotkey: (UInt32, UInt32)?

    private enum RecordTarget { case capture, longCapture }
    private var recordingTarget: RecordTarget?

    private let mosaicSeed: CGFloat
    private let thicknessSeed: CGFloat
    private let eraseBrushSeed: CGFloat
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
        volcKey: String,
        eraseBrush: CGFloat,
        onApply: @escaping (
            _ hotkey: (UInt32, UInt32)?,
            _ longHotkey: (UInt32, UInt32)?,
            _ mosaic: CGFloat,
            _ thickness: CGFloat,
            _ minerUToken: String,
            _ minerUTimeout: TimeInterval,
            _ theme: ThemeMode,
            _ volcKey: String,
            _ eraseBrush: CGFloat
        ) -> Void
    ) {
        self.currentHotkeyText = hotkeyDisplay
        self.currentLongHotkeyText = longHotkeyDisplay
        self.mosaicSeed = mosaic
        self.thicknessSeed = thickness
        self.eraseBrushSeed = eraseBrush
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
        tokenRow.value = minerUToken
        volcRow.value = volcKey
    }

    private var timeoutFieldSeed: TimeInterval = 10

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 592))
        // 显式铺主题底色：sheet 的窗口背景在暗色下才有保证，不依赖系统默认。
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.windowBackground.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 720, height: 592)

        configureHotkeyButton(hotkeyButton, action: #selector(hotkeyButtonClicked))
        configureHotkeyButton(longHotkeyButton, action: #selector(longHotkeyButtonClicked))
        configureNumberField(mosaicField, value: mosaicSeed)
        configureNumberField(thicknessField, value: thicknessSeed)
        configureNumberField(eraseBrushField, value: eraseBrushSeed)
        configureNumberField(timeoutField, value: timeoutFieldSeed)
        configureThemePopup()
        configureUpdateControls()
        tokenRow.delegate = self
        volcRow.delegate = self

        let title = NSTextField(labelWithString: "设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Equal-height form rows. Unit hints stay single-line so no row
        // gets taller than the others.
        let grid = NSGridView(views: [
            [makeFieldLabel("区域截图快捷键"), hotkeyButton, makeUnitLabel("")],
            [makeFieldLabel("长截图快捷键"), longHotkeyButton, makeUnitLabel("")],
            [makeFieldLabel("主题"), themePopup, makeUnitLabel("默认跟随系统")],
            [makeFieldLabel("马赛克密度"), mosaicField, makeUnitLabel("2–64 像素/格")],
            [makeFieldLabel("线条粗细"), thicknessField, makeUnitLabel("1–40 像素")],
            [makeFieldLabel("刷子粗细"), eraseBrushField, makeUnitLabel("4–240 像素")],
            [makeFieldLabel("超时时间"), timeoutField, makeUnitLabel("5–600 秒")],
            [makeFieldLabel("MinerU token"), tokenRow.stack, makeUnitLabel("精准解析用")],
            [makeFieldLabel("火山 API Key"), volcRow.stack, makeUnitLabel("魔法消除用")],
            [makeFieldLabel("版本更新"), updateRow, makeUnitLabel("")]
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

        let tip = NSTextField(wrappingLabelWithString: "点「录制」后按下新组合键（如 ⌘⇧A），至少含一个修饰键。超时时间是「提取内容」轻量解析的等待秒数，超时后自动改用精准解析（vlm）；MinerU token 在 mineru.net 的「API 管理」页面创建。「主题」调整软件整体背景色，点「确定」后立即生效并存到配置文件。火山 API Key 供工具栏的「魔法消除」使用；留空则该按钮会提示去配置。「检查更新」到 Gitee 上查最新版本，按本机芯片自动匹配安装包；发现新版本只会先询问，同意后才下载并替换。")
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

    /// 版本更新行：按钮 + 状态文字。状态初值直接显示当前版本与芯片架构，
    /// 让用户知道自动匹配会挑哪个包。
    private func configureUpdateControls() {
        updateButton.bezelStyle = .rounded
        updateButton.font = .systemFont(ofSize: 13, weight: .medium)
        updateButton.target = self
        updateButton.action = #selector(checkUpdateClicked)
        updateButton.toolTip = "到 Gitee Release 检查新版本（按本机芯片自动匹配安装包）"
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        updateButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        updateStatus.font = .systemFont(ofSize: 12)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.lineBreakMode = .byTruncatingTail
        updateStatus.stringValue = "当前 v\(UpdateService.currentVersion) · \(UpdateService.currentArchitecture)"
        updateStatus.translatesAutoresizingMaskIntoConstraints = false
        updateStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 168).isActive = true

        updateRow.orientation = .horizontal
        updateRow.spacing = 8
        updateRow.alignment = .centerY
        updateRow.addArrangedSubview(updateButton)
        updateRow.addArrangedSubview(updateStatus)
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

    // MARK: - 更新

    /// 手动检查更新。结果只写在状态行上；确认是否安装交给统一弹窗。
    @objc private func checkUpdateClicked() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        updateButton.isEnabled = false
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = "正在检查…"

        UpdateService.shared.check { [weak self] outcome in
            guard let self = self else { return }
            self.isCheckingUpdate = false
            self.updateButton.isEnabled = true

            switch outcome {
            case .upToDate(let current):
                self.updateStatus.textColor = .secondaryLabelColor
                self.updateStatus.stringValue = "已是最新版本（v\(current)）"
                self.updateStatus.toolTip = "当前 v\(current)（\(UpdateService.currentArchitecture)），云端没有更新的版本"

            case .available(let release):
                self.updateStatus.textColor = .systemBlue
                self.updateStatus.stringValue = "发现新版本 v\(release.version)（\(release.asset.name)）"
                self.updateStatus.toolTip = "v\(release.version)：\(release.asset.name)（适配\(UpdateService.architectureDisplayName)）"
                // 先收起设置面板再弹确认框，避免在 sheet 上再叠一层对话框
                self.dismiss(nil)
                DispatchQueue.main.async {
                    UpdateService.shared.promptAndInstall(release)
                }

            case .failure(let message):
                self.updateStatus.textColor = .systemRed
                self.updateStatus.stringValue = "检查失败：\(message)"
                self.updateStatus.toolTip = message
            }
        }
    }

    @objc private func okClicked() {
        stopRecording(restoreGlobalHotkeys: pendingHotkey == nil && pendingLongHotkey == nil)
        view.window?.makeFirstResponder(nil)
        let mosaic = max(2, min(64, mosaicField.doubleValue))
        let thickness = max(1, min(40, thicknessField.doubleValue))
        let eraseBrush = max(4, min(240, eraseBrushField.doubleValue))
        let timeout = max(5, min(600, timeoutField.doubleValue))
        let token = tokenRow.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let volcKey = volcRow.value.trimmingCharacters(in: .whitespacesAndNewlines)
        onApply(
            pendingHotkey,
            pendingLongHotkey,
            CGFloat(mosaic),
            CGFloat(thickness),
            token,
            timeout,
            selectedTheme,
            volcKey,
            CGFloat(eraseBrush)
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

/// 一行密钥输入：密码框 + 明文框叠放，右侧小眼睛切换显示。
/// MinerU token 与火山 API Key 共用这一套，省得维护两份显隐逻辑。
private final class SecretFieldRow: NSObject {
    let secure = NSSecureTextField()
    let plain = NSTextField()
    let eye = NSButton()

    /// 设置面板挂在上面，用来在开始输入时中止快捷键录制。
    weak var delegate: NSTextFieldDelegate? {
        didSet {
            secure.delegate = delegate
            plain.delegate = delegate
        }
    }

    init(tooltip: String, accessibilityLabel: String) {
        super.init()

        for field in [secure, plain] as [NSTextField] {
            field.font = .systemFont(ofSize: 12, weight: .regular)
            field.alignment = .left
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
            field.toolTip = tooltip
            field.setAccessibilityLabel(accessibilityLabel)
            field.translatesAutoresizingMaskIntoConstraints = false
            // 460px 够一行放下约 65 个字符的密钥
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        plain.isHidden = true

        eye.bezelStyle = .inline
        eye.isBordered = false
        eye.controlSize = .small
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示明文")
        eye.contentTintColor = .secondaryLabelColor
        eye.toolTip = "显示 / 隐藏明文"
        eye.target = self
        eye.action = #selector(toggleVisibility)
        eye.translatesAutoresizingMaskIntoConstraints = false
        eye.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// 当前可见那个框里的值。
    var value: String {
        get { plain.isHidden ? secure.stringValue : plain.stringValue }
        set {
            secure.stringValue = newValue
            plain.stringValue = newValue
        }
    }

    /// 横向排好的输入行，直接塞进 NSGridView 的单元格。
    lazy var stack: NSStackView = {
        let stack = NSStackView(views: [secure, plain, eye])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        return stack
    }()

    @objc private func toggleVisibility() {
        if plain.isHidden {
            plain.stringValue = secure.stringValue
            plain.isHidden = false
            secure.isHidden = true
            eye.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏明文")
        } else {
            secure.stringValue = plain.stringValue
            secure.isHidden = false
            plain.isHidden = true
            eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示明文")
        }
    }
}
