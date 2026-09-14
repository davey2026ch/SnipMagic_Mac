import AppKit

/// Sheet showing OCR result: scrollable text + copy / close.
final class OCRResultPanel: NSViewController {
    private let mode: OCRMode
    private let content: String
    private let textView = NSTextView()

    init(mode: OCRMode, content: String) {
        self.mode = mode
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 520, height: 420)

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

        let title = NSTextField(labelWithString: mode.resultTitle)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 13)
        textView.string = content
        textView.isEditable = true
        textView.isRichText = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        stack.addArrangedSubview(scroll)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let hint = NSTextField(wrappingLabelWithString: "可直接编辑后复制；快捷键 ⌘A 全选、⌘C 复制。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let close = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded

        buttons.addArrangedSubview(copy)
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(close)
        stack.addArrangedSubview(buttons)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    @objc private func copyClicked() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
    }

    @objc private func closeClicked() {
        presentingViewController?.dismiss(self)
    }
}
