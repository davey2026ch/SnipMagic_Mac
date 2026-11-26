import AppKit

/// 缩略图右键菜单的三种删除范围。
enum GifDeleteScope: String {
    case current        // 删除当前帧
    case left           // 删除当前帧左侧全部
    case right          // 删除当前帧右侧全部
}

/// 动图页签的整块界面（预览 / 缩略图条 / 控制条）。
/// 当前帧可以「编辑本帧」——本质就是一张静态图，用普通截图的标注工具改，
/// 改完的标注存在帧上，导出 GIF / 存帧 / 存为页签时自动烘进像素。
///
/// 自上而下：预览区（棋盘格 + 当前帧，Ctrl+滚轮缩放 / 滚轮平移）
/// → 缩略图条（每帧一格，格下帧号与毫秒）
/// → 底部控制条（左侧横向滚动条 + 帧计数 + 图形按钮 + 循环开关 + 三个保存出口）。
final class GifPlayerView: NSView {
    static let stripHeight: CGFloat = 72
    static let controlHeight: CGFloat = 28

    private(set) var tab: EditorTab?
    private(set) var anim: GifAnimation?

    let preview = GifPreviewCanvas()
    let strip = GifStripView()
    let controls = GifControlBarView()
    /// 编辑当前帧时，宿主的标注画布会搬进这个滚动视图（缩略图条和控制条保持可用，
    /// 方便"逐帧编辑"）。不编辑时它一直隐藏。
    let editScroll = ZoomableScrollView()
    private(set) var isEditingFrame = false

    private var frameIndex = 0
    private var playing = false
    private var loopEnabled = false
    private var playTimer: Timer?
    private var nextTick: CFTimeInterval = 0

    /// 播放状态/帧变化时通知宿主刷新状态栏。
    var onUpdate: (() -> Void)?
    /// 三个保存出口。
    var onSaveFrame: (() -> Void)?
    var onSaveFrameAsTab: (() -> Void)?
    var onSaveGIF: (() -> Void)?
    /// 点「编辑本帧 / 完成编辑」。
    var onToggleEdit: (() -> Void)?
    /// 切帧**之前**通知宿主（编辑中要先把手上的标注写回当前帧）。
    var willChangeFrame: (() -> Void)?
    /// 切帧之后通知宿主（编辑中要把新帧装回画布）。
    var didChangeFrame: (() -> Void)?
    /// 缩略图右键菜单：删除当前帧 / 左侧全部 / 右侧全部。
    var onDeleteScope: ((GifDeleteScope) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.canvasBackground.cgColor
        addSubview(preview)
        editScroll.isHidden = true
        editScroll.hasVerticalScroller = true
        editScroll.hasHorizontalScroller = true
        editScroll.scrollerStyle = .legacy
        editScroll.autohidesScrollers = true
        editScroll.borderType = .noBorder
        editScroll.drawsBackground = true
        editScroll.backgroundColor = Theme.canvasBackground
        editScroll.automaticallyAdjustsContentInsets = false
        addSubview(editScroll)
        addSubview(strip)
        addSubview(controls)
        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        preview.zoomChanged = { [weak self] _ in
            self?.onUpdate?()
        }
        strip.onSelect = { [weak self] index in
            guard let self else { return }
            self.pause()
            self.setFrame(index)
        }
        strip.onOffsetChange = { [weak self] offset in
            guard let self else { return }
            self.tab?.gifStripScroll = offset
            self.controls.setScroll(offset: offset, content: self.strip.contentWidth, visible: self.strip.bounds.width)
        }
        controls.onFirst = { [weak self] in self?.jump(to: 0) }
        controls.onLast = { [weak self] in
            guard let self, let anim = self.anim else { return }
            self.jump(to: max(0, anim.count - 1))
        }
        controls.onPrev = { [weak self] in self?.step(by: -1) }
        controls.onNext = { [weak self] in self?.step(by: 1) }
        controls.onPlayToggle = { [weak self] in self?.togglePlay() }
        controls.onLoopChanged = { [weak self] on in
            guard let self else { return }
            self.loopEnabled = on
            self.tab?.gifLoop = on
            self.onUpdate?()
            self.refreshUI()
        }
        controls.onSaveFrame = { [weak self] in self?.onSaveFrame?() }
        controls.onSaveAsTab = { [weak self] in self?.onSaveFrameAsTab?() }
        controls.onSaveGIF = { [weak self] in self?.onSaveGIF?() }
        controls.onToggleEdit = { [weak self] in self?.onToggleEdit?() }
        strip.onDeleteScope = { [weak self] scope in self?.onDeleteScope?(scope) }
        controls.onStripScroll = { [weak self] offset in
            guard let self else { return }
            self.strip.setOffset(offset)
            self.tab?.gifStripScroll = self.strip.offset
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let barH = Self.controlHeight
        let stripH = Self.stripHeight
        controls.frame = NSRect(x: 0, y: h - barH, width: w, height: barH)
        strip.frame = NSRect(x: 0, y: max(0, h - barH - stripH), width: w, height: stripH)
        let top = NSRect(x: 0, y: 0, width: w, height: max(0, h - barH - stripH))
        preview.frame = top
        editScroll.frame = top
        controls.setScroll(offset: strip.offset, content: strip.contentWidth, visible: strip.bounds.width)
    }

    // MARK: - 绑定

    func bind(tab: EditorTab) {
        guard let anim = tab.gif else {
            unbind()
            return
        }
        let changed = self.tab?.id != tab.id
        self.tab = tab
        self.anim = anim
        // 一律按 tab 上记的帧号还原：删帧之后帧数变少，光"夹一下旧帧号"会停在错的帧上。
        frameIndex = min(max(0, tab.gifFrame), max(0, anim.count - 1))
        if changed {
            loopEnabled = tab.gifLoop
            preview.resetZoom()
        }
        pause()
        strip.bind(anim: anim, index: frameIndex, offset: tab.gifStripScroll)
        controls.loopSwitch.state = loopEnabled ? .on : .off
        refreshUI()
    }

    /// 进入 / 退出「编辑本帧」。进入前会暂停播放；画布由宿主搬进 `editScroll`。
    func setEditing(_ editing: Bool) {
        guard isEditingFrame != editing else { return }
        if editing { pause() }
        isEditingFrame = editing
        preview.isHidden = editing
        editScroll.isHidden = !editing
        controls.setEditing(editing)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// 主题切换后刷新自绘底色。
    func applyTheme() {
        layer?.backgroundColor = Theme.canvasBackground.cgColor
        editScroll.backgroundColor = Theme.canvasBackground
        preview.needsDisplay = true
        strip.needsDisplay = true
        controls.applyTheme()
    }

    func unbind() {
        pause()
        tab = nil
        anim = nil
        preview.image = nil
        strip.bind(anim: nil, index: 0, offset: 0)
        refreshUI()
    }

    // MARK: - 播放

    var isPlaying: Bool { playing }

    var statusText: String {
        guard let anim, anim.count > 0 else { return "动图页签" }
        let index = min(frameIndex, anim.count - 1)
        let ms = anim.frames[index].delayMs
        let mode: String
        if playing {
            mode = loopEnabled ? "播放中 · 循环" : "播放中 · 单次"
        } else {
            mode = loopEnabled ? "已暂停 · 循环" : "已暂停 · 单次"
        }
        var text = "第 \(index + 1)/\(anim.count) 帧 · \(ms) ms · ←/→ 逐帧"
        text += "    \(mode)"
        if preview.zoom != 1 {
            text += "    缩放 \(Int((preview.zoom * 100).rounded()))%"
        }
        return text
    }

    func togglePlay() {
        // 编辑帧的时候不播：画布每帧都要重装，播起来只会抖。
        guard !isEditingFrame, let anim, anim.count > 1 else { return }
        if playing {
            pause()
            refreshUI()
            return
        }
        // 不循环且停在末帧时再点播放 → 从第 1 帧重新开始（不能"点了没反应"）。
        if !loopEnabled, frameIndex >= anim.count - 1 {
            frameIndex = 0
        }
        playing = true
        nextTick = CACurrentMediaTime() + Double(anim.frames[frameIndex].delayMs) / 1000.0
        startTimer()
        refreshUI()
    }

    func pause() {
        playing = false
        playTimer?.invalidate()
        playTimer = nil
        commitState()
    }

    private func startTimer() {
        playTimer?.invalidate()
        let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        playTimer = t
    }

    private func tick() {
        guard playing, let anim, anim.count > 1 else { return }
        let now = CACurrentMediaTime()
        guard now >= nextTick else { return }
        var next = frameIndex + 1
        if next >= anim.count {
            if loopEnabled {
                next = 0
            } else {
                // 停在末帧并停下
                playing = false
                playTimer?.invalidate()
                playTimer = nil
                refreshUI()
                return
            }
        }
        frameIndex = next
        nextTick = now + max(0.01, Double(anim.frames[next].delayMs) / 1000.0)
        refreshUI()
    }

    func step(by delta: Int) {
        guard anim != nil else { return }
        pause()
        setFrame(frameIndex + delta)
    }

    func jump(to index: Int) {
        guard anim != nil else { return }
        pause()
        setFrame(index)
    }

    /// 切帧的唯一入口：先让宿主把当前帧的标注写回（编辑中），再换帧、再通知宿主装新帧。
    private func setFrame(_ index: Int) {
        guard let anim, anim.count > 0 else { return }
        let clamped = min(max(0, index), anim.count - 1)
        if clamped != frameIndex {
            willChangeFrame?()
        }
        frameIndex = clamped
        commitState()
        refreshUI()
        didChangeFrame?()
    }

    /// 键盘 ←/→/空格/Home/End —— 由宿主的 key monitor 转发过来（不依赖焦点，避免点了页签后失效）。
    func handleKey(_ event: NSEvent) -> Bool {
        guard anim != nil else { return false }
        switch event.keyCode {
        case 123: step(by: -1); return true          // ←
        case 124: step(by: 1); return true           // →
        case 115: jump(to: 0); return true           // Home
        case 119:                                       // End
            if let anim { jump(to: anim.count - 1) }
            return true
        case 49:                                        // 空格
            togglePlay()
            return true
        default:
            if event.charactersIgnoringModifiers == " " {
                togglePlay()
                return true
            }
            return false
        }
    }

    // MARK: - 刷新

    private func commitState() {
        tab?.gifFrame = frameIndex
    }

    private func refreshUI() {
        guard let anim, anim.count > 0 else {
            preview.image = nil
            controls.update(count: 0, index: 0, ms: 0, playing: false, hasContent: false)
            strip.update(index: 0)
            onUpdate?()
            return
        }
        let index = min(frameIndex, anim.count - 1)
        preview.image = anim.image(at: index)
        strip.update(index: index)
        controls.update(
            count: anim.count,
            index: index,
            ms: anim.frames[index].delayMs,
            playing: playing,
            hasContent: true
        )
        strip.ensureVisible(index: index, viewport: strip.bounds.width)
        // 缩略图条总宽会随帧数变化，滚动条要跟着重算（否则溢出时它不出现）。
        controls.setScroll(offset: strip.offset, content: strip.contentWidth, visible: strip.bounds.width)
        tab?.gifStripScroll = strip.offset
        commitState()
        onUpdate?()
    }
}

// MARK: - 预览区

final class GifPreviewCanvas: NSView {
    var image: CGImage? {
        didSet {
            clampPan()
            needsDisplay = true
        }
    }

    private(set) var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    var zoomChanged: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var logicalSize: CGSize {
        guard let image else { return .zero }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(image.width) / max(scale, 1), height: CGFloat(image.height) / max(scale, 1))
    }

    /// 1 倍 = 适应可视区（原图比可视区大才等比缩小）。
    private var fitScale: CGFloat {
        let size = logicalSize
        guard size.width > 0, size.height > 0, bounds.width > 1, bounds.height > 1 else { return 1 }
        return min(1, min(bounds.width / size.width, bounds.height / size.height))
    }

    private var displayScale: CGFloat { fitScale * zoom }

    private var imageRect: CGRect {
        let size = logicalSize
        guard size.width > 0 else { return .zero }
        let w = size.width * displayScale
        let h = size.height * displayScale
        return CGRect(
            x: (bounds.width - w) / 2 + pan.x,
            y: (bounds.height - h) / 2 + pan.y,
            width: w,
            height: h
        )
    }

    func resetZoom() {
        zoom = 1
        pan = .zero
        zoomChanged?(zoom)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        clampPan()
        needsDisplay = true
    }

    private func clampPan() {
        let size = logicalSize
        guard size.width > 0 else { pan = .zero; return }
        let w = size.width * displayScale
        let h = size.height * displayScale
        let maxX = max(0, (w - bounds.width) / 2)
        let maxY = max(0, (h - bounds.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvasBackground.setFill()
        bounds.fill()

        // 棋盘格：用 16×16 小图当「图案色」铺底（逐格填矩形在 24fps 下会卡）。
        // ⚠️ 不能用 ctx.draw(_:in:byTiling:) —— 那个会把小图缩放到整块 rect 再"平铺"，
        // 结果是一整片两色横条，不是格子。
        if let pattern = CheckerTile.pattern(isDark: Theme.isDark) {
            pattern.setFill()
            bounds.fill()
        }

        guard let image else { return }
        // ⚠️ 必须用 NSImage 画（它会照顾 flipped 坐标系），直接 ctx.draw(cgImage:)
        // 在本视图里会被上下翻过来（文字倒着）。
        let rect = imageRect
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: bounds)
        clip.addClip()
        NSImage(cgImage: image, size: rect.size).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 交互

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) {
            // Ctrl + 滚轮 = 以光标为中心缩放（每档 10%，25%–800%）。
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return }
            let factor: CGFloat = dy > 0 ? 1.1 : 1 / 1.1
            zoomAt(point: convert(event.locationInWindow, from: nil), factor: factor)
            return
        }
        // 滚轮 = 上下平移；Shift + 滚轮 = 左右平移。
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if flags.contains(.shift), dx == 0 {
            dx = dy
            dy = 0
        }
        if !event.hasPreciseScrollingDeltas {
            dx *= 12
            dy *= 12
        }
        pan.x += dx
        pan.y += dy
        clampPan()
        needsDisplay = true
    }

    private func zoomAt(point: CGPoint, factor: CGFloat) {
        guard logicalSize.width > 0 else { return }
        let before = imageRect
        let oldScale = displayScale
        var newZoom = min(8, max(0.25, zoom * factor))
        if abs(newZoom - 1) < 0.04 { newZoom = 1 }
        guard newZoom != zoom else { return }

        // 光标下的图像坐标（相对图像中心，单位图像像素）
        let centerX = before.midX
        let centerY = before.midY
        guard oldScale > 0 else { return }
        let imgX = (point.x - centerX) / oldScale
        let imgY = (point.y - centerY) / oldScale

        zoom = newZoom
        let newScale = displayScale
        let size = logicalSize
        let newW = size.width * newScale
        let newH = size.height * newScale
        // 让同一个图像点仍然落在光标处 → 反解平移量
        pan.x = point.x - imgX * newScale - (bounds.width - newW) / 2
        pan.y = point.y - imgY * newScale - (bounds.height - newH) / 2
        if zoom == 1 { pan = .zero }
        clampPan()
        zoomChanged?(zoom)
        needsDisplay = true
    }

    private var dragStart: CGPoint?
    private var panStart: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        // 单击画面不做事（避免误触开始播放）；按住拖动才是平移。
        dragStart = convert(event.locationInWindow, from: nil)
        panStart = pan
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        pan = CGPoint(x: panStart.x + (p.x - start.x), y: panStart.y + (p.y - start.y))
        clampPan()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        zoomAt(point: convert(event.locationInWindow, from: nil), factor: 1 + event.magnification)
    }
}

// MARK: - 棋盘格图块

enum CheckerTile {
    private static var cache: [Bool: CGImage] = [:]
    private static var patterns: [Bool: NSColor] = [:]

    /// 可平铺的图案色（按 1:1 铺，不会被拉伸）。
    static func pattern(isDark: Bool) -> NSColor? {
        if let cached = patterns[isDark] { return cached }
        guard let cg = image(isDark: isDark) else { return nil }
        let tile = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
        let color = NSColor(patternImage: tile)
        patterns[isDark] = color
        return color
    }

    static func image(isDark: Bool) -> CGImage? {
        if let cached = cache[isDark] { return cached }
        let size = 16
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let light = isDark ? NSColor(calibratedWhite: 0.15, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 1)
        let dark = isDark ? NSColor(calibratedWhite: 0.2, alpha: 1) : NSColor(calibratedWhite: 0.886, alpha: 1)
        ctx.setFillColor(light.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(dark.cgColor)
        ctx.fill(CGRect(x: 8, y: 0, width: 8, height: 8))
        ctx.fill(CGRect(x: 0, y: 8, width: 8, height: 8))
        guard let image = ctx.makeImage() else { return nil }
        cache[isDark] = image
        return image
    }
}

// MARK: - 缩略图条

final class GifStripView: NSView {
    static let cellWidth: CGFloat = 100
    static let cellHeight: CGFloat = 46
    static let gap: CGFloat = 4
    static let leftInset: CGFloat = 8
    static let labelHeight: CGFloat = 16
    static let topInset: CGFloat = 4

    private var anim: GifAnimation?
    private(set) var index = 0
    private(set) var offset: CGFloat = 0
    var onSelect: ((Int) -> Void)?
    var onOffsetChange: ((CGFloat) -> Void)?
    /// 右键菜单的三种删除。宿主负责确认与真正执行。
    var onDeleteScope: ((GifDeleteScope) -> Void)?

    var contentWidth: CGFloat {
        guard let anim, anim.count > 0 else { return 0 }
        return Self.leftInset * 2 + CGFloat(anim.count) * Self.cellWidth + CGFloat(anim.count - 1) * Self.gap
    }

    override var isFlipped: Bool { true }

    func bind(anim: GifAnimation?, index: Int, offset: CGFloat) {
        self.anim = anim
        self.index = index
        setOffset(offset)
        needsDisplay = true
    }

    func update(index: Int) {
        self.index = index
        needsDisplay = true
    }

    func setOffset(_ value: CGFloat) {
        let maxOffset = max(0, contentWidth - bounds.width)
        let clamped = min(max(0, value), maxOffset)
        guard clamped != offset else { return }
        offset = clamped
        needsDisplay = true
        onOffsetChange?(offset)
    }

    private var maxOffset: CGFloat { max(0, contentWidth - bounds.width) }

    private func cellRect(_ i: Int) -> CGRect {
        CGRect(
            x: Self.leftInset + CGFloat(i) * (Self.cellWidth + Self.gap) - offset,
            y: Self.topInset,
            width: Self.cellWidth,
            height: Self.cellHeight
        )
    }

    override func layout() {
        super.layout()
        setOffset(offset)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()

        guard let anim, anim.count > 0 else { return }
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let cellSize = NSSize(width: Self.cellWidth, height: Self.cellHeight)

        for i in 0..<anim.count {
            let cell = cellRect(i)
            guard cell.maxX > 0, cell.minX < bounds.width else { continue }

            if let thumb = anim.thumbnail(at: i, cell: cellSize) {
                NSImage(cgImage: thumb, size: cellSize).draw(in: cell)
            }
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(rect: cell.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            // 帧号（0 起）在左，停留毫秒在右
            let number = "\(i)" as NSString
            number.draw(at: NSPoint(x: cell.minX + 1, y: cell.maxY + 2), withAttributes: [
                .font: labelFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            let ms = "\(anim.frames[i].delayMs)ms" as NSString
            let msSize = ms.size(withAttributes: [.font: labelFont])
            ms.draw(at: NSPoint(x: cell.maxX - msSize.width, y: cell.maxY + 2), withAttributes: [
                .font: labelFont,
                .foregroundColor: NSColor.tertiaryLabelColor
            ])

            if i == index {
                Theme.accent.setStroke()
                let highlight = NSBezierPath(rect: cell.insetBy(dx: -1, dy: -1))
                highlight.lineWidth = 2
                highlight.stroke()
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if dx == 0 { dx = dy }
        if !event.hasPreciseScrollingDeltas { dx *= 40 }
        setOffset(offset - dx)
        if let anim, index < anim.count, !cellRect(index).intersects(bounds) {
            // 不动选中帧，只是滚动
        }
    }

    private func frameIndex(at point: CGPoint) -> Int? {
        guard let anim else { return nil }
        for i in 0..<anim.count {
            let cell = cellRect(i)
            // 连同下面的标签行一起算点击区
            let hit = cell.union(CGRect(x: cell.minX, y: cell.maxY,
                                        width: cell.width, height: Self.labelHeight))
            if hit.contains(point) { return i }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = frameIndex(at: p) { onSelect?(i) }
    }

    /// 右键：先跳到这一帧（这样「当前帧」才有意义），再弹删除菜单。
    override func rightMouseDown(with event: NSEvent) {
        guard let anim, anim.count > 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = frameIndex(at: p) else { return }
        onSelect?(i)

        contextMenu(selectedIndex: i, count: anim.count).popUp(positioning: nil, at: p, in: self)
    }

    /// 右键菜单的内容（拆出来便于离屏验证标题与可用状态）。
    func contextMenu(selectedIndex: Int, count: Int) -> NSMenu {
        let menu = NSMenu()
        let items: [(String, GifDeleteScope, Bool)] = [
            ("删除当前帧", .current, true),
            ("删除左侧全部帧", .left, selectedIndex > 0),
            ("删除右侧全部帧", .right, selectedIndex < count - 1)
        ]
        for (title, scope, enabled) in items {
            let item = NSMenuItem(title: title, action: #selector(deleteScopeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scope.rawValue
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    @objc private func deleteScopeClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let scope = GifDeleteScope(rawValue: raw) else { return }
        onDeleteScope?(scope)
    }

    /// 让某一帧完整露出（切换/播放时用）。
    func ensureVisible(index: Int, viewport: CGFloat) {
        guard anim != nil, bounds.width > 1 else { return }
        let cell = cellRect(index)
        if cell.minX < Self.leftInset {
            setOffset(offset + (cell.minX - Self.leftInset))
        } else if cell.maxX > bounds.width - Self.leftInset {
            setOffset(offset + (cell.maxX - (bounds.width - Self.leftInset)))
        }
    }
}

// MARK: - 控制条

final class GifControlBarView: NSView {
    let scroll = HScrollBar()
    private let counter = NSTextField(labelWithString: "0/0 · 0ms")
    private let firstButton = GifSymbolButton("backward.end.fill", tip: "第一帧（Home）")
    private let prevButton = GifSymbolButton("backward.fill", tip: "上一帧（←）")
    private let playButton = GifSymbolButton("play.fill", tip: "播放 / 暂停（空格）")
    private let nextButton = GifSymbolButton("forward.fill", tip: "下一帧（→）")
    private let lastButton = GifSymbolButton("forward.end.fill", tip: "最后一帧（End）")
    let loopSwitch = NSSwitch()
    private let loopLabel = NSTextField(labelWithString: "循环")
    private let editButton = NSButton(title: "✎ 编辑本帧", target: nil, action: nil)
    private let saveFrameButton = NSButton(title: "保存帧", target: nil, action: nil)
    private let saveTabButton = NSButton(title: "存为页签", target: nil, action: nil)
    private let saveGifButton = NSButton(title: "保存GIF", target: nil, action: nil)

    var onFirst: (() -> Void)?
    var onPrev: (() -> Void)?
    var onPlayToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onLast: (() -> Void)?
    var onLoopChanged: ((Bool) -> Void)?
    var onSaveFrame: (() -> Void)?
    var onSaveAsTab: (() -> Void)?
    var onSaveGIF: (() -> Void)?
    var onStripScroll: ((CGFloat) -> Void)?
    var onToggleEdit: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.toolbarBackground.cgColor

        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right
        counter.translatesAutoresizingMaskIntoConstraints = false

        loopLabel.font = .systemFont(ofSize: 11)
        loopLabel.textColor = .secondaryLabelColor

        loopSwitch.controlSize = .mini
        loopSwitch.setAccessibilityLabel("循环")
        loopSwitch.toolTip = "循环播放：打开后播到末帧会回到第 1 帧继续"
        loopSwitch.target = self
        loopSwitch.action = #selector(loopToggled)

        for b in [saveFrameButton, saveTabButton, saveGifButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11, weight: .medium)
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.font = .systemFont(ofSize: 11, weight: .medium)
        editButton.target = self
        editButton.action = #selector(editClicked)
        editButton.toolTip = "把当前帧当普通截图来标注（改完点「保存GIF」会自动带上）"
        editButton.translatesAutoresizingMaskIntoConstraints = false

        saveFrameButton.target = self
        saveFrameButton.action = #selector(saveFrameClicked)
        saveFrameButton.toolTip = "把当前帧存成 PNG / JPG"
        saveTabButton.target = self
        saveTabButton.action = #selector(saveTabClicked)
        saveTabButton.toolTip = "把当前帧变成一个普通图片页签（可标注编辑）"
        saveGifButton.target = self
        saveGifButton.action = #selector(saveGifClicked)
        saveGifButton.toolTip = "把整个动图存成 .gif"

        for b in [firstButton, prevButton, playButton, nextButton, lastButton] {
            b.target = self
        }
        firstButton.action = #selector(firstClicked)
        prevButton.action = #selector(prevClicked)
        playButton.action = #selector(playClicked)
        nextButton.action = #selector(nextClicked)
        lastButton.action = #selector(lastClicked)

        let stack = NSStackView(views: [
            counter, editButton, firstButton, prevButton, playButton, nextButton, lastButton,
            loopLabel, loopSwitch, saveFrameButton, saveTabButton, saveGifButton
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: counter)
        stack.setCustomSpacing(6, after: editButton)
        stack.setCustomSpacing(6, after: lastButton)
        stack.setCustomSpacing(6, after: loopSwitch)
        stack.setCustomSpacing(6, after: saveFrameButton)
        stack.setCustomSpacing(6, after: saveTabButton)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.widthAnchor.constraint(equalToConstant: 108)
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -10),
            scroll.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 12)
        ])
        scroll.onChange = { [weak self] offset in
            self?.onStripScroll?(offset)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setScroll(offset: CGFloat, content: CGFloat, visible: CGFloat) {
        scroll.contentWidth = content
        scroll.visibleWidth = visible
        scroll.setOffset(offset)
    }

    /// 进入/退出编辑时切换按钮文案与外观。
    func setEditing(_ editing: Bool) {
        editButton.title = editing ? "✓ 完成编辑" : "✎ 编辑本帧"
        editButton.contentTintColor = editing ? Theme.accent : nil
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.toolbarBackground.cgColor
    }

    func update(count: Int, index: Int, ms: Int, playing: Bool, hasContent: Bool) {
        counter.stringValue = hasContent ? "\(index + 1)/\(count) · \(ms)ms" : "0/0"
        playButton.setSymbol(playing ? "pause.fill" : "play.fill")
        for b in [firstButton, prevButton, playButton, nextButton, lastButton] {
            b.isEnabled = hasContent
        }
        for b in [saveFrameButton, saveTabButton, saveGifButton] {
            b.isEnabled = hasContent
        }
        editButton.isEnabled = hasContent
    }

    @objc private func firstClicked() { onFirst?() }
    @objc private func prevClicked() { onPrev?() }
    @objc private func playClicked() { onPlayToggle?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func lastClicked() { onLast?() }
    @objc private func loopToggled() { onLoopChanged?(loopSwitch.state == .on) }
    @objc private func editClicked() { onToggleEdit?() }
    @objc private func saveFrameClicked() { onSaveFrame?() }
    @objc private func saveTabClicked() { onSaveAsTab?() }
    @objc private func saveGifClicked() { onSaveGIF?() }
}

/// 控制条上的图形按钮（SF Symbol，无底框）。
final class GifSymbolButton: NSButton {
    init(_ symbol: String, tip: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        toolTip = tip
        setSymbol(symbol)
        setAccessibilityLabel(tip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: symbol == "play.fill" || symbol == "pause.fill" ? 28 : 24).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }
}
