import AppKit
import UniformTypeIdentifiers

/// Sheet showing the extraction result.
///
/// 默认停在**查看模式**：把 Markdown 渲染成正常的排版（标题、列表、表格、
/// 代码块、图片）—— 直接看就知道识别出了什么，而不是对着一堆 `|` 和 `**` 猜。
/// 需要原始 Markdown 时切到**源码模式**（可编辑）。导出 / 剪贴板都按"当前这份"来：
/// - 导出 Markdown / Word / Excel 用**源码**（`markdown`）—— 排版器要的是标记；
/// - 写剪贴板用**查看模式**的内容（富文本 + 渲染后的纯文本），粘到 Word / WPS
///   直接带格式，粘到纯文本编辑器也不是一堆星号。
///
/// 有图片时：导出 Markdown 会生成文件夹（md + images/），导出 Word/Excel 会内嵌图片。
final class ExtractResultPanel: NSViewController {
    private let mode: ExtractMode
    private let images: [ExtractedImage]
    /// 源码模式的 Markdown（用户可在源码模式下编辑，导出用这份）。
    private var markdown: String
    /// 查看模式的渲染结果（显示 + 剪贴板用），只算一次。
    private let rendered: MarkdownRenderer.Rendered

    private let modeControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    /// 特意手工搭一套 **TextKit 1** 的存储栈。
    ///
    /// 原因只有一个：`NSTextTable`（查看模式的表格靠它画）在 TextKit 2 下不生效 ——
    /// 表格会整块消失。`NSTextView(frame:)` 默认走 TextKit 2，所以这里显式建
    /// NSTextStorage → NSLayoutManager → NSTextContainer 再交给 NSTextView。
    /// 别改回 `NSTextView()`。
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

    private var isViewMode = true

    private var monospacedFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    init(content: String, mode: ExtractMode, images: [ExtractedImage] = []) {
        self.markdown = content
        self.mode = mode
        self.images = images
        self.rendered = MarkdownRenderer.render(markdown: content, images: images)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.textView = NSTextView(frame: .zero, textContainer: textContainer)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 620, height: 520)

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

        // 标题 + 查看/源码切换同一行 —— 切换控件放在标题旁边，用户一眼看到。
        let title = NSTextField(labelWithString: "提取内容")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        modeControl.segmentCount = 2
        modeControl.setLabel("查看模式", forSegment: 0)
        modeControl.setLabel("源码模式", forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.toolTip = "查看模式：把 Markdown 排版成正常格式（表格会被画成真表格）\n源码模式：显示/编辑原始 Markdown，导出用的就是它"

        let titleRow = NSStackView(views: [title, modeControl, NSView()])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .centerY
        stack.addArrangedSubview(titleRow)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.delegate = self
        scrollView.documentView = textView
        stack.addArrangedSubview(scrollView)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // 引擎标签：告诉用户本次结果来自轻量模式还是精准模式
        let modeLabel = NSTextField(labelWithString: "识别引擎：\(mode.displayName)")
        modeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        switch mode {
        case .agent:
            modeLabel.textColor = .secondaryLabelColor
            modeLabel.toolTip = "本次由 MinerU 轻量解析接口完成（免登录、免 token），速度较快"
        case .precise:
            modeLabel.textColor = .systemBlue
            modeLabel.toolTip = "本次由 MinerU 精准解析接口（vlm 模型）完成"
        }
        stack.addArrangedSubview(modeLabel)

        let hint = NSTextField(wrappingLabelWithString: """
        识别结果已按「查看模式」自动复制到剪贴板（带格式，可直接粘到 Word / WPS / 微信）；切到源码模式可编辑原始 Markdown，导出用的是源码。
        """)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let exportMD = NSButton(title: "导出 Markdown", target: self, action: #selector(exportMarkdownClicked))
        exportMD.bezelStyle = .rounded
        exportMD.keyEquivalent = "\r"

        let exportXlsx = NSButton(title: "导出 Excel", target: self, action: #selector(exportXlsxClicked))
        exportXlsx.bezelStyle = .rounded

        let exportDocx = NSButton(title: "导出 Word", target: self, action: #selector(exportDocxClicked))
        exportDocx.bezelStyle = .rounded

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        copy.toolTip = "复制「查看模式」的内容：带格式的富文本 + 渲染后的纯文本"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let close = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded

        buttons.addArrangedSubview(exportMD)
        buttons.addArrangedSubview(exportXlsx)
        buttons.addArrangedSubview(exportDocx)
        buttons.addArrangedSubview(copy)
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(close)
        stack.addArrangedSubview(buttons)

        applyMode()

        // 自动写剪贴板就放在这里 —— 面板和剪贴板内容天然是同一次渲染的结果，
        // 分开在两处算容易出现"显示的"和"复制的"不一致。
        copyRenderedToPasteboard()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - 查看 / 源码模式

    @objc private func modeChanged() {
        // 顺序要紧：**先**把源码模式里的编辑收进 `markdown`，再翻标志位。
        // 反过来的话 `isViewMode` 已是 true，这次编辑就丢了（导出会用回旧内容）。
        if !isViewMode { markdown = textView.string }
        isViewMode = (modeControl.selectedSegment == 0)
        applyMode()
    }

    private func applyMode() {
        if isViewMode {
            textView.isEditable = false
            textView.isRichText = true
            textView.isHorizontallyResizable = false
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textStorage.setAttributedString(rendered.attributed)
            scrollView.hasHorizontalScroller = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
        } else {
            textView.isRichText = false
            textView.isEditable = true
            textView.isHorizontallyResizable = true
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
            textStorage.setAttributedString(NSAttributedString(
                string: markdown,
                attributes: [.font: monospacedFont, .foregroundColor: NSColor.labelColor]
            ))
            textView.typingAttributes = [.font: monospacedFont, .foregroundColor: NSColor.labelColor]
            scrollView.hasHorizontalScroller = true
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        textView.needsDisplay = true
        // 换模式等于换了一份内容，回到顶部，免得停在渲染前后不存在的行上。
        textView.scroll(.zero)
    }

    // MARK: - 剪贴板

    /// 把「查看模式」的内容写进剪贴板：RTF（带格式）+ 纯文本（渲染后、无 Markdown 标记）。
    private func copyRenderedToPasteboard() {
        let attributed = rendered.attributed
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let rtf = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(rendered.plain, forType: .string)
    }

    // MARK: - Actions

    @objc private func exportMarkdownClicked() {
        if images.isEmpty {
            runSavePanel(extension: "md") { url in
                try self.markdown.write(to: url, atomically: true, encoding: .utf8)
            }
        } else {
            // 有图片：导出为文件夹（md 文件 + images/ 图片目录），保证 md 引用完整可读
            runFolderPanel { folderURL in
                try self.writeMarkdownBundle(to: folderURL)
            }
        }
    }

    /// 把 markdown 与图片写入用户选择的文件夹：<文件夹>/<文件夹名>.md + images/…
    private func writeMarkdownBundle(to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let mdName = folder.lastPathComponent + ".md"
        try markdown.write(
            to: folder.appendingPathComponent(mdName), atomically: true, encoding: .utf8
        )
        for img in images {
            let target = folder.appendingPathComponent(img.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try img.data.write(to: target)
        }
    }

    @objc private func exportXlsxClicked() {
        runSavePanel(extension: "xlsx") { url in
            try OfficeExporter.exportXlsx(markdown: self.markdown, images: self.images, to: url)
        }
    }

    @objc private func exportDocxClicked() {
        runSavePanel(extension: "docx") { url in
            try OfficeExporter.exportDocx(markdown: self.markdown, images: self.images, to: url)
        }
    }

    private func runSavePanel(extension ext: String, onSave: @escaping (URL) throws -> Void) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        savePanel.nameFieldStringValue = "提取内容-\(formatter.string(from: Date())).\(ext)"
        savePanel.canCreateDirectories = true
        guard let window = view.window else { return }
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try onSave(url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    /// 选择导出文件夹的位置与名称（无扩展名）。
    private func runFolderPanel(onSave: @escaping (URL) throws -> Void) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.folder]
        savePanel.nameFieldStringValue = "提取内容-\(formatter.string(from: Date()))"
        savePanel.canCreateDirectories = true
        savePanel.message = "将创建此文件夹，内含 Markdown 文件与 images 图片文件夹"
        guard let window = view.window else { return }
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try onSave(url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func copyClicked() {
        copyRenderedToPasteboard()
    }

    @objc private func closeClicked() {
        presentingViewController?.dismiss(self)
    }
}

// MARK: - NSTextViewDelegate

extension ExtractResultPanel: NSTextViewDelegate {
    /// 源码模式下的编辑要收进 `markdown` —— 导出用的是它。
    func textDidChange(_ notification: Notification) {
        guard !isViewMode else { return }
        markdown = textView.string
    }
}
