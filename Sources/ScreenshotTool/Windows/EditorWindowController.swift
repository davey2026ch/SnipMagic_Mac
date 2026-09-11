import AppKit

final class EditorWindow: NSWindow {
    override func close() {
        // Close == minimize, keep app running in background
        miniaturize(nil)
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) var editorVC: EditorViewController!

    init() {
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("EditorWindow")

        super.init(window: window)
        window.delegate = self

        editorVC = EditorViewController()
        window.contentViewController = editorVC
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showAndActivate() {
        showWindow(nil)
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Close = minimize
        sender.miniaturize(nil)
        return false
    }
}
