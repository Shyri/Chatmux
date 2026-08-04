import SwiftUI
import AppKit

// MARK: - View Model

@MainActor
final class GitDiffViewModel: ObservableObject {
    @Published var spec: GitDiffSpec
    @Published var files: [GitDiffFile] = []
    @Published var selectedFile: GitDiffFile?
    @Published var currentDiff: String = ""
    @Published var isLoadingFiles = false
    @Published var isLoadingDiff = false
    @Published var filesError: String?
    @Published var diffError: String?
    /// When non-nil, the previous file-list load failed because one or more
    /// refs couldn't be resolved locally or on the remote-tracking branch.
    /// Drives the "Fetch and retry" affordance in the error UI.
    @Published var missingRefs: [String] = []
    @Published var missingRefsRemote: String = gitDiffDefaultRemote
    @Published var isFetchingRefs = false
    /// Inline discussions fetched via `glab api` when the spec comes from an
    /// MR. Empty for working-tree diffs.
    @Published var mrDiscussions: [MRDiscussion] = []
    /// MR metadata (description, author) shown above the comments timeline in
    /// the Overview pane. `nil` until the fetch completes (or for non-MR diffs).
    @Published var mrOverview: MROverview?
    /// Whether the user is viewing the MR overview (description + general
    /// discussions) in lieu of a file diff.
    @Published var overviewSelected: Bool = false

    /// Conflict regions (line ranges in the merged result) for the currently
    /// selected file. Reset whenever the selection changes.
    @Published var currentConflict: GitDiffFileConflict?
    @Published var isLoadingConflict: Bool = false

    /// Three blobs (ours/base/theirs) for the currently selected conflicting
    /// file. Populated when the file has conflicts and `spec.compare` is set;
    /// drives the 3-pane viewer.
    @Published var threeWayBlobs: ThreeWayBlobs?
    @Published var isLoadingThreeWay: Bool = false

    private var fileListTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var discussionsTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    private var conflictTask: Task<Void, Never>?
    private var threeWayTask: Task<Void, Never>?

    var positionedDiscussions: [MRDiscussion] {
        mrDiscussions.filter { $0.isPositioned }
    }
    var generalDiscussions: [MRDiscussion] {
        mrDiscussions.filter { !$0.isPositioned }
    }
    var hasOverview: Bool {
        // Show overview entry whenever this is an MR diff: description always
        // belongs there, even when there are no general comments yet.
        spec.mergeRequestIID != nil
    }

    init(spec: GitDiffSpec) {
        self.spec = spec
    }

    func reload() {
        if let iid = spec.mergeRequestIID {
            // Drop cached diff_refs, target-branch fetch state, and merge-tree
            // so a new push to the MR (or to target) is picked up on the next
            // load.
            let dir = spec.directory
            let target = spec.base
            Task {
                await MRDiffRefsStore.shared.invalidate(iid: iid, directory: dir)
                await TargetBranchFetchCache.shared.invalidate(branch: target, directory: dir)
                await MRMergedTreeStore.shared.invalidateAll(directory: dir)
            }
        }
        loadFileList()
        loadDiscussionsIfNeeded()
        loadOverviewIfNeeded()
    }

    private func loadDiscussionsIfNeeded() {
        guard let iid = spec.mergeRequestIID else {
            NSLog("[cmux-mr-comments] skipped: no mergeRequestIID in spec")
            mrDiscussions = []
            return
        }
        NSLog("[cmux-mr-comments] fetching discussions for MR !\(iid) in \(spec.directory)")
        discussionsTask?.cancel()
        let dir = spec.directory
        discussionsTask = Task { [weak self] in
            do {
                let result = try await fetchMRDiscussions(mrIID: iid, directory: dir)
                guard !Task.isCancelled else { return }
                NSLog("[cmux-mr-comments] fetched \(result.count) discussions")
                for d in result {
                    NSLog("[cmux-mr-comments]   id=\(d.id) file=\(d.filePath ?? "?") old=\(d.oldLine.map { "\($0)" } ?? "-") new=\(d.newLine.map { "\($0)" } ?? "-") notes=\(d.notes.count)")
                }
                self?.mrDiscussions = result
            } catch {
                NSLog("[cmux-mr-comments] fetch failed: \(error)")
            }
        }
    }

    private func loadOverviewIfNeeded() {
        guard let iid = spec.mergeRequestIID else {
            mrOverview = nil
            return
        }
        overviewTask?.cancel()
        let dir = spec.directory
        overviewTask = Task { [weak self] in
            do {
                let result = try await fetchMROverview(mrIID: iid, directory: dir)
                guard !Task.isCancelled else { return }
                self?.mrOverview = result
            } catch {
                NSLog("[cmux-mr-overview] fetch failed: \(error)")
            }
        }
    }

    func updateSpec(_ newSpec: GitDiffSpec) {
        spec = newSpec
        selectedFile = nil
        currentDiff = ""
        files = []
        loadFileList()
    }

    private func loadFileList() {
        fileListTask?.cancel()
        isLoadingFiles = true
        filesError = nil
        missingRefs = []

        fileListTask = Task { [weak self] in
            guard let self else { return }
            let spec = self.spec
            do {
                let result = try await fetchChangedFiles(spec: spec)
                guard !Task.isCancelled else { return }
                self.files = result
                self.isLoadingFiles = false
                if self.selectedFile == nil, let first = result.first {
                    self.select(first)
                }
                // Conflict detection runs after the list is shown so the file
                // sidebar isn't blocked on a second git invocation.
                let conflicts = await fetchConflictingPaths(spec: spec)
                guard !Task.isCancelled, !conflicts.isEmpty else { return }
                self.files = self.files.map { file in
                    var f = file
                    f.hasConflict = conflicts.contains(file.path)
                        || (file.oldPath.map { conflicts.contains($0) } ?? false)
                    return f
                }
                if let sel = self.selectedFile,
                   let updated = self.files.first(where: { $0.path == sel.path }) {
                    self.selectedFile = updated
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.files = []
                if let e = error as? GitDiffError,
                   case let .missingRefs(branches, remote) = e {
                    self.missingRefs = branches
                    self.missingRefsRemote = remote
                }
                self.filesError = Self.message(for: error)
                self.isLoadingFiles = false
            }
        }
    }

    func fetchMissingRefs() async {
        guard !missingRefs.isEmpty, !isFetchingRefs else { return }
        let refs = missingRefs
        let remote = missingRefsRemote
        let directory = spec.directory
        let mrIID = spec.mergeRequestIID
        isFetchingRefs = true
        do {
            // SHAs (from MR diff_refs) need a different fetch path than branch
            // names: GitLab may not advertise them by name, so we ask the
            // server for the SHA directly or fall back to refs/merge-requests.
            if refs.allSatisfy(looksLikeGitSHA) {
                try await ensureGitCommitsPresent(refs, remote: remote, directory: directory, mrIID: mrIID)
            } else {
                try await fetchGitBranches(refs, remote: remote, directory: directory)
            }
            isFetchingRefs = false
            missingRefs = []
            filesError = nil
            reload()
        } catch {
            isFetchingRefs = false
            filesError = Self.message(for: error)
        }
    }

    func select(_ file: GitDiffFile) {
        overviewSelected = false
        if selectedFile?.path == file.path { return }
        selectedFile = file
        loadDiff(for: file)
    }

    private func loadDiff(for file: GitDiffFile) {
        diffTask?.cancel()
        currentDiff = ""
        diffError = nil
        isLoadingDiff = true

        let spec = self.spec
        let useConflictDiff = file.hasConflict
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let diff: String
                if useConflictDiff {
                    diff = try await fetchUnifiedDiffWithConflictMarkers(spec: spec, file: file.path)
                } else {
                    diff = try await fetchUnifiedDiff(spec: spec, file: file.path)
                }
                guard !Task.isCancelled, self.selectedFile?.path == file.path else { return }
                self.currentDiff = diff
                self.isLoadingDiff = false
            } catch {
                guard !Task.isCancelled, self.selectedFile?.path == file.path else { return }
                self.diffError = Self.message(for: error)
                self.currentDiff = ""
                self.isLoadingDiff = false
            }
        }

        loadConflictRegions(for: file)
        loadThreeWayBlobs(for: file)
    }

    private func loadThreeWayBlobs(for file: GitDiffFile) {
        threeWayTask?.cancel()
        threeWayBlobs = nil
        guard file.hasConflict, spec.compare != nil, !file.isBinary else {
            isLoadingThreeWay = false
            return
        }
        isLoadingThreeWay = true
        let spec = self.spec
        threeWayTask = Task { [weak self] in
            guard let self else { return }
            let blobs: ThreeWayBlobs?
            do {
                blobs = try await fetchOursBaseTheirs(spec: spec, file: file)
            } catch {
                blobs = nil
            }
            guard !Task.isCancelled, self.selectedFile?.path == file.path else { return }
            self.threeWayBlobs = blobs
            self.isLoadingThreeWay = false
        }
    }

    private func loadConflictRegions(for file: GitDiffFile) {
        conflictTask?.cancel()
        currentConflict = nil
        guard file.hasConflict else {
            isLoadingConflict = false
            return
        }
        isLoadingConflict = true
        let spec = self.spec
        conflictTask = Task { [weak self] in
            guard let self else { return }
            let result = await fetchConflictRegions(spec: spec, path: file.path)
            guard !Task.isCancelled, self.selectedFile?.path == file.path else { return }
            self.currentConflict = result
            self.isLoadingConflict = false
        }
    }

    private static func message(for error: Error) -> String {
        if let e = error as? GitDiffError {
            switch e {
            case .gitNotFound: return String(localized: "diff.error.gitNotFound", defaultValue: "git not found")
            case .notAGitRepo: return String(localized: "diff.error.notGit", defaultValue: "Not a git repository")
            case .processError(let m): return m.isEmpty ? "git error" : m
            case .missingRefs(let branches, let remote):
                let list = branches.joined(separator: ", ")
                return String(
                    localized: "diff.error.missingRefs",
                    defaultValue: "Branch not available locally or on \(remote): \(list)"
                )
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Display Mode

enum GitDiffDisplayMode: String, CaseIterable {
    case sideBySide
    case unified
}

// MARK: - Main View

enum FileListMode: String {
    case tree
    case flat
}

struct GitDiffWindowView: View {
    @ObservedObject var viewModel: GitDiffViewModel
    @State private var displayMode: GitDiffDisplayMode = .sideBySide
    @State private var fileListMode: FileListMode = .flat
    @State private var prepared: SideBySidePrepared = .empty
    @State private var threeWayPrepared: ThreeWayPrepared = .empty
    @State private var scrollHunkIndex: Int? = nil
    @State private var activeHunk: Int = 0
    @State private var collapsedFolders: Set<String> = []
    @State private var isApproving: Bool = false
    @State private var approveMessage: String? = nil
    @State private var expandedBlocks: Set<Int> = []
    @State private var isFileListCollapsed: Bool

    init(viewModel: GitDiffViewModel) {
        self.viewModel = viewModel
        // A diff scoped to one pathspec — what the Changes sidebar opens on a
        // click — has nothing to navigate to, so the file list would be a
        // single row taking 300 pt. Start it collapsed; the toolbar button
        // brings it back.
        _isFileListCollapsed = State(initialValue: viewModel.spec.pathspec?.count == 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The whole split is swapped rather than dropping one child of a
            // live `HSplitView`: an emptied-out pane leaves its divider
            // stranded against the window edge.
            if showsFileList {
                HSplitView {
                    fileListPane
                        .frame(minWidth: 60, idealWidth: 300)
                    diffPane
                        .frame(minWidth: 400, maxWidth: .infinity)
                }
            } else {
                diffPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .alert(
            String(localized: "diff.approve.result", defaultValue: "Approval"),
            isPresented: Binding(
                get: { approveMessage != nil },
                set: { if !$0 { approveMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { approveMessage = nil }
        } message: {
            Text(approveMessage ?? "")
        }
        .onAppear { rebuildPrepared() }
        .onChange(of: viewModel.currentDiff) { _ in rebuildPrepared() }
        .onChange(of: viewModel.mrDiscussions) { _ in rebuildPrepared() }
        .onChange(of: viewModel.selectedFile?.path) { _ in
            // Reset expansion state per file so a fresh file starts collapsed.
            expandedBlocks = []
            rebuildPrepared()
            rebuildThreeWayPrepared()
        }
        .onChange(of: viewModel.threeWayBlobs) { _ in rebuildThreeWayPrepared() }
        .background(HunkNavKeyMonitor(
            onPrev: goToPrevHunk,
            onNext: goToNextHunk,
            onEscape: closeWindow
        ))
    }

    /// Collapsing only holds while there is a diff on screen. When the file
    /// list failed to load, came back empty, or nothing got auto-selected, the
    /// pane carries the explanation — and the "Fetch and retry" button — so
    /// hiding it would leave the window with no way out.
    private var showsFileList: Bool {
        guard isFileListCollapsed else { return true }
        if viewModel.isLoadingFiles { return false }
        return viewModel.selectedFile == nil && !viewModel.overviewSelected
    }

    private func rebuildPrepared() {
        prepared = SideBySidePrepared.from(
            diffText: viewModel.currentDiff,
            filePath: viewModel.selectedFile?.path,
            expandedBlocks: expandedBlocks,
            discussions: viewModel.positionedDiscussions
        )
        NSLog("[cmux-mr-comments] rebuild file=\(viewModel.selectedFile?.path ?? "?") discussions=\(viewModel.mrDiscussions.count) widgets=\(prepared.inlineComments.count)")
        activeHunk = 0
        // Auto-scroll to the first change so opening a file lands the user
        // on the relevant lines instead of the top of a large file. Deferred
        // a little so SwiftUI has pushed the new attributed string down to
        // the NSTextView and its layout manager has computed glyph frames.
        if !prepared.leftHunkOffsets.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.scrollHunkIndex = 0
            }
        }
    }

    private func rebuildThreeWayPrepared() {
        guard let blobs = viewModel.threeWayBlobs,
              let file = viewModel.selectedFile else {
            threeWayPrepared = .empty
            return
        }
        threeWayPrepared = ThreeWayPrepared.from(
            blobs: blobs,
            filePath: file.path,
            conflict: viewModel.currentConflict
        )
        if !threeWayPrepared.hunkOffsetsBase.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.scrollHunkIndex = 0
            }
        }
    }

    private var isThreeWayActive: Bool {
        guard let file = viewModel.selectedFile else { return false }
        return file.hasConflict
            && viewModel.spec.compare != nil
            && !file.isBinary
            && (viewModel.threeWayBlobs?.base != nil)
    }

    private var hunkCount: Int {
        isThreeWayActive ? threeWayPrepared.hunkOffsetsBase.count : prepared.leftHunkOffsets.count
    }

    private func goToPrevHunk() {
        guard hunkCount > 0 else { return }
        activeHunk = max(0, activeHunk - 1)
        scrollHunkIndex = activeHunk
    }

    private func goToNextHunk() {
        guard hunkCount > 0 else { return }
        activeHunk = min(hunkCount - 1, activeHunk + 1)
        scrollHunkIndex = activeHunk
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    @ViewBuilder
    private func approveButton(iid: Int) -> some View {
        Button {
            approve(iid: iid)
        } label: {
            HStack(spacing: 4) {
                if isApproving {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark.circle")
                }
                Text(String(localized: "diff.approve", defaultValue: "Approve"))
                    .fontWeight(.medium)
            }
        }
        .disabled(isApproving)
        .help(String(
            localized: "diff.approve.tooltip",
            defaultValue: "Approve MR !\(iid) with glab"
        ))
    }

    private func approve(iid: Int) {
        isApproving = true
        let directory = viewModel.spec.directory
        Task {
            do {
                let result = try await approveGitLabMergeRequest(iid: iid, directory: directory)
                await MainActor.run {
                    isApproving = false
                    approveMessage = result.isEmpty ? "Approved !\(iid)." : result
                }
            } catch {
                await MainActor.run {
                    isApproving = false
                    if let err = error as? GitLabMRFetchError,
                       case let .processError(msg) = err {
                        approveMessage = msg
                    } else {
                        approveMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                isFileListCollapsed.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help(isFileListCollapsed
                ? String(localized: "diff.fileList.show", defaultValue: "Show file list")
                : String(localized: "diff.fileList.hide", defaultValue: "Hide file list"))
            Text(viewModel.spec.title)
                .font(.headline)
            Text(rangeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.secondary.opacity(0.12)))
            Spacer()
            if viewModel.isLoadingFiles {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            HStack(spacing: 2) {
                Button {
                    goToPrevHunk()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(hunkCount == 0)
                .help(String(localized: "diff.prevHunk", defaultValue: "Previous change (Shift+F7)"))
                Button {
                    goToNextHunk()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(hunkCount == 0)
                .help(String(localized: "diff.nextHunk", defaultValue: "Next change (F7)"))
                if hunkCount > 0 {
                    Text("\(min(activeHunk + 1, hunkCount))/\(hunkCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $displayMode) {
                Image(systemName: "rectangle.split.2x1").tag(GitDiffDisplayMode.sideBySide)
                    .help(String(localized: "diff.sideBySide", defaultValue: "Side by side"))
                Image(systemName: "list.bullet.indent").tag(GitDiffDisplayMode.unified)
                    .help(String(localized: "diff.unified", defaultValue: "Unified"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            if let iid = viewModel.spec.mergeRequestIID {
                approveButton(iid: iid)
            }
            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "diff.reload", defaultValue: "Reload"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var rangeLabel: String {
        if let compare = viewModel.spec.compare {
            return "\(viewModel.spec.base) ← \(compare)"
        }
        return "\(viewModel.spec.base) ← working tree"
    }

    @ViewBuilder
    private var fileListPane: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            if viewModel.isLoadingFiles && viewModel.files.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let err = viewModel.filesError, viewModel.files.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .textSelection(.enabled)
                    if !viewModel.missingRefs.isEmpty {
                        Button {
                            Task { await viewModel.fetchMissingRefs() }
                        } label: {
                            if viewModel.isFetchingRefs {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(String(
                                        localized: "diff.error.fetching",
                                        defaultValue: "Fetching…"
                                    ))
                                }
                            } else {
                                Label(
                                    String(
                                        localized: "diff.error.fetchAndRetry",
                                        defaultValue: "Fetch from \(viewModel.missingRefsRemote) and retry"
                                    ),
                                    systemImage: "arrow.clockwise"
                                )
                            }
                        }
                        .disabled(viewModel.isFetchingRefs)
                        .padding(.top, 4)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.files.isEmpty {
                VStack {
                    Spacer()
                    Text(String(localized: "diff.noChanges", defaultValue: "No changes"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                switch fileListMode {
                case .flat:
                    flatFileList
                case .tree:
                    treeFileList
                }
            }
        }
    }

    @ViewBuilder
    private var overviewRow: some View {
        if viewModel.hasOverview {
            GitDiffOverviewRow(
                count: viewModel.generalDiscussions.count,
                isSelected: viewModel.overviewSelected
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            .listRowSeparator(.hidden)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.overviewSelected = true
            }
        }
    }

    private var flatFileList: some View {
        List(selection: selectionBinding) {
            overviewRow
            ForEach(viewModel.files) { file in
                GitDiffFileRow(file: file)
                    .tag(file.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.select(file)
                    }
            }
        }
        .listStyle(.sidebar)
    }

    private var treeFileList: some View {
        let root = FileTreeBuilder.build(from: viewModel.files)
        return List(selection: selectionBinding) {
            overviewRow
            ForEach(flattenVisible(root, depth: 0), id: \.node.id) { entry in
                if let file = entry.node.file {
                    GitDiffFileRow(file: file, depth: entry.depth)
                        .tag(file.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.select(file)
                        }
                } else {
                    GitDiffFolderRow(
                        node: entry.node,
                        depth: entry.depth,
                        isExpanded: !collapsedFolders.contains(entry.node.id)
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleFolder(entry.node.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func flattenVisible(
        _ nodes: [FileTreeNode],
        depth: Int
    ) -> [(node: FileTreeNode, depth: Int)] {
        var result: [(FileTreeNode, Int)] = []
        for node in nodes {
            result.append((node, depth))
            if let children = node.children, !collapsedFolders.contains(node.id) {
                result.append(contentsOf: flattenVisible(children, depth: depth + 1))
            }
        }
        return result
    }

    private func toggleFolder(_ id: String) {
        if collapsedFolders.contains(id) {
            collapsedFolders.remove(id)
        } else {
            collapsedFolders.insert(id)
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedFile?.id },
            set: { newId in
                if let id = newId, let f = viewModel.files.first(where: { $0.id == id }) {
                    viewModel.select(f)
                }
            }
        )
    }

    private var summaryBar: some View {
        let totalAdds = viewModel.files.reduce(0) { $0 + $1.additions }
        let totalDels = viewModel.files.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 10) {
            Text("\(viewModel.files.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("+\(totalAdds)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
            Text("-\(totalDels)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
            Spacer()
            Picker("", selection: $fileListMode) {
                Image(systemName: "list.bullet.indent").tag(FileListMode.tree)
                    .help(String(localized: "diff.fileList.tree", defaultValue: "Tree view"))
                Image(systemName: "list.bullet").tag(FileListMode.flat)
                    .help(String(localized: "diff.fileList.flat", defaultValue: "Flat view"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 74)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var diffPane: some View {
        if viewModel.overviewSelected {
            OverviewDiscussionsPane(
                overview: viewModel.mrOverview,
                discussions: viewModel.generalDiscussions
            )
        } else if let file = viewModel.selectedFile {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(file.path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if viewModel.isLoadingDiff {
                        ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                if let err = viewModel.diffError {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.currentDiff.isEmpty && !viewModel.isLoadingDiff {
                    VStack {
                        Spacer()
                        Text(String(localized: "diff.binaryOrEmpty", defaultValue: "Binary or empty diff"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isThreeWayActive {
                    DiffThreeWayCodeTextView(
                        prepared: threeWayPrepared,
                        scrollHunkIndex: $scrollHunkIndex
                    )
                } else if file.hasConflict
                            && viewModel.spec.compare != nil
                            && !file.isBinary
                            && viewModel.isLoadingThreeWay {
                    VStack {
                        Spacer()
                        ProgressView()
                        Text(String(
                            localized: "diff.threeWay.loading",
                            defaultValue: "Loading 3-way conflict view…"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch displayMode {
                    case .sideBySide:
                        SideBySideDiffView(
                            prepared: prepared,
                            scrollHunkIndex: $scrollHunkIndex,
                            onExpandBlock: { blockId in
                                expandedBlocks.insert(blockId)
                                rebuildPrepared()
                            }
                        )
                    case .unified:
                        UnifiedDiffTextView(
                            text: viewModel.currentDiff,
                            filePath: viewModel.selectedFile?.path
                        )
                    }
                }
            }
        } else {
            VStack {
                Spacer()
                Text(String(localized: "diff.selectFile", defaultValue: "Select a file to view its diff"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - File Row

private enum DiffTreeMetrics {
    static let indentWidth: CGFloat = 5
    static let chevronWidth: CGFloat = 11
    static let rowVerticalPadding: CGFloat = 1
}

private struct DiffTreeIndentGuides: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1)
                }
                .frame(width: DiffTreeMetrics.indentWidth)
            }
        }
    }
}

private struct GitDiffFileRow: View {
    let file: GitDiffFile
    var depth: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            DiffTreeIndentGuides(depth: depth)
            HStack(spacing: 5) {
                // Empty slot where a sibling folder's chevron would sit, so
                // file names stay aligned with folders above.
                Spacer().frame(width: DiffTreeMetrics.chevronWidth)
                let icon = GitDiffFileIcon.info(for: file.path)
                ZStack {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(icon.color)
                    if file.hasConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(GitDiffConflictStyle.color)
                            .offset(x: 5, y: 5)
                    }
                }
                .frame(width: 14, height: 14)
                .help(file.hasConflict ? GitDiffConflictStyle.tooltip : "")
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if depth == 0 {
                    let parent = (file.path as NSString).deletingLastPathComponent
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if file.isBinary {
                    Text("BIN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(file.changeType.symbol)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: .trailing)
            }
        }
        .help(file.hasConflict
              ? "\(file.path) — \(GitDiffConflictStyle.tooltip)"
              : file.path)
    }
}

// MARK: - Conflict banner

private struct GitDiffConflictBanner: View {
    let isLoading: Bool
    let conflict: GitDiffFileConflict?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(GitDiffConflictStyle.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GitDiffConflictStyle.color)
                if let conflict, !conflict.regions.isEmpty {
                    Text(rangesText(conflict.regions))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(GitDiffConflictStyle.color.opacity(0.10))
    }

    private var headline: String {
        if let conflict, !conflict.regions.isEmpty {
            let n = conflict.regions.count
            return String(
                localized: "diff.conflict.banner.regions",
                defaultValue: "Merge conflict — \(n) region\(n == 1 ? "" : "s") in the merged result"
            )
        }
        return String(
            localized: "diff.conflict.banner.title",
            defaultValue: "This file has a merge conflict"
        )
    }

    private func rangesText(_ regions: [GitDiffConflictRegion]) -> String {
        let prefix = String(localized: "diff.conflict.banner.lines", defaultValue: "Lines")
        let parts = regions.map { r in
            r.startLine == r.endLine ? "L\(r.startLine)" : "L\(r.startLine)–L\(r.endLine)"
        }
        return "\(prefix): \(parts.joined(separator: ", "))"
    }
}

// MARK: - Conflict styling

private enum GitDiffConflictStyle {
    /// VS Code-like amber/orange used for conflict warnings.
    static let color = Color(nsColor: NSColor(srgbRed: 0xE5/255, green: 0x8E/255, blue: 0x26/255, alpha: 1))
    static var tooltip: String {
        String(localized: "diff.fileList.hasConflicts", defaultValue: "Has merge conflicts")
    }
}

// MARK: - File-type icons

private enum GitDiffFileIcon {
    struct Info {
        let symbol: String
        let color: Color
    }

    private static let orange = Color(nsColor: NSColor(srgbRed: 0xE0/255, green: 0x77/255, blue: 0x2C/255, alpha: 1))
    private static let amber  = Color(nsColor: NSColor(srgbRed: 0xE5/255, green: 0xA5/255, blue: 0x2C/255, alpha: 1))
    private static let blue   = Color(nsColor: NSColor(srgbRed: 0x4F/255, green: 0x9D/255, blue: 0xE0/255, alpha: 1))
    private static let green  = Color(nsColor: NSColor(srgbRed: 0x6F/255, green: 0xB8/255, blue: 0x6F/255, alpha: 1))
    private static let purple = Color(nsColor: NSColor(srgbRed: 0xA9/255, green: 0x7B/255, blue: 0xFF/255, alpha: 1))
    private static let teal   = Color(nsColor: NSColor(srgbRed: 0x29/255, green: 0xBE/255, blue: 0xB0/255, alpha: 1))
    private static let pink   = Color(nsColor: NSColor(srgbRed: 0xE8/255, green: 0x6F/255, blue: 0xA8/255, alpha: 1))
    private static let neutral = Color.secondary

    static func info(for path: String) -> Info {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return Info(symbol: "swift", color: orange)
        case "kt", "kts":
            return Info(symbol: "k.square.fill", color: purple)
        case "java":
            return Info(symbol: "cup.and.saucer.fill", color: orange)
        case "xml", "html", "htm", "plist", "storyboard", "xib":
            return Info(symbol: "chevron.left.forwardslash.chevron.right", color: orange)
        case "json":
            return Info(symbol: "curlybraces", color: amber)
        case "js", "jsx", "mjs", "cjs":
            return Info(symbol: "j.square.fill", color: amber)
        case "ts", "tsx":
            return Info(symbol: "t.square.fill", color: blue)
        case "md", "markdown", "rst":
            return Info(symbol: "doc.richtext", color: blue)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "icns", "svg":
            return Info(symbol: "photo.fill", color: pink)
        case "yml", "yaml", "toml", "ini", "cfg", "conf":
            return Info(symbol: "slider.horizontal.3", color: amber)
        case "sh", "bash", "zsh", "fish":
            return Info(symbol: "terminal.fill", color: green)
        case "py":
            return Info(symbol: "p.square.fill", color: blue)
        case "rs":
            return Info(symbol: "r.square.fill", color: orange)
        case "go":
            return Info(symbol: "g.square.fill", color: teal)
        case "c", "cc", "cpp", "h", "hh", "hpp", "m", "mm":
            return Info(symbol: "c.square.fill", color: blue)
        case "css", "scss", "sass", "less":
            return Info(symbol: "paintbrush.fill", color: blue)
        case "rb":
            return Info(symbol: "diamond.fill", color: pink)
        case "zig":
            return Info(symbol: "z.square.fill", color: orange)
        case "lock", "gitignore", "gitattributes", "gitmodules":
            return Info(symbol: "lock.fill", color: neutral)
        case "txt", "log":
            return Info(symbol: "doc.plaintext.fill", color: neutral)
        case "":
            return Info(symbol: "doc.fill", color: neutral)
        default:
            return Info(symbol: "doc.text.fill", color: neutral)
        }
    }
}

// MARK: - File tree

struct FileTreeNode: Identifiable, Equatable {
    let id: String            // full path segments joined, or file path
    let displayName: String   // folder name or filename
    let file: GitDiffFile?    // nil → folder
    var additions: Int
    var deletions: Int
    var fileCount: Int
    var hasConflict: Bool = false
    var children: [FileTreeNode]?
}

enum FileTreeBuilder {
    static func build(from files: [GitDiffFile]) -> [FileTreeNode] {
        var roots: [FileTreeNode] = []
        for file in files {
            insert(file: file, into: &roots, pathPrefix: "")
        }
        sortInPlace(&roots)
        aggregateStats(&roots)
        // Collapse single-child folder chains like `src/components/ui` into one row,
        // matching VS Code's "compact folders" default.
        for i in roots.indices {
            roots[i] = compact(roots[i])
        }
        return roots
    }

    private static func insert(file: GitDiffFile, into nodes: inout [FileTreeNode], pathPrefix: String) {
        let fullPath = file.path
        let components = fullPath.split(separator: "/").map(String.init)
        insertInto(&nodes, components: components, file: file, pathPrefix: pathPrefix)
    }

    private static func insertInto(
        _ nodes: inout [FileTreeNode],
        components: [String],
        file: GitDiffFile,
        pathPrefix: String
    ) {
        guard let first = components.first else { return }
        let newPrefix = pathPrefix.isEmpty ? first : pathPrefix + "/" + first
        if components.count == 1 {
            nodes.append(FileTreeNode(
                id: newPrefix,
                displayName: first,
                file: file,
                additions: file.additions,
                deletions: file.deletions,
                fileCount: 1,
                hasConflict: file.hasConflict,
                children: nil
            ))
            return
        }
        let rest = Array(components.dropFirst())
        if let idx = nodes.firstIndex(where: { $0.file == nil && $0.displayName == first }) {
            var folder = nodes[idx]
            var children = folder.children ?? []
            insertInto(&children, components: rest, file: file, pathPrefix: newPrefix)
            folder.children = children
            nodes[idx] = folder
        } else {
            var children: [FileTreeNode] = []
            insertInto(&children, components: rest, file: file, pathPrefix: newPrefix)
            nodes.append(FileTreeNode(
                id: "folder:" + newPrefix,
                displayName: first,
                file: nil,
                additions: 0,
                deletions: 0,
                fileCount: 0,
                children: children
            ))
        }
    }

    private static func sortInPlace(_ nodes: inout [FileTreeNode]) {
        nodes.sort { lhs, rhs in
            let lIsFolder = lhs.file == nil
            let rIsFolder = rhs.file == nil
            if lIsFolder != rIsFolder { return lIsFolder && !rIsFolder }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        for i in nodes.indices {
            if var children = nodes[i].children {
                sortInPlace(&children)
                nodes[i].children = children
            }
        }
    }

    @discardableResult
    private static func aggregateStats(_ nodes: inout [FileTreeNode]) -> (adds: Int, dels: Int, count: Int, conflict: Bool) {
        var totalAdds = 0
        var totalDels = 0
        var totalCount = 0
        var anyConflict = false
        for i in nodes.indices {
            if var children = nodes[i].children {
                let child = aggregateStats(&children)
                nodes[i].children = children
                nodes[i].additions = child.adds
                nodes[i].deletions = child.dels
                nodes[i].fileCount = child.count
                nodes[i].hasConflict = child.conflict
                totalAdds += child.adds
                totalDels += child.dels
                totalCount += child.count
                if child.conflict { anyConflict = true }
            } else {
                totalAdds += nodes[i].additions
                totalDels += nodes[i].deletions
                totalCount += 1
                if nodes[i].hasConflict { anyConflict = true }
            }
        }
        return (totalAdds, totalDels, totalCount, anyConflict)
    }

    /// Collapse chains like foo → bar → baz where each has exactly one folder child
    /// into a single node named "foo/bar/baz". Stops when the descendant is a file or
    /// has more than one child.
    private static func compact(_ node: FileTreeNode) -> FileTreeNode {
        var node = node
        if var children = node.children {
            for i in children.indices {
                children[i] = compact(children[i])
            }
            node.children = children
            if node.file == nil, children.count == 1, children[0].file == nil {
                let only = children[0]
                return FileTreeNode(
                    id: node.id,
                    displayName: node.displayName + "/" + only.displayName,
                    file: nil,
                    additions: only.additions,
                    deletions: only.deletions,
                    fileCount: only.fileCount,
                    hasConflict: only.hasConflict,
                    children: only.children
                )
            }
        }
        return node
    }
}

private struct GitDiffOverviewRow: View {
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: DiffTreeMetrics.chevronWidth)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            Text("Overview")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, DiffTreeMetrics.rowVerticalPadding)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
    }
}

private struct OverviewDiscussionsPane: View {
    let overview: MROverview?
    let discussions: [MRDiscussion]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(String(
                    localized: "diff.overview.title",
                    defaultValue: "General discussion"
                ))
                .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(discussions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let overview {
                        MRDescriptionCard(overview: overview)
                    }
                    timelineHeader
                    if discussions.isEmpty {
                        Text(String(
                            localized: "diff.overview.empty",
                            defaultValue: "No general comments"
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                    } else {
                        ForEach(discussions) { d in
                            InlineCommentCard(discussion: d)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: DiffCodeContainer.editorBackground))
    }

    @ViewBuilder
    private var timelineHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "diff.overview.timeline",
                defaultValue: "Comments"
            ))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(nsColor: NSColor(white: 1, alpha: 0.08)))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

private struct MRDescriptionCard: View {
    let overview: MROverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !overview.title.isEmpty {
                Text(overview.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if !displayName.isEmpty {
                    Text(displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MRCommentMetaStyle.metaColor)
                }
                if let when = overview.createdAt {
                    Text("·")
                        .font(.system(size: 13))
                        .foregroundStyle(MRCommentMetaStyle.metaColor)
                    Text(formatted(when))
                        .font(.system(size: 13))
                        .foregroundStyle(MRCommentMetaStyle.metaColor)
                }
                Spacer()
            }
            if overview.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(String(
                    localized: "diff.overview.noDescription",
                    defaultValue: "No description"
                ))
                .font(.system(size: 14))
                .foregroundStyle(MRCommentMetaStyle.metaColor)
                .italic()
            } else {
                MarkdownText(source: overview.description, baseFontSize: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, MRCommentCardStyle.innerHorizontalPadding)
        .padding(.vertical, MRCommentCardStyle.innerVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MRCommentCardStyle.cornerRadius)
                .fill(MRCommentCardStyle.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MRCommentCardStyle.cornerRadius)
                .strokeBorder(MRCommentCardStyle.border, lineWidth: 1)
        )
        .padding(.horizontal, 6)
    }

    private var displayName: String {
        if !overview.authorName.isEmpty { return overview.authorName }
        return overview.authorUsername.isEmpty ? "" : "@\(overview.authorUsername)"
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

private struct GitDiffFolderRow: View {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            DiffTreeIndentGuides(depth: depth)
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: DiffTreeMetrics.chevronWidth)
                Text(node.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.vertical, DiffTreeMetrics.rowVerticalPadding)
        }
    }
}

// MARK: - Unified Diff Text View (NSTextView-backed for perf)

struct UnifiedDiffTextView: NSViewRepresentable {
    let text: String
    let filePath: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        update(textView: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        update(textView: textView)
    }

    private func update(textView: NSTextView) {
        let attributed = Self.attributedDiff(from: text, filePath: filePath)
        textView.textStorage?.setAttributedString(attributed)
    }

    static func attributedDiff(from text: String, filePath: String?) -> NSAttributedString {
        let font = codeFont()
        let language = filePath.map { HighlightLanguage.detect(fromFilePath: $0) } ?? .plaintext

        // Build: keep track of per-line ranges and their kind so we can apply
        // row backgrounds and also run syntax highlighting only on the content
        // portion (skipping the leading marker character).
        let result = NSMutableAttributedString()
        // For syntax highlighting we maintain a parallel "pure content" string
        // and the mapping from its indices back into `result`.
        let pureContent = NSMutableString()
        var segments: [(contentRange: NSRange, resultRange: NSRange)] = []

        var lineRanges: [(NSRange, NSColor?)] = []

        text.enumerateLines { line, _ in
            let fg: NSColor
            let bg: NSColor?
            let hasContent: Bool
            let contentStartOffset: Int
            if line.hasPrefix("+++") || line.hasPrefix("---")
                || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
                || line.hasPrefix("Binary ") {
                fg = .secondaryLabelColor
                bg = nil
                hasContent = false
                contentStartOffset = 0
            } else if line.hasPrefix("@@") {
                fg = .systemBlue
                bg = NSColor.systemBlue.withAlphaComponent(0.1)
                hasContent = false
                contentStartOffset = 0
            } else if line.hasPrefix("+") {
                fg = .labelColor
                bg = NSColor.systemGreen.withAlphaComponent(0.16)
                hasContent = true
                contentStartOffset = 1
            } else if line.hasPrefix("-") {
                fg = .labelColor
                bg = NSColor.systemRed.withAlphaComponent(0.16)
                hasContent = true
                contentStartOffset = 1
            } else {
                fg = .labelColor
                bg = nil
                hasContent = true
                contentStartOffset = line.isEmpty ? 0 : 1
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fg,
            ]
            if let bg { attrs[.backgroundColor] = bg }
            let rendered = line + "\n"
            let resultStart = result.length
            result.append(NSAttributedString(string: rendered, attributes: attrs))
            let resultRange = NSRange(location: resultStart, length: rendered.utf16.count)
            lineRanges.append((resultRange, bg))
            if hasContent {
                let trimmedStart = resultStart + contentStartOffset
                let contentUTF16 = (line as NSString).length - contentStartOffset
                if contentUTF16 > 0 {
                    let contentStart = pureContent.length
                    let contentStr = (line as NSString).substring(from: contentStartOffset)
                    pureContent.append(contentStr + "\n")
                    segments.append((
                        contentRange: NSRange(location: contentStart, length: contentUTF16 + 1),
                        resultRange: NSRange(location: trimmedStart, length: contentUTF16 + 1)
                    ))
                } else {
                    pureContent.append("\n")
                }
            } else {
                pureContent.append("\n")
            }
        }

        // Syntax highlight the reconstructed "code" side, then copy the
        // foreground attributes back onto the visible result at the mapped
        // ranges. This keeps markers and headers in their neutral color.
        let contentAttr = NSMutableAttributedString(
            string: pureContent as String,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        SyntaxHighlighter.apply(to: contentAttr, language: language)
        for seg in segments {
            contentAttr.enumerateAttribute(
                .foregroundColor,
                in: seg.contentRange,
                options: []
            ) { value, subRange, _ in
                guard let color = value as? NSColor else { return }
                let offsetInSeg = subRange.location - seg.contentRange.location
                let targetLoc = seg.resultRange.location + offsetInSeg
                let targetRange = NSRange(location: targetLoc, length: subRange.length)
                if targetRange.location + targetRange.length <= result.length {
                    result.addAttribute(.foregroundColor, value: color, range: targetRange)
                }
            }
        }
        return result
    }
}

// MARK: - Side-by-side Diff View

/// Pre-built data for side-by-side rendering. Computing attributed strings
/// every body pass would be slow for large diffs; the window view caches this
/// value in `@State` and only rebuilds when the diff text changes.
struct DiffRowBackground {
    let range: NSRange
    let color: NSColor
}

struct DiffCollapsedStub: Equatable {
    let blockId: Int
    /// Character ranges of the stub row in the left/right attributed strings.
    let leftCharRange: NSRange
    let rightCharRange: NSRange
    let hiddenLines: Int
}

enum DiffCommentSide: Equatable, Sendable { case left, right }

/// Metadata describing an inline MR-discussion card to be drawn underneath
/// a specific anchor line in one of the two text views. The builder reserves
/// `reservedHeight` of vertical space via placeholder rows at
/// `anchorCharIndex`; `DiffTextView` overlays an NSHostingView at that spot.
struct InlineCommentWidget: Identifiable, Equatable {
    let id: String
    let side: DiffCommentSide
    let anchorCharIndex: Int
    let reservedHeight: CGFloat
    let discussion: MRDiscussion
    /// When true, the rendered card is taller than `reservedHeight` and must
    /// scroll internally so it doesn't visually overflow the next code line.
    let useInternalScroll: Bool
}

/// Best-effort height estimate for an `InlineCommentCard`. Used to reserve
/// the right number of placeholder rows so a thread with many notes doesn't
/// visually overlap the next code line. Slightly generous on purpose — we'd
/// rather leave a sliver of empty space than clip a comment.
func estimatedCardHeight(for discussion: MRDiscussion) -> CGFloat {
    // Card paddings (vertical): outer .padding(.vertical, 2) on both sides
    // (4pt) + inner VStack .padding(8) on both sides (16pt).
    var height: CGFloat = 4 + 16
    // System body font is 12pt, ~16pt per wrapped line in practice.
    let bodyLineHeight: CGFloat = 16
    // Approximate average character width for the proportional body font.
    let avgCharWidth: CGFloat = 6.5
    // Approximate inner content width; the actual width depends on the diff
    // column at runtime, so this is a rough but stable target.
    let bodyContentWidth: CGFloat = 480
    let charsPerLine = max(20, Int(bodyContentWidth / avgCharWidth))
    let dividerHeight: CGFloat = 1
    for (idx, note) in discussion.notes.enumerated() {
        if idx > 0 { height += dividerHeight }
        // Per-note vertical padding (2pt top + 2pt bottom).
        height += 4
        // Header HStack with avatar (18pt circle) and meta text.
        height += 22
        // VStack spacing(4) between header and body.
        height += 4
        // Body wraps; count visual lines from explicit \n + width-based wrap.
        // Markdown extras: GFM table rows (lines starting with `|`) render
        // ~1.6× taller than plain text due to cell padding and borders, and
        // each fenced ``` code block adds extra vertical chrome (padding +
        // rounded background) — account for both so we don't underreserve
        // when a comment has rich markdown.
        let segments = note.body.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: CGFloat = 0
        var codeFenceCount = 0
        for seg in segments {
            let trimmed = seg.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                codeFenceCount += 1
            }
            let len = seg.count
            let baseLines: CGFloat
            if len == 0 {
                baseLines = 1
            } else {
                baseLines = ceil(CGFloat(len) / CGFloat(charsPerLine))
            }
            let multiplier: CGFloat = trimmed.hasPrefix("|") ? 1.6 : 1.0
            lines += baseLines * multiplier
        }
        if lines < 1 { lines = 1 }
        height += lines * bodyLineHeight
        // One ``` block contributes one open + one close fence, so each pair
        // adds the rounded-background chrome (~10pt) once.
        height += CGFloat(codeFenceCount / 2) * 10
    }
    // Safety margin so anti-aliased edges and markdown block margins aren't
    // clipped by the placeholder run.
    height += 12
    return height
}

struct SideBySidePrepared: Equatable {
    var leftAttr: NSAttributedString
    var rightAttr: NSAttributedString
    var leftHunkOffsets: [Int]
    var rightHunkOffsets: [Int]
    var leftLineKinds: [SideBySideLineKind]
    var rightLineKinds: [SideBySideLineKind]
    var leftRowBackgrounds: [DiffRowBackground]
    var rightRowBackgrounds: [DiffRowBackground]
    /// Clickable stubs that replaced long runs of unchanged lines.
    var collapsedStubs: [DiffCollapsedStub] = []
    /// Overlay widgets drawn by the text view underneath anchor lines, one
    /// per MR discussion (read-only for now).
    var inlineComments: [InlineCommentWidget] = []
    /// Line numbers for the line number gutter (nil = no number shown).
    var leftLineNumbers: [Int?]
    var rightLineNumbers: [Int?]
    /// UTF-16 character indices at the start of each line, parallel to
    /// `*LineNumbers`. Used by the gutter ruler to map glyph → line index.
    var leftLineStarts: [Int]
    var rightLineStarts: [Int]
    /// IntelliJ-style ribbon segments connecting matching hunks across the
    /// two panes. Computed once per rebuild and consumed by `DiffConnectorView`.
    var connectorSegments: [DiffConnectorSegment] = []
    /// For each row index in the left side's arrays, the right row that should
    /// be aligned with it in the viewport. Drives the row-mapped scroll sync
    /// (replaces the old wheel-1:1 forwarding so the two panes can have
    /// different total heights without one getting "stuck").
    var leftRowToRightRow: [Int] = []
    var rightRowToLeftRow: [Int] = []

    static let empty = SideBySidePrepared(
        leftAttr: NSAttributedString(),
        rightAttr: NSAttributedString(),
        leftHunkOffsets: [],
        rightHunkOffsets: [],
        leftLineKinds: [],
        rightLineKinds: [],
        leftRowBackgrounds: [],
        rightRowBackgrounds: [],
        leftLineNumbers: [],
        rightLineNumbers: [],
        leftLineStarts: [],
        rightLineStarts: [],
        connectorSegments: [],
        leftRowToRightRow: [],
        rightRowToLeftRow: []
    )

    static func == (lhs: SideBySidePrepared, rhs: SideBySidePrepared) -> Bool {
        lhs.leftAttr.isEqual(to: rhs.leftAttr)
            && rhs.rightAttr.isEqual(to: lhs.rightAttr)
            && lhs.leftHunkOffsets == rhs.leftHunkOffsets
            && lhs.rightHunkOffsets == rhs.rightHunkOffsets
            && lhs.leftLineKinds == rhs.leftLineKinds
            && lhs.rightLineKinds == rhs.rightLineKinds
            && lhs.leftLineNumbers == rhs.leftLineNumbers
            && lhs.rightLineNumbers == rhs.rightLineNumbers
            && lhs.connectorSegments == rhs.connectorSegments
            && lhs.leftRowToRightRow == rhs.leftRowToRightRow
            && lhs.rightRowToLeftRow == rhs.rightRowToLeftRow
    }

    static func from(
        diffText: String,
        filePath: String?,
        expandedBlocks: Set<Int> = [],
        discussions: [MRDiscussion] = []
    ) -> SideBySidePrepared {
        let rows = parseSideBySideRows(from: diffText)
        if rows.isEmpty { return .empty }
        let font = codeFont()
        // Force min/max line height equal to the font's natural line height so
        // background colors fill the row continuously (setting only
        // lineHeightMultiple leaves a gap between consecutive highlighted lines).
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let language = filePath.map { HighlightLanguage.detect(fromFilePath: $0) } ?? .plaintext

        // Compute gutter width from the max line number seen in any row.
        let left = NSMutableAttributedString()
        let right = NSMutableAttributedString()
        var leftHunks: [Int] = []
        var rightHunks: [Int] = []
        var leftLineKinds: [SideBySideLineKind] = []
        var rightLineKinds: [SideBySideLineKind] = []
        var leftLineNumbers: [Int?] = []
        var rightLineNumbers: [Int?] = []
        var leftLineStarts: [Int] = []
        var rightLineStarts: [Int] = []
        var leftContentRanges: [NSRange] = []
        var rightContentRanges: [NSRange] = []
        var leftRowBackgrounds: [(NSRange, NSColor)] = []
        var rightRowBackgrounds: [(NSRange, NSColor)] = []
        var leftIntraRanges: [(NSRange, NSColor)] = []
        var rightIntraRanges: [(NSRange, NSColor)] = []

        // Returns the row index just appended on this side, or nil for empty
        // cells (which contribute no row in the IntelliJ-style asymmetric
        // layout — the empty band is rendered by the connector view's funnel
        // shape, not by a placeholder row taking vertical space).
        func appendLine(
            into attr: NSMutableAttributedString,
            cell: SideBySideCell,
            kinds: inout [SideBySideLineKind],
            lineNumbers: inout [Int?],
            lineStarts: inout [Int],
            contentRanges: inout [NSRange],
            rowBackgrounds: inout [(NSRange, NSColor)],
            intraRanges: inout [(NSRange, NSColor)]
        ) -> Int? {
            if cell.kind == .empty { return nil }
            let rowIndex = kinds.count
            let start = attr.length
            lineStarts.append(start)
            let content = cell.content
            let rendered = content + "\n"
            attr.append(NSAttributedString(
                string: rendered,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            let contentUTF16Len = (content as NSString).length
            let renderedUTF16Len = (rendered as NSString).length
            if let rowBg = rowBackgroundColor(for: cell.kind) {
                let range = NSRange(location: start, length: renderedUTF16Len)
                rowBackgrounds.append((range, rowBg))
            }
            if contentUTF16Len > 0 {
                contentRanges.append(NSRange(location: start, length: contentUTF16Len))
            }
            if !cell.intraLineRanges.isEmpty, let stronger = intraLineColor(for: cell.kind) {
                for r in cell.intraLineRanges {
                    let adjusted = NSRange(location: start + r.location, length: r.length)
                    intraRanges.append((adjusted, stronger))
                }
            }
            kinds.append(cell.kind)
            lineNumbers.append(cell.lineNumber)
            return rowIndex
        }

        // Extract pair rows (the ones that render as lines) so we can detect
        // long runs of unchanged context and collapse them. Hunk headers are
        // already skipped.
        let pairs: [(SideBySideCell, SideBySideCell)] = rows.compactMap { row in
            switch row {
            case .pair(_, let l, let r): return (l, r)
            default: return nil
            }
        }

        // Detect collapsible runs of "both-sides-context" rows. Keep
        // `contextMargin` lines on each side of a change visible.
        let contextMargin = 3
        let collapseThreshold = 8
        var collapseRanges: [(start: Int, end: Int)] = []
        var runStart: Int? = nil
        func bothContext(_ i: Int) -> Bool {
            let l = pairs[i].0.kind
            let r = pairs[i].1.kind
            return l == .context && r == .context
        }
        func closeRun(at end: Int) {
            guard let s = runStart else { return }
            let atTop = (s == 0)
            let atBottom = (end == pairs.count)
            let hideStart = atTop ? s : s + contextMargin
            let hideEnd = atBottom ? end : end - contextMargin
            if hideEnd - hideStart >= collapseThreshold {
                collapseRanges.append((hideStart, hideEnd))
            }
            runStart = nil
        }
        for i in 0..<pairs.count {
            if bothContext(i) {
                if runStart == nil { runStart = i }
            } else if runStart != nil {
                closeRun(at: i)
            }
        }
        closeRun(at: pairs.count)

        // Mark which rows are inside a collapsed (non-expanded) range.
        var collapsedRowToBlock: [Int: Int] = [:]
        var stubAnchorRow: [Int: Int] = [:]
        for (blockId, range) in collapseRanges.enumerated() where !expandedBlocks.contains(blockId) {
            stubAnchorRow[range.start] = blockId
            for i in range.start..<range.end {
                collapsedRowToBlock[i] = blockId
            }
        }

        var stubs: [DiffCollapsedStub] = []
        let stubParagraph = NSMutableParagraphStyle()
        stubParagraph.minimumLineHeight = paragraph.minimumLineHeight
        stubParagraph.maximumLineHeight = paragraph.maximumLineHeight
        stubParagraph.alignment = .center

        func appendStub(blockId: Int, hiddenLines: Int) {
            let leftStart = left.length
            let rightStart = right.length
            let label = "⋮ \(hiddenLines) unchanged lines"
            let stubText = label + "\n"
            let color = NSColor(srgbRed: 120/255, green: 155/255, blue: 210/255, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: stubParagraph,
            ]
            left.append(NSAttributedString(string: stubText, attributes: attrs))
            right.append(NSAttributedString(string: stubText, attributes: attrs))
            let stubLen = (stubText as NSString).length
            let leftRange = NSRange(location: leftStart, length: stubLen)
            let rightRange = NSRange(location: rightStart, length: stubLen)
            // Background tint so the stub stands out from context.
            let stubBg = NSColor(srgbRed: 0x25/255, green: 0x30/255, blue: 0x3E/255, alpha: 1)
            leftRowBackgrounds.append((leftRange, stubBg))
            rightRowBackgrounds.append((rightRange, stubBg))
            // Track kinds / line numbers / starts with placeholder entries so
            // the gutter ruler and overview ruler stay in sync.
            leftLineKinds.append(.context)
            rightLineKinds.append(.context)
            leftLineNumbers.append(nil)
            rightLineNumbers.append(nil)
            leftLineStarts.append(leftStart)
            rightLineStarts.append(rightStart)
            stubs.append(DiffCollapsedStub(
                blockId: blockId,
                leftCharRange: leftRange,
                rightCharRange: rightRange,
                hiddenLines: hiddenLines
            ))
        }

        // Filter discussions to the current file, then bucket by anchor
        // (left for old_line, right for new_line).
        let fileRelevantDiscussions: [MRDiscussion] = {
            guard let fp = filePath else { return [] }
            let name = (fp as NSString).lastPathComponent
            return discussions.filter { d in
                guard let dp = d.filePath else { return false }
                return dp == fp || dp == name || fp.hasSuffix("/" + dp) || dp.hasSuffix("/" + (fp as NSString).lastPathComponent)
            }
        }()
        var anchorsByRightLine: [Int: [MRDiscussion]] = [:]
        var anchorsByLeftLine: [Int: [MRDiscussion]] = [:]
        for d in fileRelevantDiscussions {
            if let n = d.newLine {
                anchorsByRightLine[n, default: []].append(d)
            } else if let n = d.oldLine {
                anchorsByLeftLine[n, default: []].append(d)
            }
        }

        // Placeholder "phantom" rows reserve vertical space under an anchor
        // line; the overlay NSHostingView is drawn on top of them. The number
        // of rows is computed per-discussion so threads with many replies get
        // enough vertical space and don't visually overlap the next line.
        // Threads taller than `commentRowsCap` get a fixed height + an
        // internal scrollview inside the card so they don't push the rest of
        // the file off-screen.
        let minCommentRowsPerCard = 4
        let commentRowsCap = 24
        var collectedWidgets: [InlineCommentWidget] = []

        func appendPlaceholderRows(count: Int) {
            for _ in 0..<count {
                let ls = left.length
                let rs = right.length
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: paragraph,
                ]
                left.append(NSAttributedString(string: "\n", attributes: attrs))
                right.append(NSAttributedString(string: "\n", attributes: attrs))
                leftLineKinds.append(.commentPlaceholder)
                rightLineKinds.append(.commentPlaceholder)
                leftLineNumbers.append(nil)
                rightLineNumbers.append(nil)
                leftLineStarts.append(ls)
                rightLineStarts.append(rs)
            }
        }

        // Pair-level (parallel) kinds + cross-side row maps. Drive the
        // connector ribbons and the row-mapped scroll sync that replaces
        // the old wheel-1:1 forwarding.
        var pairLeftKinds: [SideBySideLineKind] = []
        var pairRightKinds: [SideBySideLineKind] = []
        // For each left-side row, the right row that should be aligned with
        // it in the viewport. For deletions on the left, this stays at the
        // last context row on the right (so the right viewport "pauses"
        // while the user scrolls through the deletion on the left).
        var leftRowToRightRow: [Int] = []
        var rightRowToLeftRow: [Int] = []
        var lastAlignedRight = 0
        var lastAlignedLeft = 0

        func recordPair(left lRow: Int?, right rRow: Int?) {
            if let lRow {
                leftRowToRightRow.append(rRow ?? lastAlignedRight)
            }
            if let rRow {
                rightRowToLeftRow.append(lRow ?? lastAlignedLeft)
            }
            if let lRow, let rRow {
                lastAlignedLeft = lRow
                lastAlignedRight = rRow
            }
        }

        // Reuse a single appendStub closure that keeps the maps and pair
        // arrays in sync.
        func appendStubAndRecord(blockId: Int, hiddenLines: Int) {
            let leftRow = leftLineKinds.count
            let rightRow = rightLineKinds.count
            appendStub(blockId: blockId, hiddenLines: hiddenLines)
            pairLeftKinds.append(.context)
            pairRightKinds.append(.context)
            recordPair(left: leftRow, right: rightRow)
        }

        for (rowIndex, (l, r)) in pairs.enumerated() {
            if let blockId = stubAnchorRow[rowIndex] {
                let range = collapseRanges[blockId]
                appendStubAndRecord(blockId: blockId, hiddenLines: range.end - range.start)
            }
            if collapsedRowToBlock[rowIndex] != nil { continue }
            let leftRow = appendLine(
                into: left, cell: l,
                kinds: &leftLineKinds,
                lineNumbers: &leftLineNumbers,
                lineStarts: &leftLineStarts,
                contentRanges: &leftContentRanges,
                rowBackgrounds: &leftRowBackgrounds,
                intraRanges: &leftIntraRanges
            )
            let rightRow = appendLine(
                into: right, cell: r,
                kinds: &rightLineKinds,
                lineNumbers: &rightLineNumbers,
                lineStarts: &rightLineStarts,
                contentRanges: &rightContentRanges,
                rowBackgrounds: &rightRowBackgrounds,
                intraRanges: &rightIntraRanges
            )
            pairLeftKinds.append(l.kind)
            pairRightKinds.append(r.kind)
            recordPair(left: leftRow, right: rightRow)

            // If this row anchors any inline discussion, emit the placeholder
            // rows right after it on both sides and record widget metadata.
            var matched: [(side: DiffCommentSide, discussion: MRDiscussion)] = []
            if let ln = r.lineNumber, let list = anchorsByRightLine[ln] {
                matched.append(contentsOf: list.map { (.right, $0) })
            }
            if let ln = l.lineNumber, let list = anchorsByLeftLine[ln] {
                matched.append(contentsOf: list.map { (.left, $0) })
            }
            for (side, discussion) in matched {
                let anchorLeft = left.length
                let anchorRight = right.length
                let estimatedHeight = estimatedCardHeight(for: discussion)
                let estimatedRows = max(
                    minCommentRowsPerCard,
                    Int(ceil(estimatedHeight / lineHeight))
                )
                let needsScroll = estimatedRows > commentRowsCap
                let rowsToReserve = needsScroll ? commentRowsCap : estimatedRows
                let reservedHeight = lineHeight * CGFloat(rowsToReserve)
                let preLeftRow = leftLineKinds.count
                let preRightRow = rightLineKinds.count
                appendPlaceholderRows(count: rowsToReserve)
                for i in 0..<rowsToReserve {
                    pairLeftKinds.append(.commentPlaceholder)
                    pairRightKinds.append(.commentPlaceholder)
                    recordPair(left: preLeftRow + i, right: preRightRow + i)
                }
                collectedWidgets.append(InlineCommentWidget(
                    id: discussion.id,
                    side: side,
                    anchorCharIndex: side == .left ? anchorLeft : anchorRight,
                    reservedHeight: reservedHeight,
                    discussion: discussion,
                    useInternalScroll: needsScroll
                ))
            }
        }

        // Derive change groups from the pair-level kinds (parallel run): every
        // run of consecutive pairs where either side is added/deleted becomes
        // one hunk. Hunk char offsets resolve to the first non-empty row on
        // each side within the run.
        func isChangeKind(_ k: SideBySideLineKind) -> Bool {
            switch k {
            case .added, .deleted,
                 .conflictOurs, .conflictBase, .conflictSeparator, .conflictTheirs:
                return true
            default:
                return false
            }
        }
        var pairLeftRows: [Int?] = []
        var pairRightRows: [Int?] = []
        var leftCounter = 0
        var rightCounter = 0
        for i in 0..<pairLeftKinds.count {
            if pairLeftKinds[i] == .empty {
                pairLeftRows.append(nil)
            } else {
                pairLeftRows.append(leftCounter)
                leftCounter += 1
            }
            if pairRightKinds[i] == .empty {
                pairRightRows.append(nil)
            } else {
                pairRightRows.append(rightCounter)
                rightCounter += 1
            }
        }
        var prevIsChange = false
        for i in 0..<pairLeftKinds.count {
            let isChange = isChangeKind(pairLeftKinds[i]) || isChangeKind(pairRightKinds[i])
            if isChange && !prevIsChange {
                // Find first non-empty row on each side at or after i.
                var leftStart: Int? = nil
                var rightStart: Int? = nil
                for j in i..<pairLeftKinds.count {
                    if leftStart == nil, let r = pairLeftRows[j] { leftStart = r }
                    if rightStart == nil, let r = pairRightRows[j] { rightStart = r }
                    if leftStart != nil && rightStart != nil { break }
                }
                if let lr = leftStart, lr < leftLineStarts.count {
                    leftHunks.append(leftLineStarts[lr])
                }
                if let rr = rightStart, rr < rightLineStarts.count {
                    rightHunks.append(rightLineStarts[rr])
                }
            }
            prevIsChange = isChange
        }

        // Syntax highlighting: extract pure code substring per side, highlight,
        // copy foreground colors back.
        applySyntax(
            to: left,
            contentRanges: leftContentRanges,
            language: language,
            font: font
        )
        applySyntax(
            to: right,
            contentRanges: rightContentRanges,
            language: language,
            font: font
        )

        // Only intra-line stronger ranges are baked into the attributed
        // string. Row backgrounds are returned separately so the text view
        // can fill the full editor width underneath the glyphs.
        for (range, color) in leftIntraRanges {
            left.addAttribute(.backgroundColor, value: color, range: range)
        }
        for (range, color) in rightIntraRanges {
            right.addAttribute(.backgroundColor, value: color, range: range)
        }

        let detectMoves = UserDefaults.standard.object(forKey: "diff.connector.detectMoves") as? Bool ?? true
        let connectorSegments = buildConnectorSegments(
            pairLeftKinds: pairLeftKinds,
            pairRightKinds: pairRightKinds,
            pairLeftRows: pairLeftRows,
            pairRightRows: pairRightRows,
            leftAttr: left,
            rightAttr: right,
            leftLineStarts: leftLineStarts,
            rightLineStarts: rightLineStarts,
            detectMoves: detectMoves
        )

        return SideBySidePrepared(
            leftAttr: left,
            rightAttr: right,
            leftHunkOffsets: leftHunks,
            rightHunkOffsets: rightHunks,
            leftLineKinds: leftLineKinds,
            rightLineKinds: rightLineKinds,
            leftRowBackgrounds: leftRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            rightRowBackgrounds: rightRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            collapsedStubs: stubs,
            inlineComments: collectedWidgets,
            leftLineNumbers: leftLineNumbers,
            rightLineNumbers: rightLineNumbers,
            leftLineStarts: leftLineStarts,
            rightLineStarts: rightLineStarts,
            connectorSegments: connectorSegments,
            leftRowToRightRow: leftRowToRightRow,
            rightRowToLeftRow: rightRowToLeftRow
        )
    }

    // MARK: Color palette (VS Code Dark+ / default dark)

    private static let hunkForeground = NSColor(srgbRed: 86/255, green: 156/255, blue: 214/255, alpha: 1)
    private static let hunkBackground = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0)  // subtle; real tint comes from row color
    private static let diagonalHatchColor: NSColor = DiffHatchPattern.color()

    private static func formatLineNumber(_ n: Int?, width: Int) -> String {
        guard let n else { return String(repeating: " ", count: width) }
        let s = String(n)
        if s.count >= width { return s }
        return String(repeating: " ", count: width - s.count) + s
    }

    // Solid colors (pre-composited against the VS Code editor background
    // `#1E1E1E`) so they land exactly like VS Code no matter what
    // macOS decides for `.textBackgroundColor`.
    static func rowBackgroundColor(for kind: SideBySideLineKind) -> NSColor? {
        switch kind {
        case .added: return NSColor(srgbRed: 0x37/255, green: 0x3D/255, blue: 0x29/255, alpha: 1)
        case .deleted: return NSColor(srgbRed: 0x4B/255, green: 0x18/255, blue: 0x18/255, alpha: 1)
        case .hunk: return NSColor(srgbRed: 0x23/255, green: 0x2D/255, blue: 0x3C/255, alpha: 1)
        // Conflict markers: bold magenta family so they pop against added/deleted lines.
        case .conflictOurs: return NSColor(srgbRed: 0x5A/255, green: 0x1E/255, blue: 0x4A/255, alpha: 1)
        case .conflictBase: return NSColor(srgbRed: 0x3A/255, green: 0x2A/255, blue: 0x4A/255, alpha: 1)
        case .conflictSeparator: return NSColor(srgbRed: 0x5A/255, green: 0x3F/255, blue: 0x14/255, alpha: 1)
        case .conflictTheirs: return NSColor(srgbRed: 0x1E/255, green: 0x3F/255, blue: 0x5A/255, alpha: 1)
        case .context, .empty, .commentPlaceholder: return nil
        }
    }

    static func intraLineColor(for kind: SideBySideLineKind) -> NSColor? {
        switch kind {
        case .added: return NSColor(srgbRed: 0x55/255, green: 0x62/255, blue: 0x2E/255, alpha: 1)
        case .deleted: return NSColor(srgbRed: 0x6F/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1)
        case .context, .empty, .hunk, .commentPlaceholder,
             .conflictOurs, .conflictBase, .conflictSeparator, .conflictTheirs:
            return nil
        }
    }

    static func applySyntax(
        to attr: NSMutableAttributedString,
        contentRanges: [NSRange],
        language: HighlightLanguage,
        font: NSFont
    ) {
        guard language != .plaintext, !contentRanges.isEmpty else { return }

        // Build a synthetic code buffer that concatenates the content of each
        // tracked range (plus a separator newline) so multi-line constructs
        // like block comments survive across rows.
        let synthetic = NSMutableString()
        var mapping: [(synRange: NSRange, resultRange: NSRange)] = []
        for cr in contentRanges {
            let piece = (attr.string as NSString).substring(with: cr)
            let synStart = synthetic.length
            synthetic.append(piece)
            synthetic.append("\n")
            mapping.append((
                synRange: NSRange(location: synStart, length: cr.length),
                resultRange: cr
            ))
        }
        let synAttr = NSMutableAttributedString(
            string: synthetic as String,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        SyntaxHighlighter.apply(to: synAttr, language: language)

        for map in mapping {
            synAttr.enumerateAttribute(
                .foregroundColor,
                in: map.synRange,
                options: []
            ) { value, subRange, _ in
                guard let color = value as? NSColor else { return }
                let offsetInSeg = subRange.location - map.synRange.location
                let targetLoc = map.resultRange.location + offsetInSeg
                let targetRange = NSRange(location: targetLoc, length: subRange.length)
                if targetRange.location + targetRange.length <= attr.length {
                    attr.addAttribute(.foregroundColor, value: color, range: targetRange)
                }
            }
        }
    }
}

// MARK: - 3-way (ours | base | theirs) prepared model

/// Render-ready 3-pane representation of a conflicting file. Each side carries
/// its own `NSAttributedString`, line kinds, line numbers, line starts, and
/// row backgrounds. Sync is driven via `*ToBaseRow` maps with `base` as pivot.
struct ThreeWayPrepared: Equatable {
    var oursAttr: NSAttributedString
    var baseAttr: NSAttributedString
    var theirsAttr: NSAttributedString
    var oursLineKinds: [SideBySideLineKind]
    var baseLineKinds: [SideBySideLineKind]
    var theirsLineKinds: [SideBySideLineKind]
    var oursLineNumbers: [Int?]
    var baseLineNumbers: [Int?]
    var theirsLineNumbers: [Int?]
    var oursLineStarts: [Int]
    var baseLineStarts: [Int]
    var theirsLineStarts: [Int]
    var oursRowBackgrounds: [DiffRowBackground]
    var baseRowBackgrounds: [DiffRowBackground]
    var theirsRowBackgrounds: [DiffRowBackground]
    var oursToBaseRow: [Int]
    var baseToOursRow: [Int]
    var baseToTheirsRow: [Int]
    var theirsToBaseRow: [Int]
    var oursBaseConnectorSegments: [DiffConnectorSegment]
    var baseTheirsConnectorSegments: [DiffConnectorSegment]
    /// Char offsets in `baseAttr` for next/prev change navigation.
    var hunkOffsetsBase: [Int]
    var oursLabel: String
    var baseLabel: String
    var theirsLabel: String

    static let empty = ThreeWayPrepared(
        oursAttr: NSAttributedString(),
        baseAttr: NSAttributedString(),
        theirsAttr: NSAttributedString(),
        oursLineKinds: [],
        baseLineKinds: [],
        theirsLineKinds: [],
        oursLineNumbers: [],
        baseLineNumbers: [],
        theirsLineNumbers: [],
        oursLineStarts: [],
        baseLineStarts: [],
        theirsLineStarts: [],
        oursRowBackgrounds: [],
        baseRowBackgrounds: [],
        theirsRowBackgrounds: [],
        oursToBaseRow: [],
        baseToOursRow: [],
        baseToTheirsRow: [],
        theirsToBaseRow: [],
        oursBaseConnectorSegments: [],
        baseTheirsConnectorSegments: [],
        hunkOffsetsBase: [],
        oursLabel: "",
        baseLabel: "",
        theirsLabel: ""
    )

    static func == (lhs: ThreeWayPrepared, rhs: ThreeWayPrepared) -> Bool {
        lhs.oursAttr.isEqual(to: rhs.oursAttr)
            && lhs.baseAttr.isEqual(to: rhs.baseAttr)
            && lhs.theirsAttr.isEqual(to: rhs.theirsAttr)
            && lhs.oursLineKinds == rhs.oursLineKinds
            && lhs.baseLineKinds == rhs.baseLineKinds
            && lhs.theirsLineKinds == rhs.theirsLineKinds
            && lhs.oursLineNumbers == rhs.oursLineNumbers
            && lhs.baseLineNumbers == rhs.baseLineNumbers
            && lhs.theirsLineNumbers == rhs.theirsLineNumbers
            && lhs.oursToBaseRow == rhs.oursToBaseRow
            && lhs.baseToOursRow == rhs.baseToOursRow
            && lhs.baseToTheirsRow == rhs.baseToTheirsRow
            && lhs.theirsToBaseRow == rhs.theirsToBaseRow
            && lhs.oursBaseConnectorSegments == rhs.oursBaseConnectorSegments
            && lhs.baseTheirsConnectorSegments == rhs.baseTheirsConnectorSegments
            && lhs.oursLabel == rhs.oursLabel
            && lhs.baseLabel == rhs.baseLabel
            && lhs.theirsLabel == rhs.theirsLabel
    }

    /// Cap on the per-side line count above which we skip LCS alignment and
    /// fall back to a flat side-by-side layout (rows are paired top-to-bottom
    /// without alignment). Keeps the O(N×M) LCS cost bounded.
    private static let alignmentLineCap = 50_000

    static func from(
        blobs: ThreeWayBlobs,
        filePath: String,
        conflict: GitDiffFileConflict?
    ) -> ThreeWayPrepared {
        let oursLines = splitLines(blobs.ours ?? "")
        let baseLines = splitLines(blobs.base ?? "")
        let theirsLines = splitLines(blobs.theirs ?? "")

        let aligned: [ThreeWayAlignedRow]
        let isAligned = max(oursLines.count, baseLines.count, theirsLines.count) <= alignmentLineCap
            && blobs.base != nil
        if isAligned {
            aligned = alignThreeWay(
                oursLines: oursLines, baseLines: baseLines, theirsLines: theirsLines
            )
        } else {
            // Fallback: zip rows top-to-bottom with no alignment (used for huge
            // files or when the merge-base couldn't be computed). The 2-pane
            // path remains the alternative when blobs.base == nil; here we keep
            // the 3 columns rendering as-is so the UI stays consistent.
            aligned = flatAlign(
                oursLines: oursLines, baseLines: baseLines, theirsLines: theirsLines
            )
        }

        let conflictRowFlags = computeConflictRowFlags(rows: aligned)

        let font = codeFont()
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let language = HighlightLanguage.detect(fromFilePath: filePath)

        let oursAttr = NSMutableAttributedString()
        let baseAttr = NSMutableAttributedString()
        let theirsAttr = NSMutableAttributedString()
        var oursKinds: [SideBySideLineKind] = []
        var baseKinds: [SideBySideLineKind] = []
        var theirsKinds: [SideBySideLineKind] = []
        var oursLineNumbers: [Int?] = []
        var baseLineNumbers: [Int?] = []
        var theirsLineNumbers: [Int?] = []
        var oursLineStarts: [Int] = []
        var baseLineStarts: [Int] = []
        var theirsLineStarts: [Int] = []
        var oursContentRanges: [NSRange] = []
        var baseContentRanges: [NSRange] = []
        var theirsContentRanges: [NSRange] = []
        var oursRowBackgrounds: [(NSRange, NSColor)] = []
        var baseRowBackgrounds: [(NSRange, NSColor)] = []
        var theirsRowBackgrounds: [(NSRange, NSColor)] = []

        // Pair-level kinds for connector building (parallel arrays of length =
        // number of pair rows). pair*Rows[i] is the row index in the side's
        // own line-starts array, or nil when that side is empty for the pair.
        var pairOursKinds: [SideBySideLineKind] = []
        var pairBaseKinds: [SideBySideLineKind] = []
        var pairTheirsKinds: [SideBySideLineKind] = []
        var pairOursRows: [Int?] = []
        var pairBaseRows: [Int?] = []
        var pairTheirsRows: [Int?] = []

        var oursToBaseRow: [Int] = []
        var baseToOursRow: [Int] = []
        var baseToTheirsRow: [Int] = []
        var theirsToBaseRow: [Int] = []
        var lastSeenBaseRow = 0
        var lastSeenOursRow = 0
        var lastSeenTheirsRow = 0

        var hunkOffsetsBase: [Int] = []
        var prevWasChange = false

        var oursLineCounter = 1
        var baseLineCounter = 1
        var theirsLineCounter = 1

        for (rowIdx, row) in aligned.enumerated() {
            let isConflict = conflictRowFlags[rowIdx]

            let oursKind = computeKind(side: row.ours, base: row.base, isConflict: isConflict, sideKind: .conflictOurs, fallbackAdded: .added)
            let baseKind = computeBaseKind(base: row.base, isConflict: isConflict)
            let theirsKind = computeKind(side: row.theirs, base: row.base, isConflict: isConflict, sideKind: .conflictTheirs, fallbackAdded: .added)

            let oursRowIdx = appendCell(
                content: row.ours,
                kind: oursKind,
                lineNumber: row.ours == nil ? nil : oursLineCounter,
                attr: oursAttr,
                kinds: &oursKinds,
                lineNumbers: &oursLineNumbers,
                lineStarts: &oursLineStarts,
                contentRanges: &oursContentRanges,
                rowBackgrounds: &oursRowBackgrounds,
                font: font,
                paragraph: paragraph
            )
            if row.ours != nil { oursLineCounter += 1 }

            let baseRowIdx = appendCell(
                content: row.base,
                kind: baseKind,
                lineNumber: row.base == nil ? nil : baseLineCounter,
                attr: baseAttr,
                kinds: &baseKinds,
                lineNumbers: &baseLineNumbers,
                lineStarts: &baseLineStarts,
                contentRanges: &baseContentRanges,
                rowBackgrounds: &baseRowBackgrounds,
                font: font,
                paragraph: paragraph
            )
            if row.base != nil { baseLineCounter += 1 }

            let theirsRowIdx = appendCell(
                content: row.theirs,
                kind: theirsKind,
                lineNumber: row.theirs == nil ? nil : theirsLineCounter,
                attr: theirsAttr,
                kinds: &theirsKinds,
                lineNumbers: &theirsLineNumbers,
                lineStarts: &theirsLineStarts,
                contentRanges: &theirsContentRanges,
                rowBackgrounds: &theirsRowBackgrounds,
                font: font,
                paragraph: paragraph
            )
            if row.theirs != nil { theirsLineCounter += 1 }

            // Pair-level kinds use empty for sides without a real row, which
            // makes the connector builder collapse the funnel apex correctly.
            pairOursKinds.append(oursRowIdx == nil ? .empty : oursKind)
            pairBaseKinds.append(baseRowIdx == nil ? .empty : baseKind)
            pairTheirsKinds.append(theirsRowIdx == nil ? .empty : theirsKind)
            pairOursRows.append(oursRowIdx)
            pairBaseRows.append(baseRowIdx)
            pairTheirsRows.append(theirsRowIdx)

            // Row-mapped sync (base is pivot).
            if let o = oursRowIdx {
                oursToBaseRow.append(baseRowIdx ?? lastSeenBaseRow)
                lastSeenOursRow = o
            }
            if let b = baseRowIdx {
                baseToOursRow.append(oursRowIdx ?? lastSeenOursRow)
                baseToTheirsRow.append(theirsRowIdx ?? lastSeenTheirsRow)
                lastSeenBaseRow = b
            }
            if let t = theirsRowIdx {
                theirsToBaseRow.append(baseRowIdx ?? lastSeenBaseRow)
                lastSeenTheirsRow = t
            }

            // Hunk navigation: anchor on base, mark the start of any run where
            // ours or theirs differ from base.
            let isChange = (oursKind != .context && oursKind != .empty)
                || (theirsKind != .context && theirsKind != .empty)
                || (baseKind == .empty)
            if isChange && !prevWasChange, let b = baseRowIdx, b < baseLineStarts.count {
                hunkOffsetsBase.append(baseLineStarts[b])
            }
            prevWasChange = isChange
        }

        // Syntax highlighting on each side using the existing helper.
        SideBySidePrepared.applySyntax(to: oursAttr, contentRanges: oursContentRanges, language: language, font: font)
        SideBySidePrepared.applySyntax(to: baseAttr, contentRanges: baseContentRanges, language: language, font: font)
        SideBySidePrepared.applySyntax(to: theirsAttr, contentRanges: theirsContentRanges, language: language, font: font)

        // Connector segments: ours ↔ base and base ↔ theirs.
        let oursBaseConnectors = buildConnectorSegments(
            pairLeftKinds: pairOursKinds,
            pairRightKinds: pairBaseKinds,
            pairLeftRows: pairOursRows,
            pairRightRows: pairBaseRows,
            leftAttr: oursAttr,
            rightAttr: baseAttr,
            leftLineStarts: oursLineStarts,
            rightLineStarts: baseLineStarts,
            detectMoves: false
        )
        let baseTheirsConnectors = buildConnectorSegments(
            pairLeftKinds: pairBaseKinds,
            pairRightKinds: pairTheirsKinds,
            pairLeftRows: pairBaseRows,
            pairRightRows: pairTheirsRows,
            leftAttr: baseAttr,
            rightAttr: theirsAttr,
            leftLineStarts: baseLineStarts,
            rightLineStarts: theirsLineStarts,
            detectMoves: false
        )

        _ = conflict  // currently reserved for future heuristics; kept on the API.

        return ThreeWayPrepared(
            oursAttr: oursAttr,
            baseAttr: baseAttr,
            theirsAttr: theirsAttr,
            oursLineKinds: oursKinds,
            baseLineKinds: baseKinds,
            theirsLineKinds: theirsKinds,
            oursLineNumbers: oursLineNumbers,
            baseLineNumbers: baseLineNumbers,
            theirsLineNumbers: theirsLineNumbers,
            oursLineStarts: oursLineStarts,
            baseLineStarts: baseLineStarts,
            theirsLineStarts: theirsLineStarts,
            oursRowBackgrounds: oursRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            baseRowBackgrounds: baseRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            theirsRowBackgrounds: theirsRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            oursToBaseRow: oursToBaseRow,
            baseToOursRow: baseToOursRow,
            baseToTheirsRow: baseToTheirsRow,
            theirsToBaseRow: theirsToBaseRow,
            oursBaseConnectorSegments: oursBaseConnectors,
            baseTheirsConnectorSegments: baseTheirsConnectors,
            hunkOffsetsBase: hunkOffsetsBase,
            oursLabel: blobs.oursLabel,
            baseLabel: blobs.baseLabel,
            theirsLabel: blobs.theirsLabel
        )
    }
}

// MARK: - Three-way alignment helpers

private struct ThreeWayAlignedRow {
    let ours: String?
    let base: String?
    let theirs: String?
}

private func splitLines(_ s: String) -> [String] {
    if s.isEmpty { return [] }
    var lines = s.components(separatedBy: "\n")
    // Trailing newline produces a trailing empty element; drop it so it
    // doesn't render as a blank line at the bottom.
    if let last = lines.last, last.isEmpty { lines.removeLast() }
    return lines
}

/// Walks an LCS edit script (a = base, b = side) and produces two parallel
/// structures indexed by base position k:
///  - `atBase[k]`: the side's line that matched base[k] (keep), or nil if base[k]
///    was deleted on this side.
///  - `insBefore[k]`: lines on the side that were inserted before base[k]; the
///    bucket at index `baseCount` collects trailing inserts.
private func processSideAgainstBase(
    ops: [LCSEditOp], baseCount: Int, sideLines: [String]
) -> (atBase: [String?], insBefore: [[String]]) {
    var atBase: [String?] = Array(repeating: nil, count: baseCount)
    var insBefore: [[String]] = Array(repeating: [], count: baseCount + 1)
    var baseIdx = 0
    var sideIdx = 0
    for op in ops {
        switch op {
        case .keep:
            if baseIdx < baseCount && sideIdx < sideLines.count {
                atBase[baseIdx] = sideLines[sideIdx]
            }
            baseIdx += 1
            sideIdx += 1
        case .deleteLeft:
            if baseIdx < baseCount {
                atBase[baseIdx] = nil
            }
            baseIdx += 1
        case .insertRight:
            if sideIdx < sideLines.count {
                insBefore[min(baseIdx, baseCount)].append(sideLines[sideIdx])
            }
            sideIdx += 1
        }
    }
    return (atBase, insBefore)
}

/// Aligns three line arrays into parallel rows using `base` as pivot. Each row
/// has up to one line per side (nil = the side has no line at that row).
private func alignThreeWay(
    oursLines: [String], baseLines: [String], theirsLines: [String]
) -> [ThreeWayAlignedRow] {
    let opsOurs = lcsScript(a: baseLines, b: oursLines)
    let opsTheirs = lcsScript(a: baseLines, b: theirsLines)
    let oursMap = processSideAgainstBase(
        ops: opsOurs, baseCount: baseLines.count, sideLines: oursLines
    )
    let theirsMap = processSideAgainstBase(
        ops: opsTheirs, baseCount: baseLines.count, sideLines: theirsLines
    )

    var rows: [ThreeWayAlignedRow] = []
    rows.reserveCapacity(baseLines.count + oursLines.count + theirsLines.count)

    for k in 0...baseLines.count {
        let oIns = oursMap.insBefore[k]
        let tIns = theirsMap.insBefore[k]
        let m = max(oIns.count, tIns.count)
        for i in 0..<m {
            let o = i < oIns.count ? oIns[i] : nil
            let t = i < tIns.count ? tIns[i] : nil
            rows.append(ThreeWayAlignedRow(ours: o, base: nil, theirs: t))
        }
        if k < baseLines.count {
            rows.append(ThreeWayAlignedRow(
                ours: oursMap.atBase[k],
                base: baseLines[k],
                theirs: theirsMap.atBase[k]
            ))
        }
    }
    return rows
}

/// Flat (no-alignment) fallback used when one of the blobs is missing or the
/// file is too large to LCS. Pairs lines top-to-bottom; longer sides get nil
/// padding on the others.
private func flatAlign(
    oursLines: [String], baseLines: [String], theirsLines: [String]
) -> [ThreeWayAlignedRow] {
    let n = max(oursLines.count, baseLines.count, theirsLines.count)
    var rows: [ThreeWayAlignedRow] = []
    rows.reserveCapacity(n)
    for i in 0..<n {
        rows.append(ThreeWayAlignedRow(
            ours: i < oursLines.count ? oursLines[i] : nil,
            base: i < baseLines.count ? baseLines[i] : nil,
            theirs: i < theirsLines.count ? theirsLines[i] : nil
        ))
    }
    return rows
}

/// A row is part of a conflict region when both ours and theirs diverge from
/// base in the same row (one or both sides changed where the other also did).
private func computeConflictRowFlags(rows: [ThreeWayAlignedRow]) -> [Bool] {
    var flags: [Bool] = Array(repeating: false, count: rows.count)
    var i = 0
    while i < rows.count {
        let oursDiverged = rowDiverges(side: rows[i].ours, base: rows[i].base)
        let theirsDiverged = rowDiverges(side: rows[i].theirs, base: rows[i].base)
        if oursDiverged && theirsDiverged {
            // Find the run of consecutive divergent rows.
            var j = i
            while j < rows.count {
                let od = rowDiverges(side: rows[j].ours, base: rows[j].base)
                let td = rowDiverges(side: rows[j].theirs, base: rows[j].base)
                if !(od || td) { break }
                j += 1
            }
            for k in i..<j { flags[k] = true }
            i = j
        } else {
            i += 1
        }
    }
    return flags
}

private func rowDiverges(side: String?, base: String?) -> Bool {
    if base == nil && side != nil { return true }   // insert by this side
    if base != nil && side == nil { return true }   // delete by this side
    return false
}

private func computeKind(
    side: String?, base: String?,
    isConflict: Bool,
    sideKind: SideBySideLineKind,
    fallbackAdded: SideBySideLineKind
) -> SideBySideLineKind {
    if side == nil { return .empty }
    if base == nil {
        return isConflict ? sideKind : fallbackAdded
    }
    return .context
}

private func computeBaseKind(base: String?, isConflict: Bool) -> SideBySideLineKind {
    if base == nil { return .empty }
    return .context
}

private func appendCell(
    content: String?,
    kind: SideBySideLineKind,
    lineNumber: Int?,
    attr: NSMutableAttributedString,
    kinds: inout [SideBySideLineKind],
    lineNumbers: inout [Int?],
    lineStarts: inout [Int],
    contentRanges: inout [NSRange],
    rowBackgrounds: inout [(NSRange, NSColor)],
    font: NSFont,
    paragraph: NSParagraphStyle
) -> Int? {
    guard let content else { return nil }
    let rowIndex = kinds.count
    let start = attr.length
    lineStarts.append(start)
    let rendered = content + "\n"
    attr.append(NSAttributedString(
        string: rendered,
        attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    ))
    let contentUTF16Len = (content as NSString).length
    let renderedUTF16Len = (rendered as NSString).length
    if let bg = SideBySidePrepared.rowBackgroundColor(for: kind) {
        rowBackgrounds.append((NSRange(location: start, length: renderedUTF16Len), bg))
    }
    if contentUTF16Len > 0 {
        contentRanges.append(NSRange(location: start, length: contentUTF16Len))
    }
    kinds.append(kind)
    lineNumbers.append(lineNumber)
    return rowIndex
}

struct SideBySideDiffView: View {
    let prepared: SideBySidePrepared
    @Binding var scrollHunkIndex: Int?
    let onExpandBlock: (Int) -> Void

    var body: some View {
        DiffCodeTextView(
            left: prepared.leftAttr,
            right: prepared.rightAttr,
            leftHunkOffsets: prepared.leftHunkOffsets,
            rightHunkOffsets: prepared.rightHunkOffsets,
            leftLineKinds: prepared.leftLineKinds,
            rightLineKinds: prepared.rightLineKinds,
            leftRowBackgrounds: prepared.leftRowBackgrounds,
            rightRowBackgrounds: prepared.rightRowBackgrounds,
            leftLineNumbers: prepared.leftLineNumbers,
            rightLineNumbers: prepared.rightLineNumbers,
            leftLineStarts: prepared.leftLineStarts,
            rightLineStarts: prepared.rightLineStarts,
            collapsedStubs: prepared.collapsedStubs,
            inlineComments: prepared.inlineComments,
            connectorSegments: prepared.connectorSegments,
            leftRowToRightRow: prepared.leftRowToRightRow,
            rightRowToLeftRow: prepared.rightRowToLeftRow,
            onExpandBlock: onExpandBlock,
            scrollHunkIndex: $scrollHunkIndex
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Keyboard Handler

/// Transparent helper view that installs a local NSEvent monitor scoped to
/// the hosting window, to pick up F7 / Shift+F7 even when focus is inside
/// the NSTextView. Using `.onKeyPress` does not fire for F-keys reliably.
struct HunkNavKeyMonitor: NSViewRepresentable {
    let onPrev: () -> Void
    let onNext: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyMonitorView()
        view.onPrev = onPrev
        view.onNext = onNext
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyMonitorView else { return }
        view.onPrev = onPrev
        view.onNext = onNext
        view.onEscape = onEscape
    }

    private final class KeyMonitorView: NSView {
        var onPrev: (() -> Void)?
        var onNext: (() -> Void)?
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let existing = monitor {
                NSEvent.removeMonitor(existing)
                monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.window === self.window else { return event }
                // F7 → next hunk, Shift+F7 → previous hunk.
                if event.keyCode == 98 {
                    if event.modifierFlags.contains(.shift) {
                        self.onPrev?()
                    } else {
                        self.onNext?()
                    }
                    return nil
                }
                // Escape → close the diff window.
                if event.keyCode == 53 {
                    self.onEscape?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Window Controller

@MainActor
final class GitDiffWindowController: NSWindowController {
    private let viewModel: GitDiffViewModel

    init(spec: GitDiffSpec) {
        self.viewModel = GitDiffViewModel(spec: spec)
        let hosting = NSHostingController(rootView: GitDiffWindowView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.setFrame(screen, display: true)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.title = spec.title
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show() {
        viewModel.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Registry to avoid duplicates

@MainActor
enum GitDiffWindowRegistry {
    private static var openControllers: [String: GitDiffWindowController] = [:]

    static func show(spec: GitDiffSpec) {
        let key = "\(spec.directory)|\(spec.base)|\(spec.compare ?? "<worktree>")"
        if let existing = openControllers[key] {
            existing.show()
            return
        }
        let controller = GitDiffWindowController(spec: spec)
        openControllers[key] = controller
        controller.window?.delegate = GitDiffWindowRegistryDelegate.shared
        GitDiffWindowRegistryDelegate.shared.register(key: key, window: controller.window)
        controller.show()
    }

    fileprivate static func remove(key: String) {
        openControllers[key] = nil
    }
}

@MainActor
private final class GitDiffWindowRegistryDelegate: NSObject, NSWindowDelegate {
    static let shared = GitDiffWindowRegistryDelegate()

    private var keyByWindow: [ObjectIdentifier: String] = [:]

    func register(key: String, window: NSWindow?) {
        guard let window else { return }
        keyByWindow[ObjectIdentifier(window)] = key
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)
        if let key = keyByWindow.removeValue(forKey: id) {
            GitDiffWindowRegistry.remove(key: key)
        }
    }
}

// MARK: - Code font helper

/// Mirrors VS Code's macOS default stack: `Menlo, Monaco, 'Courier New'`.
func codeFont(size: CGFloat = 12) -> NSFont {
    for name in ["Menlo", "Monaco", "Courier New"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

// MARK: - Diagonal hatch pattern (for empty-side padding rows)

enum DiffHatchPattern {
    /// Returns a pattern NSColor that renders diagonal stripes similar to
    /// VS Code's "empty side" marker on side-by-side diffs. Produces a
    /// dark tile with clearly-visible light diagonal stripes.
    static func color() -> NSColor {
        if let cached { return cached }
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        // Opaque slightly-darker-than-editor background so the hatch tile
        // reads as "no line here" rather than transparent.
        NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let stripe = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
        stripe.setStroke()
        // Two diagonals to ensure a continuous pattern when tiled.
        for offset in stride(from: -size, through: size, by: size) {
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.move(to: NSPoint(x: offset, y: 0))
            path.line(to: NSPoint(x: offset + size, y: size))
            path.stroke()
        }
        image.unlockFocus()
        let color = NSColor(patternImage: image)
        cached = color
        return color
    }

    nonisolated(unsafe) private static var cached: NSColor?
}
