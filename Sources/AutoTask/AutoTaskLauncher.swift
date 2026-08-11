import Foundation

/// Turns a `ScheduledAutoTask` into a running chat.
///
/// Sits on top of the same path a typed command takes: a chat is opened and
/// `/auto-task <iid>` is sent verbatim, because the CLI — running as
/// `claude -p --input-format stream-json`, a streaming session — expands slash
/// commands itself. See `ChatSlashCommandLauncher`.
///
/// Two things make a scheduled run different from clicking the menu item:
///
/// - It targets **its own repository**, not whichever workspace is selected
///   when the timer fires.
/// - It runs in `.auto` (`bypassPermissions`). Any other mode stops at the
///   first approval card, and at 03:00 nobody is there to answer it.
@MainActor
enum AutoTaskLauncher {
    /// The `/`-less name of the markdown command.
    static let commandName = "auto-task"

    enum Failure: Error, Equatable {
        case noWorkspaceOpen(String)
        case commandNotInstalled
        case couldNotOpenChat

        /// Shown verbatim in the task row, so it has to say what to do next.
        var message: String {
            switch self {
            case .noWorkspaceOpen(let path):
                return String(
                    localized: "autoTask.failure.noWorkspace",
                    defaultValue: "No workspace open on \(path). Open it and run the task again."
                )
            case .commandNotInstalled:
                return String(
                    localized: "autoTask.failure.commandMissing",
                    defaultValue: "/auto-task is not installed in this repository."
                )
            case .couldNotOpenChat:
                return String(
                    localized: "autoTask.failure.noChat",
                    defaultValue: "Could not open a chat tab for this run."
                )
            }
        }
    }

    /// Launch a task that has already been claimed by the caller.
    ///
    /// Claiming and launching are separate on purpose: the claim is the
    /// cross-instance race guard (`AutoTaskStore.claimForLaunch`), and it has to
    /// win *before* any UI is touched.
    static func launch(
        _ task: ScheduledAutoTask,
        tabManager: TabManager,
        store: AutoTaskStore = .shared
    ) {
        switch resolve(task, tabManager: tabManager) {
        case .failure(let failure):
            store.markFailed(id: task.id, reason: failure.message)
        case .success(let opened):
            opened.panel.send("/\(commandName) \(task.issueIID)")
            store.attachChat(
                id: task.id,
                panelId: opened.panel.id,
                workspaceId: opened.workspaceId
            )
        }
    }

    private struct OpenedChat {
        let panel: ClaudeChatPanel
        let workspaceId: UUID
    }

    /// Open the chat for a task, or say why it cannot happen.
    ///
    /// A scheduled run deliberately does **not** open a workspace on the user's
    /// behalf. Waking up to windows that opened themselves overnight, with an
    /// unattended agent already editing files in them, is worse than finding a
    /// task that says why it did not run.
    private static func resolve(
        _ task: ScheduledAutoTask,
        tabManager: TabManager
    ) -> Result<OpenedChat, Failure> {
        guard let workspace = tabManager.workspace(forDirectory: task.repositoryPath) else {
            return .failure(.noWorkspaceOpen(task.repositoryPath))
        }
        guard SlashCommandRegistry.command(named: commandName, cwd: task.repositoryPath) != nil else {
            return .failure(.commandNotInstalled)
        }
        guard let panel = tabManager.openClaudeChatPanel(
            workingDirectory: task.repositoryPath,
            inWorkspace: workspace,
            permissionMode: .auto
        ) else {
            return .failure(.couldNotOpenChat)
        }
        return .success(OpenedChat(panel: panel, workspaceId: workspace.id))
    }

    /// Whether `/auto-task` is reachable from `directory` — drives whether the
    /// menu items are offered at all.
    nonisolated static func isAvailable(directory: String) -> Bool {
        SlashCommandRegistry.command(
            named: commandName,
            cwd: directory.isEmpty ? nil : directory
        ) != nil
    }

    /// Run one right now from the UI, recording it in the queue so the panel
    /// shows launched runs alongside scheduled ones.
    static func runNow(
        issueIID: Int,
        issueTitle: String,
        repositoryPath: String,
        projectId: UUID?,
        tabManager: TabManager,
        store: AutoTaskStore = .shared,
        now: Date = Date()
    ) {
        let task = ScheduledAutoTask(
            issueIID: issueIID,
            issueTitle: issueTitle,
            repositoryPath: repositoryPath,
            projectId: projectId,
            scheduledAt: now
        )
        store.add(task)
        guard let claimed = store.claimForLaunch(id: task.id, now: now) else { return }
        launch(claimed, tabManager: tabManager, store: store)
    }

    /// Put one in the queue for later.
    static func schedule(
        issueIID: Int,
        issueTitle: String,
        repositoryPath: String,
        projectId: UUID?,
        at date: Date,
        store: AutoTaskStore = .shared
    ) {
        store.add(
            ScheduledAutoTask(
                issueIID: issueIID,
                issueTitle: issueTitle,
                repositoryPath: repositoryPath,
                projectId: projectId,
                scheduledAt: date
            )
        )
    }

    /// The project a workspace belongs to, if it is a saved one.
    ///
    /// This is the whole ownership rule: a task belongs to the project you
    /// scheduled it *from*, never to one deduced from its directory. That is
    /// what lets a project hold tasks for a worktree, or for an unrelated
    /// repository, exactly as a workspace holds tabs for any directory.
    static func owningProjectId(for workspace: Workspace) -> UUID? {
        let store = ChatmuxProjectStore.shared
        store.loadIfNeeded()
        return store.project(forWorkspaceStableId: workspace.stableId)?.id
    }
}
