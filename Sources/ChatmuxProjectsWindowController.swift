import AppKit
import SwiftUI

@MainActor
final class ChatmuxProjectsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ChatmuxProjectsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "projects.window.title",
            defaultValue: "Manage Projects"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.chatmuxProjectsManager")
        window.center()
        window.minSize = NSSize(width: 560, height: 360)
        window.contentView = NSHostingView(rootView: ChatmuxProjectsView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        ChatmuxProjectStore.shared.loadIfNeeded()
        if let window {
            if !window.isVisible { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
