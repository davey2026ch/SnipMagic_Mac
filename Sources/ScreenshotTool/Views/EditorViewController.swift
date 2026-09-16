import AppKit

/// Main editor UI: toolbar + sidebar + canvas + tab bar.
final class EditorViewController: NSViewController {
    // Data
    private(set) var tabs: [EditorTab] = []
    private var currentIndex: Int?
    private var nextSequence = 1
    private var style = EditorStyle()
    private var undoByTab: [UUID: UndoStack] = [:]

    // UI
    private let rootStack = NSStackView()
    private let toolbar = NSView()
    private let sidebar = NSView()
    private let tabStrip = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "还没有截图")
    private let hintLabel = NSTextField(labelWithString: "")
    private let scroll = ZoomableScrollView()
    private let canvas = CanvasView()
    private let emptyState = NSView()
    private let colorSwatch = ColorSwatchButton()
    /// Strong reference to the open color panel (its window does not retain
    /// it strongly enough to survive).
    private var colorPanel: ColorPickerPanel?

    // Side-by-side compare mode (drag a tab onto the right half of the canvas)
    private let compareScroll = ZoomableScrollView()
    private let compareContainer = FlippedView()
    private let compareImageView = FlippedImageView()
    private let compareExitButton = NSButton(title: "✕ 退出对比", target: nil, action: nil)
    private let compareSyncLabel = NSTextField(labelWithString: "同步滚动")
    private let compareSyncSwitch = NSSwitch()
    /// Master flag for the two-pane scroll sync (toolbar switch, default on).
    private var compareSyncOn = true
    private let compareDivider = NSView()
    private let compareHint = NSView()
    private let compareHintLabel = NSTextField(labelWithString: "松开鼠标：与当前页签左右对比")
    private var compareTabID: UUID?
    private var compareRenderStamp: (annotationCount: Int, baseImage: CGImage)?
    /// ⌘+wheel zoom for the right compare pane (1 = natural size).
    private var compareZoom: CGFloat = 1.0
    private var compareBaseSize: NSSize = .zero
    private var scrollSyncPaused = false
    private var scrollObservers: [NSObjectProtocol] = []
    private var normalTrailingConstraint: NSLayoutConstraint!
    private var compareConstraints: [NSLayoutConstraint] = []
    private var tabDragIndex: Int?

    private var sidebarButtons: [NSButton] = []
    private var toolButtons: [ToolKind: NSButton] = [:]
    private var keyMonitor: Any?
    private var extractContentBtn = NSButton()
    private var isOCRRunning = false
    private var ocrProgressIndicator: NSProgressIndicator?
    private var ocrProgressPanel: NSPanel?
    private var ocrStageLabel: NSTextField?
    private var extractTask: MinerUExtractTask?

    var onCaptureRequest: (() -> Void)?
    var onLongCaptureRequest: (() -> Void)?

    private var currentTab: EditorTab? {
        guard let i = currentIndex, i >= 0, i < tabs.count else { return nil }
        return tabs[i]
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.windowBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 启动时读取 ~/.截图工具 中的马赛克密度、线条粗细
        let persisted = MinerUOCRService.loadConfig()
        style.mosaicCell = persisted.mosaic
        style.lineWidth = persisted.thickness
        buildLayout()
        bindCanvas()
        refreshEmptyState()
        applyShortcutHints()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.view.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            // Don't steal keys from text fields
            if let resp = self.view.window?.firstResponder, resp is NSTextView || resp is NSText {
                if event.keyCode != 53 { return event }
            }
            if cmd && event.charactersIgnoringModifiers == "c" {
                self.copySelection()
                return nil
            }
            if cmd && event.charactersIgnoringModifiers == "v" {
                self.paste()
                return nil
            }
            if cmd && event.charactersIgnoringModifiers == "z" {
                if flags.contains(.shift) { self.doRedo() } else { self.doUndo() }
                return nil
            }
            if cmd && event.charactersIgnoringModifiers == "y" {
                self.doRedo()
                return nil
            }
            if cmd && event.charactersIgnoringModifiers == "s" {
                self.saveCurrentTab()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.canvas.deleteSelected()
                return nil
            }
            return event
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.distribution = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        buildToolbar()
        buildBody()
        buildTabStrip()
        buildStatus()

        rootStack.addArrangedSubview(toolbar)
        rootStack.addArrangedSubview(bodyContainer)
        rootStack.addArrangedSubview(tabContainer)
        rootStack.addArrangedSubview(statusContainer)
    }

    private lazy var bodyContainer = NSView()
    private lazy var tabContainer = NSView()
    private lazy var statusContainer = NSView()

    private func buildToolbar() {
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = Theme.toolbarBackground.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])

        let captureBtn = makePrimaryButton("开始截图", action: #selector(startCapture))
        let longCaptureBtn = makePrimaryButton("长截图", icon: "arrow.up.and.down", action: #selector(startLongCapture))
        longCaptureBtn.toolTip = "框选区域后滚动页面（网页/文档），自动拼接为长图"

        let mosaicBtn = makeToolButton("▦ 马赛克", action: #selector(applyMosaic))
        extractContentBtn = makeToolButton("📋 提取内容", action: #selector(extractContentClicked))
        extractContentBtn.toolTip = "OCR 识别当前页签图片中的文字/表格（有选区则只识别选区），结果以 Markdown 返回并自动复制"
        let settingsBtn = makeToolButton("⚙️ 设置", action: #selector(showSettingsPanel))
        let saveAllBtn = makeToolButton("💾 全部保存", action: #selector(saveAllTabs))
        saveAllBtn.toolTip = "将全部页签导出到指定文件夹（文件类型可选，默认 PNG；当前页签单张保存用 ⌘S）"
        let undoBtn = makeToolButton("↶ 撤销", action: #selector(doUndo))
        let redoBtn = makeToolButton("↷ 重做", action: #selector(doRedo))

        for b in [captureBtn, longCaptureBtn, mosaicBtn, extractContentBtn, settingsBtn, saveAllBtn, undoBtn, redoBtn] {
            stack.addArrangedSubview(b)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        // Right side (compare mode only): sync-scroll toggle + exit button.
        // The toggle makes both panes scroll together horizontally and
        // vertically; turn it off to scroll each pane independently.
        compareSyncLabel.font = .systemFont(ofSize: 12)
        compareSyncLabel.textColor = .secondaryLabelColor
        compareSyncLabel.isHidden = true
        compareSyncLabel.toolTip = "对比时两图横向、纵向一起滚动"
        stack.addArrangedSubview(compareSyncLabel)

        compareSyncSwitch.state = .on
        compareSyncSwitch.controlSize = .small
        compareSyncSwitch.target = self
        compareSyncSwitch.action = #selector(compareSyncToggled)
        compareSyncSwitch.toolTip = "对比时两图横向、纵向一起滚动"
        compareSyncSwitch.isHidden = true
        stack.addArrangedSubview(compareSyncSwitch)
        stack.setCustomSpacing(6, after: compareSyncLabel)
        stack.setCustomSpacing(14, after: compareSyncSwitch)

        // Exit button: top-right corner, same height as the primary
        // "开始截图" button. Hidden outside compare mode.
        compareExitButton.bezelStyle = .rounded
        compareExitButton.font = .systemFont(ofSize: 13, weight: .medium)
        compareExitButton.toolTip = "退出左右对比模式"
        compareExitButton.target = self
        compareExitButton.action = #selector(exitCompare)
        compareExitButton.translatesAutoresizingMaskIntoConstraints = false
        compareExitButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        compareExitButton.isHidden = true
        stack.addArrangedSubview(compareExitButton)
    }

    private func buildBody() {
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.backgroundColor = Theme.windowBackground.cgColor

        // Sidebar
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = Theme.sidebarBackground.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 52).isActive = true
        bodyContainer.addSubview(sidebar)

        let sideStack = NSStackView()
        sideStack.orientation = .vertical
        sideStack.spacing = 6
        sideStack.alignment = .centerX
        sideStack.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sideStack)
        NSLayoutConstraint.activate([
            sideStack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sideStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sideStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sideStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        ])

        let tools: [ToolKind] = [
            .select, .view, .text, .arrow, .line, .pen,
            .rect, .roundedRect, .ellipse,
            .solidRect, .solidRoundedRect, .solidEllipse,
            .number
        ]
        for tool in tools {
            let btn = NSButton(title: "", target: self, action: #selector(toolClicked(_:)))
            btn.setButtonType(.toggle)
            btn.bezelStyle = .smallSquare
            btn.isBordered = true
            btn.imagePosition = .imageOnly
            // Text tool always shows a bold "T" so users recognize it as text.
            if tool == .text {
                btn.title = "T"
                btn.font = .systemFont(ofSize: 15, weight: .bold)
                btn.imagePosition = .noImage
            } else if let img = NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: tool.displayName)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                btn.image = img
            } else {
                btn.title = tool.shortLabel
                btn.font = .systemFont(ofSize: 9, weight: .medium)
                btn.imagePosition = .noImage
            }
            btn.toolTip = tool.displayName
            btn.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 36).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            if tool == .select {
                btn.state = .on
            }
            sideStack.addArrangedSubview(btn)
            sidebarButtons.append(btn)
            toolButtons[tool] = btn
        }

        // Color swatch at the very bottom of the tool sidebar, under the
        // number tool. Borderless rounded fill (NSColorWell's black frame
        // looked harsh); a click opens the custom color panel with presets,
        // RGB/HEX and a fullscreen eyedropper.
        colorSwatch.color = style.color
        colorSwatch.target = self
        colorSwatch.action = #selector(colorSwatchClicked)
        colorSwatch.translatesAutoresizingMaskIntoConstraints = false
        colorSwatch.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorSwatch.heightAnchor.constraint(equalToConstant: 28).isActive = true
        colorSwatch.toolTip = "画笔颜色（预设色 / RGB / HEX / 屏幕取色）"
        let colorGap = NSView()
        colorGap.translatesAutoresizingMaskIntoConstraints = false
        colorGap.heightAnchor.constraint(equalToConstant: 6).isActive = true
        sideStack.addArrangedSubview(colorGap)
        sideStack.addArrangedSubview(colorSwatch)

        // Canvas area — documentView uses frame-based layout, not Auto Layout.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        // Legacy-style scrollers with auto-hide: overlay scrollers only flash
        // while scrolling, so a horizontal bar was effectively undiscoverable.
        // Legacy + autohidesScrollers keeps the bar visible whenever the
        // content overflows — vertical AND horizontal — and hidden when it fits.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.canvasBackground
        scroll.automaticallyAdjustsContentInsets = false
        bodyContainer.addSubview(scroll)

        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.autoresizingMask = []
        canvas.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true

        // Right compare pane (hidden until a tab is dragged onto the right half).
        compareScroll.translatesAutoresizingMaskIntoConstraints = false
        compareScroll.hasVerticalScroller = true
        compareScroll.hasHorizontalScroller = true
        compareScroll.scrollerStyle = .legacy
        compareScroll.autohidesScrollers = true
        compareScroll.borderType = .noBorder
        compareScroll.drawsBackground = true
        compareScroll.backgroundColor = Theme.canvasBackground
        compareScroll.automaticallyAdjustsContentInsets = false
        compareScroll.isHidden = true
        bodyContainer.addSubview(compareScroll)

        // Right pane document mirrors the left canvas: the image sits inside a
        // 28pt-padded container, so it keeps the same top/side margins as the
        // left image and stays visually aligned.
        // scaleAxesIndependently: the frame is resized on zoom, and the image
        // must stretch with it (scaleNone would keep the bitmap at natural
        // size, so zooming looked like the image merely sliding around).
        compareImageView.imageScaling = .scaleAxesIndependently
        compareImageView.frame = NSRect(x: 28, y: 28, width: 100, height: 100)
        compareContainer.addSubview(compareImageView)
        compareContainer.frame = NSRect(x: 0, y: 0, width: 156, height: 156)
        compareScroll.documentView = compareContainer
        compareScroll.contentView.postsBoundsChangedNotifications = true
        // ⌘+wheel / pinch zoom for the right pane (document is not a CanvasView).
        compareScroll.onZoom = { [weak self] factor in
            self?.zoomCompare(byFactor: factor)
        }
        compareDivider.translatesAutoresizingMaskIntoConstraints = false
        compareDivider.wantsLayer = true
        compareDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        compareDivider.isHidden = true
        bodyContainer.addSubview(compareDivider)

        // Floating controls sit above the panes.
        // (The compare exit button now lives in the toolbar's top-right.)
        compareHint.translatesAutoresizingMaskIntoConstraints = false
        compareHint.wantsLayer = true
        compareHint.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        compareHint.layer?.borderColor = Theme.accent.withAlphaComponent(0.55).cgColor
        compareHint.layer?.borderWidth = 1
        compareHint.layer?.cornerRadius = 8
        compareHint.isHidden = true
        bodyContainer.addSubview(compareHint)
        compareHintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        compareHintLabel.translatesAutoresizingMaskIntoConstraints = false
        compareHint.addSubview(compareHintLabel)

        // Empty state
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.wantsLayer = true
        bodyContainer.addSubview(emptyState)

        let emptyLabel = NSTextField(wrappingLabelWithString: "")
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: emptyState.widthAnchor, constant: -40)
        ])
        emptyLabel.tag = 99

        // Normal layout: canvas scroll spans the full body width. Compare mode
        // swaps this single trailing constraint for the split-pane set.
        normalTrailingConstraint = scroll.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor)
        let compareConstraints: [NSLayoutConstraint] = [
            compareScroll.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 1),
            compareScroll.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            compareScroll.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            compareScroll.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            compareScroll.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            compareDivider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            compareDivider.widthAnchor.constraint(equalToConstant: 1),
            compareDivider.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            compareDivider.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ]
        self.compareConstraints = compareConstraints

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            compareHint.leadingAnchor.constraint(equalTo: bodyContainer.centerXAnchor, constant: 12),
            compareHint.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -12),
            compareHint.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 12),
            compareHint.heightAnchor.constraint(equalToConstant: 44),
            compareHintLabel.centerXAnchor.constraint(equalTo: compareHint.centerXAnchor),
            compareHintLabel.centerYAnchor.constraint(equalTo: compareHint.centerYAnchor)
        ])
        normalTrailingConstraint.isActive = true

        setupCompareDragAndSync()
    }

    // MARK: - Compare mode

    private func setupCompareDragAndSync() {
        // Bidirectional proportional scroll sync between the two panes.
        scrollObservers = [
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.syncScroll(from: self.scroll, to: self.compareScroll)
            },
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: compareScroll.contentView, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.syncScroll(from: self.compareScroll, to: self.scroll)
            }
        ]
    }

    /// Manual drag tracking from a tab chip (no NSDragging machinery — the
    /// event loop in DraggableTabButton drives this directly).
    private func handleTabDrag(_ phase: DraggableTabButton.DragPhase, windowPoint: NSPoint, index: Int) {
        switch phase {
        case .began:
            tabDragIndex = index
        case .moved:
            compareHintLabel.stringValue = compareTabID == nil
                ? "松开鼠标：与当前页签左右对比"
                : "松开鼠标：替换右侧对比图"
            setCompareHintVisible(isValidCompareDrop(windowPoint: windowPoint))
        case .ended:
            setCompareHintVisible(false)
            if let i = tabDragIndex, isValidCompareDrop(windowPoint: windowPoint), i != currentIndex {
                enterCompare(tabIndex: i)
            }
            tabDragIndex = nil
        case .cancelled:
            setCompareHintVisible(false)
            tabDragIndex = nil
        }
    }

    /// Is the given window point a valid drop target for starting/replacing a
    /// compare session? (Right half of the canvas pane, or the whole right
    /// pane while already comparing.)
    private func isValidCompareDrop(windowPoint: NSPoint) -> Bool {
        guard let dragIndex = tabDragIndex, dragIndex != currentIndex,
              tabs.indices.contains(dragIndex) else { return false }
        let p = bodyContainer.convert(windowPoint, from: nil)
        if compareTabID != nil {
            return !compareScroll.isHidden && NSPointInRect(p, compareScroll.frame)
        }
        guard !scroll.isHidden else { return false }
        let r = scroll.frame
        return NSPointInRect(p, r) && p.x >= r.midX
    }

    private func setCompareHintVisible(_ visible: Bool) {
        compareHint.isHidden = !visible
    }

    private func enterCompare(tabIndex: Int) {
        guard let current = currentTab, tabs.indices.contains(tabIndex) else { return }
        let target = tabs[tabIndex]
        guard target.id != current.id else { return }

        compareTabID = target.id
        compareZoom = 1.0
        refreshCompareImage(force: true)
        compareScroll.isHidden = false
        compareDivider.isHidden = false
        compareSyncLabel.isHidden = false
        compareSyncSwitch.isHidden = false
        compareExitButton.isHidden = false

        NSLayoutConstraint.deactivate([normalTrailingConstraint])
        NSLayoutConstraint.activate(compareConstraints)
        view.layoutSubtreeIfNeeded()

        syncScroll(from: scroll, to: compareScroll)
        refreshTabs()
        refreshStatus()
    }

    @objc private func compareSyncToggled() {
        compareSyncOn = compareSyncSwitch.state == .on
        // Turning sync back on re-aligns the panes immediately.
        if compareSyncOn, compareTabID != nil {
            syncScroll(from: scroll, to: compareScroll)
        }
    }

    @objc private func exitCompare() {
        guard compareTabID != nil else { return }
        compareTabID = nil
        compareRenderStamp = nil
        compareScroll.isHidden = true
        compareDivider.isHidden = true
        compareSyncLabel.isHidden = true
        compareSyncSwitch.isHidden = true
        compareExitButton.isHidden = true
        NSLayoutConstraint.deactivate(compareConstraints)
        normalTrailingConstraint.isActive = true
        refreshTabs()
        refreshStatus()
    }

    /// Re-render the right pane when its tab's content changed (count or baked base).
    private func refreshCompareImage(force: Bool = false) {
        guard let id = compareTabID,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        let sameStamp = compareRenderStamp?.annotationCount == tab.annotations.count
            && compareRenderStamp?.baseImage === tab.baseImage
        if !force, sameStamp { return }
        guard let composite = tab.renderComposite() else { return }
        compareRenderStamp = (annotationCount: tab.annotations.count, baseImage: tab.baseImage)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        compareBaseSize = NSSize(width: CGFloat(composite.width) / scale, height: CGFloat(composite.height) / scale)
        compareImageView.image = NSImage(cgImage: composite, size: compareBaseSize)
        applyCompareZoom()
    }

    /// Lay out the right pane's image at the current compareZoom.
    private func applyCompareZoom() {
        guard compareBaseSize.width > 0 else { return }
        let w = compareBaseSize.width * compareZoom
        let h = compareBaseSize.height * compareZoom
        compareImageView.frame = NSRect(x: 28, y: 28, width: w, height: h)
        compareContainer.frame = NSRect(origin: .zero, size: NSSize(width: w + 56, height: h + 56))
    }

    /// ⌘+wheel / pinch zoom for the right pane. Same clamp-and-snap as the canvas.
    private func zoomCompare(byFactor factor: CGFloat) {
        guard compareBaseSize.width > 0 else { return }
        var new = compareZoom * factor
        new = min(8.0, max(0.1, new))
        if abs(new - 1.0) < 0.04 { new = 1.0 }
        guard new != compareZoom else { return }
        compareZoom = new
        applyCompareZoom()
    }

    /// Proportional scroll sync between the two panes (same fraction of max offset).
    /// Honors the "同步滚动" switch: off means each pane scrolls independently.
    private func syncScroll(from src: NSScrollView, to dst: NSScrollView) {
        guard compareTabID != nil, compareSyncOn, !scrollSyncPaused else { return }
        guard let srcDoc = src.documentView, let dstDoc = dst.documentView else { return }
        scrollSyncPaused = true
        defer { scrollSyncPaused = false }

        let srcBounds = src.contentView.bounds
        let dstBounds = dst.contentView.bounds
        let srcMaxX = max(0, srcDoc.frame.width - srcBounds.width)
        let srcMaxY = max(0, srcDoc.frame.height - srcBounds.height)
        let dstMaxX = max(0, dstDoc.frame.width - dstBounds.width)
        let dstMaxY = max(0, dstDoc.frame.height - dstBounds.height)
        let fx = srcMaxX > 0 ? srcBounds.origin.x / srcMaxX : 0
        let fy = srcMaxY > 0 ? srcBounds.origin.y / srcMaxY : 0
        dst.contentView.scroll(to: NSPoint(x: fx * dstMaxX, y: fy * dstMaxY))
        dst.reflectScrolledClipView(dst.contentView)
    }

    private func buildTabStrip() {
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.wantsLayer = true
        tabContainer.layer?.backgroundColor = Theme.toolbarBackground.cgColor
        tabContainer.heightAnchor.constraint(equalToConstant: 44).isActive = true

        tabStrip.orientation = .horizontal
        tabStrip.spacing = 0
        tabStrip.alignment = .centerY
        tabStrip.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(tabStrip)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: tabContainer.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor)
        ])

        // Hairline under the strip — tabs visually "root" into it.
        let hairline = NSView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        tabContainer.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func buildStatus() {
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.wantsLayer = true
        statusContainer.layer?.backgroundColor = Theme.windowBackground.cgColor
        statusContainer.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: statusContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.stringValue = "截图已包含鼠标箭头"
        stack.addArrangedSubview(hintLabel)
    }

    private func makeToolButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 13)
        return b
    }

    /// Soft sky-blue primary action with white label/icon.
    private func makePrimaryButton(_ title: String, icon: String = "viewfinder", action: Selector) -> NSButton {
        CapturePrimaryButton(title: title, icon: icon, target: self, action: action)
    }

    private func makeCaption(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .secondaryLabelColor
        return f
    }

    // MARK: - Canvas bindings

    private func bindCanvas() {
        canvas.onWillMutate = { [weak self] in
            self?.pushUndoForCurrent()
        }
        canvas.onAnnotationsChanged = { [weak self] in
            self?.refreshStatus()
            self?.refreshTabs()
            self?.refreshCompareImage()
        }
        canvas.onRequestTextInsert = { [weak self] point in
            self?.showTextPanel(at: point)
        }
        canvas.onRequestTextEdit = { [weak self] ann in
            self?.showTextEditPanel(for: ann)
        }
        canvas.onSelectionChanged = { [weak self] rect in
            self?.refreshStatus(selection: rect)
        }
        canvas.onRequestToolSwitch = { [weak self] tool in
            // Auto-switch after draw/paste keeps the new object selected.
            self?.selectedTool(tool, preserveSelection: true)
        }
    }

    private func applyShortcutHints() {
        let cmd = HotkeyService.shared.displayString
        let long = HotkeyService.shared.longDisplayString
        if let label = emptyState.viewWithTag(99) as? NSTextField {
            label.stringValue = "还没有截图\n按 \(cmd) 框选屏幕，截图会自动变成一个新页签\n长截图：\(long)（两个快捷键均可在「设置」里修改）"
        }
    }

    // MARK: - Tabs

    func addCapturedImage(_ image: CGImage, title: String? = nil) {
        let tab = EditorTab(sequence: nextSequence, image: image, title: title)
        nextSequence += 1
        tabs.append(tab)
        undoByTab[tab.id] = UndoStack()
        currentIndex = tabs.count - 1
        selectedTool(.select)
        refreshAll()
        // Bring editor forward
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        currentIndex = index
        canvas.tab = tabs[index]
        canvas.selectedAnnotation = nil
        canvas.clearSelection()
        canvas.style = style
        refreshAll()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        selectTab(at: sender.tag)
    }

    @objc private func tabRightClicked(_ sender: NSButton) {
        let index = sender.tag
        let menu = NSMenu()
        let close = NSMenuItem(title: "关闭", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = index
        let save = NSMenuItem(title: "保存", action: #selector(saveTabFromMenu(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = index
        menu.addItem(save)
        menu.addItem(close)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        requestCloseTab(at: index)
    }

    @objc private func saveTabFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        selectTab(at: index)
        saveCurrentTab()
    }

    @objc private func startCapture() {
        onCaptureRequest?()
    }

    @objc private func startLongCapture() {
        onLongCaptureRequest?()
    }

    private func requestCloseTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]

        // Unsaved check
        let reallyUnsaved = (tab.savedURL == nil) || !tab.isSaved

        if reallyUnsaved {
            let alert = NSAlert()
            alert.messageText = "尚未保存"
            alert.informativeText = "「\(tab.displayTitle)」还没有保存，要保存吗？"
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "不保存")
            alert.addButton(withTitle: "取消")
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                selectTab(at: index)
                saveCurrentTab()
                // If still unsaved (user cancelled save dialog), abort close
                if tabs.indices.contains(index), !tabs[index].isSaved {
                    return
                }
            } else if resp == .alertThirdButtonReturn {
                return
            }
        }

        tabs.remove(at: index)
        if let id = tab.id as UUID? {
            undoByTab.removeValue(forKey: id)
        }
        // If the tab shown on the compare pane was closed, leave compare mode.
        if tab.id == compareTabID {
            exitCompare()
        }
        if tabs.isEmpty {
            currentIndex = nil
            canvas.tab = nil
        } else {
            currentIndex = min(index, tabs.count - 1)
            canvas.tab = currentTab
        }
        refreshAll()
    }

    private func rebuildTabs() {
        tabStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (i, tab) in tabs.enumerated() {
            let chip = makeTabChip(
                title: tab.displayTitle,
                index: i,
                active: i == currentIndex,
                comparing: tab.id == compareTabID
            )
            tabStrip.addArrangedSubview(chip)
        }
    }

    private func makeTabChip(title: String, index: Int, active: Bool, comparing: Bool) -> TabChipView {
        let chip = TabChipView(title: title, index: index, active: active, comparing: comparing)
        chip.tabButton.target = self
        chip.tabButton.action = #selector(tabClicked(_:))

        let menu = NSMenu()
        let close = NSMenuItem(title: "关闭", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = index
        let save = NSMenuItem(title: "保存", action: #selector(saveTabFromMenu(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = index
        let compare = NSMenuItem(title: "与当前页签对比", action: #selector(compareTabFromMenu(_:)), keyEquivalent: "")
        compare.target = self
        compare.representedObject = index
        let saveAll = NSMenuItem(title: "全部保存", action: #selector(saveAllTabs), keyEquivalent: "")
        saveAll.target = self
        saveAll.toolTip = "将全部页签导出为 PNG"
        menu.addItem(save)
        menu.addItem(saveAll)
        menu.addItem(compare)
        menu.addItem(close)
        chip.tabButton.menu = menu

        return chip
    }

    @objc private func compareTabFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        if let id = tabs.indices.contains(index) ? tabs[index].id : nil, id == compareTabID {
            exitCompare()
        } else {
            enterCompare(tabIndex: index)
        }
    }

    // MARK: - Tools

    @objc private func toolClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let tool = ToolKind(rawValue: id) else { return }
        selectedTool(tool)
    }

    func selectedTool(_ tool: ToolKind, preserveSelection: Bool = false) {
        style.tool = tool
        canvas.style = style
        for (t, btn) in toolButtons {
            btn.state = (t == tool) ? .on : .off
        }
        if !preserveSelection {
            canvas.commitSelectedPasteIfAny()
            canvas.clearSelection()
            canvas.selectedAnnotation = nil
        }
        // Keep first responder on canvas so drawing shortcuts work immediately.
        if canvas.tab != nil {
            view.window?.makeFirstResponder(canvas)
        }
        // Number tool: open the value menu right away on the sidebar button.
        if tool == .number, !preserveSelection, let btn = toolButtons[.number] {
            showNumberMenu(from: btn)
        }
        refreshStatus()
    }

    private func showNumberMenu(from button: NSButton) {
        let menu = NSMenu()
        for i in 1...20 {
            let item = NSMenuItem(title: AnnotationRenderer.numberString(i), action: #selector(numberMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = i
            if i == style.numberValue {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX + 4, y: button.bounds.maxY), in: button)
    }

    @objc private func numberMenuItemClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        style.numberValue = value
        canvas.style = style
        toolButtons[.number]?.toolTip = "序号（当前 \(AnnotationRenderer.numberString(value))）"
        // Keep number tool active after picking a value.
        if style.tool != .number {
            selectedTool(.number, preserveSelection: true)
        }
    }

    // MARK: - Actions

    @objc private func applyMosaic() {
        // Apply first — switching tools clears the selection.
        let hadSelection = canvas.selectionRect.width > 2 && canvas.selectionRect.height > 2
        canvas.applyMosaicToSelection()
        if style.tool != .select {
            selectedTool(.select, preserveSelection: true)
        }
        if !hadSelection {
            let a = NSAlert()
            a.messageText = "请先框选区域"
            a.informativeText = "用「选择」工具在图上拖一个框，再点「马赛克」打码。"
            a.runModal()
        }
    }

    // MARK: - 内容提取（MinerU：轻量解析优先，失败降级精准解析 vlm）

    @objc private func extractContentClicked() {
        guard !isOCRRunning else { return }
        guard let tab = currentTab else {
            let a = NSAlert()
            a.messageText = "还没有截图"
            a.informativeText = "先截一张图，再使用「提取内容」。"
            a.runModal()
            return
        }

        let selection = canvas.selectionRect
        let hasSelection = selection.width > 2 && selection.height > 2
        let sourceImage: CGImage?
        if hasSelection {
            sourceImage = tab.renderRegion(selection)
        } else {
            sourceImage = tab.renderComposite()
        }
        guard let image = sourceImage, let png = MinerUOCRService.encodePNG(image) else {
            let a = NSAlert()
            a.messageText = "无法导出图片"
            a.informativeText = "请重试，或先保存当前截图。"
            a.runModal()
            return
        }

        isOCRRunning = true
        extractContentBtn.isEnabled = false
        showOCRProgress(scopedToSelection: hasSelection)

        extractTask = MinerUOCRService.extract(
            imageData: png,
            onStage: { [weak self] stage in
                self?.ocrStageLabel?.stringValue = stage
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isOCRRunning = false
                self.extractContentBtn.isEnabled = true
                self.extractTask = nil
                self.hideOCRProgress()

                switch result {
                case .failure(MinerUOCRError.cancelled):
                    break // user cancelled — no alert
                case .failure(let error):
                    let a = NSAlert()
                    // Token 未配置/不可用：引导用户去设置界面更新
                    var tokenIssue: MinerUOCRError?
                    if case MinerUOCRError.tokenMissing? = error as? MinerUOCRError { tokenIssue = .tokenMissing }
                    if case MinerUOCRError.tokenInvalid(let msg)? = error as? MinerUOCRError { tokenIssue = .tokenInvalid(msg) }
                    if let tokenIssue {
                        a.messageText = "需要配置可用的 MinerU Token"
                        a.informativeText = """
                        轻量解析失败后需使用精准解析（vlm），但 Token \(tokenIssue.localizedDescription)。

                        请点工具栏「⚙️ 设置」，在「MinerU token」一栏填写或更新后重试。
                        Token 可在 mineru.net 的「API 管理」页面创建。
                        """
                    } else {
                        a.messageText = "提取内容失败"
                        a.informativeText = error.localizedDescription
                    }
                    a.runModal()
                case .success(let outcome):
                    // Auto-copy to clipboard so the user can paste anywhere.
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(outcome.markdown, forType: .string)
                    self.presentExtractResult(markdown: outcome.markdown, images: outcome.images, mode: outcome.mode)
                }
            }
        )
    }

    @objc private func cancelExtractClicked() {
        extractTask?.cancel()
        // Completion fires with .cancelled and performs the UI cleanup.
    }

    private func showOCRProgress(scopedToSelection: Bool) {
        hideOCRProgress()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 190))
        panel.contentView = container

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ])

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)
        ocrProgressIndicator = spinner

        let label = NSTextField(labelWithString: "正在提取内容…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        stack.addArrangedSubview(label)

        let sub = NSTextField(labelWithString: scopedToSelection ? "识别选区 · MinerU 轻量解析" : "识别整图 · MinerU 轻量解析")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        stack.addArrangedSubview(sub)
        ocrStageLabel = sub

        let cancel = NSButton(title: "取消识别", target: self, action: #selector(cancelExtractClicked))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .regular
        stack.addArrangedSubview(cancel)
        stack.setCustomSpacing(6, after: cancel)

        if let window = view.window {
            panel.center()
            // Anchor near editor without stealing key focus.
            if let screen = window.screen ?? NSScreen.main {
                let frame = panel.frame
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.midX - frame.width / 2,
                    y: screen.visibleFrame.midY - frame.height / 2 + 40
                ))
            }
        }
        panel.orderFrontRegardless()
        ocrProgressPanel = panel
    }

    private func hideOCRProgress() {
        ocrProgressIndicator?.stopAnimation(nil)
        ocrProgressIndicator = nil
        ocrStageLabel = nil
        ocrProgressPanel?.orderOut(nil)
        ocrProgressPanel = nil
    }

    private func presentExtractResult(markdown: String, images: [ExtractedImage] = [], mode: ExtractMode) {
        let panel = ExtractResultPanel(content: markdown, mode: mode, images: images)
        if let host = view.window?.contentViewController, host !== self {
            host.presentAsSheet(panel)
        } else {
            presentAsSheet(panel)
        }
    }

    @objc private func colorSwatchClicked() {
        // Already open → just focus it.
        if let existing = colorPanel, let w = existing.view.window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ColorPickerPanel(initial: style.color) { [weak self] color in
            guard let self else { return }
            self.style.color = color
            self.colorSwatch.color = color
            self.canvas.style = self.style
            if self.canvas.selectedAnnotation != nil {
                self.canvas.applyCurrentStyleToSelected()
            }
        }
        colorPanel = panel
        panel.show(relativeTo: view) { [weak self] in
            self?.colorPanel = nil
        }
    }

    @objc private func showSettingsPanel() {
        guard view.window != nil else { return }
        // 反向带出：每次打开都从 ~/.截图工具 现读，保证界面与文件一一对应
        // （运行中手动改文件后，无需重启即可在此看到并按「确定」生效）
        let config = MinerUOCRService.loadConfig()
        let captureText = config.captureHotkey
            .map { HotkeyService.format(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            ?? HotkeyService.shared.displayString
        let longText = config.longHotkey
            .map { HotkeyService.format(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            ?? HotkeyService.shared.longDisplayString
        let panel = SettingsPanel(
            hotkeyDisplay: captureText,
            longHotkeyDisplay: longText,
            hotkey: config.captureHotkey ?? HotkeyService.shared.currentHotkey,
            longHotkey: config.longHotkey ?? HotkeyService.shared.currentLongHotkey,
            mosaic: config.mosaic,
            thickness: config.thickness,
            minerUToken: config.token ?? "",
            minerUTimeout: config.agentTimeout
        ) { [weak self] hotkey, longHotkey, mosaic, thickness, minerUToken, minerUTimeout in
            guard let self else { return }
            // 先应用新值（注册快捷键会同步更新 HotkeyService.current*）
            if let (key, mods) = hotkey {
                HotkeyService.shared.register(keyCode: key, modifiers: mods)
            } else {
                let cur = HotkeyService.shared.currentHotkey
                HotkeyService.shared.register(keyCode: cur.keyCode, modifiers: cur.modifiers)
            }
            if let (key, mods) = longHotkey {
                HotkeyService.shared.registerLong(keyCode: key, modifiers: mods)
            } else {
                let cur = HotkeyService.shared.currentLongHotkey
                HotkeyService.shared.registerLong(keyCode: cur.keyCode, modifiers: cur.modifiers)
            }
            self.applyShortcutHints()
            self.style.mosaicCell = mosaic
            self.style.lineWidth = thickness
            self.canvas.style = self.style
            if self.canvas.selectedAnnotation != nil {
                self.canvas.applyCurrentStyleToSelected()
            }
            // 正向生成：把全部设置项（快捷键/马赛克/粗细/token/超时）写入 ~/.截图工具
            let savedCapture = HotkeyService.shared.currentHotkey
            let savedLong = HotkeyService.shared.currentLongHotkey
            MinerUOCRService.saveConfig(
                captureHotkey: savedCapture,
                longHotkey: savedLong,
                mosaic: mosaic,
                thickness: thickness,
                token: minerUToken,
                agentTimeout: minerUTimeout
            )
        }
        // Present on the window's content VC — more reliable than self.presentAsSheet
        // when this VC is a plain contentViewController.
        if let host = view.window?.contentViewController, host !== self {
            host.presentAsSheet(panel)
        } else {
            presentAsSheet(panel)
        }
    }

    @objc private func doUndo() {
        guard let tab = currentTab, let stack = undoByTab[tab.id] else { return }
        let current = EditorSnapshot(
            annotations: tab.annotations.map { $0.copyAnnotation() },
            baseImage: tab.baseImage
        )
        if let prev = stack.undo(current: current) {
            tab.annotations = prev.annotations
            tab.baseImage = prev.baseImage
            canvas.selectedAnnotation = nil
            canvas.tab = tab
            canvas.needsDisplay = true
            refreshStatus()
            refreshTabs()
        }
    }

    @objc private func doRedo() {
        guard let tab = currentTab, let stack = undoByTab[tab.id] else { return }
        let current = EditorSnapshot(
            annotations: tab.annotations.map { $0.copyAnnotation() },
            baseImage: tab.baseImage
        )
        if let next = stack.redo(current: current) {
            tab.annotations = next.annotations
            tab.baseImage = next.baseImage
            canvas.selectedAnnotation = nil
            canvas.tab = tab
            canvas.needsDisplay = true
            refreshStatus()
            refreshTabs()
        }
    }

    private func pushUndoForCurrent() {
        guard let tab = currentTab else { return }
        let stack = undoByTab[tab.id] ?? {
            let s = UndoStack()
            undoByTab[tab.id] = s
            return s
        }()
        // Deep-ish snapshot: new array with copied Annotation objects, plus the
        // (immutable) base image reference — mosaic/paste commits bake pixels
        // into the base image, so undo must capture it too.
        let snapshot = EditorSnapshot(
            annotations: tab.annotations.map { $0.copyAnnotation() },
            baseImage: tab.baseImage
        )
        stack.push(snapshot)
    }

    // MARK: - Copy / Paste / Save

    func copySelection() {
        if let msg = canvas.copySelectionToClipboard() {
            flashStatus(msg)
        }
    }

    func paste() {
        if let msg = canvas.pasteFromClipboard() {
            flashStatus(msg)
        }
    }

    /// Show a transient message in the status bar (reverts to the normal
    /// status text after ~2.5s) so clipboard actions give visible feedback.
    private var statusResetWorkItem: DispatchWorkItem?
    private func flashStatus(_ message: String) {
        statusResetWorkItem?.cancel()
        statusLabel.stringValue = message
        let work = DispatchWorkItem { [weak self] in
            self?.refreshStatus()
        }
        statusResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Accessory view with a file-type popup for save panels. Default PNG
    /// (lossless — screenshots stay pixel-perfect); JPEG for smaller files.
    private func makeSaveFormatAccessory() -> (view: NSView, popup: NSPopUpButton) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "PNG 图片（.png，无损）")
        popup.addItem(withTitle: "JPEG 图片（.jpg，文件小）")
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = #selector(saveFormatPopupChanged(_:))
        popup.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "文件类型：")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        return (stack, popup)
    }

    /// Keep the save panel's filename extension / the open panel's message in
    /// sync with the file-type popup selection.
    @objc private func saveFormatPopupChanged(_ sender: NSPopUpButton) {
        let isPNG = sender.indexOfSelectedItem == 0
        if let savePanel = sender.window as? NSSavePanel {
            savePanel.allowedContentTypes = [isPNG ? .png : .jpeg]
            let base = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
            if !base.isEmpty {
                savePanel.nameFieldStringValue = "\(base).\(isPNG ? "png" : "jpg")"
            }
        } else if let openPanel = sender.window as? NSOpenPanel {
            let count = sender.tag
            openPanel.message = "选择保存位置，\(count) 个页签将以 \(isPNG ? "PNG" : "JPEG") 格式保存"
        }
    }

    func saveCurrentTab() {
        guard let tab = currentTab else { return }
        guard let image = tab.renderComposite() else { return }

        let panel = NSSavePanel()
        panel.title = "另存为"
        // Single type (PNG default) → no built-in format popup; the accessory
        // view owns the type choice and updates allowedContentTypes on change.
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = tab.displayTitle
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.accessoryView = makeSaveFormatAccessory().view

        panel.beginSheetModal(for: view.window!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let isJPG = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
            let flattened = ScreenCaptureService.flatten(image, fillWhite: isJPG) ?? image
            do {
                try ImageIOExporter.save(flattened, to: url, as: isJPG ? .jpeg : .png)
                tab.markSaved(url: url)
                self.refreshTabs()
                self.refreshStatus()
            } catch {
                let a = NSAlert()
                a.messageText = "保存失败"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    /// Save every tab into a user-chosen folder (PNG by default, JPEG optional
    /// via the file-type popup). Filenames come from tab titles (deduplicated);
    /// failures are collected and reported.
    @objc private func saveAllTabs() {
        guard !tabs.isEmpty else {
            let a = NSAlert()
            a.messageText = "还没有截图"
            a.informativeText = "先截一张图，再使用「全部保存」。"
            a.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "全部保存"
        panel.message = "选择保存位置，\(tabs.count) 个页签将以 PNG 格式保存"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let accessory = makeSaveFormatAccessory()
        accessory.popup.tag = tabs.count
        panel.accessoryView = accessory.view

        panel.beginSheetModal(for: view.window!) { resp in
            guard resp == .OK, let dir = panel.url else { return }
            let isPNG = accessory.popup.indexOfSelectedItem == 0
            var savedCount = 0
            var failedTitles: [String] = []
            var usedNames = Set<String>()

            for tab in self.tabs {
                guard let image = tab.renderComposite() else {
                    failedTitles.append(tab.displayTitle)
                    continue
                }
                let base = Self.sanitizedFileName(tab.displayTitle)
                var name = base
                var n = 2
                while usedNames.contains(name.lowercased()) {
                    name = "\(base)-\(n)"
                    n += 1
                }
                usedNames.insert(name.lowercased())
                let url = dir.appendingPathComponent("\(name).\(isPNG ? "png" : "jpg")")
                do {
                    // JPEG has no alpha — flatten onto white first.
                    let out = isPNG ? image : (ScreenCaptureService.flatten(image, fillWhite: true) ?? image)
                    try ImageIOExporter.save(out, to: url, as: isPNG ? .png : .jpeg)
                    tab.markSaved(url: url)
                    savedCount += 1
                } catch {
                    failedTitles.append(tab.displayTitle)
                }
            }

            self.refreshTabs()
            self.refreshStatus()

            if !failedTitles.isEmpty {
                let a = NSAlert()
                a.messageText = "部分页签保存失败"
                a.informativeText = "已保存 \(savedCount)/\(self.tabs.count) 个，失败：\(failedTitles.joined(separator: "、"))"
                a.runModal()
            }
        }
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "截图" : trimmed
    }

    // MARK: - Text panel

    private func showTextPanel(at point: CGPoint) {
        guard currentTab != nil else { return }
        let panel = TextInsertPanel(defaultColor: style.color) { [weak self] content, size, color, bold, opaque in
            guard let self else { return }
            self.style.color = color
            self.colorSwatch.color = color
            self.canvas.style = self.style
            self.canvas.insertText(origin: point, content: content, fontSize: size, bold: bold, opaque: opaque)
        }
        presentAsSheet(panel)
    }

    private func showTextEditPanel(for ann: Annotation) {
        guard case .text(_, let content, let fontSize, let bold, let opaque) = ann.kind else { return }
        let panel = TextInsertPanel(
            defaultColor: ann.color,
            content: content,
            fontSize: fontSize,
            bold: bold,
            opaqueBackground: opaque
        ) { [weak self] content2, size, color, bold2, opaque2 in
            guard let self else { return }
            ann.color = color
            self.canvas.updateText(annotation: ann, content: content2, fontSize: size, bold: bold2, opaque: opaque2)
        }
        presentAsSheet(panel)
    }

    // MARK: - Refresh

    private func refreshAll() {
        canvas.tab = currentTab
        canvas.style = style
        rebuildTabs()
        refreshEmptyState()
        refreshStatus()
        refreshTabs()
    }

    private func refreshTabs() {
        // Update titles without full rebuild if possible
        rebuildTabs()
    }

    private func refreshEmptyState() {
        let isEmpty = tabs.isEmpty
        emptyState.isHidden = !isEmpty
        scroll.isHidden = isEmpty
        applyShortcutHints()
    }

    private func refreshStatus(selection: CGRect? = nil) {
        if let tab = currentTab {
            let size = tab.pixelSize
            let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let logicalW = Int((size.width / scale).rounded())
            let logicalH = Int((size.height / scale).rounded())
            var text = "图片 \(Int(size.width)) × \(Int(size.height)) 像素    显示 \(logicalW) × \(logicalH) 点（1:1，不放大）"
            if let sel = selection, sel.width > 1 {
                text += "    选区 \(Int(sel.width)) × \(Int(sel.height))"
            }
            if let cid = compareTabID, let ctab = tabs.first(where: { $0.id == cid }) {
                text += "    对比中：\(ctab.displayTitle)"
            }
            statusLabel.stringValue = text
        } else {
            statusLabel.stringValue = "还没有截图"
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)

        if cmd && event.charactersIgnoringModifiers == "c" {
            copySelection()
            return
        }
        if cmd && event.charactersIgnoringModifiers == "v" {
            paste()
            return
        }
        if cmd && event.charactersIgnoringModifiers == "z" {
            if flags.contains(.shift) {
                doRedo()
            } else {
                doUndo()
            }
            return
        }
        if cmd && event.charactersIgnoringModifiers == "y" {
            doRedo()
            return
        }
        if cmd && event.charactersIgnoringModifiers == "s" {
            saveCurrentTab()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            canvas.deleteSelected()
            return
        }
        super.keyDown(with: event)
    }
}
