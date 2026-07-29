import Foundation
import SwiftUI

/// Notification posted whenever the project collection changes.
extension Notification.Name {
    static let chatmuxProjectsDidChange = Notification.Name("cmux.chatmuxProjectsDidChange")
}

/// Persistence for `ChatmuxProject`. One `<uuid>.json` per project, plus a
/// `<uuid>/transcripts/` sidecar holding copies of the Claude conversations so
/// a project stays readable after Claude Code prunes its own history.
@MainActor
final class ChatmuxProjectStore: ObservableObject {
    static let shared = ChatmuxProjectStore()

    /// Most recently opened first — this is the order the recents menu shows.
    @Published private(set) var projects: [ChatmuxProject] = []

    private let directoryURL: URL?
    private let fileManager: FileManager
    /// Where a chat's transcript lives before we copy it. Injectable because
    /// the real resolver reads `homeDirectoryForCurrentUser`, which tests
    /// cannot redirect.
    private let transcriptSource: (_ sessionId: String, _ cwd: String) -> URL?
    private var hasLoaded = false

    init(
        directoryURL: URL? = ChatmuxProjectSchema.defaultDirectoryURL(),
        fileManager: FileManager = .default,
        transcriptSource: @escaping (_ sessionId: String, _ cwd: String) -> URL? = {
            ClaudeSessionHistory.transcriptURL(sessionId: $0, cwd: $1)
        }
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.transcriptSource = transcriptSource
    }

    // MARK: - Lifecycle

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    func reload() {
        guard let directoryURL else {
            projects = []
            return
        }
        ensureDirectoryExists()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            projects = []
            return
        }

        var loaded: [ChatmuxProject] = []
        let decoder = JSONDecoder()
        // Sidecar directories live alongside the records; the extension filter
        // and `skipsSubdirectoryDescendants` keep them out of the way.
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let project = try? decoder.decode(ChatmuxProject.self, from: data) else {
                continue
            }
            loaded.append(project)
        }
        projects = Self.sorted(loaded)
        notifyDidChange()
    }

    // MARK: - Lookup

    func project(for id: UUID) -> ChatmuxProject? {
        projects.first { $0.id == id }
    }

    /// The project a live workspace belongs to, if any. Drives both
    /// "is it already open?" and the auto-refresh when a workspace closes.
    func project(forWorkspaceStableId stableId: UUID) -> ChatmuxProject? {
        projects.first { $0.workspaceStableId == stableId }
    }

    // MARK: - CRUD

    @discardableResult
    func create(
        name: String,
        workspaceStableId: UUID,
        snapshot: SessionWorkspaceSnapshot
    ) -> ChatmuxProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID()
        let project = ChatmuxProject(
            id: id,
            name: trimmed,
            workspaceStableId: workspaceStableId,
            snapshot: captureTranscripts(for: id, in: snapshot)
        )
        guard persist(project) else { return nil }
        projects.append(project)
        projects = Self.sorted(projects)
        notifyDidChange()
        return project
    }

    @discardableResult
    func rename(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        var updated = projects[index]
        updated.name = trimmed
        updated.updatedAt = Date().timeIntervalSince1970
        guard persist(updated) else { return false }
        projects[index] = updated
        notifyDidChange()
        return true
    }

    /// Refresh a project from a live capture. Transcript copies are refreshed
    /// too, so the conversation stays current with the workspace.
    @discardableResult
    func update(id: UUID, snapshot: SessionWorkspaceSnapshot) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        var updated = projects[index]
        updated.snapshot = captureTranscripts(for: id, in: snapshot)
        updated.updatedAt = Date().timeIntervalSince1970
        guard persist(updated) else { return false }
        projects[index] = updated
        notifyDidChange()
        return true
    }

    /// Bump a project to the top of the recents list.
    @discardableResult
    func markOpened(id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        var updated = projects[index]
        updated.lastOpenedAt = Date().timeIntervalSince1970
        guard persist(updated) else { return false }
        projects[index] = updated
        projects = Self.sorted(projects)
        notifyDidChange()
        return true
    }

    /// A duplicate is an independent project: it gets a fresh identity so both
    /// copies can be open at once without fighting over the same workspace.
    @discardableResult
    func duplicate(id: UUID) -> ChatmuxProject? {
        guard let original = project(for: id) else { return nil }
        let copyName = String(
            format: String(localized: "projects.duplicateName.format", defaultValue: "%@ Copy"),
            original.name
        )
        let freshStableId = UUID()
        var snapshot = original.snapshot
        snapshot.stableId = freshStableId
        return create(name: copyName, workspaceStableId: freshStableId, snapshot: snapshot)
    }

    func delete(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        if let url = fileURL(for: id) {
            try? fileManager.removeItem(at: url)
        }
        if let directoryURL {
            try? fileManager.removeItem(
                at: ChatmuxProjectSchema.sidecarDirectoryURL(projectId: id, in: directoryURL)
            )
        }
        projects.remove(at: index)
        notifyDidChange()
    }

    // MARK: - Import / Export

    /// Imported projects get a fresh identity so importing the same file twice
    /// yields two independent projects rather than two claims on one workspace.
    func importFromURL(_ url: URL) -> ChatmuxProject? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let imported = try? JSONDecoder().decode(ChatmuxProject.self, from: data) else { return nil }
        let freshStableId = UUID()
        var snapshot = imported.snapshot
        snapshot.stableId = freshStableId
        return create(name: imported.name, workspaceStableId: freshStableId, snapshot: snapshot)
    }

    func exportToURL(id: UUID, _ destination: URL) -> Bool {
        guard let project = project(for: id) else { return false }
        do {
            let data = try ChatmuxProject.canonicalEncoder().encode(project)
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Transcript sidecar

    /// Copy every chat transcript referenced by `snapshot` into the project's
    /// sidecar and rewrite `transcriptPath` to point at the copy.
    ///
    /// `SessionClaudeChatPanelSnapshot.transcriptPath` is always nil as
    /// captured (`Workspace.sessionPanelSnapshot`) — the restore path derives
    /// the location from `sessionId` + cwd instead, which resolves to Claude
    /// Code's own JSONL. That is fine for a relaunch minutes later and wrong
    /// for a project reopened in three months, so this is where the field
    /// finally earns its keep.
    ///
    /// An unreadable source is not an error: a previously copied transcript is
    /// kept as-is, so refreshing a project whose Claude history has already
    /// been pruned never destroys the copy that still works.
    private func captureTranscripts(
        for projectId: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) -> SessionWorkspaceSnapshot {
        guard let directoryURL else { return snapshot }
        var updated = snapshot
        var destinationDirectoryCreated = false

        for index in updated.panels.indices {
            guard let chat = updated.panels[index].claudeChat else { continue }
            guard let sessionId = chat.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionId.isEmpty else { continue }
            guard let cwd = chat.workingDirectory, !cwd.isEmpty else { continue }

            let transcriptsDirectory = ChatmuxProjectSchema.transcriptsDirectoryURL(
                projectId: projectId,
                in: directoryURL
            )
            let destination = transcriptsDirectory
                .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)

            guard let source = transcriptSource(sessionId, cwd),
                  fileManager.isReadableFile(atPath: source.path) else {
                // Keep an existing copy rather than dropping the reference.
                if fileManager.isReadableFile(atPath: destination.path) {
                    updated.panels[index].claudeChat?.transcriptPath = destination.path
                }
                continue
            }

            if !destinationDirectoryCreated {
                try? fileManager.createDirectory(
                    at: transcriptsDirectory,
                    withIntermediateDirectories: true
                )
                destinationDirectoryCreated = true
            }
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.copyItem(at: source, to: destination)
                updated.panels[index].claudeChat?.transcriptPath = destination.path
            } catch {
                continue
            }
        }
        return updated
    }

    // MARK: - Internals

    private static func sorted(_ projects: [ChatmuxProject]) -> [ChatmuxProject] {
        projects.sorted { lhs, rhs in
            if lhs.lastOpenedAt != rhs.lastOpenedAt {
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func ensureDirectoryExists() {
        guard let directoryURL else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    @discardableResult
    private func persist(_ project: ChatmuxProject) -> Bool {
        guard let url = fileURL(for: project.id) else { return false }
        ensureDirectoryExists()
        do {
            let data = try ChatmuxProject.canonicalEncoder().encode(project)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .chatmuxProjectsDidChange, object: self)
    }
}
