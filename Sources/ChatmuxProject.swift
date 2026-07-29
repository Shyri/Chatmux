import Foundation

/// A named, reopenable snapshot of a **single** workspace: its panels, split
/// layout, titles and — the point of the whole thing — its Claude chat
/// sessions, so closing a workspace and coming back to it days later resumes
/// the conversation where it was left.
///
/// Not to be confused with two neighbours that sound similar:
/// - `CmuxSavedLayout` (upstream, `~/.config/cmux/layouts.json`) is a
///   *declarative template*: cwd, env, setup command, split tree. It describes
///   how to build a workspace from scratch and captures nothing live.
/// - `PanelType.project` (upstream) is the Xcode project navigator panel and
///   has nothing to do with this. Hence the `Chatmux` prefix on these types.
///
/// The link back to a live workspace is `Workspace.stableId`, which round-trips
/// through `SessionWorkspaceSnapshot` (captured in `Workspace.sessionSnapshot`,
/// re-adopted in `Workspace.restoreSessionSnapshot` unless that identity is
/// already live). Keying on it means no upstream type has to grow a field for
/// this feature, which keeps `/sync-upstream` cheap.
struct ChatmuxProject: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    let createdAt: TimeInterval
    var updatedAt: TimeInterval
    /// Drives the "recents" ordering in the menu.
    var lastOpenedAt: TimeInterval
    /// Matches `Workspace.stableId` of the workspace this project is bound to.
    /// Used both to detect "already open" and to find the project to refresh
    /// when a workspace closes.
    var workspaceStableId: UUID
    var snapshot: SessionWorkspaceSnapshot

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        lastOpenedAt: TimeInterval = Date().timeIntervalSince1970,
        workspaceStableId: UUID,
        snapshot: SessionWorkspaceSnapshot
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.workspaceStableId = workspaceStableId
        self.snapshot = snapshot
    }

    /// Identity-only equality: the snapshot is large and compared by value
    /// nowhere, so `==` stays cheap for SwiftUI diffing.
    static func == (lhs: ChatmuxProject, rhs: ChatmuxProject) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.createdAt == rhs.createdAt &&
            lhs.updatedAt == rhs.updatedAt &&
            lhs.lastOpenedAt == rhs.lastOpenedAt &&
            lhs.workspaceStableId == rhs.workspaceStableId
    }
}

enum ChatmuxProjectSchema {
    /// Extension offered in the import/export panels. On-disk records are
    /// plain `<uuid>.json`; this is only the user-facing document type.
    static let fileExtension = "chatmuxproject"
    static let directoryName = "projects"
    static let transcriptsDirectoryName = "transcripts"

    /// `~/Library/Application Support/cmux/projects-<safeBundleId>/`.
    ///
    /// Scoped per bundle id so a Chatmux dev build, the release app and cmux
    /// itself never share a collection — the same split the session presets
    /// this replaces used to make.
    static func defaultDirectoryURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("\(directoryName)-\(safeBundleId)", isDirectory: true)
    }

    /// Per-project sidecar directory holding copies of the Claude transcripts.
    ///
    /// The copies exist because `SessionClaudeChatPanelSnapshot` otherwise
    /// points at Claude Code's own JSONL under `~/.claude/projects/`, which is
    /// outside our control: a project reopened months later would come back
    /// with an empty chat once that history is pruned or reorganised.
    static func transcriptsDirectoryURL(projectId: UUID, in directoryURL: URL) -> URL {
        directoryURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(transcriptsDirectoryName, isDirectory: true)
    }

    /// Sidecar root for a project — the directory removed wholesale on delete.
    static func sidecarDirectoryURL(projectId: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(projectId.uuidString, isDirectory: true)
    }
}

extension ChatmuxProject {
    /// Stable JSON encoding used for storage.
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
