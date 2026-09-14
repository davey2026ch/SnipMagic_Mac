import AppKit

/// Insert-text sheet: content, font size, color, bold, transparent background.
final class TextInsertPanel: NSViewController {
    private let onConfirm: (String, CGFloat, NSColor, Bool, Bool) -> Void
    private let defaultColor: NSColor
    private let initialContent: String
    private let initialSize: CGFloat
    private let initialBold: Bool
    /// Stored as "has opaque white background". Checkbox label is「背景透明」(inverse).
    private let initialOpaqueBackground: Bool

    private let textView = NSTextView()
    private let sizeField = NSTextField()
    private let colorWell = NSColorWell()
    private let boldCheck = NSButton(checkboxWithTitle: "加粗", target: nil, action: nil)
    private let transparentCheck = NSButton(checkboxWithTitle: "背景透明", target: nil, action: nil)

    init(
        defaultColor: NSColor,
        content: String = "",
        fontSize: CGFloat = 20,
        bold: Bool = false,
        opaqueBackground: Bool = false,
        onConfirm: @escaping (String, CGFloat, NSColor, Bool, Bool) -> Void
    ) {
        self.defaultColor = defaultColor
        self.initialContent = content
        self.initialSize = fontSize
        self.initialBold = bold
        self.initialOpaqueBackground = opaqueBackground
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 360, height: 280)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let title = NSTextField(labelWithString: "插入文字")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true

        textView.minSize = NSSize(width: 0, height: 100)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 14)
        textView.string = initialContent
        textView.isRichText = false
        scroll.documentView = textView
        stack.addArrangedSubview(scroll)

        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8
        let sl = NSTextField(labelWithString: "字号")
        sl.font = .systemFont(ofSize: 13)
        sizeField.stringValue = "\(Int(initialSize))"
        sizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sizeRow.addArrangedSubview(sl)
        sizeRow.addArrangedSubview(sizeField)
        sizeRow.addArrangedSubview(NSView())
        stack.addArrangedSubview(sizeRow)

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 10
        let cl = NSTextField(labelWithString: "颜色")
        cl.font = .systemFont(ofSize: 13)
        colorWell.color = defaultColor
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        boldCheck.font = .systemFont(ofSize: 13)
        transparentCheck.font = .systemFont(ofSize: 13)
        boldCheck.state = initialBold ? .on : .off
        // 「背景透明」勾选 = 不要白色底。默认透明。
        transparentCheck.state = initialOpaqueBackground ? .off : .on
        colorRow.addArrangedSubview(cl)
        colorRow.addArrangedSubview(colorWell)
        colorRow.addArrangedSubview(boldCheck)
        colorRow.addArrangedSubview(transparentCheck)
        colorRow.addArrangedSubview(NSView())
        stack.addArrangedSubview(colorRow)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        let ok = NSButton(title: "确定", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(ok)
        stack.addArrangedSubview(buttons)

    }

    @objc private func okClicked() {
        let content = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            cancelClicked()
            return
        }
        let size = max(8, min(200, sizeField.doubleValue))
        // 勾选「背景透明」→ 不铺白底（opaqueBackground = false）
        let opaqueBackground = transparentCheck.state != .on
        onConfirm(content, CGFloat(size), colorWell.color, boldCheck.state == .on, opaqueBackground)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
    }
}

/// Hotkey settings sheet.
final class HotkeyPanel: NSViewController {
    private let onSet: (UInt32, UInt32) -> Void
    private let field = NSTextField()
    private let recorder = HotkeyRecorderMonitor()
    private var currentText: String
    private var pending: (UInt32, UInt32)?

    init(current: String, onSet: @escaping (UInt32, UInt32) -> Void) {
        self.currentText = current
        self.onSet = onSet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        preferredContentSize = NSSize(width: 380, height: 200)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let title = NSTextField(labelWithString: "快捷键设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let label = NSTextField(labelWithString: "区域截图")
        label.font = .systemFont(ofSize: 13)
        field.stringValue = currentText
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.isEditable = false
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        stack.addArrangedSubview(row)

        let tip = NSTextField(wrappingLabelWithString: "点击输入框后直接按下新的组合键（例如 Command+Alt+A）\nWindows 用 Ctrl，Mac 用 Command（⌘）")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tip)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetClicked))
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        let ok = NSButton(title: "确定", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        buttons.addArrangedSubview(reset)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(ok)
        stack.addArrangedSubview(buttons)

        let click = NSClickGestureRecognizer(target: self, action: #selector(beginRecord))
        field.addGestureRecognizer(click)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        beginRecord()
    }

    @objc private func beginRecord() {
        field.stringValue = "请按下组合键…"
        recorder.start { [weak self] keyCode, mods, _ -> Bool in
            guard let self else { return false }
            let text = HotkeyService.format(keyCode: keyCode, modifiers: mods)
            // Require at least one modifier
            guard mods != 0 else { return false }
            self.pending = (keyCode, mods)
            self.field.stringValue = text
            self.currentText = text
            self.recorder.stop()
            return true
        }
    }

    @objc private func resetClicked() {
        pending = (UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey))
        field.stringValue = HotkeyService.displayStringDefault
        currentText = field.stringValue
    }

    @objc private func okClicked() {
        recorder.stop()
        if let pending {
            onSet(pending.0, pending.1)
        } else if let parsed = HotkeyService.parse(currentText) {
            onSet(parsed.keyCode, parsed.modifiers)
        }
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        recorder.stop()
        dismiss(nil)
    }

    deinit {
        recorder.stop()
    }
}

import Carbon.HIToolbox

extension HotkeyService {
    static var displayStringDefault: String {
        format(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey))
    }

    static var displayStringDefaultLong: String {
        format(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey))
    }
}
