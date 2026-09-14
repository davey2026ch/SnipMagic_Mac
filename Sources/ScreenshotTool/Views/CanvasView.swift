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
        let factor: CGFloat = deltaY > 0 ? 1.1 : 1 / 1.1
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

    override func mouseDown(with event: NSEvent) {
        guard tab != nil else { return }
        window?.makeFirstResponder(self)
        let p = imagePoint(from: event)

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
    /// (cut-style: a white patch covers the original pixels; undo restores both).
    private func beginFloatingSelectionMove(at p: CGPoint) {
        guard let tab = tab,
              selectionRect.width > 2, selectionRect.height > 2,
              let region = tab.renderRegion(selectionRect) else { return }

        onWillMutate?()
        let origin = selectionRect.origin
        let size = CGSize(width: region.width, height: region.height)
        let rect = selectionRect.standardized

        // White patch stays behind so lifting the layer looks like a cut.
        let patch = Annotation(
            kind: .solidRect(rect: rect, rounded: false),
            color: .white,
            lineWidth: 1
        )
        tab.annotations.append(patch)

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
        let ann = Annotation(kind: .mosaic(rect: rect, cellSize: cell, snapshot: pixelated),
                             color: style.color, lineWidth: style.lineWidth)
        // Bake into the base image immediately — mosaic is a redaction, not a movable layer.
        bake(annotation: ann, into: &tab.baseImage)
        tab.markUnsaved()
        clearSelection()
        selectedAnnotation = nil
        onAnnotationsChanged?()
        needsDisplay = true
    }

    /// Draw one annotation onto a copy of the base bitmap (top-left coords).
    private func bake(annotation ann: Annotation, into base: inout CGImage) {
        let w = base.width
        let h = base.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Mosaic/paste snapshots are bitmaps — draw them in unflipped CG space
        // (top-left annotation coords → bottom-left CG y).
        switch ann.kind {
        case .mosaic(let rect, _, let snapshot):
            let r = rect.standardized
            let cgRect = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height)
            ctx.interpolationQuality = .none
            ctx.draw(snapshot, in: cgRect)
        case .pastedImage(let origin, let size, let image):
            let cgRect = CGRect(
                x: origin.x,
                y: CGFloat(h) - origin.y - size.height,
                width: size.width,
                height: size.height
            )
            ctx.interpolationQuality = .high
            ctx.draw(image, in: cgRect)
        default:
            // Vector annotations still need the top-left flip.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            AnnotationRenderer.draw(ann, in: ctx, flipped: true)
            NSGraphicsContext.restoreGraphicsState()
        }

        if let newImage = ctx.makeImage() {
            base = newImage
        }
    }

    func copySelectionToClipboard() {
        guard let tab else { return }
        // With a selection: copy that region. Without: copy the whole composite.
        if selectionRect.width > 2, selectionRect.height > 2 {
            if let region = tab.renderRegion(selectionRect) {
                ClipboardService.writeImage(region)
            }
        } else if let full = tab.renderComposite() {
            ClipboardService.writeImage(full)
        }
    }

    func pasteFromClipboard() {
        guard let tab, let img = ClipboardService.readImage() else { return }
        onWillMutate?()
        // Place at former selection origin, else near center — and leave the paste selected.
        let origin: CGPoint
        if selectionRect.width > 2 {
            origin = selectionRect.origin
        } else {
            origin = CGPoint(x: tab.pixelSize.width / 4, y: tab.pixelSize.height / 4)
        }
        clearSelection()
        let ann = Annotation(
            kind: .pastedImage(origin: origin, size: CGSize(width: img.width, height: img.height), image: img),
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
