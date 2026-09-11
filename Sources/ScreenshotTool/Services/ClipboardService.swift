import AppKit

final class UndoStack {
    private(set) var undoStack: [[Annotation]] = []
    private(set) var redoStack: [[Annotation]] = []
    private let limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Snapshot current annotations before a mutation.
    func push(_ annotations: [Annotation]) {
        undoStack.append(annotations)
        if undoStack.count > limit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo(current: [Annotation]) -> [Annotation]? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current.map { $0.copyAnnotation() })
        return prev
    }

    func redo(current: [Annotation]) -> [Annotation]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current.map { $0.copyAnnotation() })
        return next
    }
}

enum ClipboardService {
    static func writeImage(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    static func readImage() -> CGImage? {
        let pb = NSPasteboard.general
        if let items = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = items.first {
            var rect = CGRect(origin: .zero, size: CGSize(width: img.size.width, height: img.size.height))
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }
}
