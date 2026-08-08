import SwiftUI
import AppKit

// MARK: - MR List State

@MainActor
final class MergeRequestsState: ObservableObject {
    @Published var mergeRequests: [GitLabMergeRequest] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastDirectory: String?
    @Published private(set) var projectWebURL: String?
    /// Project members fetched lazily via `glab api projects/:id/members/all`,
    /// surfaced in the "Assignee" submenu on each MR card. Empty until the
    /// first refresh comes back; the submenu falls back to the visible
    /// candidates while it's pending.
    @Published private(set) var projectMembers: [GitLabProjectMember] = []
    /// The currently authenticated GitLab user; powers "Assign to me" in the
    /// context menu. `nil` until `glab api user` succeeds.
    @Published private(set) var currentUser: GitLabProjectMember?

    private var fetchTask: Task<Void, Never>?
    private var approvalsTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var membersTask: Task<Void, Never>?
    private var currentUserTask: Task<Void, Never>?
    private var requestCounter: UInt64 = 0

    func refresh(directory: String) {
        fetchTask?.cancel()
        approvalsTask?.cancel()
        remoteTask?.cancel()
        membersTask?.cancel()
        currentUserTask?.cancel()
        requestCounter &+= 1
        let token = requestCounter

        if lastDirectory != directory {
            mergeRequests = []
            projectWebURL = nil
            projectMembers = []
            currentUser = nil
        }
        lastDirectory = directory
        isLoading = true
        errorMessage = nil

        remoteTask = Task { [weak self] in
            let url = await gitLabProjectWebURL(directory: directory)
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter,
                  directory == self.lastDirectory else { return }
            self.projectWebURL = url
        }

        currentUserTask = Task { [weak self] in
            let user = try? await fetchGitLabCurrentUser(in: directory)
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter,
                  directory == self.lastDirectory else { return }
            self.currentUser = user
        }

        fetchTask = Task { [weak self] in
            let result: Result<[GitLabMergeRequest], Error>
            do {
                result = .success(try await fetchGitLabMergeRequests(in: directory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter, directory == self.lastDirectory else {
                return
            }

            switch result {
            case .success(let mrs):
                self.mergeRequests = mrs
                self.errorMessage = nil
                self.loadApprovals(for: mrs, directory: directory, token: token)
                self.loadProjectMembers(for: mrs, directory: directory, token: token)
            case .failure(let error):
                self.mergeRequests = []
                self.errorMessage = self.messageFor(error: error)
            }
            self.isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        approvalsTask?.cancel()
        remoteTask?.cancel()
        membersTask?.cancel()
        currentUserTask?.cancel()
        requestCounter &+= 1
        mergeRequests = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
        projectWebURL = nil
        projectMembers = []
        currentUser = nil
    }

    /// Loads the project's member list once per refresh so the assignee
    /// submenu can offer any member, not just the ones already visible on
    /// the open MRs. Picks the first MR with a real `projectId` — every MR
    /// in the panel belongs to the same project.
    private func loadProjectMembers(
        for mrs: [GitLabMergeRequest],
        directory: String,
        token: UInt64
    ) {
        guard let projectId = mrs.first(where: { $0.projectId > 0 })?.projectId else {
            self.projectMembers = []
            return
        }
        membersTask = Task { [weak self] in
            let members = (try? await fetchGitLabProjectMembers(
                projectId: projectId,
                in: directory
            )) ?? []
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter,
                  directory == self.lastDirectory else { return }
            self.projectMembers = members
        }
    }

    /// Optimistically replaces a single MR's assignees with `assignee` (or
    /// clears them when `assignee` is `nil`), then issues the `glab mr update`
    /// subcommand. On failure the assignee list is rolled back and an
    /// `NSAlert` is presented; on success the panel is refreshed to reconcile
    /// with the server.
    func setAssignee(
        mrIID: Int,
        to assignee: GitLabReviewer?,
        directory: String
    ) {
        guard let idx = mergeRequests.firstIndex(where: { $0.iid == mrIID }) else { return }
        let previous = mergeRequests[idx].assignees
        mergeRequests[idx].assignees = assignee.map { [$0] } ?? []

        Task { [weak self] in
            do {
                try await updateGitLabMRAssignee(
                    iid: mrIID,
                    assigneeUsername: assignee?.username,
                    in: directory
                )
                guard let self else { return }
                self.refresh(directory: directory)
            } catch {
                guard let self else { return }
                if let i = self.mergeRequests.firstIndex(where: { $0.iid == mrIID }) {
                    self.mergeRequests[i].assignees = previous
                }
                MergeRequestsState.presentAssigneeError(error)
            }
        }
    }

    @MainActor
    private static func presentAssigneeError(_ error: Error) {
        let message: String
        if let mrErr = error as? GitLabMRFetchError,
           case let .processError(msg) = mrErr {
            message = msg
        } else {
            message = error.localizedDescription
        }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "mr.card.assigneeError",
            defaultValue: "Failed to update assignee"
        )
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func loadApprovals(
        for mrs: [GitLabMergeRequest],
        directory: String,
        token: UInt64
    ) {
        let targets: [(projectId: Int, iid: Int)] = mrs
            .filter { $0.state == "opened" && $0.projectId > 0 }
            .map { ($0.projectId, $0.iid) }
        guard !targets.isEmpty else { return }

        approvalsTask = Task { [weak self] in
            // Cap in-flight fetches. Each `fetchGitLabMRApproval` spawns a
            // `glab` process whose pipe drain can block its Swift Concurrency
            // worker thread (see `drainPipesInParallel`); an unbounded
            // `addTask` per MR could pin every thread in the fixed-width
            // cooperative pool at once and stall unrelated `async` work
            // (e.g. the Claude Chat panel spinning on "Thinking…"). Bounding
            // to `maxConcurrent` keeps the pool from ever being fully starved
            // by this fan-out.
            let maxConcurrent = 4
            await withTaskGroup(of: (Int, GitLabMRApproval?).self) { group in
                var next = 0
                while next < min(maxConcurrent, targets.count) {
                    let t = targets[next]
                    next += 1
                    group.addTask {
                        do {
                            let a = try await fetchGitLabMRApproval(
                                projectId: t.projectId,
                                iid: t.iid,
                                in: directory
                            )
                            return (t.iid, a)
                        } catch {
                            return (t.iid, nil)
                        }
                    }
                }
                for await (iid, approval) in group {
                    // Keep the pipeline full: enqueue the next target as each
                    // result lands, never exceeding `maxConcurrent`.
                    if next < targets.count {
                        let t = targets[next]
                        next += 1
                        group.addTask {
                            do {
                                let a = try await fetchGitLabMRApproval(
                                    projectId: t.projectId,
                                    iid: t.iid,
                                    in: directory
                                )
                                return (t.iid, a)
                            } catch {
                                return (t.iid, nil)
                            }
                        }
                    }
                    guard let self else { return }
                    if Task.isCancelled || token != self.requestCounter
                        || directory != self.lastDirectory { return }
                    guard let approval else { continue }
                    if let idx = self.mergeRequests.firstIndex(where: { $0.iid == iid }) {
                        self.mergeRequests[idx].approval = approval
                    }
                }
            }
        }
    }

    private func messageFor(error: Error) -> String {
        switch error {
        case GitLabMRFetchError.glabNotFound:
            return String(localized: "mr.error.glabNotFound", defaultValue: "glab not found")
        case GitLabMRFetchError.notGitLabRepo:
            return String(localized: "mr.error.notGitLab", defaultValue: "Not a GitLab repository")
        case GitLabMRFetchError.processError(let msg):
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - MR List View

struct MergeRequestsListView: View {
    @ObservedObject var workspace: Workspace
    /// Run `/mr-review <iid>` in a new chat tab. Injected by the container
    /// that owns the `TabManager`; `nil` where no chat can be opened.
    var onReview: ((Int) -> Void)? = nil
    @StateObject private var state = MergeRequestsState()
    @State private var reviewerFilter: String = ""  // empty = all
    @State private var assigneeFilter: String = ""  // empty = all
    /// Whether an `mr-review` command file is reachable from this workspace.
    /// Resolved once per directory: it is a filesystem scan, and the rows
    /// below the `LazyVStack` boundary must receive plain values.
    @State private var reviewAvailable = false

    var body: some View {
        VStack(spacing: 0) {
            mrHeader
            Divider()
            if !availableReviewers.isEmpty || !availableAssignees.isEmpty {
                filtersBar
                Divider()
            }
            if state.isLoading && state.mergeRequests.isEmpty {
                loadingState
            } else if let error = state.errorMessage, state.mergeRequests.isEmpty {
                errorState(error)
            } else if filteredMergeRequests.isEmpty {
                emptyState
            } else {
                mrList
            }
        }
        .onAppear {
            refreshIfNeeded()
            refreshReviewAvailability()
        }
        .onChange(of: workspace.id) { _ in
            state.clear()
            reviewerFilter = ""
            assigneeFilter = ""
            refreshIfNeeded()
            refreshReviewAvailability()
        }
        .onChange(of: workspace.currentDirectory) { _ in
            reviewerFilter = ""
            assigneeFilter = ""
            refreshIfNeeded()
            refreshReviewAvailability()
        }
    }

    /// `/mr-review` is a user- or project-level markdown command, so its
    /// presence is a property of the checkout, not of cmux.
    private func refreshReviewAvailability() {
        let available = onReview != nil
            && GitLabChatCommandCoordinator.isAvailable(
                .reviewMergeRequest,
                directory: workspace.currentDirectory
            )
        if reviewAvailable != available {
            reviewAvailable = available
        }
    }

    private var availableReviewers: [GitLabReviewer] {
        uniqueUsers(\.reviewers)
    }

    private var availableAssignees: [GitLabReviewer] {
        uniqueUsers(\.assignees)
    }

    private func uniqueUsers(
        _ keyPath: KeyPath<GitLabMergeRequest, [GitLabReviewer]>
    ) -> [GitLabReviewer] {
        var seen = Set<String>()
        var result: [GitLabReviewer] = []
        for mr in state.mergeRequests {
            for u in mr[keyPath: keyPath] where !u.username.isEmpty {
                if seen.insert(u.username).inserted {
                    result.append(u)
                }
            }
        }
        return result.sorted { $0.username.lowercased() < $1.username.lowercased() }
    }

    private var filteredMergeRequests: [GitLabMergeRequest] {
        state.mergeRequests.filter { mr in
            if !reviewerFilter.isEmpty,
               !mr.reviewers.contains(where: { $0.username == reviewerFilter }) {
                return false
            }
            if !assigneeFilter.isEmpty,
               !mr.assignees.contains(where: { $0.username == assigneeFilter }) {
                return false
            }
            return true
        }
    }

    private var mrHeader: some View {
        HStack {
            if !state.mergeRequests.isEmpty {
                Text("\(filteredMergeRequests.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(.secondary.opacity(0.15))
                    )
            }
            if let url = panelURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(
                    localized: "mr.sidebar.openPanel",
                    defaultValue: "Open merge requests in browser"
                ))
            }
            Spacer()
            if state.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else {
                Button {
                    refreshIfNeeded()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var filtersBar: some View {
        HStack(spacing: 8) {
            if !availableReviewers.isEmpty {
                filterDropdown(
                    icon: "person.crop.circle.badge.checkmark",
                    selection: $reviewerFilter,
                    available: availableReviewers,
                    allLabel: String(
                        localized: "mr.filter.allReviewers",
                        defaultValue: "All reviewers"
                    ),
                    placeholder: { selection in
                        labelFor(username: selection, in: availableReviewers)
                            ?? String(
                                localized: "mr.filter.allReviewers",
                                defaultValue: "All reviewers"
                            )
                    }
                )
            }
            if !availableAssignees.isEmpty {
                filterDropdown(
                    icon: "person.fill",
                    selection: $assigneeFilter,
                    available: availableAssignees,
                    allLabel: String(
                        localized: "mr.filter.allAssignees",
                        defaultValue: "All assignees"
                    ),
                    placeholder: { selection in
                        labelFor(username: selection, in: availableAssignees)
                            ?? String(
                                localized: "mr.filter.allAssignees",
                                defaultValue: "All assignees"
                            )
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func filterDropdown(
        icon: String,
        selection: Binding<String>,
        available: [GitLabReviewer],
        allLabel: String,
        placeholder: @escaping (String) -> String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Menu {
                Button {
                    selection.wrappedValue = ""
                } label: {
                    HStack {
                        Text(allLabel)
                        if selection.wrappedValue.isEmpty {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                ForEach(available, id: \.username) { user in
                    Button {
                        selection.wrappedValue = user.username
                    } label: {
                        HStack {
                            Text(
                                user.name.isEmpty
                                    ? user.username
                                    : "\(user.name) (@\(user.username))"
                            )
                            if selection.wrappedValue == user.username {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(placeholder(selection.wrappedValue))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)

            if !selection.wrappedValue.isEmpty {
                Button {
                    selection.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "mr.filter.clear", defaultValue: "Clear filter"))
            }
        }
    }

    private func labelFor(username: String, in pool: [GitLabReviewer]) -> String? {
        guard !username.isEmpty else { return nil }
        if let match = pool.first(where: { $0.username == username }) {
            return match.name.isEmpty ? "@\(match.username)" : match.name
        }
        return "@\(username)"
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
            Text(String(localized: "mr.sidebar.loading", defaultValue: "Loading..."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button(String(localized: "mr.sidebar.retry", defaultValue: "Retry")) {
                refreshIfNeeded()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(
                (reviewerFilter.isEmpty && assigneeFilter.isEmpty)
                    ? String(localized: "mr.sidebar.empty", defaultValue: "No merge requests")
                    : String(localized: "mr.sidebar.emptyFiltered", defaultValue: "No merge requests match this filter")
            )
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mrList: some View {
        let directory = workspace.currentDirectory
        let menuContext = MRAssigneeMenuContext(
            currentUser: state.currentUser,
            projectMembers: state.projectMembers,
            visibleCandidates: visibleCandidates
        )
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredMergeRequests) { mr in
                    MRCardView(
                        mr: mr,
                        directory: directory,
                        assigneeMenu: menuContext,
                        onSelectAssignee: { assignee in
                            state.setAssignee(
                                mrIID: mr.iid,
                                to: assignee,
                                directory: directory
                            )
                        },
                        onReview: reviewAvailable ? { onReview?(mr.iid) } : nil
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Snapshot of every distinct user already visible in the panel's MRs
    /// (assignees + reviewers, deduped by username). Powers the
    /// instant fallback in the "Assignee" submenu while the project members
    /// fetch is still in flight.
    private var visibleCandidates: [GitLabReviewer] {
        var seen = Set<String>()
        var result: [GitLabReviewer] = []
        for mr in state.mergeRequests {
            for u in (mr.assignees + mr.reviewers) where !u.username.isEmpty {
                if seen.insert(u.username).inserted {
                    result.append(u)
                }
            }
        }
        return result.sorted { $0.username.lowercased() < $1.username.lowercased() }
    }

    private func refreshIfNeeded() {
        let dir = workspace.currentDirectory
        guard !dir.isEmpty else { return }
        state.refresh(directory: dir)
    }

    private var panelURL: URL? {
        guard let base = state.projectWebURL, !base.isEmpty else { return nil }
        return URL(string: "\(base)/-/merge_requests")
    }
}

// MARK: - Assignee menu context

/// Snapshot of everything the assignee submenu needs, passed by value into
/// each `MRCardView` so the row never reaches back into `MergeRequestsState`
/// (the LazyVStack snapshot-boundary rule from `CLAUDE.md`).
struct MRAssigneeMenuContext: Equatable {
    let currentUser: GitLabProjectMember?
    let projectMembers: [GitLabProjectMember]
    let visibleCandidates: [GitLabReviewer]

    /// Merges project members and visible candidates into one deduped,
    /// alphabetically sorted list. The "Assign to me" row already covers the
    /// current user, so callers normally exclude them from this list to avoid
    /// repeating the entry.
    func candidates(excludingCurrentUser: Bool) -> [GitLabReviewer] {
        var byUsername: [String: GitLabReviewer] = [:]
        for member in projectMembers where !member.username.isEmpty {
            byUsername[member.username] = GitLabReviewer(
                name: member.name,
                username: member.username
            )
        }
        for reviewer in visibleCandidates where !reviewer.username.isEmpty {
            if byUsername[reviewer.username] == nil {
                byUsername[reviewer.username] = reviewer
            }
        }
        if excludingCurrentUser, let me = currentUser {
            byUsername.removeValue(forKey: me.username)
        }
        return byUsername.values.sorted { lhs, rhs in
            let l = (lhs.name.isEmpty ? lhs.username : lhs.name).lowercased()
            let r = (rhs.name.isEmpty ? rhs.username : rhs.name).lowercased()
            return l < r
        }
    }
}

// MARK: - MR Card

private struct MRCardView: View {
    let mr: GitLabMergeRequest
    let directory: String
    let assigneeMenu: MRAssigneeMenuContext
    let onSelectAssignee: (GitLabReviewer?) -> Void
    /// Non-nil only when an `mr-review` command is actually available from
    /// the workspace.
    let onReview: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            Text(mr.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !mr.labels.isEmpty {
                labelsView
            }

            Divider().opacity(0.5)

            metadataSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.darculaCardHover : Color.darculaCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            showDiff()
        }
        .contextMenu {
            if let onReview {
                Button(action: onReview) {
                    Label(
                        String(localized: "mr.card.review", defaultValue: "Review MR"),
                        systemImage: "play.circle"
                    )
                }
                Divider()
            }
            Button {
                showDiff()
            } label: {
                Label(
                    String(localized: "mr.card.showDiff", defaultValue: "Show Diff"),
                    systemImage: "text.magnifyingglass"
                )
            }
            .disabled(directory.isEmpty || mr.sourceBranch.isEmpty || mr.targetBranch.isEmpty)
            Button {
                guard let url = URL(string: mr.webURL) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label(
                    String(localized: "mr.card.openBrowser", defaultValue: "Open in Browser"),
                    systemImage: "safari"
                )
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mr.webURL, forType: .string)
            } label: {
                Label(
                    String(localized: "mr.card.copyLink", defaultValue: "Copy Link"),
                    systemImage: "link"
                )
            }
            assigneeSubmenu
        }
        .help(mr.webURL)
    }

    @ViewBuilder
    private var assigneeSubmenu: some View {
        let currentAssigneeUsernames = Set(mr.assignees.map(\.username))
        let candidates = assigneeMenu.candidates(excludingCurrentUser: true)
        let myUsername = assigneeMenu.currentUser?.username ?? ""

        Menu {
            if let me = assigneeMenu.currentUser {
                Button {
                    onSelectAssignee(
                        GitLabReviewer(name: me.name, username: me.username)
                    )
                } label: {
                    assigneeMenuRow(
                        title: String(
                            localized: "mr.card.assignToMe",
                            defaultValue: "Assign to me"
                        ),
                        isCurrent: currentAssigneeUsernames.count == 1
                            && currentAssigneeUsernames.contains(me.username)
                    )
                }
            }
            Button {
                onSelectAssignee(nil)
            } label: {
                assigneeMenuRow(
                    title: String(
                        localized: "mr.card.unassign",
                        defaultValue: "Unassign"
                    ),
                    isCurrent: mr.assignees.isEmpty
                )
            }
            if !candidates.isEmpty {
                Divider()
                ForEach(candidates, id: \.username) { reviewer in
                    if reviewer.username != myUsername {
                        Button {
                            onSelectAssignee(reviewer)
                        } label: {
                            assigneeMenuRow(
                                title: assigneeDisplayLabel(for: reviewer),
                                isCurrent: currentAssigneeUsernames.contains(reviewer.username)
                            )
                        }
                    }
                }
            }
        } label: {
            Label(
                String(localized: "mr.card.assignee", defaultValue: "Assignee"),
                systemImage: "person.crop.circle"
            )
        }
        .disabled(mr.projectId <= 0)
    }

    private func assigneeMenuRow(title: String, isCurrent: Bool) -> some View {
        HStack {
            Text(title)
            if isCurrent {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    private func assigneeDisplayLabel(for reviewer: GitLabReviewer) -> String {
        if reviewer.name.isEmpty { return "@\(reviewer.username)" }
        if reviewer.username.isEmpty { return reviewer.name }
        return "\(reviewer.name) (@\(reviewer.username))"
    }

    private func showDiff() {
        guard !directory.isEmpty,
              !mr.sourceBranch.isEmpty,
              !mr.targetBranch.isEmpty else {
            // Fallback when we can't compute a git diff (e.g. directory or
            // branches missing): open the MR in the browser.
            if let url = URL(string: mr.webURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let spec = GitDiffSpec(
            base: mr.targetBranch,
            compare: mr.sourceBranch,
            directory: directory,
            title: "!\(mr.iid) · \(mr.title)",
            mergeRequestIID: mr.iid,
            mergeRequestURL: mr.webURL
        )
        GitDiffWindowRegistry.show(spec: spec)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 6) {
            stateIcon
                .font(.system(size: 12, weight: .semibold))
            Text("!\(mr.iid)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if mr.userNotesCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(mr.userNotesCount)")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.15))
                )
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
                .help(String(
                    localized: "mr.card.comments",
                    defaultValue: "Comments"
                ))
            }
            if mr.isDraft {
                Text(String(localized: "mr.card.draft", defaultValue: "Draft"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.orange.opacity(0.15))
                    )
            }
            approvalBadge
            Spacer()
            if let created = mr.createdAt {
                Text(relativeTime(from: created))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(fullDate(created))
            }
        }
    }

    @ViewBuilder
    private var approvalBadge: some View {
        if let approval = mr.approval, !approval.approvedBy.isEmpty {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .help(approvalTooltip(approval))
        }
    }

    private func approvalTooltip(_ a: GitLabMRApproval) -> String {
        if a.approvedBy.isEmpty {
            return String(localized: "mr.card.approved", defaultValue: "Approved")
        }
        let names = a.approvedBy
            .map { $0.name.isEmpty ? "@\($0.username)" : $0.name }
            .joined(separator: ", ")
        let template = String(
            localized: "mr.card.approvedBy",
            defaultValue: "Approved by %@"
        )
        return String(format: template, names)
    }

    private func fullDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !mr.authorName.isEmpty || !mr.authorUsername.isEmpty {
                metaRow(
                    icon: "person.fill",
                    label: String(localized: "mr.card.author", defaultValue: "Author"),
                    content: AnyView(
                        AvatarLabel(
                            name: mr.authorName.isEmpty ? mr.authorUsername : mr.authorName,
                            username: mr.authorUsername
                        )
                    )
                )
            }

            if !mr.assignees.isEmpty {
                metaRow(
                    icon: "person.crop.circle.badge.checkmark",
                    label: String(localized: "mr.card.assignees", defaultValue: "Assignees"),
                    content: AnyView(usersList(mr.assignees, moreSuffix: String(
                        localized: "mr.card.moreAssignees",
                        defaultValue: "more"
                    )))
                )
            }

            if !mr.reviewers.isEmpty {
                metaRow(
                    icon: "person.2.fill",
                    label: String(localized: "mr.card.reviewers", defaultValue: "Reviewers"),
                    content: AnyView(usersList(mr.reviewers, moreSuffix: String(
                        localized: "mr.card.moreReviewers",
                        defaultValue: "more"
                    )))
                )
            }
        }
    }

    @ViewBuilder
    private func metaRow(icon: String, label: String, content: AnyView) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 18, alignment: .center)
            content
        }
    }

    private func usersList(
        _ users: [GitLabReviewer],
        moreSuffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(users.prefix(4), id: \.username) { user in
                HStack(spacing: 5) {
                    AvatarBadge(name: user.name.isEmpty ? user.username : user.name)
                    Text(user.name.isEmpty ? user.username : user.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !user.username.isEmpty && user.username != user.name {
                        Text("@\(user.username)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .help(user.name.isEmpty ? "@\(user.username)" : "\(user.name) (@\(user.username))")
            }
            if users.count > 4 {
                Text("+\(users.count - 4) \(moreSuffix)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 23)
            }
        }
    }

    private var branchesView: some View {
        HStack(spacing: 4) {
            Text(mr.sourceBranch)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
            Text(mr.targetBranch)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch mr.state {
        case "opened":
            if mrHasMergeProblem {
                // Conflict / can't merge: warning triangle in orange.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(mergeProblemTooltip)
            } else {
                // Always-green arrow when opened without a known conflict.
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.green)
            }
        case "merged":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.purple)
        case "closed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var mrHasMergeProblem: Bool {
        if mr.hasConflicts { return true }
        return mr.mergeStatus == "cannot_be_merged"
            || mr.mergeStatus == "cannot_be_merged_recheck"
    }

    private var mergeProblemTooltip: String {
        if mr.hasConflicts {
            return String(localized: "mr.card.hasConflicts", defaultValue: "Has conflicts")
        }
        return String(localized: "mr.card.cannotBeMerged", defaultValue: "Cannot be merged")
    }

    @ViewBuilder
    private var labelsView: some View {
        let displayed = Array(mr.labels.prefix(4))
        HStack(spacing: 4) {
            ForEach(displayed, id: \.self) { label in
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.secondary.opacity(0.12))
                    )
                    .lineLimit(1)
            }
            if mr.labels.count > 4 {
                Text("+\(mr.labels.count - 4)")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Avatar components

struct AvatarBadge: View {
    let name: String

    private var initials: String {
        let parts = name.split(separator: " ")
        if let first = parts.first?.first, let second = parts.dropFirst().first?.first {
            return "\(first)\(second)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        // Deterministic FNV-1a 64-bit hash of the name so the same user always
        // gets the same color (String.hashValue is randomized per process run).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Map to a hue on the full color wheel for many more distinct colors
        // than a fixed 8-color palette. Use the golden-ratio offset to spread
        // adjacent hashes apart visually.
        let hueBase = Double(hash % 1_000_000) / 1_000_000.0
        let hue = (hueBase + 0.61803398875).truncatingRemainder(dividingBy: 1.0)
        // Slight saturation/brightness jitter (also derived from the hash) so
        // two names that happen to land on a similar hue still feel distinct
        // against the Darcula card surface.
        let satJitter = Double((hash >> 16) % 100) / 100.0   // 0.0 ..< 1.0
        let briJitter = Double((hash >> 32) % 100) / 100.0   // 0.0 ..< 1.0
        let saturation = 0.55 + satJitter * 0.30             // 0.55 ..< 0.85
        let brightness = 0.70 + briJitter * 0.20             // 0.70 ..< 0.90
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color.opacity(0.8)))
    }
}

struct AvatarLabel: View {
    let name: String
    let username: String

    var body: some View {
        HStack(spacing: 5) {
            AvatarBadge(name: name)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !username.isEmpty && username != name {
                Text("@\(username)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
