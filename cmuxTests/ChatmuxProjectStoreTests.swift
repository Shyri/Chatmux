import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers `ChatmuxProjectStore`, the persistence behind saving a
/// single workspace as a reopenable project.
///
/// The load-bearing part is the transcript sidecar. A chat snapshot only
/// carries a `sessionId`, and the restore path turns that into a path under
/// Claude Code's own `~/.claude/projects/`. That is fine for a relaunch and
/// wrong for a project reopened months later, so the store copies each
/// transcript next to the project — and must never destroy a good copy when
/// the original has already been pruned.
@Suite @MainActor struct ChatmuxProjectStoreTests {
    // MARK: - Fixtures

    private func makeSnapshot(
        stableId: UUID = UUID(),
        panels: [SessionPanelSnapshot] = []
    ) -> SessionWorkspaceSnapshot {
        var snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: panels,
            statusEntries: [],
            logEntries: []
        )
        snapshot.stableId = stableId
        return snapshot
    }

    /// Built by decoding, mirroring what session restore reads off disk —
    /// `SessionPanelSnapshot` has far too many fields to spell out here.
    private func makeChatPanel(sessionId: String, cwd: String) throws -> SessionPanelSnapshot {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "type": "claudeChat",
          "isPinned": false,
          "isManuallyUnread": false,
          "listeningPorts": [],
          "claudeChat": {
            "sessionId": "\(sessionId)",
            "workingDirectory": "\(cwd)",
            "transcriptPath": null
          }
        }
        """
        return try JSONDecoder().decode(SessionPanelSnapshot.self, from: Data(json.utf8))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatmux-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    // MARK: - CRUD round-trip

    @Test func createPersistsAndSurvivesAReload() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let stableId = UUID()
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: stableId,
                snapshot: makeSnapshot(stableId: stableId)
            ))
            #expect(created.name == "Chatmux")

            let reloaded = ChatmuxProjectStore(directoryURL: directory)
            reloaded.loadIfNeeded()
            #expect(reloaded.projects.count == 1)
            #expect(reloaded.projects.first?.id == created.id)
            #expect(reloaded.projects.first?.workspaceStableId == stableId)
        }
    }

    @Test func createRejectsABlankName() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            #expect(store.create(name: "   ", workspaceStableId: UUID(), snapshot: makeSnapshot()) == nil)
            #expect(store.projects.isEmpty)
        }
    }

    /// The menu shows these as "recents", so most recently opened wins.
    @Test func projectsAreOrderedByMostRecentlyOpened() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let first = try #require(store.create(name: "A", workspaceStableId: UUID(), snapshot: makeSnapshot()))
            let second = try #require(store.create(name: "B", workspaceStableId: UUID(), snapshot: makeSnapshot()))

            #expect(store.markOpened(id: first.id))
            #expect(store.projects.first?.id == first.id)

            #expect(store.markOpened(id: second.id))
            #expect(store.projects.first?.id == second.id)
            #expect(store.projects.last?.id == first.id)
        }
    }

    /// The stableId lookup is what answers "is this project already open?" and
    /// "which project should this closing workspace refresh?".
    @Test func projectIsFoundByItsWorkspaceStableId() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let stableId = UUID()
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: stableId,
                snapshot: makeSnapshot(stableId: stableId)
            ))
            #expect(store.project(forWorkspaceStableId: stableId)?.id == created.id)
            #expect(store.project(forWorkspaceStableId: UUID()) == nil)
        }
    }

    /// Both copies must be openable at once, so a duplicate cannot inherit the
    /// identity that decides which live workspace a project owns.
    @Test func duplicateGetsAnIndependentWorkspaceIdentity() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let stableId = UUID()
            let original = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: stableId,
                snapshot: makeSnapshot(stableId: stableId)
            ))
            let copy = try #require(store.duplicate(id: original.id))

            #expect(copy.id != original.id)
            #expect(copy.workspaceStableId != original.workspaceStableId)
            #expect(copy.snapshot.stableId == copy.workspaceStableId)
            #expect(store.project(forWorkspaceStableId: stableId)?.id == original.id)
        }
    }

    @Test func renameUpdatesTheStoredRecord() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let created = try #require(store.create(name: "Old", workspaceStableId: UUID(), snapshot: makeSnapshot()))
            #expect(store.rename(id: created.id, to: "New"))
            #expect(store.rename(id: created.id, to: "  ") == false)

            let reloaded = ChatmuxProjectStore(directoryURL: directory)
            reloaded.loadIfNeeded()
            #expect(reloaded.projects.first?.name == "New")
        }
    }

    // MARK: - Transcript sidecar

    @Test func transcriptIsCopiedIntoTheProjectSidecar() throws {
        try withTemporaryDirectory { directory in
            let claudeHome = directory.appendingPathComponent("fake-claude", isDirectory: true)
            try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
            let source = claudeHome.appendingPathComponent("sess-1.jsonl")
            try #"{"type":"user","message":{"content":"hola"}}"#.write(
                to: source, atomically: true, encoding: .utf8
            )

            let store = ChatmuxProjectStore(
                directoryURL: directory,
                transcriptSource: { sessionId, _ in
                    claudeHome.appendingPathComponent("\(sessionId).jsonl")
                }
            )
            let panel = try makeChatPanel(sessionId: "sess-1", cwd: "/work/dir")
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: UUID(),
                snapshot: makeSnapshot(panels: [panel])
            ))

            let copiedPath = try #require(created.snapshot.panels.first?.claudeChat?.transcriptPath)
            #expect(FileManager.default.fileExists(atPath: copiedPath))
            #expect(copiedPath.hasPrefix(directory.path))
            #expect(try String(contentsOfFile: copiedPath, encoding: .utf8).contains("hola"))
        }
    }

    /// Refreshing a project whose Claude history has already been pruned must
    /// keep the copy that still works rather than dropping the reference.
    @Test func refreshKeepsAnExistingCopyWhenTheSourceIsGone() throws {
        try withTemporaryDirectory { directory in
            let claudeHome = directory.appendingPathComponent("fake-claude", isDirectory: true)
            try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
            let source = claudeHome.appendingPathComponent("sess-1.jsonl")
            try "original".write(to: source, atomically: true, encoding: .utf8)

            let store = ChatmuxProjectStore(
                directoryURL: directory,
                transcriptSource: { sessionId, _ in
                    claudeHome.appendingPathComponent("\(sessionId).jsonl")
                }
            )
            let panel = try makeChatPanel(sessionId: "sess-1", cwd: "/work/dir")
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: UUID(),
                snapshot: makeSnapshot(panels: [panel])
            ))
            let copiedPath = try #require(created.snapshot.panels.first?.claudeChat?.transcriptPath)

            // Claude Code prunes its history, then the workspace closes and the
            // project refreshes from a fresh capture.
            try FileManager.default.removeItem(at: source)
            #expect(store.update(id: created.id, snapshot: makeSnapshot(panels: [panel])))

            let refreshed = try #require(store.project(for: created.id))
            #expect(refreshed.snapshot.panels.first?.claudeChat?.transcriptPath == copiedPath)
            #expect(try String(contentsOfFile: copiedPath, encoding: .utf8) == "original")
        }
    }

    @Test func chatWithoutASessionIdGetsNoTranscriptPath() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let json = """
            {
              "id": "\(UUID().uuidString)",
              "type": "claudeChat",
              "isPinned": false,
              "isManuallyUnread": false,
              "listeningPorts": [],
              "claudeChat": { "workingDirectory": "/work/dir" }
            }
            """
            let panel = try JSONDecoder().decode(SessionPanelSnapshot.self, from: Data(json.utf8))
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: UUID(),
                snapshot: makeSnapshot(panels: [panel])
            ))
            #expect(created.snapshot.panels.first?.claudeChat?.transcriptPath == nil)
        }
    }

    @Test func deleteRemovesBothTheRecordAndItsTranscriptSidecar() throws {
        try withTemporaryDirectory { directory in
            let claudeHome = directory.appendingPathComponent("fake-claude", isDirectory: true)
            try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
            try "transcript".write(
                to: claudeHome.appendingPathComponent("sess-1.jsonl"),
                atomically: true,
                encoding: .utf8
            )

            let store = ChatmuxProjectStore(
                directoryURL: directory,
                transcriptSource: { sessionId, _ in
                    claudeHome.appendingPathComponent("\(sessionId).jsonl")
                }
            )
            let panel = try makeChatPanel(sessionId: "sess-1", cwd: "/work/dir")
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: UUID(),
                snapshot: makeSnapshot(panels: [panel])
            ))
            let sidecar = ChatmuxProjectSchema.sidecarDirectoryURL(projectId: created.id, in: directory)
            #expect(FileManager.default.fileExists(atPath: sidecar.path))

            store.delete(id: created.id)
            #expect(store.projects.isEmpty)
            #expect(FileManager.default.fileExists(atPath: sidecar.path) == false)

            let reloaded = ChatmuxProjectStore(directoryURL: directory)
            reloaded.loadIfNeeded()
            #expect(reloaded.projects.isEmpty)
        }
    }

    /// Sidecar directories sit next to the `<uuid>.json` records; the reload
    /// scan must not try to decode them as projects.
    @Test func reloadIgnoresSidecarDirectories() throws {
        try withTemporaryDirectory { directory in
            let claudeHome = directory.appendingPathComponent("fake-claude", isDirectory: true)
            try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
            try "t".write(
                to: claudeHome.appendingPathComponent("sess-1.jsonl"),
                atomically: true,
                encoding: .utf8
            )
            let store = ChatmuxProjectStore(
                directoryURL: directory,
                transcriptSource: { sessionId, _ in
                    claudeHome.appendingPathComponent("\(sessionId).jsonl")
                }
            )
            let panel = try makeChatPanel(sessionId: "sess-1", cwd: "/work/dir")
            _ = store.create(name: "Chatmux", workspaceStableId: UUID(), snapshot: makeSnapshot(panels: [panel]))

            let reloaded = ChatmuxProjectStore(directoryURL: directory)
            reloaded.loadIfNeeded()
            #expect(reloaded.projects.count == 1)
        }
    }

    // MARK: - Import / export

    @Test func exportThenImportYieldsAnIndependentProject() throws {
        try withTemporaryDirectory { directory in
            let store = ChatmuxProjectStore(directoryURL: directory)
            let created = try #require(store.create(
                name: "Chatmux",
                workspaceStableId: UUID(),
                snapshot: makeSnapshot()
            ))
            let exported = directory.appendingPathComponent("exported.chatmuxproject")
            #expect(store.exportToURL(id: created.id, exported))

            let imported = try #require(store.importFromURL(exported))
            #expect(imported.id != created.id)
            #expect(imported.workspaceStableId != created.workspaceStableId)
            #expect(imported.name == created.name)
            #expect(store.projects.count == 2)
        }
    }
}
