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
    /// 页签条：手动布局（要算横向滚动量），裁剪容器 + 承载 chips 的视图 + 自绘细滚动条。
    private let tabClip = TabClipView()
    private let tabStripView = FlippedView()
    private let tabScrollBar = HScrollBar()
    private var tabScrollOffset: CGFloat = 0
    private var tabContentWidth: CGFloat = 0
    private var isLayingOutTabs = false
    private let statusLabel = NSTextField(labelWithString: "还没有截图")
    private let hintLabel = NSTextField(labelWithString: "")
    private let scroll = ZoomableScrollView()
    private let canvas = CanvasView()
    private let emptyState = NSView()
    /// 动图页签的播放页（画布整块交给它）。
    private let gifHost = GifPlayerView()
    /// 正在「编辑本帧」：此时画布搬进播放页的预览区，标注写回当前帧。
    private var gifEditing = false
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
    /// 主题变更通知的监听令牌。
    private var themeObserver: NSObjectProtocol?
    /// buildLayout 完成后才允许重新套用主题配色（避免过早访问 lazy 视图）。
    private var layoutBuilt = false
    /// 防重入：applyThemeColors 内部会重建页签，可能再次触发 appearance 回调。
    private var isApplyingTheme = false

    private var toolButtons: [ToolKind: ToolButton] = [:]
    /// 被「锁定」的工具（右下角带小锁）：双击锁定后连续绘制，不必每笔点一次按钮。
    private var lockedTools: Set<ToolKind> = []
    private var keyMonitor: Any?
    private var extractContentBtn = NSButton()
    private var magicEraseBtn = NSButton()
    private var extractVectorBtn = NSButton()
    private var isOCRRunning = false
    private var isMagicErasing = false
    private var isExtractingSubject = false
    /// 「提取矢量图」正在跑的请求，点「取消」时用它掐掉。
    private var mattingCancel: MediaKitClient.CancelToken?
    /// 耗时操作的浮层：转圈的 spinner + 可随时改的副标题。
    private var busyPanel: NSPanel?
    private var busySpinner: NSProgressIndicator?
    private var busyStageLabel: NSTextField?
    /// 浮层上「取消」按钮的动作，没有就说明这个操作不可取消（按钮不显示）。
    private var busyCancelHandler: (() -> Void)?
    private var ocrProgressIndicator: NSProgressIndicator?
    private var ocrProgressPanel: NSPanel?
    private var ocrStageLabel: NSTextField?
    private var extractTask: MinerUExtractTask?

    var onCaptureRequest: (() -> Void)?
    var onLongCaptureRequest: (() -> Void)?
    var onGifRecordRequest: (() -> Void)?

    private var currentTab: EditorTab? {
        guard let i = currentIndex, i >= 0, i < tabs.count else { return nil }
        return tabs[i]
    }

    override func loadView() {
        // AppearanceAwareView: 系统亮/暗切换（主题=跟随系统时）也要重新取色。
        let root = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.onAppearanceChange = { [weak self] in self?.applyThemeColors() }
        view = root
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.windowBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 启动时读取 ~/.SnipMagic.ini 中的马赛克密度、线条粗细、擦除刷粗细
        let persisted = MinerUOCRService.loadConfig()
        style.mosaicCell = persisted.mosaic
        style.lineWidth = persisted.thickness
        canvas.eraseBrushDiameter = persisted.eraseBrush
        buildLayout()
        bindCanvas()
        refreshEmptyState()
        applyShortcutHints()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .appThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyThemeColors()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard layoutBuilt, !isLayingOutTabs else { return }
        isLayingOutTabs = true
        clampTabScroll()
        isLayingOutTabs = false
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Theme

    /// 重新套用主题配色。`.cgColor` 是取值瞬间的快照，切换主题（或系统亮/暗切换）
    /// 后必须重取一次，否则自绘的 layer 背景会停留在旧配色。
    /// 幂等：可被通知与 viewDidChangeEffectiveAppearance 同时触发。
    func applyThemeColors() {
        guard isViewLoaded, layoutBuilt, !isApplyingTheme else { return }
        isApplyingTheme = true
        defer { isApplyingTheme = false }
        view.layer?.backgroundColor = Theme.windowBackground.cgColor
        toolbar.layer?.backgroundColor = Theme.toolbarBackground.cgColor
        bodyContainer.layer?.backgroundColor = Theme.windowBackground.cgColor
        sidebar.layer?.backgroundColor = Theme.sidebarBackground.cgColor
        tabContainer.layer?.backgroundColor = Theme.toolbarBackground.cgColor
        statusContainer.layer?.backgroundColor = Theme.windowBackground.cgColor
        scroll.backgroundColor = Theme.canvasBackground
        compareScroll.backgroundColor = Theme.canvasBackground
        compareDivider.layer?.backgroundColor = Theme.resolved(NSColor.separatorColor)
        compareHint.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        compareHint.layer?.borderColor = Theme.accent.withAlphaComponent(0.55).cgColor
        rebuildTabs()   // 页签 chip 的底色也需要按新主题重取
        refreshToolButtons()   // 侧栏激活态是自绘蓝底，同样要按新主题重取
        gifHost.applyTheme()
        canvas.needsDisplay = true
        view.needsDisplay = true
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
            // 动图页签的 ←/→/空格/Home/End 在窗口层统一拦（不依赖画布焦点，
            // 否则点了页签之后快捷键会失效）。
            if self.currentTab?.isGIF == true, !self.gifEditing, self.gifHost.handleKey(event) {
                return nil
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
            // 擦除刷粗细：按 [ 变细、] 变粗。只在擦除刷激活时接管，避免影响别的输入。
            if self.canvas.eraseBrushActive, !cmd, let key = event.charactersIgnoringModifiers {
                if key == "[" { self.adjustEraseBrush(delta: -8); return nil }
                if key == "]" { self.adjustEraseBrush(delta: 8); return nil }
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

        layoutBuilt = true
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
        // 顶部这两个按钮改用自绘悬浮气泡（停留 0.35s）显示**当前**快捷键：
        // 内容在弹出那一刻才现算，所以去设置里改完快捷键，回来悬浮就是新的。
        // 其余按钮保持原有 toolTip 或干脆没有 —— 它们的中文名已经说明白了自己。
        HoverHint.install(on: captureBtn) {
            HoverHintContent("开始截图（\(HotkeyService.shared.displayString)）")
        }
        HoverHint.install(on: longCaptureBtn) {
            HoverHintContent(
                "长截图（\(HotkeyService.shared.longDisplayString)）",
                subtitle: "框选区域后滚动页面（网页/文档），自动拼接为长图"
            )
        }

        let mosaicBtn = makeToolButton("▦ 马赛克", action: #selector(applyMosaic))
        // GIF 录制：与「开始截图 / 长截图」同样是蓝底白字的主操作，
        // 宽度对齐「马赛克」（Windows 版是 66pt 定宽，这里用等宽约束达到同样效果）。
        let gifBtn = makePrimaryButton("GIF", icon: "record.circle", action: #selector(startGifRecord))
        gifBtn.toolTip = "GIF 录制（框选区域录制成动图，停止后生成可播放的动图页签）"
        // 下面这三个 AI 按钮**按用户指定顺序排**：提取内容 → 提取矢量图 → 魔法消除
        // （"先取文字、再抠图、最后擦除"的使用节奏）。要改顺序先问一句，别随手调。
        extractContentBtn = makeToolButton("📋 提取内容", action: #selector(extractContentClicked))
        extractContentBtn.toolTip = """
        OCR 识别文字 / 表格，结果以 Markdown 返回并自动复制。
        识别范围：①有浮动图层被激活选中 → 只识别那一块；②框了选区 → 只识别框内；
        ③两样都没有 → 识别整张图。
        """
        extractVectorBtn = makeToolButton(
            "提取矢量图",
            customIcon: ExtractSubjectIcon.toolbarImage(),
            action: #selector(extractVectorClicked)
        )
        extractVectorBtn.toolTip = """
        框选主体，或用「框选」点中一个浮动图层（那一块就处于激活选中态），再点这里：
        由火山引擎抠图，把主体从背景里抠出来，落成一个透明底图层放回画布 ——
        可拖动、可缩放，⌘C 复制到微信 / Keynote / Word 也保留透明。
        抠的就是你选中的这一块：选中浮动图层时只用图层自身的像素，不含它下面那一层。
        图片会上传到火山引擎；选区别贴太紧，留一圈背景更好认。
        """
        magicEraseBtn = makeToolButton("🪄 魔法消除", action: #selector(magicEraseClicked))
        magicEraseBtn.toolTip = "用「擦除刷」刷出要抹掉的部分，或直接用「框选」框一块，再点这里：由火山引擎的图像修复模型重建背景（纹理还原好，图片会上传到火山引擎）"
        let settingsBtn = makeToolButton("⚙️ 设置", action: #selector(showSettingsPanel))
        let saveAllBtn = makeToolButton("💾 全部保存", action: #selector(saveAllTabs))
        saveAllBtn.toolTip = "全部保存：自动在「下载」里建「截图大师_年月日时分」文件夹，动图页签存 .gif、其余存 .png（不弹选择框；单张保存用 ⌘S）"
        let undoBtn = makeToolButton("↶ 撤销", action: #selector(doUndo))
        let redoBtn = makeToolButton("↷ 重做", action: #selector(doRedo))

        // 数组顺序 = 界面上从左到右的顺序，调 UI 排序改这一行即可。
        for b in [captureBtn, longCaptureBtn, gifBtn, mosaicBtn, extractContentBtn, extractVectorBtn, magicEraseBtn, settingsBtn, saveAllBtn, undoBtn, redoBtn] {
            stack.addArrangedSubview(b)
        }
        // 「GIF」宽度与「马赛克」完全一致 —— 必须等两个按钮都进了同一个视图层级
        // 才能激活这条约束（否则没有共同祖先，激活即抛异常）。
        gifBtn.widthAnchor.constraint(equalTo: mosaicBtn.widthAnchor).isActive = true

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
            .select, .eraseBrush, .view, .text, .arrow, .line, .pen,
            .rect, .roundedRect, .ellipse,
            .solidRect, .solidRoundedRect, .solidEllipse,
            .number
        ]
        for tool in tools {
            let btn = ToolButton(tool: tool, target: self, action: #selector(toolClicked(_:)))
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 36).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            sideStack.addArrangedSubview(btn)
            toolButtons[tool] = btn
        }
        refreshToolButtons()
        refreshEraseBrushToolTip()

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
        compareDivider.layer?.backgroundColor = Theme.resolved(NSColor.separatorColor)
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

        // GIF 播放页：与画布同区域，切到动图页签时显示、普通页签时隐藏。
        gifHost.translatesAutoresizingMaskIntoConstraints = false
        gifHost.isHidden = true
        bodyContainer.addSubview(gifHost)
        gifHost.onUpdate = { [weak self] in self?.refreshStatus() }
        gifHost.onSaveFrame = { [weak self] in self?.saveCurrentGifFrame() }
        gifHost.onSaveFrameAsTab = { [weak self] in self?.promoteGifFrameToTab() }
        gifHost.onSaveGIF = { [weak self] in self?.saveCurrentGif() }
        gifHost.onToggleEdit = { [weak self] in self?.toggleGifFrameEdit() }
        gifHost.willChangeFrame = { [weak self] in self?.syncGifFrameAnnotations() }
        gifHost.didChangeFrame = { [weak self] in
            guard let self, self.gifEditing, let tab = self.currentTab else { return }
            self.loadCurrentFrameIntoCanvas(tab)
        }
        gifHost.onDeleteScope = { [weak self] scope in self?.deleteGifFrames(scope) }

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

            gifHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            gifHost.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            gifHost.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            gifHost.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

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
        guard !current.isGIF, !tabs[tabIndex].isGIF else {
            flashStatus("动图页签不支持左右对比（可先「存为页签」再对比）")
            return
        }
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

        // 裁剪容器：页签超出宽度时靠它把多出来的部分切掉，滚动只是移动里面那层。
        tabClip.wantsLayer = true
        tabClip.layer?.masksToBounds = true
        tabClip.translatesAutoresizingMaskIntoConstraints = false
        tabClip.onScrollWheel = { [weak self] event in
            guard let self else { return }
            var delta = event.scrollingDeltaX
            if delta == 0 { delta = event.scrollingDeltaY }
            if !event.hasPreciseScrollingDeltas { delta *= 40 }
            self.tabScrollOffset -= delta
            self.clampTabScroll()
        }
        tabContainer.addSubview(tabClip)
        NSLayoutConstraint.activate([
            tabClip.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tabClip.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tabClip.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tabClip.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor)
        ])
        tabClip.addSubview(tabStripView)
        tabStripView.frame = NSRect(x: 0, y: 0, width: 0, height: 44)

        // 溢出时才出现的细滚动条：贴在 28pt 高的 chip 下沿、发丝线上方那一条。
        tabScrollBar.translatesAutoresizingMaskIntoConstraints = false
        tabScrollBar.isHidden = true
        tabContainer.addSubview(tabScrollBar)
        NSLayoutConstraint.activate([
            tabScrollBar.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor, constant: 8),
            tabScrollBar.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor, constant: -8),
            tabScrollBar.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor, constant: -1),
            tabScrollBar.heightAnchor.constraint(equalToConstant: 7)
        ])
        tabScrollBar.onChange = { [weak self] offset in
            guard let self else { return }
            self.tabScrollOffset = offset
            self.tabStripView.frame.origin = NSPoint(x: -offset, y: 0)
        }

        // Hairline under the strip — tabs visually "root" into it.
        let hairline = NSView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.resolved(NSColor.separatorColor.withAlphaComponent(0.5))
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
        hintLabel.stringValue = "截图不含鼠标箭头 / 鼠标手势"
        stack.addArrangedSubview(hintLabel)
    }

    /// 工具栏的次要按钮。大多数用 emoji 当图标（写在标题里）；
    /// 需要"正经"图标时二选一：
    /// - `icon` 传 SF Symbol 名（注意 macOS 里没有 `stamp` 这个符号，别写不存在的名字）；
    /// - `customIcon` 传自绘 / 内嵌位图，比如 `ExtractSubjectIcon`（提取矢量图的图标）。
    private func makeToolButton(
        _ title: String,
        icon: String? = nil,
        customIcon: NSImage? = nil,
        action: Selector
    ) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 13)
        let symbol = icon.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        }
        if let image = customIcon ?? symbol {
            b.image = image
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
        }
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
            guard let self else { return }
            // 画完一笔，画布请求退回「框选」；但工具要是被锁定了就别退
            // —— 那正是"连着画好几个"的意思（Office 里锁定的格式刷一个道理）。
            if tool == .select, self.isCurrentToolLocked { return }
            // Auto-switch after draw/paste keeps the new object selected.
            self.selectedTool(tool, preserveSelection: true)
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

    /// GIF 录制结束后生成新动图页签。调用方负责随后把主窗口叫回前台
    /// （先建页签、再显示窗口，避免主界面先闪一下空白）。
    func addGifTab(_ anim: GifAnimation) {
        guard let first = anim.rawImage(at: 0) else { return }
        let tab = EditorTab(sequence: nextSequence, image: first)
        tab.gif = anim
        tab.gifFrame = 0
        nextSequence += 1
        tabs.append(tab)
        undoByTab[tab.id] = UndoStack()
        currentIndex = tabs.count - 1
        canvas.tab = nil
        selectedTool(.select)
        refreshAll()
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        finishGifEditingIfNeeded()
        currentIndex = index
        // 动图页签不参与标注编辑：画布整块交给播放页。
        canvas.tab = tabs[index].isGIF ? nil : tabs[index]
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

    @objc private func startGifRecord() {
        onGifRecordRequest?()
    }

    private func requestCloseTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        finishGifEditingIfNeeded()
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
        tabStripView.subviews.forEach { $0.removeFromSuperview() }

        var x: CGFloat = 8
        var activeFrame: CGRect = .zero
        for (i, tab) in tabs.enumerated() {
            let active = i == currentIndex
            let width = TabChipView.width(for: tab.displayTitle, active: active)
            let chip = makeTabChip(
                title: tab.displayTitle,
                index: i,
                active: active,
                comparing: tab.id == compareTabID
            )
            chip.frame = NSRect(x: x, y: 8, width: width, height: 28)
            tabStripView.addSubview(chip)
            if active { activeFrame = chip.frame }
            x += width
        }
        tabContentWidth = x + 8

        let clipHeight = tabClip.bounds.height > 0 ? tabClip.bounds.height : 44
        tabStripView.frame = NSRect(x: -tabScrollOffset, y: 0,
                                    width: max(tabContentWidth, tabClip.bounds.width),
                                    height: clipHeight)
        // 激活页签自动滚进可视区（最小移动，不做居中对齐）。
        revealActiveTab(activeFrame)
    }

    /// 把激活页签"最小位移"地滚进可视区。
    private func revealActiveTab(_ frame: CGRect) {
        let visible = tabClip.bounds.width
        guard visible > 1, tabs.count > 0 else { return }
        if frame.minX < tabScrollOffset {
            tabScrollOffset = frame.minX - 8
        } else if frame.maxX > tabScrollOffset + visible {
            tabScrollOffset = frame.maxX - visible + 8
        }
        clampTabScroll()
    }

    /// 夹住滚动量，并同步滚动条与页签层的位置。
    /// 窗口变宽、溢出量变小时，这一夹保证页签不会"飘"在中间。
    private func clampTabScroll() {
        let visible = tabClip.bounds.width
        let maxOffset = max(0, tabContentWidth - visible)
        tabScrollOffset = min(max(0, tabScrollOffset), maxOffset)
        if tabStripView.frame.origin.x != -tabScrollOffset {
            tabStripView.frame.origin = NSPoint(x: -tabScrollOffset, y: 0)
        }
        tabScrollBar.contentWidth = tabContentWidth
        tabScrollBar.visibleWidth = visible
        tabScrollBar.setOffset(tabScrollOffset)
        tabScrollBar.isHidden = !tabScrollBar.isNeeded
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

    /// 侧栏按钮三种点法，别搞混：
    /// - **单击可锁定的工具** → 普通激活（画一笔就自动回到「框选」）；
    /// - **双击可锁定的工具** → 锁定（右下角出现小锁），之后连续绘制不再自动退出；
    /// - **单击已锁定的工具** → 解除锁定并回到「框选」（明确"取消"语义，也不会误画一笔）。
    @objc private func toolClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let tool = ToolKind(rawValue: id) else { return }
        handleToolClick(tool, clickCount: NSApp.currentEvent?.clickCount ?? 1)
    }

    /// 点按钮的实际逻辑。与事件对象解耦（`clickCount` 直接传进来），
    /// 这样离屏验证时不用合成真实双击事件也能测到分支。
    func handleToolClick(_ tool: ToolKind, clickCount: Int) {
        if tool.supportsLock {
            if clickCount >= 2 {
                lockedTools.insert(tool)
                selectedTool(tool)
                flashStatus("已锁定「\(tool.displayName)」：可连续画，单击该按钮解除锁定")
                return
            }
            if lockedTools.contains(tool) {
                lockedTools.remove(tool)
                selectedTool(.select)
                flashStatus("已解除「\(tool.displayName)」锁定")
                return
            }
        }
        selectedTool(tool)
    }

    /// 当前工具是否处于锁定（连续绘制）状态。
    private var isCurrentToolLocked: Bool {
        style.tool.supportsLock && lockedTools.contains(style.tool)
    }

    /// 把「当前工具 + 锁定状态」同步到侧栏按钮（蓝底激活态 / 右下角小锁）。
    /// 主题切换后也要重来一次 —— layer 背景色是取值瞬间的快照。
    private func refreshToolButtons() {
        for (tool, button) in toolButtons {
            button.isActiveTool = (tool == style.tool)
            button.isLocked = lockedTools.contains(tool)
        }
    }

    func selectedTool(_ tool: ToolKind, preserveSelection: Bool = false) {
        // 动图页签：一选绘图工具就自动进入「编辑本帧」——
        // 用户的理解是"这一帧就是一张静态图，直接画就行"，不该还要先点一次按钮。
        if currentTab?.isGIF == true, !gifEditing,
           tool != .select, tool != .view, tool != .eraseBrush {
            beginGifFrameEdit()
        }
        style.tool = tool
        canvas.style = style
        // 擦除刷不画图形 —— 它刷出「要抹掉的区域」，画布据此切换事件行为。
        canvas.eraseBrushActive = (tool == .eraseBrush)
        refreshEraseBrushToolTip()
        refreshToolButtons()
        // 「查看」= 定版：进这个模式就把画布上的浮动元素烙进底图
        // （先压快照再烘焙，所以 ⌘Z 能把整套浮动元素还回来）。
        let didFlatten = (tool == .view) ? canvas.flattenEditsForViewMode() : false
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
        if didFlatten {
            flashStatus("已定版：浮动图层与标注已烙进画面（⌘Z 可退回）")
        }
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
        toolButtons[.number]?.toolTip = "序号（当前 \(AnnotationRenderer.numberString(value))）：单击盖一个编号，自动回到「框选」"
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
            promptForSelection("用「框选」工具在图上拖一个框，再点「马赛克」打码。")
        }
    }

    // MARK: - 魔法消除（火山引擎 AI MediaKit 云端擦除重建）

    @objc private func magicEraseClicked() {
        guard !isMagicErasing else { return }

        let apiKey = MinerUOCRService.loadConfig().volcKey ?? ""
        guard !apiKey.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "还没配置火山引擎 API Key"
            alert.informativeText = """
            「魔法消除」把擦除与重建交给火山引擎的图像修复模型，需要先在「设置」里填入 AI MediaKit 的 API Key（在 console.volcengine.com/imp/ai-mediakit/settings 创建）。填一次即可长期使用。
            """
            alert.addButton(withTitle: "去设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                showSettingsPanel()
            }
            return
        }

        let hasStrokes = canvas.hasEraseStrokes
        let hasSelection = canvas.selectionRect.width > 2 && canvas.selectionRect.height > 2
        guard hasStrokes || hasSelection else {
            let alert = NSAlert()
            alert.messageText = "请先指定要擦掉的区域"
            alert.informativeText = """
            两种方式任选：
            · 用侧栏的「擦除刷」在图上刷出要抹掉的部分（形状自由）
            · 或者用「框选」工具拖一个矩形框
            """
            alert.runModal()
            return
        }

        isMagicErasing = true
        magicEraseBtn.isEnabled = false
        showBusyPanel(title: "正在云端重建…",
                      subtitle: hasStrokes ? "准备上传擦除范围…" : "准备上传选区…")

        canvas.applyCloudEraseToSelection(
            apiKey: apiKey,
            onStage: { [weak self] stage in
                self?.busyStageLabel?.stringValue = stage
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isMagicErasing = false
                self.magicEraseBtn.isEnabled = true
                self.hideBusyPanel()

                if self.style.tool != .select {
                    self.selectedTool(.select, preserveSelection: true)
                }

                switch result {
                case .success(let summary):
                    self.flashStatus("🪄 \(summary)")
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "云端擦除失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        )
    }

    // MARK: - 提取矢量图（火山引擎 AI MediaKit 云端抠图）

    @objc private func extractVectorClicked() {
        guard !isExtractingSubject else { return }

        guard currentTab != nil else {
            let alert = NSAlert()
            alert.messageText = "还没有截图"
            alert.informativeText = "先截一张图，框选要抠出的主体，再点「提取矢量图」。"
            alert.runModal()
            return
        }

        let apiKey = MinerUOCRService.loadConfig().volcKey ?? ""
        guard !apiKey.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "还没配置火山引擎 API Key"
            alert.informativeText = """
            「提取矢量图」把抠图交给火山引擎的云端模型，需要先在「设置」里填入 AI MediaKit 的 API Key（在 console.volcengine.com/imp/ai-mediakit/settings 创建）。这把 Key 与「魔法消除」是同一把，填一次即可长期使用。
            """
            alert.addButton(withTitle: "去设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                showSettingsPanel()
            }
            return
        }

        // 前置校验：没有选区 / 选区太小，都在弹进度浮窗之前拦下来（别让用户白等一场）。
        guard let region = canvas.subjectRegion() else {
            let alert = NSAlert()
            alert.messageText = "请先框选要抠出的主体"
            alert.informativeText = """
            两种方式任选：
            · 用「框选」工具在图上拖一个框，把主体连同一圈背景一起框进来
            · 或者用「框选」点中一个浮动图层（粘贴块 / 已抠出的主体），再点这里
            有浮动图层处于激活选中态时，就只处理那一块 —— 不会带上它下面那一层。
            """
            alert.runModal()
            return
        }
        do {
            try VolcMattingService.validate(region: region)
        } catch {
            let alert = NSAlert()
            alert.messageText = "选区太小了"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }

        let cancel = MediaKitClient.CancelToken()
        mattingCancel = cancel
        isExtractingSubject = true
        extractVectorBtn.isEnabled = false
        showBusyPanel(title: "正在抠出主体…", subtitle: "准备上传选区…") { [weak self] in
            self?.mattingCancel?.cancel()
            self?.busyStageLabel?.stringValue = "正在取消…"
        }

        canvas.extractSubjectFromSelection(
            apiKey: apiKey,
            cancel: cancel,
            onStage: { [weak self] stage in
                self?.busyStageLabel?.stringValue = stage
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isExtractingSubject = false
                self.mattingCancel = nil
                self.extractVectorBtn.isEnabled = true
                self.hideBusyPanel()

                if self.style.tool != .select {
                    self.selectedTool(.select, preserveSelection: true)
                }

                switch result {
                case .success(let summary):
                    self.flashStatus("✂️ \(summary)")
                case .failure(let error):
                    if let mediaError = error as? MediaKitClient.Error, case .cancelled = mediaError {
                        self.flashStatus("已取消，未改动图片")
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "提取矢量图失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        )
    }

    /// 擦除刷的提示里带上当前笔刷大小，顺手说明怎么调。
    /// 特意强调「涂满」—— 遮罩没盖到的笔画会被云端当成背景留下来。
    private func refreshEraseBrushToolTip() {
        let width = Int(canvas.eraseBrushDiameter)
        toolButtons[.eraseBrush]?.toolTip = """
        \(ToolKind.eraseBrush.displayName)
        在图上按住拖动即可刷出要抹掉的区域，然后点工具栏的「魔法消除」。
        当前刷子 \(width) px：按 [ 变细，按 ] 变粗；右键可清空重刷。
        默认粗细在「设置」→「刷子粗细」里改。记得盖满目标 —— 没盖到的部分会被当作背景保留。
        """
    }

    /// 调整擦除刷粗细（快捷键 [ 与 ]），步进 8 px。
    private func adjustEraseBrush(delta: CGFloat) {
        let next = min(max(canvas.eraseBrushDiameter + delta, 4), 240)
        guard next != canvas.eraseBrushDiameter else { return }
        canvas.eraseBrushDiameter = next
        refreshEraseBrushToolTip()
        flashStatus("刷子粗细：\(Int(next)) px")
    }

    /// 框选类操作（马赛克 / 魔法消除）缺选区时的统一提示。
    private func promptForSelection(_ hint: String) {
        let alert = NSAlert()
        alert.messageText = "请先框选区域"
        alert.informativeText = hint
        alert.runModal()
    }

    // MARK: - 耗时操作的浮层（魔法消除 / 提取矢量图走云端时盖住画布）

    /// 弹一个带转圈的小浮层，返回副标题 label 供随时改阶段文案。
    /// 传了 `onCancel` 就多一个「取消」按钮 —— 只有能真正掐断链路的操作才给这个按钮。
    @discardableResult
    private func showBusyPanel(
        title: String,
        subtitle: String,
        onCancel: (() -> Void)? = nil
    ) -> NSTextField {
        hideBusyPanel()

        let size = NSSize(width: 320, height: onCancel == nil ? 132 : 168)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = container

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
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
        busySpinner = spinner

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.alignment = .center
        stack.addArrangedSubview(heading)

        let stage = NSTextField(labelWithString: subtitle)
        stage.font = .systemFont(ofSize: 11)
        stage.textColor = .secondaryLabelColor
        stage.alignment = .center
        stage.lineBreakMode = .byWordWrapping
        stage.maximumNumberOfLines = 3
        stage.preferredMaxLayoutWidth = 270
        stack.addArrangedSubview(stage)
        busyStageLabel = stage

        if let onCancel {
            busyCancelHandler = onCancel
            let cancelButton = NSButton(title: "取消", target: self, action: #selector(busyCancelClicked(_:)))
            cancelButton.bezelStyle = .rounded
            cancelButton.controlSize = .small
            cancelButton.toolTip = "中止这次云端处理（不会扣费，也不会改动图片）"
            stack.addArrangedSubview(cancelButton)
        }

        if let screen = view.window?.screen ?? NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.midY - frame.height / 2 + 40
            ))
        }
        panel.orderFrontRegardless()
        busyPanel = panel
        return stage
    }

    /// 点「取消」后先禁用按钮（避免连点），再交给操作自己的取消动作。
    @objc private func busyCancelClicked(_ sender: NSButton) {
        sender.isEnabled = false
        busyCancelHandler?()
    }

    private func hideBusyPanel() {
        busySpinner?.stopAnimation(nil)
        busySpinner = nil
        busyStageLabel = nil
        busyCancelHandler = nil
        busyPanel?.orderOut(nil)
        busyPanel = nil
    }

    // MARK: - 内容提取（MinerU：轻量解析优先，失败降级精准解析 vlm）

    @objc private func extractContentClicked() {
        guard !isOCRRunning else { return }
        guard currentTab != nil else {
            let a = NSAlert()
            a.messageText = "还没有截图"
            a.informativeText = "先截一张图，再使用「提取内容」。"
            a.runModal()
            return
        }

        // 取图优先级都收在画布侧：激活选中的浮动图层 → 橡皮筋选区 → 整张图。
        guard let source = canvas.contentExtractionImage() else {
            let a = NSAlert()
            a.messageText = "无法导出图片"
            a.informativeText = "请重试，或先保存当前截图。"
            a.runModal()
            return
        }
        guard let png = MinerUOCRService.encodePNG(source.image) else {
            let a = NSAlert()
            a.messageText = "无法导出图片"
            a.informativeText = "请重试，或先保存当前截图。"
            a.runModal()
            return
        }

        isOCRRunning = true
        extractContentBtn.isEnabled = false
        showOCRProgress(source: source.scope)

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
                        // 「超时时间 = 0」是"跳过轻量、直接用精准"，这时说"轻量解析失败后
                        // 需使用精准解析"就不对了 —— 按配置文件里的实际设置给不同措辞。
                        let reason = MinerUOCRService.AgentTimeout.skipsAgent(
                            MinerUOCRService.loadConfig().agentTimeout
                        )
                            ? "「超时时间」设为 0，已跳过轻量解析、直接使用精准解析（vlm），但 Token"
                            : "轻量解析失败后需使用精准解析（vlm），但 Token"
                        a.informativeText = """
                        \(reason) \(tokenIssue.localizedDescription)。

                        请点工具栏「⚙️ 设置」，在「MinerU token」一栏填写或更新后重试；
                        也可以把「超时时间」调回大于 0 的值，改走免 Token 的轻量解析。
                        Token 可在 mineru.net 的「API 管理」页面创建。
                        """
                    } else {
                        a.messageText = "提取内容失败"
                        a.informativeText = error.localizedDescription
                    }
                    a.runModal()
                case .success(let outcome):
                    // 剪贴板由结果窗统一写（写的是「查看模式」的富文本 + 渲染后纯文本，
                    // 不是生 Markdown 源码），见 ExtractResultPanel.copyRenderedToPasteboard()。
                    self.presentExtractResult(markdown: outcome.markdown, images: outcome.images, mode: outcome.mode)
                }
            }
        )
    }

    @objc private func cancelExtractClicked() {
        extractTask?.cancel()
        // Completion fires with .cancelled and performs the UI cleanup.
    }

    private func showOCRProgress(source: CanvasView.ExtractionScope) {
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

        let sub = NSTextField(labelWithString: "识别\(source.label) · MinerU 轻量解析")
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
        // 侧栏工具色面板：三处入口共用同一套（固定色/最近使用/吸管都在里面了）。
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
        // 反向带出：每次打开都从 ~/.SnipMagic.ini 现读，保证界面与文件一一对应
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
            minerUTimeout: config.agentTimeout,
            theme: config.theme,
            volcKey: config.volcKey ?? "",
            eraseBrush: config.eraseBrush,
            borderCopy: config.borderCopyToExternal,
            gifFps: config.gifFps,
            cursorInScreenshot: config.cursorInScreenshot,
            cursorInGif: config.cursorInGif
        ) { [weak self] hotkey, longHotkey, mosaic, thickness, minerUToken, minerUTimeout, theme, volcKey, eraseBrush, borderCopy, gifFps, cursorShot, cursorGif in
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
            self.canvas.eraseBrushDiameter = eraseBrush
            self.canvas.style = self.style
            if self.canvas.selectedAnnotation != nil {
                self.canvas.applyCurrentStyleToSelected()
            }
            // 主题：立刻应用（整窗跟随 appearance + 自绘 layer 重新取色）
            Theme.apply(mode: theme)
            // 正向生成：把全部设置项（快捷键/马赛克/粗细/token/超时/主题/火山 key/带边框复制）写入 ~/.SnipMagic.ini
            let savedCapture = HotkeyService.shared.currentHotkey
            let savedLong = HotkeyService.shared.currentLongHotkey
            MinerUOCRService.saveConfig(
                captureHotkey: savedCapture,
                longHotkey: savedLong,
                mosaic: mosaic,
                thickness: thickness,
                token: minerUToken,
                agentTimeout: minerUTimeout,
                theme: theme,
                volcKey: volcKey,
                eraseBrush: eraseBrush,
                borderCopyToExternal: borderCopy,
                gifFps: gifFps,
                cursorInScreenshot: cursorShot,
                cursorInGif: cursorGif
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
            baseImage: tab.baseImage,
            eraseStrokes: canvas.eraseStrokes
        )
        if let prev = stack.undo(current: current) {
            tab.annotations = prev.annotations
            tab.baseImage = prev.baseImage
            canvas.selectedAnnotation = nil
            canvas.tab = tab
            // 必须放在 canvas.tab 之后：赋值本身不会再清（同一个 tab），
            // 但顺序反了会被 didSet 里的清空逻辑吃掉。
            canvas.restoreEraseStrokes(prev.eraseStrokes)
            canvas.needsDisplay = true
            refreshStatus()
            refreshTabs()
        }
    }

    @objc private func doRedo() {
        guard let tab = currentTab, let stack = undoByTab[tab.id] else { return }
        let current = EditorSnapshot(
            annotations: tab.annotations.map { $0.copyAnnotation() },
            baseImage: tab.baseImage,
            eraseStrokes: canvas.eraseStrokes
        )
        if let next = stack.redo(current: current) {
            tab.annotations = next.annotations
            tab.baseImage = next.baseImage
            canvas.selectedAnnotation = nil
            canvas.tab = tab
            canvas.restoreEraseStrokes(next.eraseStrokes)
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
        // 涂抹痕迹同理：它不改像素也不进 annotations，漏掉就成了「撤销对刷子没反应」。
        let snapshot = EditorSnapshot(
            annotations: tab.annotations.map { $0.copyAnnotation() },
            baseImage: tab.baseImage,
            eraseStrokes: canvas.eraseStrokes
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

    /// 单张保存（⌘S / 右键「保存」）。动图页签存 `.gif`，其余存 PNG/JPG。
    /// 同名文件不直接覆盖：先问「追加序号再保存 / 替换已有文件」，默认按钮是追加。
    func saveCurrentTab() {
        guard let tab = currentTab else { return }
        if let anim = tab.gif {
            saveGIF(anim: anim, suggestedName: tab.displayTitle, tab: tab)
            return
        }
        guard let image = tab.renderComposite() else { return }

        let panel = NSSavePanel()
        panel.title = "另存为"
        // Single type (PNG default) → no built-in format popup; the accessory
        // view owns the type choice and updates allowedContentTypes on change.
        panel.allowedContentTypes = [.png]
        panel.directoryURL = SaveSupport.lastSaveDirectory
        panel.nameFieldStringValue = SaveSupport.uniqueDefaultName(for: "\(tab.displayTitle).png")
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.accessoryView = makeSaveFormatAccessory().view

        panel.beginSheetModal(for: view.window!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let isJPG = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
            let flattened = ScreenCaptureService.flatten(image, fillWhite: isJPG) ?? image
            do {
                try ImageIOExporter.save(flattened, to: url, as: isJPG ? .jpeg : .png)
                SaveSupport.rememberSaveDirectory(url)
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

    // MARK: - 动图页签：编辑当前帧 / 删帧

    /// 「编辑本帧 / 完成编辑」的开关。
    private func toggleGifFrameEdit() {
        if gifEditing { endGifFrameEdit() } else { beginGifFrameEdit() }
    }

    private func beginGifFrameEdit() {
        guard !gifEditing, let tab = currentTab, tab.isGIF,
              let anim = tab.gif, anim.count > 0 else { return }
        gifEditing = true
        gifHost.setEditing(true)
        // 画布搬进播放页的预览区（缩略图条、控制条保持可用，方便逐帧编辑）
        gifHost.editScroll.documentView = canvas
        loadCurrentFrameIntoCanvas(tab)
        updateVisibility()
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(canvas)
        flashStatus("编辑第 \(min(tab.gifFrame, anim.count - 1) + 1)/\(anim.count) 帧：用侧栏工具标注，改完点「完成编辑」")
    }

    /// 把当前帧装进画布（底图用**不带标注**的原始像素，否则标注会被叠两遍）。
    private func loadCurrentFrameIntoCanvas(_ tab: EditorTab) {
        guard let anim = tab.gif, anim.count > 0 else { return }
        let index = min(max(0, tab.gifFrame), anim.count - 1)
        tab.baseImage = anim.rawImage(at: index) ?? tab.baseImage
        tab.annotations = anim.annotations(at: index)
        canvas.clearEraseStrokes()
        canvas.selectedAnnotation = nil
        canvas.clearSelection()
        canvas.style = style
        canvas.tab = tab
        // 换帧了，上一帧的撤销栈对不上号，清掉免得 ⌘Z 把别的帧还原回来。
        undoByTab[tab.id] = UndoStack()
        refreshStatus()
    }

    /// 把画布上的标注写回当前帧（切帧前、退出编辑前、保存前都要调）。
    private func syncGifFrameAnnotations() {
        guard gifEditing, let tab = currentTab, let anim = tab.gif, anim.count > 0 else { return }
        let index = min(max(0, tab.gifFrame), anim.count - 1)
        // 底图被"烘焙"过（马赛克 / 魔法消除 / 粘贴 / 定版都会换一张像素）→ 写回这一帧。
        if let raw = anim.rawImage(at: index), tab.baseImage !== raw {
            anim.replaceFrameImage(at: index, with: tab.baseImage)
        }
        anim.setAnnotations(tab.annotations, at: index)
    }

    /// 退出编辑态（不刷新界面）—— 切页签、关页签时用，避免中间态闪一下。
    private func finishGifEditingIfNeeded() {
        guard gifEditing else { return }
        syncGifFrameAnnotations()
        gifEditing = false
        canvas.tab = nil
        canvas.clearEraseStrokes()
        scroll.documentView = canvas
        gifHost.setEditing(false)
    }

    private func endGifFrameEdit() {
        guard gifEditing else { return }
        finishGifEditingIfNeeded()
        refreshAll()
        flashStatus("已完成编辑：标注已记到这一帧，保存 GIF 时会自动带上")
    }

    /// 缩略图右键：删除当前帧 / 左侧全部 / 右侧全部。前两种不可恢复，删多帧先确认。
    private func deleteGifFrames(_ scope: GifDeleteScope) {
        guard let tab = currentTab, let anim = tab.gif, anim.count > 1 else { return }
        let index = min(max(0, tab.gifFrame), anim.count - 1)
        let count = anim.count

        switch scope {
        case .left where index > 0:
            if !confirmFrameDeletion("将删除第 1–\(index) 帧（共 \(index) 帧），只剩第 \(index + 1)–\(count) 帧。") { return }
        case .right where index < count - 1:
            let removed = count - index - 1
            if !confirmFrameDeletion("将删除第 \(index + 2)–\(count) 帧（共 \(removed) 帧），只剩第 1–\(index + 1) 帧。") { return }
        default:
            break
        }

        // 编辑中先把手上的标注写回，再删。
        if gifEditing { syncGifFrameAnnotations() }

        var newIndex = index
        switch scope {
        case .current:
            guard anim.removeFrame(at: index) else { return }
            newIndex = min(index, anim.count - 1)
        case .left:
            guard anim.removeFrames(before: index) else { return }
            newIndex = 0
        case .right:
            guard anim.removeFrames(after: index) else { return }
            newIndex = index
        }

        tab.gifFrame = newIndex
        if gifEditing {
            loadCurrentFrameIntoCanvas(tab)
        }
        gifHost.bind(tab: tab)
        updateVisibility()
        refreshStatus()
        refreshTabs()
        flashStatus("已删除帧：现在共 \(anim.count) 帧（保存 GIF 时生效）")
    }

    private func confirmFrameDeletion(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "删除这些帧？"
        alert.informativeText = message + "\n删除后无法恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 动图页签的三个保存出口

    /// 导出前把每帧的标注烘进像素。没有标注的帧原样写（省掉重新量化）。
    private static func bakedGIFData(_ anim: GifAnimation) -> Data {
        guard anim.hasAnnotations else { return GifCodec.encode(anim) }
        let baked = GifAnimation(width: anim.width, height: anim.height,
                                 frames: anim.framesForExport(), loop: anim.loop)
        return GifCodec.encode(baked)
    }

    /// 保存整个动图（`.gif`）。同名规则与单张保存一致。
    private func saveGIF(anim: GifAnimation, suggestedName: String, tab: EditorTab?) {
        syncGifFrameAnnotations()
        let panel = NSSavePanel()
        panel.title = "保存 GIF"
        panel.allowedContentTypes = [.gif]
        panel.directoryURL = SaveSupport.lastSaveDirectory
        panel.nameFieldStringValue = SaveSupport.uniqueDefaultName(for: "\(suggestedName).gif")
        panel.canCreateDirectories = true
        panel.showsTagField = false

        panel.beginSheetModal(for: view.window!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try Self.bakedGIFData(anim).write(to: url)
                SaveSupport.rememberSaveDirectory(url)
                tab?.markSaved(url: url)
                self.refreshTabs()
                self.refreshStatus()
                self.flashStatus("已保存 GIF 到 \(url.lastPathComponent)")
            } catch {
                let a = NSAlert()
                a.messageText = "保存 GIF 失败"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    /// 保存当前帧为图片，默认名 `P1_<帧号>.png`。
    func saveCurrentGifFrame() {
        syncGifFrameAnnotations()
        guard let tab = currentTab, let anim = tab.gif, anim.count > 0 else { return }
        let index = min(max(0, tab.gifFrame), anim.count - 1)
        guard let image = anim.image(at: index) else { return }

        let panel = NSSavePanel()
        panel.title = "保存当前帧"
        panel.allowedContentTypes = [.png]
        panel.directoryURL = SaveSupport.lastSaveDirectory
        panel.nameFieldStringValue = SaveSupport.uniqueDefaultName(for: "\(tab.displayTitle)_\(index).png")
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.accessoryView = makeSaveFormatAccessory().view

        panel.beginSheetModal(for: view.window!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let isJPG = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
            let out = isJPG ? (ScreenCaptureService.flatten(image, fillWhite: true) ?? image) : image
            do {
                try ImageIOExporter.save(out, to: url, as: isJPG ? .jpeg : .png)
                SaveSupport.rememberSaveDirectory(url)
                self.flashStatus("已保存第 \(index + 1) 帧")
            } catch {
                let a = NSAlert()
                a.messageText = "保存失败"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    /// 把当前帧变成一个普通图片页签（可以直接标注编辑）。
    func promoteGifFrameToTab() {
        syncGifFrameAnnotations()
        guard let tab = currentTab, let anim = tab.gif, anim.count > 0 else { return }
        let index = min(max(0, tab.gifFrame), anim.count - 1)
        guard let image = anim.image(at: index) else { return }

        let newTab = EditorTab(sequence: nextSequence, image: image)
        nextSequence += 1
        tabs.append(newTab)
        undoByTab[newTab.id] = UndoStack()
        currentIndex = tabs.count - 1
        refreshAll()
        flashStatus("已把第 \(index + 1) 帧存成新页签")
    }

    /// 保存当前动图为 GIF（"保存GIF"按钮的入口）。
    func saveCurrentGif() {
        guard let tab = currentTab, let anim = tab.gif else { return }
        saveGIF(anim: anim, suggestedName: tab.displayTitle, tab: tab)
    }

    /// 全部保存：**不弹任何选择框**，直接建 `下载/截图大师_yyyyMMddHHmm/`，
    /// 动图页签写 `.gif`、其余写 `.png`（同名自动加 `_001`）。
    @objc private func saveAllTabs() {
        syncGifFrameAnnotations()
        guard !tabs.isEmpty else {
            let a = NSAlert()
            a.messageText = "还没有截图"
            a.informativeText = "先截一张图，再使用「全部保存」。"
            a.runModal()
            return
        }

        let parent = SaveSupport.downloadsDirectory()
        guard let dir = SaveSupport.uniqueDirectory(in: parent, name: SaveSupport.timestampName()) else {
            let a = NSAlert()
            a.messageText = "无法创建保存文件夹"
            a.informativeText = "在「\(parent.path)」下建目录失败，请检查磁盘空间与权限。"
            a.runModal()
            return
        }

        var savedCount = 0
        var failedTitles: [String] = []

        for tab in tabs {
            let title = tab.displayTitle
            // 文件名按页签序号（P1、P2…，进程内递增不复用）
            let stem = "P\(tab.sequence)"
            do {
                if let anim = tab.gif {
                    let url = SaveSupport.uniqueFile(in: dir, stem: stem, ext: "gif")
                    try Self.bakedGIFData(anim).write(to: url)
                    tab.markSaved(url: url)
                } else {
                    guard let image = tab.renderComposite() else {
                        failedTitles.append(title)
                        continue
                    }
                    let url = SaveSupport.uniqueFile(in: dir, stem: stem, ext: "png")
                    try ImageIOExporter.save(image, to: url, as: .png)
                    tab.markSaved(url: url)
                }
                savedCount += 1
            } catch {
                failedTitles.append(title)
            }
        }

        refreshTabs()
        refreshStatus()

        if failedTitles.isEmpty {
            flashStatus("已保存 \(savedCount) 张到 \(dir.path)")
        } else {
            let a = NSAlert()
            a.messageText = "部分页签保存失败"
            a.informativeText = "已保存 \(savedCount)/\(tabs.count) 个到 \(dir.path)，失败：\(failedTitles.joined(separator: "、"))"
            a.runModal()
        }
    }


    // MARK: - Text panel

    private func showTextPanel(at point: CGPoint) {
        guard currentTab != nil else { return }
        // 文字颜色与侧栏工具色彼此独立：默认值用文字面板自己的记忆，
        // 确认后也不回写 style.color / colorSwatch。
        let panel = TextInsertPanel(defaultColor: TextInsertPanel.lastColor) { [weak self] content, size, color, bold, background in
            guard let self else { return }
            self.canvas.insertText(origin: point, content: content, fontSize: size, bold: bold, background: background, color: color)
        }
        presentAsSheet(panel)
    }

    private func showTextEditPanel(for ann: Annotation) {
        guard case .text(_, let content, let fontSize, let bold, let background) = ann.kind else { return }
        let panel = TextInsertPanel(
            defaultColor: ann.color,
            content: content,
            fontSize: fontSize,
            bold: bold,
            backgroundColor: background
        ) { [weak self] content2, size, color, bold2, background2 in
            guard let self else { return }
            ann.color = color
            TextInsertPanel.lastColor = color
            self.canvas.updateText(annotation: ann, content: content2, fontSize: size, bold: bold2, background: background2)
        }
        presentAsSheet(panel)
    }

    // MARK: - Refresh

    private func refreshAll() {
        let tab = currentTab
        let isGIF = tab?.isGIF == true
        if !isGIF { finishGifEditingIfNeeded() }
        canvas.tab = (isGIF && !gifEditing) ? nil : tab
        canvas.style = style
        if isGIF, let tab {
            gifHost.bind(tab: tab)
        } else {
            gifHost.unbind()
        }
        updateVisibility()
        rebuildTabs()
        refreshStatus()
        refreshTabs()
    }

    /// 谁该出现：空状态 / 动图页 / 画布。集中在这里，别处只调它。
    private func updateVisibility() {
        let isEmpty = tabs.isEmpty
        let isGIF = currentTab?.isGIF == true
        let editing = isGIF && gifEditing
        emptyState.isHidden = !isEmpty
        gifHost.isHidden = isEmpty || !isGIF
        scroll.isHidden = isEmpty || (isGIF && !editing)
        gifHost.setEditing(editing)
    }

    private func refreshTabs() {
        // Update titles without full rebuild if possible
        rebuildTabs()
    }

    private func refreshEmptyState() {
        updateVisibility()
        applyShortcutHints()
    }

    private func refreshStatus(selection: CGRect? = nil) {
        if let tab = currentTab, tab.isGIF {
            if gifEditing, let anim = tab.gif, anim.count > 0 {
                let index = min(max(0, tab.gifFrame), anim.count - 1)
                statusLabel.stringValue = "编辑第 \(index + 1)/\(anim.count) 帧 · 用侧栏工具标注 · 点「完成编辑」返回动图"
            } else {
                // 动图页签：帧号/播放状态由播放页给（`第 i/n 帧 · ←/→ 逐帧`）。
                statusLabel.stringValue = gifHost.statusText
            }
            return
        }
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

        if currentTab?.isGIF == true, !gifEditing, gifHost.handleKey(event) { return }

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
