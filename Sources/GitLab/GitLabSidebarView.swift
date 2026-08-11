import SwiftUI

enum GitLabSidebarTab: String, CaseIterable, Identifiable {
    case mergeRequests
    case issues
    case pipelines
    case releases

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mergeRequests:
            return String(localized: "gitlab.tab.mrs", defaultValue: "MRs")
        case .pipelines:
            return String(localized: "gitlab.tab.pipelines", defaultValue: "Pipelines")
        case .issues:
            return String(localized: "gitlab.tab.issues", defaultValue: "Issues")
        case .releases:
            return String(localized: "gitlab.tab.releases", defaultValue: "Releases")
        }
    }

    var icon: String {
        switch self {
        case .mergeRequests: return "arrow.triangle.merge"
        case .pipelines: return "circle.dashed"
        case .issues: return "exclamationmark.circle"
        case .releases: return "tag"
        }
    }
}

struct GitLabSidebarView: View {
    @ObservedObject var workspace: Workspace
    /// Start `/start-task <iid>` for an issue in a new chat tab. Supplied by
    /// the container that owns the `TabManager`.
    var onStartTask: ((Int) -> Void)? = nil
    /// Same, for `/mr-review <iid>` on a merge request.
    var onReviewMergeRequest: ((Int) -> Void)? = nil
    /// Run `/auto-task <iid>` now, or queue it for a date. Both carry the issue
    /// title so the auto-task queue can render without going back to GitLab.
    var onRunAutoTask: ((Int, String) -> Void)? = nil
    var onScheduleAutoTask: ((Int, String, Date) -> Void)? = nil
    @State private var selectedTab: GitLabSidebarTab = .mergeRequests

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle()
                .fill(Color.darculaBorder)
                .frame(height: 1)
            content
        }
        .background(Color.darculaSidebarBackground)
        // Preserve the selected sub-tab per workspace: restore it on appear and
        // when the workspace changes, and persist every change.
        .onAppear {
            selectedTab = GitLabSidebarTabStore.shared.tab(for: workspace.id)
        }
        .onChange(of: workspace.id) { newWorkspaceId in
            selectedTab = GitLabSidebarTabStore.shared.tab(for: newWorkspaceId)
        }
        .onChange(of: selectedTab) { newTab in
            GitLabSidebarTabStore.shared.setTab(newTab, for: workspace.id)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(GitLabSidebarTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Button {
                showWorkingTreeDiff()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.darculaForeground.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.darculaCardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(workspace.currentDirectory.isEmpty)
            .help(String(
                localized: "gitlab.sidebar.showWorkingTreeDiff",
                defaultValue: "Show working tree diff"
            ))
            .padding(.trailing, 8)
        }
    }

    private func showWorkingTreeDiff() {
        guard !workspace.currentDirectory.isEmpty else { return }
        let spec = GitDiffSpec(
            base: "HEAD",
            compare: nil,
            directory: workspace.currentDirectory,
            title: String(localized: "diff.workingTree.title", defaultValue: "Working tree")
        )
        GitDiffWindowRegistry.show(spec: spec)
    }

    private func tabButton(_ tab: GitLabSidebarTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
            }
            .foregroundStyle(isSelected ? Color.darculaAccent : Color.darculaForeground.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.darculaAccent.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.darculaAccent.opacity(0.45) : Color.clear,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .mergeRequests:
            MergeRequestsListView(workspace: workspace, onReview: onReviewMergeRequest)
        case .pipelines:
            PipelinesListView(workspace: workspace)
        case .issues:
            IssuesListView(
                workspace: workspace,
                onStartTask: onStartTask,
                onRunAutoTask: onRunAutoTask,
                onScheduleAutoTask: onScheduleAutoTask
            )
        case .releases:
            ReleasesListView(workspace: workspace)
        }
    }
}

/// The chat commands the GitLab sidebar can start for the object under the
/// cursor. Each is a user-authored markdown command under `.claude/commands/`,
/// not something cmux ships — hence `isAvailable`.
enum GitLabChatCommand {
    /// Issues tab → `/start-task <iid>`.
    case startTask
    /// MRs tab → `/mr-review <iid>`.
    case reviewMergeRequest

    /// The `/`-less command name. Must match the markdown filename.
    var commandName: String {
        switch self {
        case .startTask: return "start-task"
        case .reviewMergeRequest: return "mr-review"
        }
    }
}

/// Bridges "act on this issue / MR" from the GitLab sidebar into the chat:
/// opens a new Claude Chat tab in the selected workspace and sends
/// `/<command> <iid>` as if the user had typed it, leaving the CLI to expand
/// the command.
///
/// Mirrors `SessionEntryResumeCoordinator`: the sidebar views take a plain
/// closure, and the container that owns the `TabManager` binds it here.
extension GitLabSidebarView {
    /// Bind every sidebar action to a workspace and the tab manager.
    ///
    /// Both mount sites (`RightSidebarToolPanelView` and `RightSidebarPanelView`)
    /// need the same four closures; without this they drift apart, which is
    /// exactly what the shared-behavior rule in `CLAUDE.md` exists to prevent.
    @MainActor
    init(workspace: Workspace, tabManager: TabManager) {
        self.init(
            workspace: workspace,
            onStartTask: { iid in
                GitLabChatCommandCoordinator.run(
                    .startTask, iid: iid, workspace: workspace, tabManager: tabManager
                )
            },
            onReviewMergeRequest: { iid in
                GitLabChatCommandCoordinator.run(
                    .reviewMergeRequest, iid: iid, workspace: workspace, tabManager: tabManager
                )
            },
            onRunAutoTask: { iid, title in
                AutoTaskLauncher.runNow(
                    issueIID: iid,
                    issueTitle: title,
                    repositoryPath: workspace.currentDirectory,
                    projectId: AutoTaskLauncher.owningProjectId(for: workspace),
                    tabManager: tabManager
                )
            },
            onScheduleAutoTask: { iid, title, date in
                AutoTaskLauncher.schedule(
                    issueIID: iid,
                    issueTitle: title,
                    repositoryPath: workspace.currentDirectory,
                    projectId: AutoTaskLauncher.owningProjectId(for: workspace),
                    at: date
                )
            }
        )
    }
}

enum GitLabChatCommandCoordinator {
    @MainActor
    static func run(
        _ command: GitLabChatCommand,
        iid: Int,
        workspace: Workspace,
        tabManager: TabManager
    ) {
        let directory = workspace.currentDirectory
        ChatSlashCommandLauncher.openChat(
            running: command.commandName,
            arguments: String(iid),
            workingDirectory: directory.isEmpty ? nil : directory,
            tabManager: tabManager,
            // Same reason `/auto-task` runs this way: these commands carry out
            // a whole flow — branch, worktree, edits, MR — and answering an
            // approval card per tool is not what you asked for when you picked
            // the item out of a context menu.
            permissionMode: .auto
        )
    }

    /// Whether the command's markdown file is reachable from `directory`
    /// (project scope) or the user's home. A menu item that resolves to
    /// nothing is worse than no menu item.
    ///
    /// This is a filesystem scan: resolve it once per directory, from
    /// `onAppear`/`onChange`, never per row and never from `body`.
    static func isAvailable(_ command: GitLabChatCommand, directory: String) -> Bool {
        SlashCommandRegistry.command(
            named: command.commandName,
            cwd: directory.isEmpty ? nil : directory
        ) != nil
    }
}

/// Persists the selected GitLab sidebar sub-tab per workspace so switching
/// workspaces and returning keeps you on the same tab (survives the
/// `.id(ws.id)` view recreation and app restarts). Mirrors the per-workspace
/// `GitLabIssueFiltersStore`.
@MainActor
final class GitLabSidebarTabStore {
    static let shared = GitLabSidebarTabStore()

    private let defaultsKey = "gitlab.sidebar.selectedTabByWorkspace"
    private var tabsByWorkspaceId: [String: String]

    private init() {
        tabsByWorkspaceId = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    func tab(for workspaceId: UUID) -> GitLabSidebarTab {
        guard let raw = tabsByWorkspaceId[workspaceId.uuidString],
              let tab = GitLabSidebarTab(rawValue: raw) else {
            return .mergeRequests
        }
        return tab
    }

    func setTab(_ tab: GitLabSidebarTab, for workspaceId: UUID) {
        guard tabsByWorkspaceId[workspaceId.uuidString] != tab.rawValue else { return }
        tabsByWorkspaceId[workspaceId.uuidString] = tab.rawValue
        UserDefaults.standard.set(tabsByWorkspaceId, forKey: defaultsKey)
    }
}
