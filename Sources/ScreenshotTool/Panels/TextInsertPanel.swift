import AppKit

/// Insert-text sheet: content, font size, text color / background color, bold.
///
/// 版面按需求放大到原来的 **1.5 倍**（360×280 → 540×420），并且**可以拖边框缩放**：
/// 输入区吸收多余高度、底部控件行贴着「取消 / 确定」上方，缩到最小尺寸也不会重叠。
final class TextInsertPanel: NSViewController {
    /// 文字颜色独立记忆：与侧栏工具色互不联动，应用运行期间记住上次的文字颜色。
    static var lastColor: NSColor = .systemRed
    /// 文字底色的独立记忆（默认白底，和以前"不勾背景透明"时的效果一致）。
    static var lastBackgroundColor: NSColor = .white

    /// 面板尺寸：初始 = 原尺寸 × 1.5；最小尺寸 = 刚好放得下底部那一行控件。
    private enum Size {
        static let initial = NSSize(width: 540, height: 420)
        static let min = NSSize(width: 520, height: 340)
    }

    private let onConfirm: (String, CGFloat, NSColor, Bool, NSColor?) -> Void
    private let defaultColor: NSColor
    private let initialContent: String
    private let initialSize: CGFloat
    private let initialBold: Bool
    /// nil = 背景透明（不铺底）。
    private let initialBackgroundColor: NSColor?

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let sizeField = NSTextField()
    /// 文字颜色 / 背景颜色各自一个色块按钮，都打开**同一个**取色面板
    /// （wheel + 24 格固定色与最近使用 + 全屏吸管）。
    private let textColorSwatch = ColorSwatchButton()
    private let bgColorSwatch = ColorSwatchButton()
    private let bgColorLabel = NSTextField(labelWithString: "背景颜色")
    private var textColorPicker: ColorPickerPanel?
    private var bgColorPicker: ColorPickerPanel?
    private var pickedColor: NSColor
    private var pickedBackground: NSColor
    private let boldCheck = NSButton(checkboxWithTitle: "加粗 (⌘B)", target: nil, action: nil)
    private let transparentCheck = NSButton(checkboxWithTitle: "背景透明", target: nil, action: nil)
    private var keyMonitor: Any?

    init(
        defaultColor: NSColor,
        content: String = "",
        fontSize: CGFloat = 20,
        bold: Bool = false,
        backgroundColor: NSColor? = nil,
        onConfirm: @escaping (String, CGFloat, NSColor, Bool, NSColor?) -> Void
    ) {
        self.defaultColor = defaultColor
        self.pickedColor = defaultColor
        self.pickedBackground = backgroundColor ?? TextInsertPanel.lastBackgroundColor
        self.initialContent = content
        self.initialSize = fontSize
        self.initialBold = bold
        self.initialBackgroundColor = backgroundColor
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Size.initial))
    }

    // ⚠️ 刻意**不设** `preferredContentSize`：
    // 它的默认值是 (0, 0)，含意是"没有偏好"；一旦给它一个具体值，AppKit 在每次
    // 布局时都会把窗口掰回那个尺寸 —— 表现在界面上就是"边框拖不动、松手弹回原来大小"。
    // sheet 的初始尺寸由 `loadView` 里 view 的 frame 决定，后面的尺寸交给用户拖。

    override func viewDidLoad() {
        super.viewDidLoad()

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

        // 输入区：占据上方全部空间，随窗口伸缩。
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 14)
        textView.string = initialContent
        textView.isRichText = false
        scroll.documentView = textView

        let controls = makeControlsRow()

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

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(buttons)
        // 底部控件行紧贴「确定 / 取消」上方。
        stack.setCustomSpacing(14, after: controls)
        for row in [controls, buttons] {
            row.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }

        transparentCheck.target = self
        transparentCheck.action = #selector(transparentToggled)
        syncBackgroundRowVisibility()
    }

    /// 底部合并成**一行**：字号 / 加粗 / 背景透明 / 文字颜色 / 背景颜色。
    /// 勾上「背景透明」时，「背景颜色」的文字与按钮整组隐藏（NSStackView 会自动
    /// 把隐藏的 arrangedSubviews 从布局里摘掉，不用手改约束）。
    private func makeControlsRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let sl = NSTextField(labelWithString: "字号")
        sl.font = .systemFont(ofSize: 13)
        sizeField.stringValue = "\(Int(initialSize))"
        sizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeField.alignment = .center
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        boldCheck.font = .systemFont(ofSize: 13)
        transparentCheck.font = .systemFont(ofSize: 13)
        boldCheck.state = initialBold ? .on : .off
        // 「背景透明」勾选 = 不要底色。老数据没有底色 → 默认勾上（透明）。
        transparentCheck.state = initialBackgroundColor == nil ? .on : .off

        configureSwatch(textColorSwatch, color: pickedColor, action: #selector(textColorClicked),
                        tooltip: "文字颜色（彩色圆盘 / 常用色 / 最近使用 / 屏幕取色）")
        configureSwatch(bgColorSwatch, color: pickedBackground, action: #selector(bgColorClicked),
                        tooltip: "文字背景颜色（彩色圆盘 / 常用色 / 最近使用 / 屏幕取色）")

        let tl = NSTextField(labelWithString: "文字颜色")
        tl.font = .systemFont(ofSize: 13)
        bgColorLabel.font = .systemFont(ofSize: 13)

        row.addArrangedSubview(sl)
        row.addArrangedSubview(sizeField)
        row.addArrangedSubview(boldCheck)
        row.addArrangedSubview(transparentCheck)
        row.addArrangedSubview(tl)
        row.addArrangedSubview(textColorSwatch)
        row.addArrangedSubview(bgColorLabel)
        row.addArrangedSubview(bgColorSwatch)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    private func configureSwatch(_ swatch: ColorSwatchButton, color: NSColor, action: Selector, tooltip: String) {
        swatch.color = color
        swatch.target = self
        swatch.action = action
        swatch.toolTip = tooltip
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 34).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func syncBackgroundRowVisibility() {
        let hidden = transparentCheck.state == .on
        bgColorLabel.isHidden = hidden
        bgColorSwatch.isHidden = hidden
    }

    // MARK: - 窗口：可拖边框缩放

    override func viewWillAppear() {
        super.viewWillAppear()
        makeResizable()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        makeResizable()
        view.window?.makeFirstResponder(textView)
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyMonitor()
    }

    /// sheet 默认不吃「拖边框缩放」，得手动补上 `.resizable` 并设好尺寸上下限。
    /// 上限取屏幕工作区 —— 顺手也就是"最大化"的天花板。
    private func makeResizable() {
        guard let window = view.window else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.minSize = Size.min
        window.contentMinSize = Size.min
        let cap = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
        window.maxSize = cap
        window.contentMaxSize = cap
    }

    /// ⌘B 切换加粗（Windows 上是 Ctrl+B）。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.view.window?.isKeyWindow == true else { return event }
            guard event.modifierFlags.contains(.command) else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == "b" else { return event }
            self.boldCheck.state = self.boldCheck.state == .on ? .off : .on
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - 取色

    @objc private func textColorClicked() { openPicker(forBackground: false) }
    @objc private func bgColorClicked() { openPicker(forBackground: true) }

    /// 文字颜色与背景颜色打开的是**同一个** `ColorPickerPanel` 实现，只是各自的
    /// 初始色与回写目标不同。
    private func openPicker(forBackground: Bool) {
        let existing = forBackground ? bgColorPicker : textColorPicker
        if let existing, let w = existing.view.window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let initial = forBackground ? pickedBackground : pickedColor
        let panel = ColorPickerPanel(initial: initial) { [weak self] color in
            guard let self else { return }
            if forBackground {
                self.pickedBackground = color
                self.bgColorSwatch.color = color
                TextInsertPanel.lastBackgroundColor = color
            } else {
                self.pickedColor = color
                self.textColorSwatch.color = color
                TextInsertPanel.lastColor = color
            }
        }
        if forBackground { bgColorPicker = panel } else { textColorPicker = panel }
        panel.show(relativeTo: view) { [weak self] in
            guard let self else { return }
            if forBackground { self.bgColorPicker = nil } else { self.textColorPicker = nil }
        }
    }

    @objc private func transparentToggled() {
        syncBackgroundRowVisibility()
    }

    // MARK: - 收尾

    @objc private func okClicked() {
        let content = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            cancelClicked()
            return
        }
        let size = max(8, min(200, sizeField.doubleValue))
        // 勾选「背景透明」→ 不铺底（backgroundColor = nil）
        let background: NSColor? = transparentCheck.state == .on ? nil : pickedBackground
        // 记入文字颜色自己的记忆（不碰侧栏工具色）。
        TextInsertPanel.lastColor = pickedColor
        TextInsertPanel.lastBackgroundColor = pickedBackground
        onConfirm(content, CGFloat(size), pickedColor, boldCheck.state == .on, background)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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
        format(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | shiftKey))
    }
}
