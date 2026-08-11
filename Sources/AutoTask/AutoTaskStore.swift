import Combine
import Foundation

/// The queue of scheduled `/auto-task` runs, persisted as JSON.
///
/// The queue is **global, not per workspace**: tasks are scheduled against a
/// repository path and must fire wherever the user happens to be.
///
/// It also lives in the shared `com.cmuxterm.app` Application Support folder,
/// which means every cmux on this machine — the installed app, a second
/// install, any tagged DEV build — reads and writes the same file, and several
/// are routinely open at once. So a launch is not "check the array, then run":
/// it is a `claim(...)` that takes an exclusive `flock`, re-reads from disk,
/// and only wins if the task is still pending. Without that, three instances
/// launch the same autonomous agent three times on the same repository.
@MainActor
final class AutoTaskStore: ObservableObject {
    static let shared = AutoTaskStore()

    @Published private(set) var tasks: [ScheduledAutoTask] = []

    private let fileURL: URL
    private let lockURL: URL
    private let fileManager: FileManager

    /// `directory` is injectable so tests get their own queue instead of the
    /// developer's real one.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = directory ?? Self.defaultDirectory(fileManager: fileManager)
        fileURL = base.appendingPathComponent("auto-tasks.json", isDirectory: false)
        lockURL = base.appendingPathComponent("auto-tasks.lock", isDirectory: false)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        reload()
    }

    /// Shared with the rest of cmux's user data. The release bundle id is used
    /// on purpose so a tagged DEV build sees the same queue the installed app
    /// does — same reason the settings file store does it.
    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("com.cmuxterm.app", isDirectory: true)
    }

    // MARK: - Reading

    /// Re-read from disk. Cheap, and the only way to notice writes made by
    /// another cmux instance.
    func reload() {
        tasks = Self.decode(data: try? Data(contentsOf: fileURL))
    }

    private static func decode(data: Data?) -> [ScheduledAutoTask] {
        guard let data, !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A corrupt file must not wedge the panel forever. Losing the queue is
        // bad; refusing to start is worse.
        return (try? decoder.decode([ScheduledAutoTask].self, from: data)) ?? []
    }

    private static func encode(_ tasks: [ScheduledAutoTask]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(tasks)
    }

    // MARK: - Writing

    /// Mutate the queue under the lock, re-reading first so a concurrent
    /// instance's changes are not clobbered. The closure receives the on-disk
    /// state and returns the state to write.
    @discardableResult
    private func withQueue<T>(_ body: (inout [ScheduledAutoTask]) -> T) -> T {
        let lock = AutoTaskFileLock(url: lockURL)
        lock.lock()
        defer { lock.unlock() }

        var current = Self.decode(data: try? Data(contentsOf: fileURL))
        let result = body(&current)
        if let data = try? Self.encode(current) {
            try? data.write(to: fileURL, options: .atomic)
        }
        tasks = current
        return result
    }

    func add(_ task: ScheduledAutoTask) {
        withQueue { $0.append(task) }
    }

    func cancel(id: UUID) {
        withQueue { queue in
            guard let idx = queue.firstIndex(where: { $0.id == id }), !queue[idx].isSettled else { return }
            queue[idx].state = .cancelled
        }
    }

    func reschedule(id: UUID, to date: Date) {
        withQueue { queue in
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
            queue[idx].scheduledAt = date
            queue[idx].state = .pending
            queue[idx].failureReason = nil
            queue[idx].claimedByPID = nil
        }
    }

    func remove(id: UUID) {
        withQueue { $0.removeAll { $0.id == id } }
    }

    /// Mark every pending task whose time has passed as `.missed`.
    /// Returns the ones just transitioned, for the "while you were away" notice.
    @discardableResult
    func markOverdueAsMissed(now: Date = Date()) -> [ScheduledAutoTask] {
        withQueue { queue in
            var moved: [ScheduledAutoTask] = []
            for idx in queue.indices where queue[idx].isOverdue(now: now) {
                queue[idx].state = .missed
                moved.append(queue[idx])
            }
            return moved
        }
    }

    /// Try to take ownership of a task for launching.
    ///
    /// Returns the claimed task, or `nil` when another instance got there
    /// first, the task was cancelled, or it no longer exists. The caller must
    /// only launch on a non-nil result.
    func claimForLaunch(id: UUID, now: Date = Date()) -> ScheduledAutoTask? {
        withQueue { queue -> ScheduledAutoTask? in
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return nil }
            switch queue[idx].state {
            case .pending, .missed:
                queue[idx].state = .launched
                queue[idx].launchedAt = now
                queue[idx].claimedByPID = ProcessInfo.processInfo.processIdentifier
                return queue[idx]
            case .launched, .cancelled, .failed:
                return nil
            }
        }
    }

    /// Record that a claimed launch could not actually happen.
    func markFailed(id: UUID, reason: String) {
        withQueue { queue in
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
            queue[idx].state = .failed
            queue[idx].failureReason = reason
            queue[idx].launchedAt = nil
        }
    }

    /// Record the chat this run opened, so the row can jump back to it.
    func attachChat(id: UUID, panelId: UUID, workspaceId: UUID) {
        withQueue { queue in
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
            queue[idx].chatPanelId = panelId
            queue[idx].chatWorkspaceId = workspaceId
        }
    }

    /// The tasks belonging to a project, plus every ownerless one.
    ///
    /// Ownerless tasks — scheduled from a workspace that was not a saved
    /// project, or queued before projects existed — are shown under every
    /// project on purpose. Filtering them out would leave runs that fire on
    /// their own with nowhere to be seen or cancelled.
    func tasks(inProject projectId: UUID?) -> [ScheduledAutoTask] {
        guard let projectId else { return tasks }
        var out: [ScheduledAutoTask] = []
        for task in tasks where task.projectId == projectId || task.projectId == nil {
            out.append(task)
        }
        return out
    }

    /// What the GitLab issue list needs to mark an issue: for each issue number
    /// in this repository, the outstanding auto-task, if any.
    ///
    /// Purely local — nothing is written to GitLab. Computed here, above the
    /// row list, so the rows themselves receive plain values and never reach
    /// into this store (the `LazyVStack` snapshot boundary).
    ///
    /// Only tasks that still owe a run are reported. A launched or cancelled
    /// one is history, and marking an issue "scheduled" for it would be a lie.
    /// When an issue has several, the soonest wins.
    func outstandingByIssue(
        repositoryPath: String,
        projectId: UUID? = nil
    ) -> [Int: ScheduledAutoTask] {
        let target = Self.comparablePath(repositoryPath)
        guard !target.isEmpty else { return [:] }
        var out: [Int: ScheduledAutoTask] = [:]
        for task in tasks(inProject: projectId) {
            switch task.state {
            case .pending, .missed: break
            case .launched, .cancelled, .failed: continue
            }
            guard Self.comparablePath(task.repositoryPath) == target else { continue }
            if let existing = out[task.issueIID], existing.scheduledAt <= task.scheduledAt { continue }
            out[task.issueIID] = task
        }
        return out
    }

    /// Paths are compared standardized and symlink-resolved: a task scheduled
    /// from `/tmp/x` must still mark the issue when the workspace reports
    /// `/private/tmp/x`.
    private static func comparablePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let resolved = URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") { return String(resolved.dropLast()) }
        return resolved
    }

    /// The soonest pending task, which is what the scheduler arms its timer to.
    /// Loop rather than `filter`/`min` for the same type-checker reason as
    /// `AutoTaskScheduler.dueTasks`.
    func nextPending(after now: Date = Date()) -> ScheduledAutoTask? {
        var soonest: ScheduledAutoTask?
        for task in tasks {
            guard task.state == .pending, task.scheduledAt > now else { continue }
            if let current = soonest, current.scheduledAt <= task.scheduledAt { continue }
            soonest = task
        }
        return soonest
    }
}

/// A cross-process advisory lock. `flock` on a sidecar file — the queue itself
/// is replaced atomically on write, so locking it directly would lock an inode
/// that is about to be swapped out from under the holder.
private final class AutoTaskFileLock {
    private let url: URL
    private var descriptor: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    func lock() {
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return }
        // Blocking: contention lasts as long as one JSON read+write, and a
        // launch that silently skipped its turn would be worse than a wait.
        _ = flock(descriptor, LOCK_EX)
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
