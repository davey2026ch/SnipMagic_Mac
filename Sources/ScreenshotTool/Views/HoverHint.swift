import AppKit

/// 悬浮气泡的内容。`title` 是主行（如「开始截图（Shift+Command+R）」），
/// `subtitle` 是可选的次要说明行。
struct HoverHintContent {
    var title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// 顶部按钮的悬浮气泡：鼠标停住约 0.35 秒后在按钮下方弹出一个小气泡。
///
/// 几个刻意的设计：
/// - **文本在弹出那一刻才现算**（`textProvider` 闭包）—— 用户去设置里改了快捷键，
///   回来再悬浮就是新的，不需要额外的"刷新按钮"钩子；
/// - 同一时刻只允许一个气泡存在，切到别的按钮时先藏旧的、再重新计时；
/// - 用 `NSVisualEffectView(.toolTip)` 画，亮暗主题都自动跟系统气泡一个观感。
final class HoverHint: NSObject {
    /// 停留多久才弹出。0.35s 是需求给的值：比系统默认提示（约 1.5s）快得多，
    /// 又不至于扫过按钮就闪一下。
    static let showDelay: TimeInterval = 0.35


    /// 当前已经弹出来的那个（切按钮时先把它收掉）。
    private static weak var visible: HoverHint?

    private let textProvider: () -> HoverHintContent
    private weak var anchor: NSView?
    private var trackingArea: NSTrackingArea?
    private var timer: Timer?
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var frameObserver: NSKeyValueObservation?

    init(anchor: NSView, text: @escaping () -> HoverHintContent) {
        self.anchor = anchor
        self.textProvider = text
        super.init()
    }

    deinit {
        timer?.invalidate()
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    // MARK: - 装到视图上

    /// 装上气泡的监听。返回的对象会被视图持有（关联对象），不用自己存。
    ///
    /// 注意：TrackingArea 必须等视图**进了窗口**才装得上 —— 这里先装一次兜底，
    /// 真正的时机是 `CapturePrimaryButton.viewDidMoveToWindow()` 里再调一次
    /// `attachTracking()`。
    @discardableResult
    static func install(on view: NSView, text: @escaping () -> HoverHintContent) -> HoverHint {
        let hint = HoverHint(anchor: view, text: text)
        objc_setAssociatedObject(view, &hoverHintAssociatedKey, hint, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // 布局把按钮撑到真实尺寸时（frame 变化）重装一次 —— 光靠 viewDidMoveToWindow
        // 拿到的还是 (0,0,0,0)。
        hint.frameObserver = view.observe(\.frame, options: [.new]) { [weak hint] _, _ in
            hint?.attachTracking()
        }
        (view as? CapturePrimaryButton)?.hoverHint = hint
        hint.attachTracking()
        return hint
    }

    /// 视图进窗口（或几何变化）后重新挂一次追踪区。
    /// 防重入：KVO / layout 回调里都可能调进来。
    private var isAttachingTracking = false
    func attachTracking() {
        guard !isAttachingTracking else { return }
        isAttachingTracking = true
        defer { isAttachingTracking = false }
        installTrackingArea()
    }

    /// 装上（或重装）追踪区。
    ///
    /// ⚠️ 两个坑都踩过，别改回去：
    /// 1. **必须在视图有真实 bounds 之后再装**。`viewDidMoveToWindow` 触发时 Auto Layout
    ///    还没跑，按钮的 bounds 是 `(0,0,0,0)`；拿这个装出来的追踪区永远不派事件
    ///    （连 `.inVisibleRect` 也救不回来），表现就是"悬浮没反应"。
    /// 2. **owner 用视图自己**（NSResponder），事件到了再转交给 HoverHint —— 比让
    ///    一个裸 NSObject 当 owner 稳妥。
    private func installTrackingArea() {
        guard let anchor else { return }
        if let trackingArea {
            anchor.removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let rect = anchor.bounds
        guard rect.width > 1, rect.height > 1 else {
            return
        }
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: anchor,
            userInfo: nil
        )
        anchor.addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - 鼠标进出（NSTrackingArea 的 owner 就是本对象）

    @objc func mouseEntered(with event: NSEvent) {
        scheduleShow()
    }

    @objc func mouseExited(with event: NSEvent) {
        cancelTimer()
        hide()
    }

    private func scheduleShow() {
        cancelTimer()
        // 换到别的按钮时：先把上一个气泡收掉，再重新计时，避免两个气泡同时挂着。
        if let current = HoverHint.visible, current !== self { current.hide() }
        // 用 .common 模式：拖窗口 / 拖滚动条时鼠标也没在动，但计时不该被卡住。
        let t = Timer(timeInterval: Self.showDelay, repeats: false) { [weak self] _ in
            self?.show()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 显示 / 隐藏

    private func show() {
        // 窗口不是 key（应用不在前台）就不弹 —— 跟系统提示气泡的脾气一致。
        guard let anchor, let window = anchor.window, window.isKeyWindow else { return }
        HoverHint.visible?.hide()

        let content = textProvider()
        let panel = makePanel(for: content)
        let size = panel.frame.size

        // 贴在按钮正下方居中；超出屏幕工作区就往回收。
        let rectInWindow = anchor.convert(anchor.bounds, to: nil)
        let onScreen = window.convertToScreen(rectInWindow)
        var origin = NSPoint(
            x: onScreen.midX - size.width / 2,
            y: onScreen.minY - size.height - 6
        )
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)

        self.panel = panel
        HoverHint.visible = self
        installDismissWatches()
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        removeDismissWatches()
        if HoverHint.visible === self { HoverHint.visible = nil }
    }

    // MARK: - 兜底收起

    /// 点一下按钮就离开了（气泡不一定收到 mouseExited），窗口失焦同理 ——
    /// 这两种情况下气泡必须立刻收掉，不然会飘在别的界面上。
    private func installDismissWatches() {
        removeDismissWatches()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.hide()
            return event
        }
        if let window = anchor?.window {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.hide()
            }
        }
    }

    private func removeDismissWatches() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
    }

    private func makePanel(for content: HoverHintContent) -> NSPanel {
        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let subtitle = content.subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(sub)
        }

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -9)
        ])

        effect.layoutSubtreeIfNeeded()
        let size = effect.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true          // 气泡不能让鼠标"穿透不过去"
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = effect
        return panel
    }
}

/// 关联对象的稳定地址（file 级 `var`，避免 `static var` 的 inout 麻烦）。
private var hoverHintAssociatedKey: UInt8 = 0
