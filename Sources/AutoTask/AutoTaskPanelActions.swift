import Foundation

/// Builds the panel's action bundle, bound to a `TabManager`.
///
/// Both mount sites of the Auto-Tasks panel use this instead of repeating the
/// closures, for the same reason `GitLabSidebarView.init(workspace:tabManager:)`
/// exists: one behaviour, one implementation.
@MainActor
enum AutoTaskPanelActions {
    static func make(
        tabManager: TabManager,
        store: AutoTaskStore = .shared
    ) -> AutoTaskRowActions {
        AutoTaskRowActions(
            runNow: { id in
                // Go through the claim even for a manual run: another cmux
                // instance may be firing the same task at this exact moment.
                guard let claimed = store.claimForLaunch(id: id) else { return }
                AutoTaskLauncher.launch(claimed, tabManager: tabManager, store: store)
            },
            cancel: { id in store.cancel(id: id) },
            remove: { id in store.remove(id: id) },
            openChat: { id in
                guard let task = store.tasks.first(where: { $0.id == id }),
                      let panelId = task.chatPanelId,
                      let workspaceId = task.chatWorkspaceId,
                      let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                      workspace.panels[panelId] != nil else {
                    return
                }
                if tabManager.selectedTabId != workspaceId {
                    tabManager.selectedTabId = workspaceId
                }
                workspace.focusPanel(panelId)
            }
        )
    }
}
