import AppKit
import Foundation

/// Saving and reopening a single workspace as a `ChatmuxProject`.
///
/// Everything here delegates to machinery that already exists for closing and
/// reopening a workspace: `Workspace.sessionSnapshot` captures, and
/// `TabManager.restoreClosedWorkspace` rebuilds. A project is that same
/// snapshot with a name, a permanent home, and no consumption on reopen.
extension AppDelegate {
    // MARK: - Lookup

    /// The live workspace a project is bound to, if it is currently open.
    /// Keyed on `Workspace.stableId`, which round-trips through the snapshot.
    @MainActor
    func liveWorkspace(forStableId stableId: UUID) -> (manager: TabManager, workspace: Workspace)? {
        for context in mainWindowContexts.values {
            if let workspace = context.tabManager.tabs.first(where: { $0.stableId == stableId }) {
                return (context.tabManager, workspace)
            }
        }
        return nil
    }

    /// The project a live workspace belongs to, if any.
    @MainActor
    func project(for workspace: Workspace) -> ChatmuxProject? {
        let store = ChatmuxProjectStore.shared
        store.loadIfNeeded()
        return store.project(forWorkspaceStableId: workspace.stableId)
    }

    // MARK: - Saving

    /// Capture a workspace for storage. No scrollback: a project is meant to
    /// be reopened weeks later, and stale terminal output is both large and
    /// worthless by then — the terminals come back clean in their cwd.
    @MainActor
    func projectSnapshot(for workspace: Workspace) -> SessionWorkspaceSnapshot {
        workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                ?? RestorableAgentSessionIndex.load()
        )
    }

    @discardableResult
    @MainActor
    func saveWorkspaceAsProject(_ workspace: Workspace, name: String) -> ChatmuxProject? {
        let store = ChatmuxProjectStore.shared
        store.loadIfNeeded()
        return store.create(
            name: name,
            workspaceStableId: workspace.stableId,
            snapshot: projectSnapshot(for: workspace)
        )
    }

    /// Refresh the project bound to a workspace that is closing.
    ///
    /// Called from `TabManager.closeWorkspace` with the snapshot it already
    /// captured for the closed-item history, so closing never pays for a
    /// second capture on the main thread. Scrollback is stripped here rather
    /// than re-capturing without it.
    @MainActor
    func updateProjectForClosingWorkspace(
        stableId: UUID,
        snapshot: SessionWorkspaceSnapshot
    ) {
        let store = ChatmuxProjectStore.shared
        store.loadIfNeeded()
        guard let project = store.project(forWorkspaceStableId: stableId) else { return }
        var stripped = snapshot
        for index in stripped.panels.indices {
            stripped.panels[index].terminal?.scrollback = nil
        }
        store.update(id: project.id, snapshot: stripped)
    }

    // MARK: - Opening

    /// Open a project, or focus it when it is already open.
    ///
    /// Reopening a project that already has a live workspace would produce two
    /// workspaces claiming the same chat sessions, so the live one wins.
    @discardableResult
    @MainActor
    func openProject(_ project: ChatmuxProject) -> Bool {
        let store = ChatmuxProjectStore.shared
        store.loadIfNeeded()

        if let live = liveWorkspace(forStableId: project.workspaceStableId) {
            live.manager.selectWorkspace(live.workspace)
            if let windowId = windowId(for: live.manager) {
                _ = focusMainWindow(windowId: windowId)
            }
            store.markOpened(id: project.id)
            return true
        }

        guard let manager = tabManager ?? mainWindowContexts.values.first?.tabManager else {
            return false
        }
        // `closeWorkspace` refuses to close the last workspace, so the empty
        // one has to go *after* the project is in place, not before.
        let emptyWorkspace = manager.selectedWorkspace.flatMap { $0.panels.isEmpty ? $0 : nil }

        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: project.snapshot.workspaceId ?? UUID(),
            windowId: windowId(for: manager),
            workspaceIndex: manager.tabs.count,
            snapshot: project.snapshot
        )
        guard manager.restoreClosedWorkspace(entry) else { return false }

        if let emptyWorkspace, manager.tabs.count > 1 {
            manager.closeWorkspace(emptyWorkspace, recordHistory: false)
        }
        if let windowId = windowId(for: manager) {
            _ = focusMainWindow(windowId: windowId)
        }
        store.markOpened(id: project.id)
        return true
    }

    // MARK: - Prompts

    @MainActor
    func presentSaveCurrentWorkspaceAsProjectPrompt() {
        guard let workspace = tabManager?.selectedWorkspace else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "projects.dialog.noWorkspace.title",
                defaultValue: "Nothing to save"
            )
            alert.informativeText = String(
                localized: "projects.dialog.noWorkspace.message",
                defaultValue: "There is no open workspace to save as a project."
            )
            alert.runModal()
            return
        }

        if let existing = project(for: workspace) {
            // Already a project: saving again would create a second claim on
            // the same workspace, so refresh instead.
            ChatmuxProjectStore.shared.update(
                id: existing.id,
                snapshot: projectSnapshot(for: workspace)
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "projects.dialog.saveProject.title",
            defaultValue: "Save Workspace as Project"
        )
        alert.informativeText = String(
            localized: "projects.dialog.saveProject.message",
            defaultValue: "Choose a name for this project."
        )
        let input = NSTextField(string: workspace.customTitle ?? workspace.processTitle)
        input.placeholderString = String(
            localized: "projects.dialog.saveProject.placeholder",
            defaultValue: "Project name"
        )
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveWorkspaceAsProject(workspace, name: trimmed)
    }

    @MainActor
    func presentManageChatmuxProjects() {
        ChatmuxProjectStore.shared.loadIfNeeded()
        ChatmuxProjectsWindowController.shared.show()
    }
}
