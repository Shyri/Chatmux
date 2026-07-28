import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers Claude Code transcript resolution + parsing, which
/// powers "resume this session in a chat panel". The cwd→path encoding is
/// the bug-prone part: `claude --resume <id>` reads
/// `~/.claude/projects/<encoded-cwd>/<id>.jsonl`, so a wrong encoding yields
/// "No conversation found".
@Suite struct ClaudeSessionHistoryTests {
    // MARK: - transcriptURL cwd encoding

    @Test func transcriptURLEncodesSimpleCwd() throws {
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "abc", cwd: "/tmp/proj"))
        #expect(url.path.hasSuffix(".claude/projects/-tmp-proj/abc.jsonl"))
    }

    @Test func transcriptURLEncodesNestedCwd() throws {
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "sid", cwd: "/Users/me/code/app"))
        #expect(url.path.hasSuffix(".claude/projects/-Users-me-code-app/sid.jsonl"))
    }

    @Test func transcriptURLStripsTrailingSlash() throws {
        let withSlash = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "s", cwd: "/tmp/proj/"))
        #expect(withSlash.path.hasSuffix(".claude/projects/-tmp-proj/s.jsonl"))
    }

    @Test func transcriptURLLivesUnderHomeClaudeProjects() throws {
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "s", cwd: "/x"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(url.path.hasPrefix(home))
        #expect(url.path.contains("/.claude/projects/"))
    }

    // MARK: - decodeTranscript

    @Test func decodeTranscriptParsesUserStringAndAssistantBlocks() {
        let jsonl = """
        {"type":"user","message":{"content":"Hello claude"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Hi there"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"out","is_error":false}]}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 3)

        #expect(messages[0].role == .user)
        #expect(messages[0].plainText == "Hello claude")

        #expect(messages[1].role == .assistant)
        #expect(messages[1].blocks.first == .text("Hi there"))
        guard case let .toolUse(toolUse) = messages[1].blocks.last else {
            Issue.record("expected trailing toolUse block")
            return
        }
        #expect(toolUse.name == "Bash")

        #expect(messages[2].role == .user)
        guard case let .toolResult(result) = messages[2].blocks.first else {
            Issue.record("expected toolResult block")
            return
        }
        #expect(result.toolUseId == "t1")
        #expect(result.content == "out")
    }

    @Test func decodeTranscriptSkipsThinkingBlocks() {
        let jsonl = """
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret reasoning"},{"type":"text","text":"visible"}]}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].blocks == [.text("visible")])
    }

    /// Claude Code 2.1.212 records the reasoning effort on each assistant
    /// line of the transcript, so a rehydrated conversation can show what
    /// each answer was produced with. Shape taken from a real 2.1.220
    /// transcript under ~/.claude/projects.
    @Test func decodeTranscriptCarriesAssistantEffort() {
        let jsonl = """
        {"type":"assistant","effort":"xhigh","message":{"content":[{"type":"text","text":"answer"}]}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].effort == "xhigh")
    }

    /// Transcripts written before 2.1.212 have no `effort` key, and an empty
    /// value is not a level — both must read as "unknown", not as a chip
    /// rendering an empty string.
    @Test func decodeTranscriptLeavesEffortNilWhenAbsentOrEmpty() {
        let jsonl = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"old"}]}}
        {"type":"assistant","effort":"","message":{"content":[{"type":"text","text":"blank"}]}}
        {"type":"user","message":{"content":"mine"}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 3)
        #expect(messages.allSatisfy { $0.effort == nil })
    }

    @Test func decodeTranscriptSkipsMetadataAndMalformedLines() {
        let jsonl = """
        {"type":"file-history-snapshot","snapshot":{}}
        {"type":"system","subtype":"init"}
        not-json-at-all
        {"type":"summary"}
        {"type":"user","message":{"content":"real message"}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "real message")
    }

    @Test func decodeTranscriptDropsEmptyUserContent() {
        let jsonl = """
        {"type":"user","message":{"content":"   "}}
        {"type":"user","message":{"content":"kept"}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "kept")
    }

    @Test func decodeTranscriptEmptyTextReturnsEmpty() {
        #expect(ClaudeSessionHistory.decodeTranscript(text: "").isEmpty)
        #expect(ClaudeSessionHistory.decodeTranscript(text: "\n\n").isEmpty)
    }
}
