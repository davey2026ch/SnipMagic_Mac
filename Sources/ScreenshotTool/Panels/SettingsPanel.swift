import AppKit
import Carbon.HIToolbox

/// Toolbar settings sheet: capture hotkey, mosaic density, stroke thickness.
final class SettingsPanel: NSViewController {
    private let onApply: (_ hotkey: (UInt32, UInt32)?, _ mosaic: CGFloat, _ thickness: CGFloat) -> Void

    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let mosaicField = NSTextField()
    private let thicknessField = NSTextField()
    private let recorder = HotkeyRecorderMonitor()
    private var currentHotkeyText: String
    private var pendingHotkey: (UInt32, UInt32)?
    private var isRecordingHotkey = false

    private let mosaicSeed: CGFloat
    private let thicknessSeed: CGFloat
    private let previousHotkey: (keyCode: UInt32, modifiers: UInt32)

    init(
        hotkeyDisplay: String,
        mosaic: CGFloat,
        thickness: CGFloat,
        onApply: @escaping (_ hotkey: (UInt32, UInt32)?, _ mosaic: CGFloat, _ thickness: CGFloat) -> Void
    ) {
        self.currentHotkeyText = hotkeyDisplay
        self.mosaicSeed = mosaic
        self.thicknessSeed = thickness
        self.previousHotkey = HotkeyService.shared.currentHotkey
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 480, height: 260)

        configureHotkeyButton()
        configureNumberField(mosaicField, value: mosaicSeed)
        configureNumberField(thicknessField, value: thicknessSeed)

        let title = NSTextField(labelWithString: "设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Three equal-height form rows. Unit hints stay single-line so no row
        // gets taller than the others (that was making the mosaic→thickness gap look huge).
        let grid = NSGridView(views: [
            [makeFieldLabel("截图快捷键"), hotkeyButton, makeUnitLabel("")],
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

        let tip = NSTextField(wrappingLabelWithString: "点「录制」后按下新组合键（如 ⌘⇧A），至少含一个修饰键。马赛克密度数值越大越糊；录制期间原截图快捷键会临时停用。")
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

        updateHotkeyButtonTitle()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(mosaicField)
    }

    // MARK: - Controls

    private func configureHotkeyButton() {
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.font = .systemFont(ofSize: 13, weight: .medium)
        hotkeyButton.target = self
        hotkeyButton.action = #selector(hotkeyButtonClicked)
        hotkeyButton.translatesAutoresizingMaskIntoConstraints = false
        hotkeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        hotkeyButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
        l.widthAnchor.constraint(equalToConstant: 88).isActive = true
        return l
    }

    private func makeUnitLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func updateHotkeyButtonTitle() {
        if isRecordingHotkey {
            hotkeyButton.title = "请按下组合键…"
            hotkeyButton.contentTintColor = .systemRed
        } else {
            hotkeyButton.title = "录制：\(currentHotkeyText)"
            hotkeyButton.contentTintColor = nil
        }
    }

    // MARK: - Actions

    @objc private func numberFieldChanged() {
        view.window?.makeFirstResponder(nil)
    }

    @objc private func hotkeyButtonClicked() {
        if isRecordingHotkey {
            stopRecording(restoreGlobalHotkey: true)
            return
        }
        startRecording()
    }

    private func startRecording() {
        stopRecording(restoreGlobalHotkey: false)
        HotkeyService.shared.unregister()
        isRecordingHotkey = true
        updateHotkeyButtonTitle()
        view.window?.makeFirstResponder(hotkeyButton)
        recorder.start { [weak self] keyCode, mods, event -> Bool in
            guard let self else { return false }
            if event.keyCode == 53 { // Esc
                self.stopRecording(restoreGlobalHotkey: true)
                return true
            }
            guard mods != 0 else { return false }
            let text = HotkeyService.format(keyCode: keyCode, modifiers: mods)
            self.pendingHotkey = (keyCode, mods)
            self.currentHotkeyText = text
            self.stopRecording(restoreGlobalHotkey: false)
            return true
        }
    }

    private func stopRecording(restoreGlobalHotkey: Bool) {
        recorder.stop()
        let wasRecording = isRecordingHotkey
        isRecordingHotkey = false
        if wasRecording {
            updateHotkeyButtonTitle()
        }
        if restoreGlobalHotkey {
            HotkeyService.shared.register(
                keyCode: previousHotkey.keyCode,
                modifiers: previousHotkey.modifiers
            )
        }
    }

    @objc private func resetHotkey() {
        stopRecording(restoreGlobalHotkey: false)
        pendingHotkey = (UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey))
        currentHotkeyText = HotkeyService.displayStringDefault
        updateHotkeyButtonTitle()
    }

    @objc private func okClicked() {
        stopRecording(restoreGlobalHotkey: pendingHotkey == nil)
        view.window?.makeFirstResponder(nil)
        let mosaic = max(2, min(64, mosaicField.doubleValue))
        let thickness = max(1, min(40, thicknessField.doubleValue))
        onApply(pendingHotkey, CGFloat(mosaic), CGFloat(thickness))
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        stopRecording(restoreGlobalHotkey: true)
        dismiss(nil)
    }

    deinit {
        recorder.stop()
        if isRecordingHotkey {
            HotkeyService.shared.register(
                keyCode: previousHotkey.keyCode,
                modifiers: previousHotkey.modifiers
            )
        }
    }
}

extension SettingsPanel: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        if isRecordingHotkey {
            stopRecording(restoreGlobalHotkey: true)
        }
    }
}
