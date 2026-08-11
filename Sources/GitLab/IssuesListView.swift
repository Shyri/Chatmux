import SwiftUI
import AppKit

// MARK: - Issues State

@MainActor
final class IssuesState: ObservableObject {
    @Published var issues: [GitLabIssue] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastDirectory: String?
    @Published private(set) var projectWebURL: String?
    /// Project label catalogue keyed by label name. Loaded lazily after the
    /// issue list comes back so we can paint each label chip with its real
    /// GitLab colour. Empty until labels finish loading or when the project
    /// has no labels; chips fall back to the neutral style in that case.
    @Published private(set) var labelsByName: [String: GitLabLabel] = [:]
    /// Project members fetched lazily for the assignee context menu. See
    /// `MergeRequestsState.projectMembers` for the matching MR-side store.
    @Published private(set) var projectMembers: [GitLabProjectMember] = []
    /// Currently authenticated user. Powers "Assign to me" in the context
    /// menu; `nil` until `glab api user` succeeds.
    @Published private(set) var currentUser: GitLabProjectMember?

    private var fetchTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var relatedMRsTask: Task<Void, Never>?
    private var labelsTask: Task<Void, Never>?
    private var membersTask: Task<Void, Never>?
    private var currentUserTask: Task<Void, Never>?
    private var requestCounter: UInt64 = 0

    func refresh(directory: String) {
        fetchTask?.cancel()
        remoteTask?.cancel()
        relatedMRsTask?.cancel()
        labelsTask?.cancel()
        membersTask?.cancel()
        currentUserTask?.cancel()
        requestCounter &+= 1
        let token = requestCounter

        if lastDirectory != directory {
            issues = []
            projectWebURL = nil
            labelsByName = [:]
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
            let result: Result<[GitLabIssue], Error>
            do {
                result = .success(try await fetchGitLabIssues(in: directory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter, directory == self.lastDirectory else {
                return
            }

            switch result {
            case .success(let items):
                self.issues = items
                self.errorMessage = nil
                self.loadRelatedMRs(for: items, directory: directory, token: token)
                self.loadProjectLabels(for: items, directory: directory, token: token)
                self.loadProjectMembers(for: items, directory: directory, token: token)
            case .failure(let error):
                self.issues = []
                self.errorMessage = self.messageFor(error: error)
            }
            self.isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        remoteTask?.cancel()
        relatedMRsTask?.cancel()
        labelsTask?.cancel()
        membersTask?.cancel()
        currentUserTask?.cancel()
        requestCounter &+= 1
        issues = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
        projectWebURL = nil
        labelsByName = [:]
        projectMembers = []
        currentUser = nil
    }

    private func loadProjectMembers(
        for items: [GitLabIssue],
        directory: String,
        token: UInt64
    ) {
        guard let projectId = items.first(where: { $0.projectId > 0 })?.projectId else {
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

    /// Optimistically replaces a single issue's assignees with `assignee` (or
    /// clears them when `nil`), then issues `glab issue update`. Rolls back +
    /// shows an `NSAlert` on failure; refreshes the panel on success.
    func setAssignee(
        issueIID: Int,
        to assignee: GitLabAssignee?,
        directory: String
    ) {
        guard let idx = issues.firstIndex(where: { $0.iid == issueIID }) else { return }
        let previous = issues[idx].assignees
        issues[idx].assignees = assignee.map { [$0] } ?? []

        Task { [weak self] in
            do {
                try await updateGitLabIssueAssignee(
                    iid: issueIID,
                    assigneeUsername: assignee?.username,
                    in: directory
                )
                guard let self else { return }
                self.refresh(directory: directory)
            } catch {
                guard let self else { return }
                if let i = self.issues.firstIndex(where: { $0.iid == issueIID }) {
                    self.issues[i].assignees = previous
                }
                IssuesState.presentAssigneeError(error)
            }
        }
    }

    @MainActor
    private static func presentAssigneeError(_ error: Error) {
        let message: String
        if let issueErr = error as? GitLabIssueFetchError,
           case let .processError(msg) = issueErr {
            message = msg
        } else {
            message = error.localizedDescription
        }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "issue.card.assigneeError",
            defaultValue: "Failed to update assignee"
        )
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Pulls the project's label catalogue (name + colour + text colour)
    /// via `glab api projects/:id/labels` so each issue chip can be
    /// rendered with its real GitLab colour. Picks the first non-zero
    /// projectId from the loaded issues — every issue in a side-panel
    /// listing belongs to the same project, so one call is enough.
    private func loadProjectLabels(
        for items: [GitLabIssue],
        directory: String,
        token: UInt64
    ) {
        guard let projectId = items.first(where: { $0.projectId > 0 })?.projectId else {
            self.labelsByName = [:]
            return
        }
        labelsTask = Task { [weak self] in
            let result: Result<[GitLabLabel], Error>
            do {
                result = .success(try await fetchGitLabProjectLabels(
                    projectId: projectId,
                    in: directory
                ))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled,
                  token == self.requestCounter,
                  directory == self.lastDirectory else { return }
            switch result {
            case .success(let labels):
                self.labelsByName = Dictionary(
                    labels.map { ($0.name, $0) },
                    uniquingKeysWith: { lhs, _ in lhs }
                )
            case .failure:
                // Best-effort: chips fall back to the neutral style when
                // the catalogue can't be loaded (e.g. no network).
                break
            }
        }
    }

    private func loadRelatedMRs(
        for items: [GitLabIssue],
        directory: String,
        token: UInt64
    ) {
        let targets: [(projectId: Int, iid: Int)] = items
            .filter { $0.state == "opened" && $0.projectId > 0 }
            .map { ($0.projectId, $0.iid) }
        guard !targets.isEmpty else { return }

        relatedMRsTask = Task { [weak self] in
            await withTaskGroup(of: (Int, Int?).self) { group in
                let maxConcurrent = 5
                var iter = targets.makeIterator()
                var inFlight = 0

                func enqueueNext() {
                    guard let t = iter.next() else { return }
                    inFlight += 1
                    group.addTask {
                        do {
                            let count = try await fetchGitLabIssueOpenRelatedMRsCount(
                                projectId: t.projectId,
                                iid: t.iid,
                                in: directory
                            )
                            return (t.iid, count)
                        } catch {
                            return (t.iid, nil)
                        }
                    }
                }

                for _ in 0..<min(maxConcurrent, targets.count) { enqueueNext() }

                while inFlight > 0 {
                    guard let (iid, count) = await group.next() else { break }
                    inFlight -= 1
                    enqueueNext()

                    guard let self else { return }
                    if Task.isCancelled || token != self.requestCounter
                        || directory != self.lastDirectory { return }
                    guard let count else { continue }
                    if let idx = self.issues.firstIndex(where: { $0.iid == iid }) {
                        self.issues[idx].relatedOpenMRsCount = count
                    }
                }
            }
        }
    }

    private func messageFor(error: Error) -> String {
        switch error {
        case GitLabIssueFetchError.glabNotFound:
            return String(localized: "issue.error.glabNotFound", defaultValue: "glab not found")
        case GitLabIssueFetchError.notGitLabRepo:
            return String(localized: "issue.error.notGitLab", defaultValue: "Not a GitLab repository")
        case GitLabIssueFetchError.processError(let msg):
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Issues List View

struct IssuesListView: View {
    @ObservedObject var workspace: Workspace
    /// Start `/start-task <iid>` in a new chat tab. Injected by the container
    /// that owns the `TabManager`; `nil` where no chat can be opened.
    var onStartTask: ((Int) -> Void)? = nil
    /// Run `/auto-task <iid>` now. Takes the issue title too: the queue keeps a
    /// snapshot so the panel renders without going back to GitLab.
    var onRunAutoTask: ((Int, String) -> Void)? = nil
    /// Queue `/auto-task <iid>` for a date.
    var onScheduleAutoTask: ((Int, String, Date) -> Void)? = nil
    @StateObject private var state = IssuesState()
    @ObservedObject private var filtersStore = GitLabIssueFiltersStore.shared
    /// Observed here, above the row list, so rows receive a plain value and
    /// never hold the store — the `LazyVStack` snapshot boundary.
    @ObservedObject private var autoTaskStore = AutoTaskStore.shared
    @State private var milestoneFilter: String = ""  // "" = all, kNoMilestoneSentinel = no milestone, else milestone title
    @State private var assigneeFilter: String = ""  // "" = all, kNoAssigneeSentinel = unassigned, else username
    /// Whether a `/start-task` command file is reachable from this
    /// workspace. Resolved once per directory rather than per row: it is a
    /// filesystem scan, and the rows below the `LazyVStack` boundary must
    /// receive plain values.
    @State private var startTaskAvailable = false
    @State private var autoTaskAvailable = false

    private var hasMilestoneOptions: Bool {
        !availableMilestones.isEmpty || state.issues.contains(where: { $0.milestone == nil })
    }

    private var hasAssigneeOptions: Bool {
        !availableAssignees.isEmpty || state.issues.contains(where: { $0.assignees.isEmpty })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if hasMilestoneOptions || hasAssigneeOptions {
                filterBar
                Divider()
            }
            if state.isLoading && state.issues.isEmpty {
                loadingState
            } else if let error = state.errorMessage, state.issues.isEmpty {
                errorState(error)
            } else if filteredIssues.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear {
            loadPersistedFilters()
            refreshIfNeeded()
            refreshStartTaskAvailability()
        }
        .onChange(of: workspace.id) { _ in
            loadPersistedFilters()
            refreshIfNeeded()
            refreshStartTaskAvailability()
        }
        .onChange(of: workspace.currentDirectory) { _ in
            refreshIfNeeded()
            refreshStartTaskAvailability()
        }
        .onChange(of: milestoneFilter) { newValue in
            filtersStore.setMilestoneFilter(newValue, for: workspace.id)
        }
        .onChange(of: assigneeFilter) { newValue in
            filtersStore.setAssigneeFilter(newValue, for: workspace.id)
        }
    }

    private func loadPersistedFilters() {
        let stored = filtersStore.filters(for: workspace.id)
        if milestoneFilter != stored.milestone { milestoneFilter = stored.milestone }
        if assigneeFilter != stored.assignee { assigneeFilter = stored.assignee }
    }

    private var availableMilestones: [GitLabMilestone] {
        var seen = Set<String>()
        var result: [GitLabMilestone] = []
        for issue in state.issues {
            guard let m = issue.milestone, !m.title.isEmpty else { continue }
            if seen.insert(m.title).inserted {
                result.append(m)
            }
        }
        return result.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title.lowercased() < rhs.title.lowercased()
            }
        }
    }

    private var availableAssignees: [GitLabAssignee] {
        var seen = Set<String>()
        var result: [GitLabAssignee] = []
        for issue in state.issues {
            for a in issue.assignees {
                let key = a.username.isEmpty ? a.name : a.username
                guard !key.isEmpty else { continue }
                if seen.insert(key).inserted {
                    result.append(a)
                }
            }
        }
        return result.sorted { lhs, rhs in
            let l = (lhs.name.isEmpty ? lhs.username : lhs.name).lowercased()
            let r = (rhs.name.isEmpty ? rhs.username : rhs.name).lowercased()
            return l < r
        }
    }

    private var filteredIssues: [GitLabIssue] {
        var result = state.issues

        if !milestoneFilter.isEmpty {
            if milestoneFilter == kNoMilestoneSentinel {
                result = result.filter { $0.milestone == nil }
            } else {
                result = result.filter { $0.milestone?.title == milestoneFilter }
            }
        }

        if !assigneeFilter.isEmpty {
            if assigneeFilter == kNoAssigneeSentinel {
                result = result.filter { $0.assignees.isEmpty }
            } else {
                result = result.filter { issue in
                    issue.assignees.contains { a in
                        let key = a.username.isEmpty ? a.name : a.username
                        return key == assigneeFilter
                    }
                }
            }
        }

        return result
    }

    private var header: some View {
        HStack {
            if !state.issues.isEmpty {
                Text("\(filteredIssues.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
            if let boardsURL = issueBoardURL {
                Button {
                    NSWorkspace.shared.open(boardsURL)
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(
                    localized: "issue.sidebar.openBoard",
                    defaultValue: "Open issue board"
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

    private var filterBar: some View {
        VStack(spacing: 4) {
            if hasMilestoneOptions {
                milestoneFilterRow
            }
            if hasAssigneeOptions {
                assigneeFilterRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var milestoneFilterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .center)
            Menu {
                Button {
                    milestoneFilter = ""
                } label: {
                    HStack {
                        Text(String(localized: "issue.filter.allMilestones", defaultValue: "All milestones"))
                        if milestoneFilter.isEmpty {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    milestoneFilter = kNoMilestoneSentinel
                } label: {
                    HStack {
                        Text(String(localized: "issue.filter.noMilestone", defaultValue: "No milestone"))
                        if milestoneFilter == kNoMilestoneSentinel {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                if !availableMilestones.isEmpty {
                    Divider()
                    ForEach(availableMilestones, id: \.id) { milestone in
                        Button {
                            milestoneFilter = milestone.title
                        } label: {
                            HStack {
                                Text(milestoneMenuLabel(milestone))
                                if milestoneFilter == milestone.title {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                filterMenuChipLabel(text: currentMilestoneFilterLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)

            if !milestoneFilter.isEmpty {
                Button {
                    milestoneFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "issue.filter.clear", defaultValue: "Clear filter"))
            }
        }
    }

    private var assigneeFilterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .center)
            Menu {
                Button {
                    assigneeFilter = ""
                } label: {
                    HStack {
                        Text(String(localized: "issue.filter.allAssignees", defaultValue: "All assignees"))
                        if assigneeFilter.isEmpty {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    assigneeFilter = kNoAssigneeSentinel
                } label: {
                    HStack {
                        Text(String(localized: "issue.filter.noAssignee", defaultValue: "Unassigned"))
                        if assigneeFilter == kNoAssigneeSentinel {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                if !availableAssignees.isEmpty {
                    Divider()
                    ForEach(availableAssignees, id: \.username) { assignee in
                        let key = assignee.username.isEmpty ? assignee.name : assignee.username
                        Button {
                            assigneeFilter = key
                        } label: {
                            HStack {
                                Text(assigneeMenuLabel(assignee))
                                if assigneeFilter == key {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                filterMenuChipLabel(text: currentAssigneeFilterLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)

            if !assigneeFilter.isEmpty {
                Button {
                    assigneeFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "issue.filter.clear", defaultValue: "Clear filter"))
            }
        }
    }

    private func filterMenuChipLabel(text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
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

    private func milestoneMenuLabel(_ m: GitLabMilestone) -> String {
        guard let due = m.dueDate else { return m.title }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "\(m.title) • \(df.string(from: due))"
    }

    private func assigneeMenuLabel(_ a: GitLabAssignee) -> String {
        let display = a.name.isEmpty ? a.username : a.name
        if !a.username.isEmpty && a.username != a.name {
            return "\(display) (@\(a.username))"
        }
        return display
    }

    private var currentMilestoneFilterLabel: String {
        if milestoneFilter.isEmpty {
            return String(localized: "issue.filter.allMilestones", defaultValue: "All milestones")
        }
        if milestoneFilter == kNoMilestoneSentinel {
            return String(localized: "issue.filter.noMilestone", defaultValue: "No milestone")
        }
        return milestoneFilter
    }

    private var currentAssigneeFilterLabel: String {
        if assigneeFilter.isEmpty {
            return String(localized: "issue.filter.allAssignees", defaultValue: "All assignees")
        }
        if assigneeFilter == kNoAssigneeSentinel {
            return String(localized: "issue.filter.noAssignee", defaultValue: "Unassigned")
        }
        if let match = availableAssignees.first(where: {
            ($0.username.isEmpty ? $0.name : $0.username) == assigneeFilter
        }) {
            return match.name.isEmpty ? "@\(match.username)" : match.name
        }
        return assigneeFilter
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
            Text(String(localized: "issue.sidebar.loading", defaultValue: "Loading..."))
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
            Button(String(localized: "issue.sidebar.retry", defaultValue: "Retry")) {
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
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(
                (milestoneFilter.isEmpty && assigneeFilter.isEmpty)
                    ? String(localized: "issue.sidebar.empty", defaultValue: "No issues")
                    : String(localized: "issue.sidebar.emptyFiltered", defaultValue: "No issues match this filter")
            )
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let directory = workspace.currentDirectory
        let menuContext = IssueAssigneeMenuContext(
            currentUser: state.currentUser,
            projectMembers: state.projectMembers,
            visibleCandidates: visibleCandidates
        )
        let scheduled = autoTaskStore.outstandingByIssue(
            repositoryPath: directory,
            projectId: AutoTaskLauncher.owningProjectId(for: workspace)
        )
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredIssues) { issue in
                    IssueCardView(
                        issue: issue,
                        schedule: scheduled[issue.iid].map(AutoTaskIssueBadge.init(task:)),
                        assigneeMenu: menuContext,
                        onSelectAssignee: { assignee in
                            state.setAssignee(
                                issueIID: issue.iid,
                                to: assignee,
                                directory: directory
                            )
                        },
                        onStartTask: startTaskAvailable
                            ? { onStartTask?(issue.iid) }
                            : nil,
                        onRunAutoTask: autoTaskAvailable
                            ? { onRunAutoTask?(issue.iid, issue.title) }
                            : nil,
                        onScheduleAutoTask: autoTaskAvailable
                            ? { date in onScheduleAutoTask?(issue.iid, issue.title, date) }
                            : nil
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
        }
        .environment(\.gitlabLabelsByName, state.labelsByName)
    }

    /// Snapshot of every distinct user already visible in the panel's issues
    /// (deduped by username), used as the instant fallback for the assignee
    /// submenu while the project members fetch is pending.
    private var visibleCandidates: [GitLabAssignee] {
        var seen = Set<String>()
        var result: [GitLabAssignee] = []
        for issue in state.issues {
            for a in issue.assignees where !a.username.isEmpty {
                if seen.insert(a.username).inserted {
                    result.append(a)
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

    /// `/start-task` is a user- or project-level markdown command, so its
    /// presence is a property of the checkout, not of cmux. Re-resolved
    /// whenever the workspace directory changes.
    private func refreshStartTaskAvailability() {
        let directory = workspace.currentDirectory
        let start = onStartTask != nil
            && GitLabChatCommandCoordinator.isAvailable(.startTask, directory: directory)
        if startTaskAvailable != start {
            startTaskAvailable = start
        }
        let auto = onRunAutoTask != nil
            && AutoTaskLauncher.isAvailable(directory: directory)
        if autoTaskAvailable != auto {
            autoTaskAvailable = auto
        }
    }

    /// Derives the project's issue-board URL, preferring the cached project
    /// web URL (from `git remote`) and falling back to parsing any issue's
    /// `web_url` (`https://host/group/project/-/issues/<iid>`).
    private var issueBoardURL: URL? {
        if let base = state.projectWebURL, !base.isEmpty {
            return URL(string: "\(base)/-/boards")
        }
        if let sample = state.issues.first?.webURL,
           let range = sample.range(of: "/-/issues/") {
            let base = sample[..<range.lowerBound]
            return URL(string: "\(base)/-/boards")
        }
        return nil
    }
}

// MARK: - Assignee menu context

/// Snapshot of everything the assignee submenu needs for an issue card,
/// passed by value so the row never reaches back into `IssuesState` (the
/// LazyVStack snapshot-boundary rule from `CLAUDE.md`).
struct IssueAssigneeMenuContext: Equatable {
    let currentUser: GitLabProjectMember?
    let projectMembers: [GitLabProjectMember]
    let visibleCandidates: [GitLabAssignee]

    /// Merges project members and visible candidates into a deduped,
    /// alphabetically sorted list. The "Assign to me" row already covers the
    /// current user, so callers normally exclude them.
    func candidates(excludingCurrentUser: Bool) -> [GitLabAssignee] {
        var byUsername: [String: GitLabAssignee] = [:]
        for member in projectMembers where !member.username.isEmpty {
            byUsername[member.username] = GitLabAssignee(
                name: member.name,
                username: member.username
            )
        }
        for assignee in visibleCandidates where !assignee.username.isEmpty {
            if byUsername[assignee.username] == nil {
                byUsername[assignee.username] = assignee
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

// MARK: - Issue Card

/// Immutable snapshot of an issue's outstanding auto-task, for the row badge.
/// A value, not the task and not the store.
struct AutoTaskIssueBadge: Equatable {
    let scheduledAt: Date
    let isMissed: Bool

    init(task: ScheduledAutoTask) {
        scheduledAt = task.scheduledAt
        isMissed = task.state == .missed
    }
}

private struct IssueCardView: View {
    let issue: GitLabIssue
    /// Non-nil when Chatmux has an auto-task queued for this issue. Local
    /// only — nothing about this is ever sent to GitLab.
    let schedule: AutoTaskIssueBadge?
    let assigneeMenu: IssueAssigneeMenuContext
    let onSelectAssignee: (GitLabAssignee?) -> Void
    /// Non-nil only when a `/start-task` command is actually available from
    /// the workspace — offering a menu item that resolves to nothing would
    /// be worse than not offering it.
    let onStartTask: (() -> Void)?
    /// Same, for `/auto-task`: run it now, or schedule it for a date.
    let onRunAutoTask: (() -> Void)?
    let onScheduleAutoTask: ((Date) -> Void)?
    @State private var isPickingSchedule = false
    @State private var isHovered = false
    @Environment(\.gitlabLabelsByName) private var labelsByName

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            Text(issue.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let milestone = issue.milestone {
                milestoneBadge(milestone)
            }

            if !issue.assignees.isEmpty {
                assigneesView
            }

            if !issue.labels.isEmpty {
                labelsView
            }
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
            guard let url = URL(string: issue.webURL) else { return }
            NSWorkspace.shared.open(url)
        }
        .contextMenu {
            if let onStartTask {
                Button(action: onStartTask) {
                    Label(
                        String(localized: "issue.card.startTask", defaultValue: "Start Task"),
                        systemImage: "play.circle"
                    )
                }
            }
            if let onRunAutoTask {
                Button(action: onRunAutoTask) {
                    Label(
                        String(localized: "issue.card.runAutoTask", defaultValue: "Run Auto-Task Now"),
                        systemImage: "bolt.circle"
                    )
                }
            }
            if onScheduleAutoTask != nil {
                Button {
                    isPickingSchedule = true
                } label: {
                    Label(
                        String(localized: "issue.card.scheduleAutoTask", defaultValue: "Schedule Auto-Task…"),
                        systemImage: "clock.badge.checkmark"
                    )
                }
            }
            if onStartTask != nil || onRunAutoTask != nil || onScheduleAutoTask != nil {
                Divider()
            }
            Button {
                guard let url = URL(string: issue.webURL) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label(
                    String(localized: "issue.card.openBrowser", defaultValue: "Open in Browser"),
                    systemImage: "safari"
                )
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.webURL, forType: .string)
            } label: {
                Label(
                    String(localized: "issue.card.copyLink", defaultValue: "Copy Link"),
                    systemImage: "link"
                )
            }
            assigneeSubmenu
        }
        .popover(isPresented: $isPickingSchedule, arrowEdge: .trailing) {
            AutoTaskSchedulePicker(issueIID: issue.iid) { date in
                isPickingSchedule = false
                onScheduleAutoTask?(date)
            }
        }
        .help(issue.webURL)
    }

    @ViewBuilder
    private var assigneeSubmenu: some View {
        let currentUsernames = Set(issue.assignees.map(\.username))
        let candidates = assigneeMenu.candidates(excludingCurrentUser: true)
        let myUsername = assigneeMenu.currentUser?.username ?? ""

        Menu {
            if let me = assigneeMenu.currentUser {
                Button {
                    onSelectAssignee(
                        GitLabAssignee(name: me.name, username: me.username)
                    )
                } label: {
                    assigneeMenuRow(
                        title: String(
                            localized: "issue.card.assignToMe",
                            defaultValue: "Assign to me"
                        ),
                        isCurrent: currentUsernames.count == 1
                            && currentUsernames.contains(me.username)
                    )
                }
            }
            Button {
                onSelectAssignee(nil)
            } label: {
                assigneeMenuRow(
                    title: String(
                        localized: "issue.card.unassign",
                        defaultValue: "Unassign"
                    ),
                    isCurrent: issue.assignees.isEmpty
                )
            }
            if !candidates.isEmpty {
                Divider()
                ForEach(candidates, id: \.username) { assignee in
                    if assignee.username != myUsername {
                        Button {
                            onSelectAssignee(assignee)
                        } label: {
                            assigneeMenuRow(
                                title: assigneeDisplayLabel(for: assignee),
                                isCurrent: currentUsernames.contains(assignee.username)
                            )
                        }
                    }
                }
            }
        } label: {
            Label(
                String(localized: "issue.card.assignee", defaultValue: "Assignee"),
                systemImage: "person.crop.circle"
            )
        }
        .disabled(issue.projectId <= 0)
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

    private func assigneeDisplayLabel(for assignee: GitLabAssignee) -> String {
        if assignee.name.isEmpty { return "@\(assignee.username)" }
        if assignee.username.isEmpty { return assignee.name }
        return "\(assignee.name) (@\(assignee.username))"
    }

    /// Marks an issue that has an auto-task waiting in Chatmux.
    ///
    /// Local only: nothing is written to GitLab, no label is applied, and
    /// nobody else on the team sees it. It reflects this machine's queue.
    private func scheduleBadge(_ schedule: AutoTaskIssueBadge) -> some View {
        let tint: Color = schedule.isMissed ? .orange : Color.accentColor
        return HStack(spacing: 3) {
            Image(systemName: schedule.isMissed ? "clock.badge.exclamationmark" : "clock")
                .font(.system(size: 9, weight: .semibold))
            Text(Self.badgeLabel(schedule))
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .help(
            schedule.isMissed
                ? String(
                    localized: "issue.card.autoTask.missedTooltip",
                    defaultValue: "This auto-task's time passed while Chatmux was closed. Local only — nothing was sent to GitLab."
                )
                : String(
                    localized: "issue.card.autoTask.scheduledTooltip",
                    defaultValue: "An auto-task is scheduled for this issue in Chatmux. Local only — nothing is sent to GitLab."
                )
        )
    }

    private static func badgeLabel(_ schedule: AutoTaskIssueBadge) -> String {
        if schedule.isMissed {
            return String(localized: "issue.card.autoTask.missed", defaultValue: "missed")
        }
        let formatter = DateFormatter()
        // Day + time when it is not today, time alone when it is: a queue is
        // usually "tonight", and the date would be noise on a narrow row.
        if Calendar.current.isDateInToday(schedule.scheduledAt) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEHm")
        }
        return formatter.string(from: schedule.scheduledAt)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 6) {
            stateIcon
                .font(.system(size: 12, weight: .semibold))
            Text("#\(issue.iid)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if let schedule {
                scheduleBadge(schedule)
            }
            if issue.userNotesCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(issue.userNotesCount)")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                .help(String(localized: "issue.card.comments", defaultValue: "Comments"))
            }
            if let openMRs = issue.relatedOpenMRsCount, openMRs > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(openMRs)")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
                .help(openMRs == 1
                    ? String(localized: "issue.card.openMR", defaultValue: "1 open merge request")
                    : String(format: String(localized: "issue.card.openMRs", defaultValue: "%d open merge requests"), openMRs))
            }
            Spacer()
            if let updated = issue.updatedAt {
                Text(relativeTime(from: updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch issue.state {
        case "opened":
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.green)
        case "closed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.purple)
        default:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func milestoneBadge(_ m: GitLabMilestone) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9))
            Text(m.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            if let due = m.dueDate {
                Text("•")
                    .font(.system(size: 9))
                    .opacity(0.6)
                Text(dueDateString(due))
                    .font(.system(size: 10))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.teal)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.teal.opacity(0.15)))
        .overlay(Capsule().strokeBorder(Color.teal.opacity(0.35), lineWidth: 0.5))
    }

    private var assigneesView: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(issue.assignees.prefix(4), id: \.username) { assignee in
                    let displayName = assignee.name.isEmpty ? assignee.username : assignee.name
                    HStack(spacing: 5) {
                        AvatarBadge(name: displayName)
                        Text(displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !assignee.username.isEmpty && assignee.username != assignee.name {
                            Text("@\(assignee.username)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .help(assignee.name.isEmpty ? "@\(assignee.username)" : "\(assignee.name) (@\(assignee.username))")
                }
                if issue.assignees.count > 4 {
                    Text("+\(issue.assignees.count - 4) \(String(localized: "issue.card.moreAssignees", defaultValue: "more"))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 23)
                }
            }
        }
    }

    @ViewBuilder
    private var labelsView: some View {
        let displayed = Array(issue.labels.prefix(4))
        HStack(spacing: 4) {
            ForEach(displayed, id: \.self) { label in
                labelChip(name: label)
            }
            if issue.labels.count > 4 {
                Text("+\(issue.labels.count - 4)")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    /// Renders a single label chip. When the project labels catalogue
    /// has loaded and reports a colour for `name`, we paint the chip in
    /// that colour with the text colour GitLab paired with it (so
    /// contrast matches what the user sees on gitlab.com). Otherwise we
    /// fall back to the neutral `.secondary` style — same as before
    /// colour support landed.
    @ViewBuilder
    private func labelChip(name: String) -> some View {
        let descriptor = labelsByName[name]
        let bg = descriptor.flatMap { Color(gitlabHex: $0.color) }
        let fg = descriptor.flatMap { Color(gitlabHex: $0.textColor) }

        Text(name)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(fg ?? Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(bg ?? Color.secondary.opacity(0.12))
            )
            .lineLimit(1)
    }

    private func dueDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Label colour wiring

private struct GitLabLabelsByNameKey: EnvironmentKey {
    static let defaultValue: [String: GitLabLabel] = [:]
}

extension EnvironmentValues {
    /// Project label catalogue keyed by name. Pushed by `IssuesListView`
    /// so descendant rows can look up real GitLab colours without having
    /// to plumb the dict through every initializer.
    var gitlabLabelsByName: [String: GitLabLabel] {
        get { self[GitLabLabelsByNameKey.self] }
        set { self[GitLabLabelsByNameKey.self] = newValue }
    }
}

extension Color {
    /// Parses a `#RRGGBB` or `#RGB` hex string as written by the GitLab
    /// labels API. Returns `nil` for anything else (empty, malformed,
    /// `transparent` placeholders) so callers can fall back cleanly.
    init?(gitlabHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 {
            // Expand `#abc` to `#aabbcc`.
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6,
              let value = UInt32(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
