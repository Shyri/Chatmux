import AppKit
import SwiftUI

/// The one path that opens a new chat.
///
/// Every entrypoint — the File menu item and the tab bar's `newClaudeChat`
/// button — goes through `present(over:tabManager:)`, so "new chat" behaves the
/// same wherever it is invoked. Adding a third entrypoint means calling this,
/// not repeating the panel setup.
///
/// Browsing is a real `NSOpenPanel`: favourites sidebar, search, path bar,
/// ⌘⇧G, tags, network volumes — the picker users already know. The only thing
/// AppKit does not provide is "which agent sessions already live in the folder
/// I am pointing at", and that rides along in the panel's `accessoryView`.
@MainActor
final class NewChatLauncher: NSObject, NSOpenSavePanelDelegate {
    static let shared = NewChatLauncher()

    /// Its own store, deliberately not the right sidebar's: scoping the shared
    /// store to whatever folder the panel is browsing would rewrite what the
    /// Vault is showing behind it.
    private let sessionStore = SessionIndexStore()
    private var panel: NSOpenPanel?
    private var accessoryHost: NSHostingView<NewChatLauncherAccessory>?
    private var onOpen: ((_ directory: String, _ sessionId: String?) -> Void)?

    private override init() {
        super.init()
    }

    /// Present over `host` and open the chosen chat in `tabManager`.
    func present(
        over host: NSWindow?,
        tabManager: TabManager,
        initialDirectory: String? = nil
    ) {
        present(over: host, initialDirectory: initialDirectory) { directory, sessionId in
            _ = tabManager.openClaudeChat(
                resumingSessionId: sessionId,
                workingDirectory: directory
            )
        }
    }

    func present(
        over host: NSWindow?,
        initialDirectory: String? = nil,
        open: @escaping (_ directory: String, _ sessionId: String?) -> Void
    ) {
        // A second invocation while the panel is up should focus it, not stack
        // another sheet on the same window.
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        onOpen = open

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(
            localized: "newChat.launcher.open",
            defaultValue: "New Chat Here"
        )
        panel.message = String(
            localized: "newChat.launcher.message",
            defaultValue: "Choose a folder for the chat, or resume a session in it."
        )
        // Start where the workspace already is: opening a chat almost always
        // means "here", so home would cost a navigation every single time.
        panel.directoryURL = initialDirectory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        panel.delegate = self
        self.panel = panel

        installAccessory(on: panel, directory: panel.directoryURL?.path)
        updateDirectory(panel.directoryURL?.path)

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            let chosen = panel.urls.first?.path ?? panel.directoryURL?.path
            self.teardown()
            guard response == .OK, let chosen else { return }
            open(chosen, nil)
        }

        if let host {
            panel.beginSheetModal(for: host, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    // MARK: - NSOpenSavePanelDelegate

    /// Fires as the user moves through the hierarchy, which is what keeps the
    /// session list showing the folder actually under the cursor rather than
    /// the one the panel opened on.
    func panelSelectionDidChange(_ sender: Any?) {
        guard let panel = sender as? NSOpenPanel else { return }
        updateDirectory(panel.urls.first?.path ?? panel.directoryURL?.path)
    }

    // MARK: - Private

    private func installAccessory(on panel: NSOpenPanel, directory: String?) {
        let view = NewChatLauncherAccessory(
            sessionStore: sessionStore,
            directory: directory,
            onResume: { [weak self] entry in
                guard let self else { return }
                // Resuming answers the panel's question, so close it the same
                // way OK would and hand the session to the caller.
                let cwd = self.currentDirectory ?? entry.cwd
                let open = self.onOpen
                self.dismiss()
                guard let cwd else { return }
                open?(cwd, entry.sessionId)
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
        accessoryHost = host
        panel.accessoryView = host
        panel.isAccessoryViewDisclosed = true
    }

    private var currentDirectory: String?

    private func updateDirectory(_ directory: String?) {
        currentDirectory = directory
        sessionStore.setCurrentDirectoryIfChanged(directory)
        guard let accessoryHost else { return }
        accessoryHost.rootView = NewChatLauncherAccessory(
            sessionStore: sessionStore,
            directory: directory,
            onResume: accessoryHost.rootView.onResume
        )
    }

    private func dismiss() {
        panel?.cancel(nil)
    }

    private func teardown() {
        panel?.delegate = nil
        panel = nil
        accessoryHost = nil
        onOpen = nil
        currentDirectory = nil
        // Stop the session index from tracking a folder nobody is looking at.
        sessionStore.setCurrentDirectoryIfChanged(nil)
    }
}
