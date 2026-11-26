import AppKit

protocol GifRecordDelegate: AnyObject {
    /// 已经停止并生成了动图（可能帧数很少）。调用时录制窗口已经关闭。
    func gifRecordDidFinish(_ anim: GifAnimation)
    /// 取消（Esc / 取消按钮 / 关闭窗口），什么也没产生。
    func gifRecordDidCancel()
}

/// GIF 录制窗口：一个**中间镂空**的窗口，镂空区就是录制区域。
///
/// 为什么做成"洞"：录制区域里的像素必须是纯桌面，边框和按钮绝不能进画面。
/// 所以窗口 = 2px 边框 + 洞 + 底部控制条，抓帧只抓洞的矩形，并额外把自己这个
/// 窗口从 ScreenCaptureKit 里排除掉（双保险）。
final class GifRecordController: NSObject, NSWindowDelegate {
    private weak var delegate: GifRecordDelegate?
    private let screen: NSScreen
    private let fps: Int
    /// 是否把鼠标箭头录进画面（来自设置「录制鼠标箭头 - GIF录制」）。
    private let showsCursor: Bool

    private var window: GifRecordWindow?
    private var content: GifRecordContentView?
    private var controlBar: GifControlBar? { content?.controlBar }
    private var recorder: GifScreenRecorder?

    private enum State { case idle, recording, paused, finishing }
    private var state: State = .idle

    init(screen: NSScreen, fps: Int, showsCursor: Bool, delegate: GifRecordDelegate) {
        self.screen = screen
        self.fps = max(1, min(60, fps))
        self.showsCursor = showsCursor
        self.delegate = delegate
        super.init()
    }

    // MARK: - 建窗

    func present() {
        var holeW: CGFloat = 700
        var holeH: CGFloat = 400
        let visible = screen.visibleFrame
        let maxW = (visible.width - 40) * 0.9
        let maxH = (visible.height - 80) * 0.9
        if holeW > maxW { holeW = maxW }
        if holeH > maxH { holeH = maxH }

        let w = (holeW + GifRecordContentView.border * 2).rounded()
        let h = (holeH + GifRecordContentView.border * 2 + GifRecordContentView.barHeight).rounded()
        let rect = NSRect(
            x: (visible.midX - w / 2).rounded(),
            y: (visible.midY - h / 2).rounded(),
            width: w,
            height: h
        )

        let window = GifRecordWindow(
            contentRect: rect,
            // 三个标准按钮（关闭/最小化/最大化）都要有 —— 和普通 Mac 窗口一致。
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GIF 录制"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false      // 内容区挖成"洞"，透出桌面
        window.hasShadow = true
        window.minSize = NSSize(width: 240, height: 190)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.onEscape = { [weak self] in self?.cancel() }

        let content = GifRecordContentView(frame: NSRect(origin: .zero, size: rect.size))
        content.autoresizingMask = [.width, .height]
        content.controlBar.primary.target = self
        content.controlBar.primary.action = #selector(primaryClicked)
        content.controlBar.secondary.target = self
        content.controlBar.secondary.action = #selector(secondaryClicked)
        window.contentView = content
        self.content = content

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        state = .idle
        refreshUI()
    }

    // MARK: - 状态机

    @objc private func primaryClicked() {
        switch state {
        case .idle: startRecording()
        case .recording: pauseRecording()
        case .paused: resumeRecording()
        case .finishing: break
        }
    }

    @objc private func secondaryClicked() {
        switch state {
        case .idle: cancel()
        case .recording, .paused: stopRecording()
        case .finishing: break
        }
    }

    private func startRecording() {
        guard let window, let content else { return }
        let hole = content.holeRect
        let inWindow = content.convert(hole, to: nil)
        let region = window.convertToScreen(inWindow)
        guard region.width >= 8, region.height >= 8 else { return }

        // 录制中禁止拖动/缩放：否则录区与实际画面不一致。
        // 注意不能把 .resizable 从 styleMask 里摘掉 —— 那样"最大化"按钮会消失；
        // 改为在 windowWillResize 里锁住尺寸，按钮还在、只是按不动。
        window.isMovable = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        let recorder = GifScreenRecorder(screen: screen, region: region, fps: fps, showsCursor: showsCursor)
        self.recorder = recorder
        recorder.onStats = { [weak self] seconds, count in
            self?.updateStats(seconds: seconds, frames: count)
        }

        state = .recording
        refreshUI()

        Task { @MainActor in
            do {
                try await recorder.start(excludingWindowNumbers: [window.windowNumber])
            } catch {
                self.recorder = nil
                self.state = .idle
                self.refreshUI()
                window.isMovable = true
                window.standardWindowButton(.zoomButton)?.isEnabled = true
                let alert = NSAlert()
                alert.messageText = "GIF 录制启动失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func pauseRecording() {
        recorder?.pause()
        state = .paused
        refreshUI()
    }

    private func resumeRecording() {
        recorder?.resume()
        state = .recording
        refreshUI()
    }

    private func stopRecording() {
        guard let recorder else { cancel(); return }
        state = .finishing
        refreshUI()
        controlBar?.statusLabel.stringValue = "正在生成动图…"
        recorder.finish { [weak self] anim in
            guard let self else { return }
            self.closeWindow()
            if anim.frames.isEmpty {
                // 一帧都没录到（点了录制立刻停止）：别生成空白页签。
                let alert = NSAlert()
                alert.messageText = "没有录到画面"
                alert.informativeText = "录制时间太短，或该区域的画面没有变化。再试一次？"
                alert.runModal()
                self.delegate?.gifRecordDidCancel()
            } else {
                self.delegate?.gifRecordDidFinish(anim)
            }
        }
    }

    @objc func cancel() {
        recorder?.abort()
        recorder = nil
        closeWindow()
        delegate?.gifRecordDidCancel()
    }

    private func closeWindow() {
        window?.onEscape = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        content = nil
    }

    // MARK: - UI 同步

    private func refreshUI() {
        guard let bar = controlBar else { return }
        let primary = bar.primary
        let secondary = bar.secondary
        switch state {
        case .idle:
            primary.configure(title: "● 录制", fill: Theme.accent)
            secondary.configure(title: "✕ 取消", fill: GifControlBar.secondaryFill)
            primary.isEnabled = true
            secondary.isEnabled = true
            updateIdleStatus()
        case .recording:
            primary.configure(title: "⏸ 暂停", fill: Theme.accent)
            secondary.configure(title: "■ 停止", fill: NSColor.systemRed.withAlphaComponent(0.9))
            primary.isEnabled = true
            secondary.isEnabled = true
        case .paused:
            primary.configure(title: "● 继续", fill: Theme.accent)
            secondary.configure(title: "■ 停止", fill: NSColor.systemRed.withAlphaComponent(0.9))
            primary.isEnabled = true
            secondary.isEnabled = true
        case .finishing:
            primary.isEnabled = false
            secondary.isEnabled = false
            primary.alphaValue = 0.55
            secondary.alphaValue = 0.55
        }
        if state != .finishing {
            primary.alphaValue = 1
            secondary.alphaValue = 1
        }
    }

    private func updateIdleStatus() {
        guard let content else { return }
        let scale = screen.backingScaleFactor
        let hole = content.holeRect
        let w = max(2, Int((hole.width * scale).rounded()) & ~1)
        let h = max(2, Int((hole.height * scale).rounded()) & ~1)
        // 设置值超过 GIF 能表达的上限（50fps / 2 厘秒）时说明一下，
        // 否则用户会以为"设了 60 却没按 60 录"。
        let note = fps > GifScreenRecorder.maxGifFps ? "（GIF 上限 \(GifScreenRecorder.maxGifFps)）" : ""
        let cursorNote = showsCursor ? " · 含鼠标箭头" : ""
        controlBar?.statusLabel.stringValue = "录制区域 \(w) × \(h) · \(fps) fps\(note)\(cursorNote) · 点「录制」开始"
    }

    private func updateStats(seconds: TimeInterval, frames: Int) {
        guard state == .recording || state == .paused else { return }
        let prefix = state == .recording ? "录制中" : "已暂停"
        controlBar?.statusLabel.stringValue = "\(prefix) \(Self.timeText(seconds)) · \(frames) 帧 · \(fps) fps"
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard state == .idle else { return }
        updateIdleStatus()
    }

    /// 录制中锁死尺寸（拖边框也不动），按钮仍然是可点的外观。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard state == .recording || state == .paused || state == .finishing else {
            return frameSize
        }
        return sender.frame.size
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state != .finishing { cancel() }
        return false
    }
}

// MARK: - 窗口

/// Esc = 取消（录制中也一样）。
final class GifRecordWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 内容视图（洞 + 边框 + 控制条）

final class GifRecordContentView: NSView {
    static let border: CGFloat = 2
    static let barHeight: CGFloat = 46

    let controlBar = GifControlBar()

    override var isFlipped: Bool { true }

    /// 录制区域（视图坐标）：四周留 2px 边框，底部留出控制条。
    var holeRect: CGRect {
        CGRect(
            x: Self.border,
            y: Self.border,
            width: max(1, bounds.width - Self.border * 2),
            height: max(1, bounds.height - Self.border * 2 - Self.barHeight)
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(controlBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        controlBar.frame = NSRect(
            x: 0,
            y: bounds.height - Self.barHeight,
            width: bounds.width,
            height: Self.barHeight
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 只画边框：洞里什么都不画，窗口又是非不透明的 → 直接透出桌面。
        let hole = holeRect
        let path = NSBezierPath(rect: hole.insetBy(dx: -Self.border / 2, dy: -Self.border / 2))
        path.lineWidth = Self.border
        Theme.accent.setStroke()
        path.stroke()
    }
}

/// 底部控制条：左边状态文字，右边「主操作 / 次操作」两个按钮。
/// 按钮 104×32、间距 8、右留白 12（与 Windows 版一致）。
final class GifControlBar: NSView {
    let statusLabel = NSTextField(labelWithString: "")
    private var themeObserver: NSObjectProtocol?
    let primary = GifActionButton(title: "● 录制", fill: Theme.accent)
    let secondary = GifActionButton(title: "✕ 取消", fill: NSColor(calibratedWhite: 0.28, alpha: 1))

    /// 次要按钮（取消）的底色：深色主题深灰、浅色主题浅灰。
    static var secondaryFill: NSColor {
        Theme.isDark ? NSColor(calibratedWhite: 0.28, alpha: 1)
                     : NSColor(calibratedWhite: 0.88, alpha: 1)
    }

    private static let buttonW: CGFloat = 104
    private static let buttonH: CGFloat = 32
    private static let gap: CGFloat = 8
    private static let rightInset: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        addSubview(primary)
        addSubview(secondary)
        applyTheme()

        themeObserver = NotificationCenter.default.addObserver(
            forName: .appThemeDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyTheme() }
    }

    /// 底部状态栏跟随主题：暗色才用近黑色，浅色用浅灰白（原来两套主题都是黑的）。
    func applyTheme() {
        let dark = Theme.isDark
        layer?.backgroundColor = (dark
            ? NSColor(calibratedWhite: 0.11, alpha: 0.94)
            : NSColor(calibratedWhite: 0.97, alpha: 0.96)).cgColor
        statusLabel.textColor = dark
            ? NSColor(calibratedWhite: 0.90, alpha: 1)
            : NSColor(calibratedWhite: 0.16, alpha: 1)
        // 「取消」是次要按钮：深色下用深灰、浅色下用浅灰（按钮自己按底色挑字的明暗）。
        secondary.applyTheme(fill: Self.secondaryFill)
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = ((bounds.height - Self.buttonH) / 2).rounded()
        let secondaryX = max(0, bounds.width - Self.rightInset - Self.buttonW)
        secondary.frame = NSRect(x: secondaryX, y: y, width: Self.buttonW, height: Self.buttonH)
        let primaryX = max(0, secondaryX - Self.gap - Self.buttonW)
        primary.frame = NSRect(x: primaryX, y: y, width: Self.buttonW, height: Self.buttonH)
        statusLabel.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(40, primaryX - 24), height: 16)
    }
}

// MARK: - 控制条按钮

final class GifActionButton: NSButton {
    private var fill: NSColor
    /// 纯标题（`attributedTitle` 拿不回来原文，重新配色时要用）。
    private(set) var plainTitle = ""

    init(title: String, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        configure(title: title, fill: fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, fill: NSColor) {
        self.fill = fill
        self.plainTitle = title
        layer?.backgroundColor = (isEnabled ? fill : fill.withAlphaComponent(0.4)).cgColor
        // 浅色底配深字、深色底配白字（浅灰的「取消」在亮色主题下不能被白字吞掉）。
        let textColor: NSColor = fill.brightness > 0.62
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : .white
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: textColor
        ])
        setAccessibilityLabel(title)
    }

    /// 只换底色（换主题时用），标题沿用当前的。
    func applyTheme(fill: NSColor) {
        guard fill != self.fill else { return }
        configure(title: plainTitle, fill: fill)
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = fill.blended(withFraction: 0.18, of: .black)?.cgColor ?? fill.cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = fill.cgColor
    }
}


// MARK: - 颜色亮度

extension NSColor {
    /// 粗略亮度（0 = 黑，1 = 白）。用来决定按钮上放白字还是深色字。
    var brightness: CGFloat {
        guard let rgb = usingColorSpace(.deviceRGB) else { return 0.5 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
}
