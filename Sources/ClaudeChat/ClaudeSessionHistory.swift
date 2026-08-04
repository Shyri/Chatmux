import Foundation

/// Reads Claude Code's per-session JSONL transcript and the file-history
/// snapshots it stores under `~/.claude/file-history/<sessionId>/`. cmux
/// uses these to power the "undo last turn" button: claude already tracks
/// the file contents for us, we just need to find and copy them back.
enum ClaudeSessionHistory {
    /// File backups captured by Claude Code at the start of a turn — i.e.
    /// the state of each touched file before claude modified it.
    struct TurnFileBackups {
        let sessionId: String
        /// Map of absolute file path → URL of the backup blob inside
        /// `~/.claude/file-history/<sessionId>/`.
        let backups: [String: URL]
    }

    /// Find the latest non-empty `file-history-snapshot` event in the
    /// JSONL for `sessionId` and return the file→backup map. The "latest"
    /// snapshot represents the pre-state of the most recent turn that
    /// touched files.
    static func latestTurnBackups(
        sessionId: String,
        cwd: String
    ) -> TurnFileBackups? {
        guard let jsonlURL = resolveTranscriptURL(sessionId: sessionId, cwd: cwd, copiedAt: nil),
              let data = try? Data(contentsOf: jsonlURL),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let historyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/file-history", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)

        var latest: [String: URL] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "file-history-snapshot",
                  let snapshot = obj["snapshot"] as? [String: Any],
                  let backups = snapshot["trackedFileBackups"] as? [String: [String: Any]],
                  !backups.isEmpty
            else { continue }

            // Each later snapshot supersedes earlier ones for the same path
            // (Claude Code rewrites the entry as new versions land).
            for (path, info) in backups {
                guard let backupName = info["backupFileName"] as? String else { continue }
                latest[path] = historyDir.appendingPathComponent(backupName)
            }
        }
        guard !latest.isEmpty else { return nil }
        return TurnFileBackups(sessionId: sessionId, backups: latest)
    }

    /// Restore the files in `backups` to disk, replacing whatever is at
    /// each path right now. Returns the paths that were restored
    /// successfully.
    @discardableResult
    static func restore(_ backups: TurnFileBackups) -> [String] {
        var restored: [String] = []
        for (path, backupURL) in backups.backups {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { continue }
            do {
                let data = try Data(contentsOf: backupURL)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                restored.append(path)
            } catch {
                #if DEBUG
                NSLog("ClaudeSessionHistory.restore failed path=\(path) err=\(error.localizedDescription)")
                #endif
            }
        }
        return restored
    }

    /// Read the per-session JSONL transcript written by the Claude Code
    /// CLI and return it as a list of `ChatMessage` ready to seed a
    /// `ClaudeChatPanel`'s `initialMessages`. Used when the Sessions
    /// panel asks us to resume a Claude Code session inside a chat
    /// panel — the panel shows the full conversation immediately and
    /// the runner picks up the same `--resume <sessionId>` from there.
    ///
    /// The JSONL written by Claude Code is *not* identical to the
    /// stream-json `claude -p` emits: each line carries metadata
    /// (parentUuid, timestamp, gitBranch…) and the `message.content`
    /// of a user line can be a String *or* an array of blocks. We parse
    /// it defensively — malformed lines are skipped, never abort the
    /// load. Returns `nil` if the file doesn't exist or can't be read.
    static func loadTranscript(sessionId: String, cwd: String) async -> [ChatMessage]? {
        guard let jsonlURL = resolveTranscriptURL(
            sessionId: sessionId,
            cwd: cwd,
            copiedAt: nil
        ) else { return nil }
        return await loadTranscript(at: jsonlURL)
    }

    /// Same as `loadTranscript(sessionId:cwd:)` but reading a file chosen by
    /// the caller.
    ///
    /// Saved projects copy each transcript into their own sidecar, because
    /// Claude Code's history under `~/.claude/projects/` is outside our control
    /// and a project reopened months later would otherwise come back empty.
    /// See `resolveTranscriptURL(sessionId:cwd:copiedAt:)`.
    static func loadTranscript(at url: URL) async -> [ChatMessage]? {
        await Task.detached(priority: .userInitiated) { () -> [ChatMessage]? in
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }

            let messages = decodeTranscript(text: text)
            return messages.isEmpty ? nil : messages
        }.value
    }

    /// Which file actually backs a restored chat, preferring a copy captured
    /// alongside a saved project over Claude Code's own history.
    ///
    /// `nil` means the conversation is gone. That answer matters: the caller
    /// must then restore the panel *without* a resume id, because a chat that
    /// keeps a `sessionId` whose transcript no longer exists sends
    /// `--resume <id>` on the next turn, the CLI fails, and the panel is stuck
    /// in an error state until the user runs `/clear`.
    static func resolveTranscriptURL(
        sessionId: String,
        cwd: String,
        copiedAt copiedPath: String?,
        projectsDirectory: URL? = nil
    ) -> URL? {
        if let copiedPath, !copiedPath.isEmpty {
            let copied = URL(fileURLWithPath: copiedPath)
            if FileManager.default.fileExists(atPath: copied.path) {
                return copied
            }
        }
        if let derived = transcriptURL(sessionId: sessionId, cwd: cwd),
           FileManager.default.fileExists(atPath: derived.path) {
            return derived
        }
        // The derived path is a guess: it assumes the conversation still lives
        // under the cwd the panel was launched from. `EnterWorktree` breaks
        // that assumption — Claude Code follows the CLI into
        // `<repo>/.claude/worktrees/<n>` and writes the transcript under that
        // encoded directory instead, while the panel snapshot still carries the
        // original cwd. Measured against one real history: 10 of 47 restorable
        // chats resolved to nothing this way, each with its transcript sitting
        // on disk under a worktree directory.
        //
        // Session ids are UUIDs, so a filename match anywhere under
        // `~/.claude/projects` is unambiguous. Only runs when the cheap path
        // misses.
        return findTranscript(sessionId: sessionId, in: projectsDirectory)
    }

    /// Locate `<sessionId>.jsonl` by scanning the per-cwd project directories.
    ///
    /// Used as the fallback in `resolveTranscriptURL` when the cwd-derived path
    /// misses. `projectsDirectory` is injectable so tests can point at a
    /// fixture tree instead of the real `~/.claude/projects`.
    static func findTranscript(sessionId: String, in projectsDirectory: URL? = nil) -> URL? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let root = projectsDirectory ?? defaultProjectsDirectory()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let filename = "\(trimmed).jsonl"
        for directory in entries {
            let candidate = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func defaultProjectsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Parse the raw JSONL transcript text into renderable `ChatMessage`s,
    /// skipping metadata lines and `thinking` blocks. Split out from
    /// `loadTranscript` (which owns the file I/O) so the line-decoding
    /// contract — string vs. array user content, tool_use/tool_result
    /// mapping, thinking suppression — can be unit-tested with fixture
    /// text instead of a real `~/.claude/projects` file.
    static func decodeTranscript(text: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            if let message = decodeTranscriptLine(obj) {
                messages.append(message)
            }
        }
        return messages
    }

    /// Compute the path of the JSONL transcript for a session given the
    /// chat's cwd. Claude Code stores transcripts under
    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where the
    /// encoded cwd replaces `/` with `-` and prefixes with `-`.
    static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let encoded = encodeCwd(cwd)
        guard !encoded.isEmpty else { return nil }
        return defaultProjectsDirectory()
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Private

    /// Convert one decoded JSONL line into a `ChatMessage`. Returns nil
    /// for metadata lines (worktree-state, file-history-snapshot,
    /// attachment, last-prompt, system) and for `user`/`assistant`
    /// lines whose content yields no blocks the chat panel can render.
    private static func decodeTranscriptLine(_ obj: [String: Any]) -> ChatMessage? {
        let type = obj["type"] as? String ?? ""
        switch type {
        case "user":
            let message = obj["message"] as? [String: Any] ?? [:]
            let blocks = decodeUserMessageContent(message["content"])
            guard !blocks.isEmpty else { return nil }
            return ChatMessage(role: .user, blocks: blocks)
        case "assistant":
            let message = obj["message"] as? [String: Any] ?? [:]
            let contentArray = message["content"] as? [[String: Any]] ?? []
            let blocks = contentArray.compactMap { decodeTranscriptContentBlock($0) }
            guard !blocks.isEmpty else { return nil }
            // Claude Code 2.1.212 records the reasoning effort on every
            // assistant line; older transcripts simply omit the key.
            let effort = (obj["effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ChatMessage(role: .assistant, blocks: blocks, effort: effort)
        default:
            return nil
        }
    }

    /// `user.message.content` can be a plain string (typed prompt) or
    /// an array of blocks (tool_result lines after the assistant ran
    /// tools). Handle both.
    private static func decodeUserMessageContent(_ raw: Any?) -> [ChatMessageBlock] {
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [.text(str)]
        }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { decodeTranscriptContentBlock($0) }
        }
        return []
    }

    /// Mirrors `ClaudeStreamEvent.decodeContentBlock` but lives here so
    /// the chat module can hydrate transcripts without depending on the
    /// live stream parser. `thinking` blocks are persisted by Claude
    /// Code but the chat panel doesn't render them, so they're skipped.
    private static func decodeTranscriptContentBlock(_ block: [String: Any]) -> ChatMessageBlock? {
        guard let type = block["type"] as? String else { return nil }
        switch type {
        case "text":
            guard let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .text(text)
        case "tool_use":
            let id = (block["id"] as? String) ?? ""
            let name = (block["name"] as? String) ?? "unknown"
            let inputAny = block["input"] ?? [:]
            return .toolUse(.init(
                id: id,
                name: name,
                inputJSON: encodeJSONValue(inputAny)
            ))
        case "tool_result":
            let toolUseId = (block["tool_use_id"] as? String) ?? ""
            let isError = (block["is_error"] as? Bool) ?? false
            return .toolResult(.init(
                toolUseId: toolUseId,
                content: stringifyTranscriptToolResultContent(block["content"]),
                isError: isError
            ))
        case "thinking":
            return nil
        default:
            return nil
        }
    }

    private static func stringifyTranscriptToolResultContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if let t = item["type"] as? String, t == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            .joined(separator: "\n")
        }
        return ""
    }

    private static func encodeJSONValue(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.sortedKeys, .prettyPrinted]
           ) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    private static func encodeCwd(_ path: String) -> String {
        // Mirror Claude Code's filename convention: strip trailing slashes,
        // then replace every `/` with `-` (the leading slash becomes a
        // leading `-` so the result matches `-Users-shyri-...`).
        let trimmed = path.trimmingCharacters(in: .init(charactersIn: "/"))
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        return "-" + encoded
    }
}
