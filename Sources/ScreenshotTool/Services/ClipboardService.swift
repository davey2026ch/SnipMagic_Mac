import AppKit

/// Full editor state snapshot. Mosaic and paste-commit bake pixels directly
/// into the tab's base image, so undo must restore both layers — an
/// annotations-only snapshot makes mosaic undo appear to do nothing.
struct EditorSnapshot {
    let annotations: [Annotation]
    let baseImage: CGImage
}

final class UndoStack {
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private let limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Snapshot current state before a mutation.
    func push(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > limit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return prev
    }

    func redo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
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
