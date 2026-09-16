import AppKit
import UniformTypeIdentifiers

/// Sheet showing extraction result as Markdown source:
/// scrollable/editable text + export .md / copy / close.
/// 有图片时：导出 Markdown 会生成文件夹（md + images/），导出 Word/Excel 会内嵌图片。
final class ExtractResultPanel: NSViewController {
    private let content: String
    private let mode: ExtractMode
    private let images: [ExtractedImage]
    private let textView = NSTextView()

    init(content: String, mode: ExtractMode, images: [ExtractedImage] = []) {
        self.content = content
        self.mode = mode
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 560, height: 460)

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

        let title = NSTextField(labelWithString: "提取内容（Markdown）")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = content
        textView.isEditable = true
        textView.isRichText = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        stack.addArrangedSubview(scroll)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        // 引擎标签：告诉用户本次结果来自轻量模式还是精准模式
        let modeLabel = NSTextField(labelWithString: "识别引擎：\(mode.displayName)")
        modeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        switch mode {
        case .agent:
            modeLabel.textColor = .secondaryLabelColor
            modeLabel.toolTip = "本次由 MinerU 轻量解析接口完成（免登录、免 token），速度较快"
        case .precise:
            modeLabel.textColor = .systemBlue
            modeLabel.toolTip = "轻量解析失败后自动降级，本次由 MinerU 精准解析接口（vlm 模型）完成"
        }
        stack.addArrangedSubview(modeLabel)

        let hint = NSTextField(wrappingLabelWithString: "识别结果已自动复制到剪贴板，可直接到其他文件中粘贴；上方内容可编辑。")
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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Actions

    @objc private func exportMarkdownClicked() {
        if images.isEmpty {
            runSavePanel(extension: "md") { url in
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
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
        try textView.string.write(
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
            try OfficeExporter.exportXlsx(markdown: self.textView.string, images: self.images, to: url)
        }
    }

    @objc private func exportDocxClicked() {
        runSavePanel(extension: "docx") { url in
            try OfficeExporter.exportDocx(markdown: self.textView.string, images: self.images, to: url)
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
    }

    @objc private func closeClicked() {
        presentingViewController?.dismiss(self)
    }
}
