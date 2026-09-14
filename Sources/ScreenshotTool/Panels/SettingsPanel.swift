import AppKit
import Carbon.HIToolbox

/// Toolbar settings sheet: capture/long-capture hotkeys, mosaic density, stroke thickness.
final class SettingsPanel: NSViewController {
    private let onApply: (
        _ hotkey: (UInt32, UInt32)?,
        _ longHotkey: (UInt32, UInt32)?,
        _ mosaic: CGFloat,
        _ thickness: CGFloat
    ) -> Void

    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let longHotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let mosaicField = NSTextField()
    private let thicknessField = NSTextField()
    private let recorder = HotkeyRecorderMonitor()
    private var currentHotkeyText: String
    private var currentLongHotkeyText: String
    private var pendingHotkey: (UInt32, UInt32)?
    private var pendingLongHotkey: (UInt32, UInt32)?

    private enum RecordTarget { case capture, longCapture }
    private var recordingTarget: RecordTarget?

    private let mosaicSeed: CGFloat
    private let thicknessSeed: CGFloat
    private let previousHotkey: (keyCode: UInt32, modifiers: UInt32)
    private let previousLongHotkey: (keyCode: UInt32, modifiers: UInt32)

    init(
        hotkeyDisplay: String,
        longHotkeyDisplay: String,
        mosaic: CGFloat,
        thickness: CGFloat,
        onApply: @escaping (
            _ hotkey: (UInt32, UInt32)?,
            _ longHotkey: (UInt32, UInt32)?,
            _ mosaic: CGFloat,
            _ thickness: CGFloat
        ) -> Void
    ) {
        self.currentHotkeyText = hotkeyDisplay
        self.currentLongHotkeyText = longHotkeyDisplay
        self.mosaicSeed = mosaic
        self.thicknessSeed = thickness
        self.previousHotkey = HotkeyService.shared.currentHotkey
        self.previousLongHotkey = HotkeyService.shared.currentLongHotkey
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 480, height: 320)

        configureHotkeyButton(hotkeyButton, action: #selector(hotkeyButtonClicked))
        configureHotkeyButton(longHotkeyButton, action: #selector(longHotkeyButtonClicked))
        configureNumberField(mosaicField, value: mosaicSeed)
        configureNumberField(thicknessField, value: thicknessSeed)

        let title = NSTextField(labelWithString: "设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Equal-height form rows. Unit hints stay single-line so no row
        // gets taller than the others.
        let grid = NSGridView(views: [
            [makeFieldLabel("区域截图快捷键"), hotkeyButton, makeUnitLabel("")],
            [makeFieldLabel("长截图快捷键"), longHotkeyButton, makeUnitLabel("")],
            [makeFieldLabel("马赛克密度"), mosaicField, makeUnitLabel("2–64 像素/格")],
            [makeFieldLabel("线条粗细"), thicknessField, makeUnitLabel("1–40 像素")]
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

        let tip = NSTextField(wrappingLabelWithString: "点「录制」后按下新组合键（如 ⌘⇧A），至少含一个修饰键。马赛克密度数值越大越糊；录制期间两个截图快捷键都会临时停用。")
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

        let root = NSStackView(views: [title, grid, tip, buttonRow])
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
            tip.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
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
        pendingLongHotkey = (UInt32(kVK_ANSI_G), UInt32(cmdKey | shiftKey))
        currentHotkeyText = HotkeyService.displayStringDefault
        currentLongHotkeyText = HotkeyService.displayStringDefaultLong
        updateHotkeyButtonTitles()
    }

    @objc private func okClicked() {
        stopRecording(restoreGlobalHotkeys: pendingHotkey == nil && pendingLongHotkey == nil)
        view.window?.makeFirstResponder(nil)
        let mosaic = max(2, min(64, mosaicField.doubleValue))
        let thickness = max(1, min(40, thicknessField.doubleValue))
        onApply(pendingHotkey, pendingLongHotkey, CGFloat(mosaic), CGFloat(thickness))
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
