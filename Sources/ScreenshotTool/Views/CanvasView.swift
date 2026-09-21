import AppKit

/// Scroll view that turns ⌘ + mouse wheel (and trackpad pinch) into image
/// zoom instead of scrolling. Plain wheel / trackpad scrolling still works.
/// Zooming the canvas view keeps annotation editing fully functional — the
/// canvas geometry simply runs at a different points-per-pixel ratio.
/// For document views that are not a CanvasView (e.g. the compare pane's
/// plain container), set `onZoom` to handle the zoom yourself.
final class ZoomableScrollView: NSScrollView {
    /// Fallback zoom handler for non-canvas document views. Receives a
    /// multiplicative factor (> 1 = zoom in).
    var onZoom: ((CGFloat) -> Void)?

    private func handleWheelZoom(deltaY: CGFloat) {
        // User preference: wheel up (away) = zoom out, wheel down (toward) = zoom in.
        let factor: CGFloat = deltaY > 0 ? 1 / 1.1 : 1.1
        performZoom(factor: factor)
    }

    private func performZoom(factor: CGFloat) {
        if let canvas = documentView as? CanvasView {
            canvas.zoom(byFactor: factor)
        } else {
            onZoom?(factor)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ + wheel → zoom (matches the user's muscle memory from browsers/Preview).
        if event.modifierFlags.contains(.command), event.deltaY != 0 {
            handleWheelZoom(deltaY: event.deltaY)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        // Trackpad pinch also zooms — it is the same intent.
        if event.magnification != 0 {
            performZoom(factor: 1 + event.magnification)
        }
    }
}

/// Drawings and hit-testing on the screenshot canvas. Coordinates are image pixels.
final class CanvasView: NSView {
    /// Breathing room around the screenshot inside the scroll view.
    static let canvasPadding: CGFloat = 28

    var tab: EditorTab? {
        didSet {
            // 涂抹记的是图像坐标，换到另一张图就没意义了。
            // 但撤销/重做会把同一个 tab 再赋一次值 —— 那种情况必须保留，
            // 否则刚恢复出来的涂抹痕迹会被自己抹掉（这正是「撤销对刷子不生效」的成因）。
            if tab !== oldValue {
                clearEraseStrokes()
            }
            updateFrameSize()
            needsDisplay = true
        }
    }
    var style = EditorStyle() {
        didSet { needsDisplay = true }
    }
    var selectedAnnotation: Annotation? {
        didSet { needsDisplay = true }
    }

    /// Selection rect drawn by the select tool (image pixels)
    private(set) var selectionRect: CGRect = .zero

    // MARK: - 消除画笔（「魔法消除」的涂抹选区）

    /// 打开后，画布上的拖动变成涂抹，而不是拉选区或画图形。
    var eraseBrushActive = false {
        didSet {
            if !eraseBrushActive { resetEraseStrokeInProgress() }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 刷子直径（图像像素）。对外一律用直径 —— 那才是用户能直接感觉到的大小；
    /// 内部画圆/画线时才换算成半径。
    var eraseBrushDiameter: CGFloat = 26 {
        didSet { needsDisplay = true }
    }

    /// 已落笔的涂抹。
    private(set) var eraseStrokes: [EraseStroke] = []
    private var currentStroke: EraseStroke?
    private var isPaintingStroke = false

    var hasEraseStrokes: Bool { !eraseStrokes.isEmpty || currentStroke != nil }

    /// 清空涂抹痕迹。
    func clearEraseStrokes() {
        eraseStrokes.removeAll()
        resetEraseStrokeInProgress()
        needsDisplay = true
    }

    /// 撤销 / 重做要把涂抹整体换回去，所以给一个明确的写入口。
    func restoreEraseStrokes(_ strokes: [EraseStroke]) {
        eraseStrokes = strokes
        resetEraseStrokeInProgress()
        needsDisplay = true
    }

    private func resetEraseStrokeInProgress() {
        currentStroke = nil
        isPaintingStroke = false
    }

    /// 追加一个涂抹采样点。挨得太近的点直接丢掉 —— 既没必要，也会拖慢遮罩生成。
    private func appendErasePoint(_ point: CGPoint) {
        guard isPaintingStroke, var stroke = currentStroke else { return }
        if let last = stroke.points.last,
           hypot(point.x - last.x, point.y - last.y) < max(stroke.radius * 0.3, 2) {
            return
        }
        stroke.points.append(point)
        currentStroke = stroke
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if eraseBrushActive {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // In-progress drawing
    private var draftKind: AnnotationKind?
    private var draftColor: NSColor = .systemRed
    private var draftWidth: CGFloat = 4
    private var penPoints: [CGPoint] = []
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var isDragging = false
    private var isMovingSelection = false
    private var isResizing = false
    private var activeHandle: SelectionHandle = .body
    private var moveOffset: CGPoint = .zero
    private var selectionStart: CGPoint?
    private var selectionEnd: CGPoint?

    var onSelectionChanged: ((CGRect) -> Void)?
    var onAnnotationsChanged: (() -> Void)?
    var onRequestTextInsert: ((CGPoint) -> Void)?
    var onRequestTextEdit: ((Annotation) -> Void)?
    var onStyleChanged: ((EditorStyle) -> Void)?
    var onRequestToolSwitch: ((ToolKind) -> Void)?
    private var pendingTextEditID: UUID?
    private var pendingTextEditOrigin: CGPoint = .zero

    private var draggedAnnotation: Annotation?
    private var annotationDragOrigin: CGPoint = .zero
    private var pendingLiftPoint: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Ctrl+wheel / pinch zoom factor (1 = native logical size).
    private(set) var zoomScale: CGFloat = 1.0

    /// Display scale: canvas view size is in points; annotations stay in pixels.
    private var pixelScale: CGFloat {
        let s = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        return max(s, 1.0)
    }

    /// Effective points-per-image-pixel after zoom (zoom in → smaller value).
    private var displayScale: CGFloat { pixelScale / zoomScale }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFrameSize()
        needsDisplay = true
    }

    private func updateFrameSize() {
        let pad = Self.canvasPadding
        if let tab, tab.pixelSize.width > 0, tab.pixelSize.height > 0 {
            // Show at logical point size so a Retina capture is not drawn 2× larger
            // than the on-screen region the user selected.
            let s = displayScale
            let logical = CGSize(width: tab.pixelSize.width / s, height: tab.pixelSize.height / s)
            setFrameSize(NSSize(width: logical.width + pad * 2, height: logical.height + pad * 2))
        } else {
            setFrameSize(NSSize(width: 120, height: 120))
        }
    }

    func setContentSize(_ size: CGSize) {
        let pad = Self.canvasPadding
        let s = displayScale
        setFrameSize(NSSize(width: size.width / s + pad * 2, height: size.height / s + pad * 2))
        needsDisplay = true
    }

    /// Zoom by a multiplicative factor (⌘+wheel / trackpad pinch). Clamped to
    /// 10%…800% with a gentle snap back to 100%. The scroll view keeps the
    /// visible top-left anchored since the canvas origin stays at (0,0).
    func zoom(byFactor factor: CGFloat) {
        var new = zoomScale * factor
        new = min(8.0, max(0.1, new))
        if abs(new - 1.0) < 0.04 { new = 1.0 }
        guard new != zoomScale else { return }
        zoomScale = new
        updateFrameSize()
        needsDisplay = true
    }

    func clearSelection() {
        selectionRect = .zero
        selectionStart = nil
        selectionEnd = nil
        isMovingSelection = false
        pendingLiftPoint = nil
        onSelectionChanged?(.zero)
        needsDisplay = true
    }

    /// View point → image pixel coordinates.
    private func imagePoint(from event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let s = displayScale
        let pad = Self.canvasPadding
        return CGPoint(x: (p.x - pad) * s, y: (p.y - pad) * s)
    }

    private func viewPoint(fromPixel p: CGPoint) -> CGPoint {
        let s = displayScale
        let pad = Self.canvasPadding
        return CGPoint(x: p.x / s + pad, y: p.y / s + pad)
    }

    private func viewRect(fromPixel r: CGRect) -> CGRect {
        let origin = viewPoint(fromPixel: r.origin)
        let s = displayScale
        return CGRect(x: origin.x, y: origin.y, width: r.width / s, height: r.height / s)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let tab else {
            NSColor.clear.setFill()
            dirtyRect.fill()
            return
        }

        let size = tab.pixelSize
        let pad = Self.canvasPadding
        let s = displayScale

        // Soft mat behind the screenshot so it reads as a card, not edge-to-edge.
        let imgViewSize = CGSize(width: size.width / s, height: size.height / s)
        let imgViewRect = CGRect(x: pad, y: pad, width: imgViewSize.width, height: imgViewSize.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: imgViewRect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()

        // Base image at logical size (never upscaled beyond 1 point per logical pixel)
        NSImage(cgImage: tab.baseImage, size: imgViewSize).draw(in: imgViewRect)

        // Annotations in pixel coordinates via context scale
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: pad, y: pad)
        cg.scaleBy(x: 1 / s, y: 1 / s)
        for ann in tab.annotations {
            AnnotationRenderer.draw(ann, in: cg, flipped: true)
        }
        cg.restoreGState()

        // Selected highlight (view coordinates)
        if let selected = selectedAnnotation {
            let box = viewRect(fromPixel: selected.boundingBox.insetBy(dx: -2, dy: -2))
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: box)
            path.lineWidth = 1.5
            path.stroke()
            drawHandles(for: selected)
        }

        // Selection rect (select tool rubber band)
        if selectionRect.width > 0.5 || selectionRect.height > 0.5 {
            let vr = viewRect(fromPixel: selectionRect)
            let path = NSBezierPath(rect: vr)
            NSColor.systemBlue.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            vr.fill()
        }

        // Draft shape while dragging (pixel space via scaled context)
        if isDragging, let start = dragStart, let end = dragEnd, draggedAnnotation == nil {
            cg.saveGState()
            cg.translateBy(x: pad, y: pad)
            cg.scaleBy(x: 1 / s, y: 1 / s)
            drawDraft(start: start, end: end)
            cg.restoreGState()
        }
        if !penPoints.isEmpty, style.tool == .pen {
            cg.saveGState()
            cg.translateBy(x: pad, y: pad)
            cg.scaleBy(x: 1 / s, y: 1 / s)
            drawPenDraft()
            cg.restoreGState()
        }

        // 刷子涂过的地方用半透明红标出来，提交前一目了然
        let strokes = eraseStrokes + (currentStroke.map { [$0] } ?? [])
        if !strokes.isEmpty {
            cg.saveGState()
            cg.translateBy(x: pad, y: pad)
            cg.scaleBy(x: 1 / s, y: 1 / s)
            drawEraseStrokes(strokes)
            cg.restoreGState()
        }
    }

    /// 把涂抹画成半透明红带。调用方已经把上下文缩放成图像像素坐标。
    private func drawEraseStrokes(_ strokes: [EraseStroke]) {
        NSColor.systemRed.withAlphaComponent(0.30).setFill()
        NSColor.systemRed.withAlphaComponent(0.30).setStroke()
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let path = NSBezierPath()
            path.lineWidth = stroke.radius * 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if stroke.points.count == 1 {
                // 单点也要看得见 —— 画成圆点
                path.appendOval(in: CGRect(x: first.x - stroke.radius, y: first.y - stroke.radius,
                                           width: stroke.radius * 2, height: stroke.radius * 2))
                path.fill()
            } else {
                path.move(to: first)
                for point in stroke.points.dropFirst() { path.line(to: point) }
                path.stroke()
            }
        }
    }

    private func drawHandles(for ann: Annotation) {
        let box = viewRect(fromPixel: ann.boundingBox)
        let pts: [CGPoint]
        switch ann.kind {
        case .arrow(let st, let en), .line(let st, let en):
            pts = [viewPoint(fromPixel: st), viewPoint(fromPixel: en)]
        default:
            pts = [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.midX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.midY),
                CGPoint(x: box.maxX, y: box.midY),
                CGPoint(x: box.minX, y: box.maxY),
                CGPoint(x: box.midX, y: box.maxY),
                CGPoint(x: box.maxX, y: box.maxY)
            ]
        }
        NSColor.white.setFill()
        NSColor.systemBlue.setStroke()
        for p in pts {
            let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            let path = NSBezierPath(rect: r)
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }

    private func handlePoints(for ann: Annotation, box: CGRect) -> [CGPoint] {
        switch ann.kind {
        case .arrow(let s, let e), .line(let s, let e):
            return [s, e]
        default:
            return [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.midX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.midY),
                CGPoint(x: box.maxX, y: box.midY),
                CGPoint(x: box.minX, y: box.maxY),
                CGPoint(x: box.midX, y: box.maxY),
                CGPoint(x: box.maxX, y: box.maxY)
            ]
        }
    }

    private func drawDraft(start: CGPoint, end: CGPoint) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let (s, e) = constrain(start: start, end: end, lock: shift)

        switch style.tool {
        case .arrow:
            AnnotationRenderer.draw(
                Annotation(kind: .arrow(start: s, end: e), color: style.color, lineWidth: style.lineWidth),
                in: NSGraphicsContext.current!.cgContext,
                flipped: true
            )
        case .line:
            AnnotationRenderer.draw(
                Annotation(kind: .line(start: s, end: e), color: style.color, lineWidth: style.lineWidth),
                in: NSGraphicsContext.current!.cgContext,
                flipped: true
            )
        case .rect, .roundedRect, .ellipse, .solidRect, .solidRoundedRect, .solidEllipse:
            let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
            let kind: AnnotationKind
            switch style.tool {
            case .rect: kind = .rect(rect: rect, rounded: false)
            case .roundedRect: kind = .rect(rect: rect, rounded: true)
            case .ellipse: kind = .ellipse(rect: rect)
            case .solidRect: kind = .solidRect(rect: rect, rounded: false)
            case .solidRoundedRect: kind = .solidRect(rect: rect, rounded: true)
            default: kind = .solidEllipse(rect: rect)
            }
            AnnotationRenderer.draw(
                Annotation(kind: kind, color: style.color, lineWidth: style.lineWidth),
                in: NSGraphicsContext.current!.cgContext,
                flipped: true
            )
        default:
            break
        }
    }

    private func drawPenDraft() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        if let f = penPoints.first {
            ctx.move(to: f)
            for p in penPoints.dropFirst() {
                ctx.addLine(to: p)
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func constrain(start: CGPoint, end: CGPoint, lock: Bool) -> (CGPoint, CGPoint) {
        guard lock else { return (start, end) }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)
        let step = Double.pi / 4
        let snapped = (angle / step).rounded() * step
        let len = hypot(dx, dy)
        let e = CGPoint(x: start.x + CGFloat(cos(snapped)) * len, y: start.y + CGFloat(sin(snapped)) * len)
        return (start, e)
    }

    // MARK: - Mouse

    /// 刷错了就右键清掉重来。
    override func rightMouseDown(with event: NSEvent) {
        if eraseBrushActive, hasEraseStrokes {
            onWillMutate?()   // 清空也是一步操作，同样要能退回来
            clearEraseStrokes()
            return
        }
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard tab != nil else { return }
        window?.makeFirstResponder(self)
        let p = imagePoint(from: event)

        if eraseBrushActive {
            // 每一笔都先存一个快照 —— 刷错了能原样退回去。
            onWillMutate?()
            currentStroke = EraseStroke(points: [p], radius: eraseBrushDiameter / 2)
            isPaintingStroke = true
            needsDisplay = true
            return
        }

        // Double-click existing text to re-edit
        if event.clickCount == 2 {
            if let hit = annotation(at: p), case .text = hit.kind {
                selectedAnnotation = hit
                onRequestTextEdit?(hit)
                if case .text(let origin, let content, let fontSize, let bold, let opaque) = hit.kind {
                    pendingTextEditID = hit.id
                    pendingTextEditOrigin = origin
                    _ = (content, fontSize, bold, opaque)
                }
                return
            }
        }

        if style.tool == .view {
            return
        }

        if style.tool == .select {
            // 1) Resize selected annotation via handles
            if selectedAnnotation != nil, let handle = hitHandle(at: p) {
                isResizing = true
                activeHandle = handle
                dragStart = p
                return
            }
            // 2) Drag existing annotation / pasted image (priority over selection frame)
            if let hit = annotation(at: p) {
                selectedAnnotation = hit
                beginAnnotationDrag(hit, at: p)
                return
            }
            // 3) Inside an active rubber-band selection → lift on drag (cut + move)
            if selectionRect.width > 2, selectionRect.height > 2, selectionRect.contains(p) {
                pendingLiftPoint = p
                return
            }
            // 4) Click blank → commit any floating paste, then start a new rubber band
            commitSelectedPasteIfAny()
            selectedAnnotation = nil
            clearSelection()
            selectionStart = p
            selectionEnd = p
            isDragging = true
            return
        }

        if style.tool == .text {
            // Clicking existing text re-opens the editor; otherwise insert new text.
            if let hit = annotation(at: p), case .text = hit.kind {
                selectedAnnotation = hit
                onRequestTextEdit?(hit)
                return
            }
            onRequestTextInsert?(p)
            return
        }

        if style.tool == .number {
            pushUndo()
            let ann = Annotation(kind: .number(center: p, value: style.numberValue), color: style.color, lineWidth: style.lineWidth)
            tab?.annotations.append(ann)
            tab?.markUnsaved()
            selectedAnnotation = ann
            onAnnotationsChanged?()
            needsDisplay = true
            // One stamp, then move it.
            onRequestToolSwitch?(.select)
            return
        }

        // Drawing tools — one stroke creates one shape, then switch to select for moving.
        pushUndo()
        dragStart = p
        dragEnd = p
        isDragging = true
        penPoints = [p]
        selectedAnnotation = nil
        needsDisplay = true
    }

    private func beginAnnotationDrag(_ ann: Annotation, at p: CGPoint) {
        draggedAnnotation = ann
        annotationDragOrigin = p
        pushUndo()
        isDragging = true
    }

    /// Convert the current selection into a floating pasted layer and start dragging it
    /// (cut-style: the original position is baked white into the base image — NOT a
    /// separate movable white rectangle; undo restores both).
    private func beginFloatingSelectionMove(at p: CGPoint) {
        guard let tab = tab,
              selectionRect.width > 2, selectionRect.height > 2,
              let region = tab.renderRegion(selectionRect) else { return }

        onWillMutate?()
        let origin = selectionRect.origin
        let size = CGSize(width: region.width, height: region.height)
        let rect = selectionRect.standardized

        // Destructive cut: fill the original position with white straight into
        // the base bitmap. Vector shapes fully inside the selection were already
        // captured into the floating layer — drop them so they don't reappear
        // once the layer moves away.
        tab.annotations.removeAll { rect.contains($0.boundingBox) }
        if let filled = Self.bakedWhiteFill(in: rect, of: tab.baseImage) {
            tab.baseImage = filled
        }

        let ann = Annotation(
            kind: .pastedImage(origin: origin, size: size, image: region),
            color: style.color,
            lineWidth: style.lineWidth
        )
        tab.annotations.append(ann)
        tab.markUnsaved()

        clearSelection()
        selectedAnnotation = ann
        draggedAnnotation = ann
        annotationDragOrigin = p
        isDragging = true
        onAnnotationsChanged?()
        needsDisplay = true
    }

    /// Copy of `image` with `rect` (top-left origin, image-pixel coords) filled
    /// solid white — the destructive half of a cut-move.
    private static func bakedWhiteFill(in rect: CGRect, of image: CGImage) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard clamped.width >= 1, clamped.height >= 1,
              let ctx = CGContext(
                  data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Annotation coords are top-left origin; CG context is bottom-left → flip Y.
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: clamped.minX, y: h - clamped.maxY, width: clamped.width, height: clamped.height))
        return ctx.makeImage()
    }

    /// Bake a selected pasted image into the base bitmap so it can no longer be dragged.
    /// Called when the user clicks empty space after placing/moving a paste.
    func commitSelectedPasteIfAny() {
        guard let tab = tab,
              let ann = selectedAnnotation,
              case .pastedImage(let origin, let size, let image) = ann.kind else { return }

        onWillMutate?()
        let w = CGFloat(tab.baseImage.width)
        let h = CGFloat(tab.baseImage.height)
        guard let ctx = CGContext(
            data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw in unflipped CG space (origin bottom-left). CGContext.draw after a
        // y-flip would invert the bitmap — convert top-left coords instead.
        ctx.interpolationQuality = .high
        ctx.draw(tab.baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cgRect = CGRect(
            x: origin.x,
            y: h - origin.y - size.height,
            width: size.width,
            height: size.height
        )
        ctx.draw(image, in: cgRect)

        if let newBase = ctx.makeImage() {
            tab.baseImage = newBase
        }
        tab.annotations.removeAll { $0.id == ann.id }
        selectedAnnotation = nil
        tab.markUnsaved()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tab != nil else { return }
        let p = imagePoint(from: event)

        if eraseBrushActive {
            appendErasePoint(p)
            return
        }

        if style.tool == .view { return }

        if style.tool == .select {
            if isResizing, selectedAnnotation != nil {
                resizeSelected(to: p)
                needsDisplay = true
                return
            }
            if let ann = draggedAnnotation {
                let dx = p.x - annotationDragOrigin.x
                let dy = p.y - annotationDragOrigin.y
                translate(ann, by: CGPoint(x: dx, y: dy))
                annotationDragOrigin = p
                needsDisplay = true
                return
            }
            if let pending = pendingLiftPoint {
                // Real drag inside the selection lifts the pixels (cut-move).
                if hypot(p.x - pending.x, p.y - pending.y) > 4 {
                    pendingLiftPoint = nil
                    beginFloatingSelectionMove(at: pending)
                }
                return
            }
            if let s = selectionStart {
                selectionEnd = p
                selectionRect = CGRect(
                    x: min(s.x, p.x), y: min(s.y, p.y),
                    width: abs(p.x - s.x), height: abs(p.y - s.y)
                )
                onSelectionChanged?(selectionRect)
                needsDisplay = true
            }
            return
        }

        dragEnd = p
        if style.tool == .pen {
            penPoints.append(p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tab != nil else { return }
        let p = imagePoint(from: event)

        if eraseBrushActive {
            // 单击也要留一个圆点，所以直接把当前这一笔收下
            if let stroke = currentStroke { eraseStrokes.append(stroke) }
            resetEraseStrokeInProgress()
            needsDisplay = true
            return
        }

        defer {
            isDragging = false
            isResizing = false
            isMovingSelection = false
            draggedAnnotation = nil
        }

        if style.tool == .view { return }

        if style.tool == .select {
            pendingLiftPoint = nil
            // Selection stays for copy/mosaic; floating lift already cleared it.
            return
        }

        guard let start = dragStart else { return }
        dragStart = nil
        let end = dragEnd ?? p
        let shift = event.modifierFlags.contains(.shift)
        let (s, e) = constrain(start: start, end: end, lock: shift)

        if style.tool == .pen {
            guard penPoints.count > 1 else { penPoints = []; needsDisplay = true; return }
            let ann = Annotation(kind: .pen(points: penPoints), color: style.color, lineWidth: style.lineWidth)
            tab?.annotations.append(ann)
            tab?.markUnsaved()
            penPoints = []
            selectedAnnotation = ann
            onAnnotationsChanged?()
            needsDisplay = true
            onRequestToolSwitch?(.select)
            return
        }

        let dx = abs(e.x - s.x)
        let dy = abs(e.y - s.y)
        if dx < 2 && dy < 2 {
            needsDisplay = true
            return
        }

        let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: dx, height: dy)
        let kind: AnnotationKind
        switch style.tool {
        case .arrow: kind = .arrow(start: s, end: e)
        case .line: kind = .line(start: s, end: e)
        case .rect: kind = .rect(rect: rect, rounded: false)
        case .roundedRect: kind = .rect(rect: rect, rounded: true)
        case .ellipse: kind = .ellipse(rect: rect)
        case .solidRect: kind = .solidRect(rect: rect, rounded: false)
        case .solidRoundedRect: kind = .solidRect(rect: rect, rounded: true)
        case .solidEllipse: kind = .solidEllipse(rect: rect)
        default:
            needsDisplay = true
            return
        }

        let ann = Annotation(kind: kind, color: style.color, lineWidth: style.lineWidth)
        tab?.annotations.append(ann)
        tab?.markUnsaved()
        selectedAnnotation = ann
        onAnnotationsChanged?()
        needsDisplay = true
        // One stroke = one shape; remaining gestures move/resize it.
        onRequestToolSwitch?(.select)
    }

    override func mouseMoved(with event: NSEvent) {
        // required for cursor updates if needed
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / forward delete
            deleteSelected()
            return
        }
        if event.keyCode == 53 { // Esc
            commitSelectedPasteIfAny()
            selectedAnnotation = nil
            clearSelection()
            return
        }
        // Enter / Return on selected text opens the editor
        if event.keyCode == 36 || event.keyCode == 76 {
            if let ann = selectedAnnotation, case .text = ann.kind {
                onRequestTextEdit?(ann)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    // MARK: - Helpers

    private func annotation(at point: CGPoint) -> Annotation? {
        guard let tab else { return nil }
        for ann in tab.annotations.reversed() where ann.contains(point) {
            return ann
        }
        return nil
    }

    private func hitHandle(at point: CGPoint) -> SelectionHandle? {
        guard let ann = selectedAnnotation else { return nil }
        let box = ann.boundingBox
        let pts = handlePoints(for: ann, box: box)
        // Threshold scales a bit with backing so hit targets stay usable in points.
        let threshold = max(10.0, 6.0 * pixelScale)
        if case .arrow = ann.kind {
            if hypot(point.x - pts[0].x, point.y - pts[0].y) < threshold { return .start }
            if hypot(point.x - pts[1].x, point.y - pts[1].y) < threshold { return .end }
            return nil
        }
        if case .line = ann.kind {
            if hypot(point.x - pts[0].x, point.y - pts[0].y) < threshold { return .start }
            if hypot(point.x - pts[1].x, point.y - pts[1].y) < threshold { return .end }
            return nil
        }
        let handles: [SelectionHandle] = [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight]
        for (i, p) in pts.enumerated() where i < handles.count {
            if abs(point.x - p.x) < threshold && abs(point.y - p.y) < threshold {
                return handles[i]
            }
        }
        return nil
    }

    private func resizeSelected(to point: CGPoint) {
        guard let ann = selectedAnnotation else { return }
        switch ann.kind {
        case .arrow(var s, var e):
            if activeHandle == .start { s = point } else { e = point }
            ann.kind = .arrow(start: s, end: e)
        case .line(var s, var e):
            if activeHandle == .start { s = point } else { e = point }
            ann.kind = .line(start: s, end: e)
        case .rect(let r, let rounded):
            ann.kind = .rect(rect: applyResize(r, to: point), rounded: rounded)
        case .ellipse(let r):
            ann.kind = .ellipse(rect: applyResize(r, to: point))
        case .solidRect(let r, let rounded):
            ann.kind = .solidRect(rect: applyResize(r, to: point), rounded: rounded)
        case .solidEllipse(let r):
            ann.kind = .solidEllipse(rect: applyResize(r, to: point))
        case .pastedImage(let origin, let size, let image):
            var r = CGRect(origin: origin, size: size)
            r = applyResize(r, to: point)
            ann.kind = .pastedImage(origin: r.origin, size: r.size, image: image)
        case .text(let origin, let content, let fontSize, let bold, let opaque):
            let box = ann.boundingBox
            let original = max(hypot(box.width, box.height), 1)
            let current = max(hypot(point.x - origin.x, point.y - origin.y), 1)
            let newSize = max(8, min(200, fontSize * (current / original)))
            ann.kind = .text(origin: origin, content: content, fontSize: newSize, bold: bold, opaqueBackground: opaque)
        default:
            break
        }
        tab?.markUnsaved()
        onAnnotationsChanged?()
    }

    private func applyResize(_ rect: CGRect, to point: CGPoint) -> CGRect {
        var r = rect.standardized
        switch activeHandle {
        case .topLeft: r = CGRect(x: point.x, y: point.y, width: r.maxX - point.x, height: r.maxY - point.y)
        case .top: r = CGRect(x: r.minX, y: point.y, width: r.width, height: r.maxY - point.y)
        case .topRight: r = CGRect(x: r.minX, y: point.y, width: point.x - r.minX, height: r.maxY - point.y)
        case .left: r = CGRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: r.height)
        case .right: r = CGRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: r.height)
        case .bottomLeft: r = CGRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: point.y - r.minY)
        case .bottom: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: point.y - r.minY)
        case .bottomRight: r = CGRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: point.y - r.minY)
        default: break
        }
        return r
    }

    private func translate(_ ann: Annotation, by delta: CGPoint) {
        switch ann.kind {
        case .arrow(let s, let e):
            ann.kind = .arrow(start: CGPoint(x: s.x + delta.x, y: s.y + delta.y),
                              end: CGPoint(x: e.x + delta.x, y: e.y + delta.y))
        case .line(let s, let e):
            ann.kind = .line(start: CGPoint(x: s.x + delta.x, y: s.y + delta.y),
                             end: CGPoint(x: e.x + delta.x, y: e.y + delta.y))
        case .pen(let points):
            ann.kind = .pen(points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) })
        case .rect(let r, let rounded):
            ann.kind = .rect(rect: r.offsetBy(dx: delta.x, dy: delta.y), rounded: rounded)
        case .ellipse(let r):
            ann.kind = .ellipse(rect: r.offsetBy(dx: delta.x, dy: delta.y))
        case .solidRect(let r, let rounded):
            ann.kind = .solidRect(rect: r.offsetBy(dx: delta.x, dy: delta.y), rounded: rounded)
        case .solidEllipse(let r):
            ann.kind = .solidEllipse(rect: r.offsetBy(dx: delta.x, dy: delta.y))
        case .text(let o, let c, let fs, let b, let bg):
            ann.kind = .text(origin: CGPoint(x: o.x + delta.x, y: o.y + delta.y),
                             content: c, fontSize: fs, bold: b, opaqueBackground: bg)
        case .number(let c, let v):
            ann.kind = .number(center: CGPoint(x: c.x + delta.x, y: c.y + delta.y), value: v)
        case .pastedImage(let o, let s, let img):
            ann.kind = .pastedImage(origin: CGPoint(x: o.x + delta.x, y: o.y + delta.y), size: s, image: img)
        case .mosaic(let r, let cell, let snap):
            ann.kind = .mosaic(rect: r.offsetBy(dx: delta.x, dy: delta.y), cellSize: cell, snapshot: snap)
        }
        tab?.markUnsaved()
    }

    private func pushUndo() {
        onWillMutate?()
    }

    var onWillMutate: (() -> Void)?

    func deleteSelected() {
        guard let tab, let ann = selectedAnnotation else { return }
        onWillMutate?()
        tab.annotations.removeAll { $0.id == ann.id }
        selectedAnnotation = nil
        tab.markUnsaved()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    // MARK: - Public ops used by editor VC

    func applyMosaicToSelection() {
        guard let tab, selectionRect.width > 2, selectionRect.height > 2 else { return }
        onWillMutate?()
        // Render current content and pixelate selection
        let rect = selectionRect.integral
        guard let region = tab.renderRegion(rect) else { return }
        let cell = max(style.mosaicCell, 2)
        let pixelated = pixelate(region, cell: cell)
        // Bake into the base image immediately — mosaic is a redaction, not a movable layer.
        bake(snapshot: pixelated, in: rect, crisp: true, into: &tab.baseImage)
        finishPixelEdit(on: tab)
    }

    /// 把刷子涂过的地方渲染成与底图同尺寸的单通道遮罩：255 = 擦除，0 = 保留。
    ///
    /// 云端 API 要求遮罩图和输入图分辨率一致，所以这里按底图的像素尺寸作画
    /// （画布上看到的半透明红只是预览，不是最终遮罩）。
    func renderEraseMask() -> [UInt8]? {
        guard let tab, hasEraseStrokes else { return nil }
        let width = tab.baseImage.width
        let height = tab.baseImage.height
        guard width > 0, height > 0 else { return nil }

        var mask = [UInt8](repeating: 0, count: width * height)
        let strokes = eraseStrokes + (currentStroke.map { [$0] } ?? [])

        let drawn = mask.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            for stroke in strokes {
                guard let first = stroke.points.first else { continue }
                ctx.setLineWidth(stroke.radius * 2)
                // 遮罩位图是 CG 的左下原点，涂抹点是图像的左上原点，y 要翻过来。
                if stroke.points.count == 1 {
                    ctx.fillEllipse(in: CGRect(x: first.x - stroke.radius,
                                               y: CGFloat(height) - first.y - stroke.radius,
                                               width: stroke.radius * 2,
                                               height: stroke.radius * 2))
                } else {
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: first.x, y: CGFloat(height) - first.y))
                    for point in stroke.points.dropFirst() {
                        ctx.addLine(to: CGPoint(x: point.x, y: CGFloat(height) - point.y))
                    }
                    ctx.strokePath()
                }
            }
            return true
        }
        return drawn ? mask : nil
    }

    /// 魔法消除：把选区交给火山引擎做云端擦除重建。
    ///
    /// 两种选法二选一，刷子优先 —— 那是用户一笔一笔涂出来的，意图最明确；
    /// 没有涂抹痕迹时退回矩形选区。跟马赛克一样是"直接改像素"，收尾走同一套。
    ///
    /// - Parameter onStage: 阶段文案，已切回主线程。
    func applyCloudEraseToSelection(
        apiKey: String,
        onStage: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let targetTab = tab, let patch = targetTab.renderComposite() else {
            completion(.failure(MediaKitClient.Error.encodeFailed))
            return
        }

        let mask = renderEraseMask()
        let rect = selectionRect
        let hasRect = rect.width > 2 && rect.height > 2
        guard mask != nil || hasRect else {
            completion(.failure(VolcEraseService.EraseError.noSelection))
            return
        }

        let reportStage: (VolcEraseService.Stage) -> Void = { stage in
            DispatchQueue.main.async { onStage(stage.rawValue) }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result: CGImage
                if let mask {
                    result = try VolcEraseService.eraseMask(
                        in: patch, mask: mask, apiKey: apiKey, onStage: reportStage)
                } else {
                    result = try VolcEraseService.eraseRect(
                        in: patch, region: rect, apiKey: apiKey, onStage: reportStage)
                }
                DispatchQueue.main.async {
                    // 云端往返期间用户可能换了页签，别把结果贴到别人身上。
                    guard let self, let liveTab = self.tab, liveTab === targetTab else {
                        completion(.failure(MediaKitClient.Error.encodeFailed))
                        return
                    }
                    self.onWillMutate?()
                    liveTab.baseImage = result
                    self.clearEraseStrokes()
                    self.finishPixelEdit(on: liveTab)
                    completion(.success("选区已用云端模型擦除并重建背景"))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - 提取内容（OCR）与 提取矢量图（云端抠图）的作用对象

    /// 「提取」类操作当前作用在什么上 —— 决定送出去的是哪一块像素。
    enum ExtractionScope: Equatable {
        /// 有浮动图层处于激活选中态：只认**这个图层自己的像素**，
        /// 不含它下面那一层（底图 / 别的图层）。
        case floatingLayer
        /// 橡皮筋框选：认框内的画面。
        case selection
        /// 什么都没选：整张图。
        case wholeImage

        /// 给用户的一句说明（进度浮层 / 结果提示用）。
        var label: String {
            switch self {
            case .floatingLayer: return "激活选中的浮动图层"
            case .selection: return "框选区域"
            case .wholeImage: return "整张图片"
            }
        }
    }

    /// 提取源的选择规则 —— 优先级：**激活选中的浮动图层 → 橡皮筋选区 → 整张图**。
    ///
    /// 单独抽成纯函数是为了能离屏验证：真跑一遍"选中浮动图层"要造鼠标事件，
    /// 而这条优先级本身就是最容易改错的地方（用户明确要求"有浮动块被选中时
    /// 只认那一块，不含它下面那一层"）。`ExtractionScopeCheck` 会遍历四种组合。
    static func extractionScope(floatingLayerSelected: Bool, rubberBandActive: Bool) -> ExtractionScope {
        if floatingLayerSelected { return .floatingLayer }
        if rubberBandActive { return .selection }
        return .wholeImage
    }

    /// 当前激活选中的浮动图层 —— 只有带自己像素的粘贴 / 抠图图层算数
    /// （形状、文字、序号是画上去的标注，没有独立像素）。
    private var selectedFloatingLayer: Annotation? {
        guard let ann = selectedAnnotation, case .pastedImage = ann.kind else { return nil }
        return ann
    }

    /// 当前生效的提取范围。
    var currentExtractionScope: ExtractionScope {
        Self.extractionScope(floatingLayerSelected: selectedFloatingLayer != nil,
                             rubberBandActive: selectionRect.width > 2 && selectionRect.height > 2)
    }

    /// 提取内容（OCR）要识别的图。
    ///
    /// 浮动图层走它自己的像素，透明底先垫成白底 —— 直接把透明 PNG 丢给识别模型，
    /// 透明区常被判成黑色块，文字就糊了。
    func contentExtractionImage() -> (image: CGImage, scope: ExtractionScope)? {
        guard let tab else { return nil }

        switch currentExtractionScope {
        case .floatingLayer:
            guard let ann = selectedFloatingLayer,
                  case .pastedImage(_, _, let layerImage) = ann.kind else { return nil }
            return (Self.flattenedOnWhite(layerImage) ?? layerImage, .floatingLayer)

        case .selection:
            guard let region = tab.renderRegion(selectionRect) else { return nil }
            return (region, .selection)

        case .wholeImage:
            guard let full = tab.renderComposite() else { return nil }
            return (full, .wholeImage)
        }
    }

    /// 抠图要上送的图 + 其中的目标区域 + **这张图左上角在画布坐标里的位置**。
    ///
    /// 与 OCR 的取图策略不同：抠图需要选区周围一圈上下文帮模型认清主体边缘，
    /// 所以框选时上送整张合成图 + 选区坐标；只有"选中的浮动图层"这一种情况
    /// 上送图层自身像素 —— 它本来就只有自己那一块，下面是别的层。
    /// 返回的 `anchor` 供结果落图层时把坐标平移回画布（否则会落到画布左上角）。
    func subjectExtractionPatch() -> (patch: CGImage, region: CGRect, anchor: CGPoint, scope: ExtractionScope)? {
        guard let tab else { return nil }

        switch currentExtractionScope {
        case .floatingLayer:
            guard let ann = selectedFloatingLayer,
                  case .pastedImage(let origin, let size, let layerImage) = ann.kind else { return nil }
            return (layerImage,
                    CGRect(x: 0, y: 0, width: size.width, height: size.height),
                    origin,
                    .floatingLayer)

        case .selection:
            guard let full = tab.renderComposite() else { return nil }
            return (full, selectionRect, .zero, .selection)

        case .wholeImage:
            // 整图没有"要抠的主体"可言 —— 交给调用方提示用户先框选。
            return nil
        }
    }

    /// 抠图的目标区域（画布坐标）。没有任何可抠目标时返回 nil —— 调用方据此弹提示。
    /// 优先级与 `subjectExtractionPatch()` 一致：选中的浮动图层优先于橡皮筋选区。
    func subjectRegion() -> CGRect? {
        if let ann = selectedFloatingLayer { return ann.boundingBox }
        if selectionRect.width >= 2, selectionRect.height >= 2 { return selectionRect }
        return nil
    }

    /// 把带 alpha 的图垫到白底上，得到不透明图。
    static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// 提取矢量图：把选区（或选中的浮动图层）交给火山引擎抠图，结果**落成透明底浮动图层**。
    ///
    /// 与马赛克 / 魔法消除不同 —— 它不改底图像素，而是新增一个可拖动、可缩放的图层，
    /// 落图层前压一次撤销快照（一步撤销即可移除）。
    ///
    /// - Parameters:
    ///   - cancel: UI 点「取消」时掐掉正在跑的请求。
    ///   - onStage: 阶段文案，已切回主线程。
    func extractSubjectFromSelection(
        apiKey: String,
        cancel: MediaKitClient.CancelToken,
        onStage: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let targetTab = tab, let source = subjectExtractionPatch() else {
            completion(.failure(VolcMattingService.MattingError.noSelection))
            return
        }

        let reportStage: (VolcMattingService.Stage) -> Void = { stage in
            DispatchQueue.main.async { onStage(stage.rawValue) }
        }

        let canvasSize = targetTab.pixelSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let subject = try VolcMattingService.extractSubject(
                    in: source.patch, region: source.region, anchor: source.anchor,
                    canvasSize: canvasSize, apiKey: apiKey,
                    cancel: cancel, onStage: reportStage
                )
                DispatchQueue.main.async {
                    // 云端往返期间用户可能换了页签，别把结果贴到别人身上。
                    guard let self, let liveTab = self.tab, liveTab === targetTab else {
                        completion(.failure(VolcMattingService.MattingError.targetChanged))
                        return
                    }
                    // 新图层是一步可撤销的操作，落笔前先压快照。
                    self.onWillMutate?()
                    let ann = Annotation(
                        kind: .pastedImage(origin: subject.origin,
                                           size: subject.size,
                                           image: subject.image),
                        color: self.style.color,
                        lineWidth: self.style.lineWidth
                    )
                    liveTab.annotations.append(ann)
                    liveTab.markUnsaved()
                    self.clearSelection()
                    self.selectedAnnotation = ann
                    self.onAnnotationsChanged?()
                    self.needsDisplay = true
                    // 新图层要能立刻拖动 / 缩放，所以停在「框选」工具上。
                    self.onRequestToolSwitch?(.select)
                    let label = VolcMattingService.sceneLabel(subject.scene)
                    completion(.success(
                        "已抠出主体（\(label)场景）\(Int(subject.size.width)) × \(Int(subject.size.height)) 像素，已选中并\(Self.placementText(subject.offset))，可拖动 / 缩放"
                    ))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }


    // MARK: - 查看模式：把编辑「定版」

    /// 「查看」模式下把画布上的编辑一次性定版：所有浮动元素（粘贴 / 抠出来的图层、
    /// 形状、画笔、文本、序号、马赛克）烙进底图，`annotations` 随之清空 ——
    /// 之后画布上就是"成品"，没有可再拖动 / 缩放的东西了。
    ///
    /// **顺序很重要**：先把当前的撤销快照压进去，再烘焙。这样"定版"本身也是一步操作，
    /// `⌘Z` 能把整套浮动元素原样还回来（不然定版就成了不可逆的破坏性动作）。
    ///
    /// - Returns: 真的定了版才返回 true（没有浮动元素时什么都不做，
    ///   免得往撤销栈里塞一个空快照）。
    @discardableResult
    func flattenEditsForViewMode() -> Bool {
        guard let tab, !tab.annotations.isEmpty, let flattened = tab.renderComposite() else {
            return false
        }
        onWillMutate?()          // 定版前的快照 —— 必须早于改 baseImage
        tab.baseImage = flattened
        tab.annotations.removeAll()
        selectedAnnotation = nil
        clearSelection()
        tab.markUnsaved()
        onAnnotationsChanged?()
        needsDisplay = true
        return true
    }

    /// 把"错开多少"翻译成一句人话（状态栏反馈用）。
    private static func placementText(_ offset: CGPoint) -> String {
        let dx = Int(offset.x.rounded())
        let dy = Int(offset.y.rounded())
        guard dx != 0 || dy != 0 else { return "原地摆放（主体比画布还大）" }
        var direction = ""
        direction += dy < 0 ? "上" : (dy > 0 ? "下" : "")
        direction += dx < 0 ? "左" : (dx > 0 ? "右" : "")
        let amount = dx == 0 || dy == 0 ? "\(max(abs(dx), abs(dy)))" : "\(abs(dx)) × \(abs(dy))"
        return "往\(direction)错开 \(amount) 像素摆放"
    }

    /// 直接改像素的操作（马赛克 / 魔法消除）收尾动作一致：落盘标记 + 收选区 + 重绘。
    private func finishPixelEdit(on tab: EditorTab) {
        tab.markUnsaved()
        clearSelection()
        selectedAnnotation = nil
        onAnnotationsChanged?()
        needsDisplay = true
    }

    /// Copy the base bitmap, hand the fresh context to `body`, then adopt
    /// whatever it drew. Every bake goes through here so the "flatten, draw,
    /// swap the image" plumbing lives in exactly one place.
    private func bake(into base: inout CGImage, _ body: (CGContext, Int, Int) -> Void) {
        let w = base.width
        let h = base.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        body(ctx, w, h)
        if let newImage = ctx.makeImage() {
            base = newImage
        }
    }

    /// Paste an already-rendered bitmap back onto the base image. `rect` uses
    /// annotation coordinates (top-left origin), hence the y-flip.
    /// `crisp` keeps the exact pixels — right for redactions like mosaic, where
    /// resampling would smear the block edges. Photographic content (magic
    /// erase) wants the smoothing instead, so it passes `false`.
    private func bake(snapshot: CGImage, in rect: CGRect, crisp: Bool, into base: inout CGImage) {
        bake(into: &base) { ctx, _, h in
            let r = rect.standardized
            let cgRect = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height)
            ctx.interpolationQuality = crisp ? .none : .high
            ctx.draw(snapshot, in: cgRect)
        }
    }

    /// Copy to clipboard. Priority: rubber-band selection → the selected
    /// shape's bounding region (framing with a drawing tool reads as a
    /// selection — e.g. a rectangle drawn with the 矩形 tool) → the whole
    /// composite. Returns a feedback message so it is always obvious what
    /// was copied.
    @discardableResult
    func copySelectionToClipboard() -> String? {
        guard let tab else { return nil }
        if selectionRect.width > 2, selectionRect.height > 2,
           let region = tab.renderRegion(selectionRect) {
            ClipboardService.writeImage(region)
            return "已复制选区 \(Int(region.width)) × \(Int(region.height)) 像素（⌘V 可粘贴为可拖动图层）"
        }
        if let ann = selectedAnnotation {
            // A floating pasted layer (e.g. a cut-moved selection) copies its
            // OWN pixels — excluding it would copy the white patch underneath.
            if case .pastedImage(_, let size, let image) = ann.kind {
                ClipboardService.writeImage(image)
                return "已复制选中图层 \(Int(size.width)) × \(Int(size.height)) 像素（⌘V 可粘贴）"
            }
            let box = ann.boundingBox.integral
            // Exclude the frame shape itself so its outline is not baked
            // into the copied pixels.
            if box.width >= 2, box.height >= 2, let region = tab.renderRegion(box, excluding: ann) {
                ClipboardService.writeImage(region)
                return "已复制选中图形所在区域 \(Int(region.width)) × \(Int(region.height)) 像素（⌘V 可粘贴）"
            }
        }
        if let full = tab.renderComposite() {
            ClipboardService.writeImage(full)
            return "已复制整张图片（框选局部区域后再 ⌘C 则只复制选区）"
        }
        return nil
    }

    /// Paste the clipboard image as a floating, draggable layer. With an active
    /// selection the copy lands slightly offset from the selection (not exactly
    /// on top — pasting in place made it look like nothing happened); without a
    /// selection it lands near the image center. Returns a feedback message.
    @discardableResult
    func pasteFromClipboard() -> String? {
        guard let tab, let img = ClipboardService.readImage() else { return nil }
        onWillMutate?()
        let imgSize = CGSize(width: img.width, height: img.height)
        // Place at former selection origin (offset so the copy is visible),
        // else near center — and leave the paste selected.
        let origin: CGPoint
        if selectionRect.width > 2 {
            let maxX = max(0, tab.pixelSize.width - imgSize.width)
            let maxY = max(0, tab.pixelSize.height - imgSize.height)
            origin = CGPoint(
                x: min(selectionRect.origin.x + 24, maxX),
                y: min(selectionRect.origin.y + 24, maxY)
            )
        } else {
            origin = CGPoint(x: tab.pixelSize.width / 4, y: tab.pixelSize.height / 4)
        }
        clearSelection()
        let ann = Annotation(
            kind: .pastedImage(origin: origin, size: imgSize, image: img),
            color: style.color,
            lineWidth: style.lineWidth
        )
        tab.annotations.append(ann)
        tab.markUnsaved()
        selectedAnnotation = ann
        onAnnotationsChanged?()
        needsDisplay = true
        // Pasted layer is what the user moves next.
        onRequestToolSwitch?(.select)
        return "已粘贴 \(Int(imgSize.width)) × \(Int(imgSize.height)) 像素（拖动放置，点击空白处固定）"
    }

    func updateText(annotation: Annotation, content: String, fontSize: CGFloat, bold: Bool, opaque: Bool) {
        guard case .text(let origin, _, _, _, _) = annotation.kind else { return }
        onWillMutate?()
        annotation.kind = .text(origin: origin, content: content, fontSize: fontSize, bold: bold, opaqueBackground: opaque)
        tab?.markUnsaved()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    func insertText(origin: CGPoint, content: String, fontSize: CGFloat, bold: Bool, opaque: Bool) {
        guard let tab, !content.isEmpty else { return }
        onWillMutate?()
        let ann = Annotation(
            kind: .text(origin: origin, content: content, fontSize: fontSize, bold: bold, opaqueBackground: opaque),
            color: style.color,
            lineWidth: style.lineWidth
        )
        tab.annotations.append(ann)
        tab.markUnsaved()
        selectedAnnotation = ann
        onAnnotationsChanged?()
        needsDisplay = true
        // After insert, user moves the text block; double-click / text tool edits content.
        onRequestToolSwitch?(.select)
    }

    func updateSelectedStyle() {
        guard let ann = selectedAnnotation else { return }
        onWillMutate?()
        ann.color = style.color
        ann.lineWidth = style.lineWidth
        tab?.markUnsaved()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    func applyCurrentStyleToSelected() {
        updateSelectedStyle()
    }

    private func pixelate(_ image: CGImage, cell: CGFloat) -> CGImage {
        let w = image.width
        let h = image.height
        let smallW = max(1, Int(CGFloat(w) / cell))
        let smallH = max(1, Int(CGFloat(h) / cell))

        // Downsample
        guard let ctxSmall = CGContext(
            data: nil, width: smallW, height: smallH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctxSmall.interpolationQuality = .low
        ctxSmall.draw(image, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let small = ctxSmall.makeImage() else { return image }

        // Upsample nearest
        guard let ctxBig = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctxBig.interpolationQuality = .none
        ctxBig.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctxBig.makeImage() ?? image
    }
}
