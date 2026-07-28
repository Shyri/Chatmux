import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the `claude -p --output-format stream-json` wire
/// decoder. This is the protocol seam between the CLI and the chat panel —
/// if a field name or shape drifts, the chat shows nothing / wrong content,
/// so the parser's tolerance (`.other` fallback, missing fields → defaults)
/// is pinned here.
@Suite struct ClaudeStreamEventParseTests {
    // MARK: - Framing / errors

    @Test func emptyAndWhitespaceLinesReturnNil() throws {
        #expect(try ClaudeStreamEvent.parse(line: "") == nil)
        #expect(try ClaudeStreamEvent.parse(line: "   \n  ") == nil)
    }

    @Test func nonJSONThrowsNotJSON() {
        #expect(throws: ClaudeStreamEvent.ParseError.self) {
            _ = try ClaudeStreamEvent.parse(line: "this is not json")
        }
    }

    @Test func topLevelArrayThrowsMalformed() {
        #expect(throws: ClaudeStreamEvent.ParseError.self) {
            _ = try ClaudeStreamEvent.parse(line: "[1,2,3]")
        }
    }

    @Test func objectWithoutTypeThrowsMissingType() {
        #expect(throws: ClaudeStreamEvent.ParseError.self) {
            _ = try ClaudeStreamEvent.parse(line: #"{"foo":"bar"}"#)
        }
    }

    @Test func unknownTypeMapsToOtherInsteadOfThrowing() throws {
        let event = try #require(try ClaudeStreamEvent.parse(line: #"{"type":"brand_new_event"}"#))
        guard case let .other(typeName) = event else {
            Issue.record("expected .other, got \(event)")
            return
        }
        #expect(typeName == "brand_new_event")
    }

    // MARK: - system / init

    @Test func systemInitCarriesSessionModelCwdAndMcpServers() throws {
        let line = """
        {"type":"system","subtype":"init","session_id":"sess-1","model":"claude-opus-4-8","cwd":"/tmp/proj",\
        "mcp_servers":[{"name":"cmux","status":"connected"},{"name":"fs","status":"failed","error":"boom"}]}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .systemInit(sessionId, model, cwd, mcpServers) = event else {
            Issue.record("expected .systemInit, got \(event)")
            return
        }
        #expect(sessionId == "sess-1")
        #expect(model == "claude-opus-4-8")
        #expect(cwd == "/tmp/proj")
        #expect(mcpServers == [
            McpServerInitStatus(name: "cmux", status: "connected", error: nil),
            McpServerInitStatus(name: "fs", status: "failed", error: "boom"),
        ])
    }

    @Test func systemInitAcceptsMessageKeyAsErrorBlobFallback() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"x","status":"failed","message":"alt"}]}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .systemInit(_, _, _, servers) = event else {
            Issue.record("expected .systemInit")
            return
        }
        #expect(servers == [McpServerInitStatus(name: "x", status: "failed", error: "alt")])
    }

    /// Claude Code 2.1.219 reports servers it dropped during `--mcp-config`
    /// validation in a separate `mcp_server_errors` array — they never appear
    /// in `mcp_servers`, so without folding them in a mistyped server config
    /// is silently invisible in the panel. Payload captured from a real
    /// claude-code 2.1.220 run against a deliberately broken config.
    @Test func systemInitFoldsRejectedServersFromMcpServerErrors() throws {
        let line = """
        {"type":"system","subtype":"init","session_id":"s","mcp_servers":[],\
        "mcp_server_errors":[\
        {"name":"broken-no-transport","type":"invalid_config","message":"Skipped — command: expected string"},\
        {"name":"broken-type","type":"unknown_type","message":"Skipped — unknown MCP server type"}]}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .systemInit(_, _, _, servers) = event else {
            Issue.record("expected .systemInit, got \(event)")
            return
        }
        #expect(servers == [
            McpServerInitStatus(
                name: "broken-no-transport",
                status: "invalid_config",
                error: "Skipped — command: expected string"
            ),
            McpServerInitStatus(
                name: "broken-type",
                status: "unknown_type",
                error: "Skipped — unknown MCP server type"
            ),
        ])
    }

    /// A future CLI that lists a rejected server in both arrays must not
    /// produce two rows for it.
    @Test func systemInitDoesNotDuplicateServersListedInBothArrays() throws {
        let line = """
        {"type":"system","subtype":"init","session_id":"s",\
        "mcp_servers":[{"name":"dup","status":"failed","error":"boom"}],\
        "mcp_server_errors":[{"name":"dup","type":"invalid_config","message":"also here"}]}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .systemInit(_, _, _, servers) = event else {
            Issue.record("expected .systemInit")
            return
        }
        #expect(servers == [McpServerInitStatus(name: "dup", status: "failed", error: "boom")])
    }

    /// Older CLIs simply omit the key; the list must stay exactly as before.
    @Test func systemInitWithoutMcpServerErrorsIsUnchanged() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"x","status":"connected"}]}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .systemInit(_, _, _, servers) = event else {
            Issue.record("expected .systemInit")
            return
        }
        #expect(servers == [McpServerInitStatus(name: "x", status: "connected", error: nil)])
    }

    @Test func unknownSystemSubtypeMapsToOther() throws {
        let event = try #require(try ClaudeStreamEvent.parse(line: #"{"type":"system","subtype":"weird"}"#))
        guard case let .other(typeName) = event else {
            Issue.record("expected .other, got \(event)")
            return
        }
        #expect(typeName == "system.weird")
    }

    // MARK: - background tasks

    @Test func taskStartedDecodesRunningPhase() throws {
        let line = #"{"type":"system","subtype":"task_started","task_id":"t1","tool_use_id":"u1","task_type":"local_bash"}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .backgroundTask(phase, taskId, toolUseId, taskType, status, _, _) = event else {
            Issue.record("expected .backgroundTask, got \(event)")
            return
        }
        #expect(phase == .started)
        #expect(taskId == "t1")
        #expect(toolUseId == "u1")
        #expect(taskType == "local_bash")
        #expect(status == "running")
    }

    @Test func taskUpdatedPullsStatusFromPatch() throws {
        let line = #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"completed"}}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .backgroundTask(phase, _, _, _, status, _, _) = event else {
            Issue.record("expected .backgroundTask")
            return
        }
        #expect(phase == .updated)
        #expect(status == "completed")
    }

    @Test func taskNotificationParsesExitCodeFromSummary() throws {
        let line = #"{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed","summary":"shell completed (exit code 0)"}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .backgroundTask(phase, _, _, _, status, exitCode, summary) = event else {
            Issue.record("expected .backgroundTask")
            return
        }
        #expect(phase == .notification)
        #expect(status == "completed")
        #expect(exitCode == "0")
        #expect(summary == "shell completed (exit code 0)")
    }

    @Test func taskNotificationParsesNegativeExitCode() throws {
        let line = #"{"type":"system","subtype":"task_notification","task_id":"t1","summary":"failed (exit code -1)"}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .backgroundTask(_, _, _, _, _, exitCode, _) = event else {
            Issue.record("expected .backgroundTask")
            return
        }
        #expect(exitCode == "-1")
    }

    // MARK: - assistant

    @Test func assistantDecodesTextAndToolUseBlocks() throws {
        let line = """
        {"type":"assistant","message":{"id":"m1","content":[\
        {"type":"text","text":"Hello"},\
        {"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}\
        ],"usage":{"input_tokens":10,"output_tokens":5}}}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .assistant(messageId, blocks, usage, subagent) = event else {
            Issue.record("expected .assistant, got \(event)")
            return
        }
        #expect(messageId == "m1")
        #expect(blocks.count == 2)
        #expect(blocks[0] == .text("Hello"))
        guard case let .toolUse(toolUse) = blocks[1] else {
            Issue.record("expected toolUse block")
            return
        }
        #expect(toolUse.id == "tu1")
        #expect(toolUse.name == "Bash")
        #expect(toolUse.inputJSON.contains("\"command\""))
        #expect(toolUse.inputJSON.contains("\"ls\""))
        #expect(usage?.inputTokens == 10)
        #expect(usage?.outputTokens == 5)
        #expect(subagent == nil)
    }

    /// With `--forward-subagent-text` the stream carries the subagent's own
    /// messages. Telling them apart matters: the panel runs tool-use side
    /// effects (background shells, EnterWorktree, todo banner) for the lead
    /// only. Payload captured from a real claude-code 2.1.220 Agent call.
    @Test func assistantCarriesSubagentOriginWhenForwarded() throws {
        let line = """
        {"type":"assistant","parent_tool_use_id":"toolu_01UH9jZZT414tXsVRnLCfyyH",\
        "subagent_type":"Explore","task_description":"Answer simple math question",\
        "message":{"id":"m2","content":[{"type":"text","text":"4"}]}}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .assistant(_, blocks, _, subagent) = event else {
            Issue.record("expected .assistant, got \(event)")
            return
        }
        #expect(blocks == [.text("4")])
        #expect(subagent == SubagentOrigin(
            parentToolUseId: "toolu_01UH9jZZT414tXsVRnLCfyyH",
            subagentType: "Explore",
            taskDescription: "Answer simple math question"
        ))
    }

    /// The lead sends `parent_tool_use_id` as an explicit null rather than
    /// omitting it, so a presence check would tag every message as a
    /// subagent's and silently stop the panel's tool bookkeeping.
    @Test func assistantWithNullParentToolUseIdIsNotASubagent() throws {
        let line = """
        {"type":"assistant","parent_tool_use_id":null,\
        "message":{"id":"m1","content":[{"type":"text","text":"lead"}]}}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .assistant(_, _, _, subagent) = event else {
            Issue.record("expected .assistant")
            return
        }
        #expect(subagent == nil)
    }

    /// Nested forwards (depth 2+, Claude Code 2.1.219) may only carry the
    /// parent id — that alone still identifies the message as a subagent's.
    @Test func assistantSubagentOriginToleratesMissingTypeAndDescription() throws {
        let line = """
        {"type":"assistant","parent_tool_use_id":"toolu_nested",\
        "message":{"content":[{"type":"text","text":"deep"}]}}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .assistant(_, _, _, subagent) = event else {
            Issue.record("expected .assistant")
            return
        }
        #expect(subagent?.parentToolUseId == "toolu_nested")
        #expect(subagent?.subagentType == nil)
        #expect(subagent?.taskDescription == nil)
    }

    @Test func assistantDropsWhitespaceOnlyTextBlocks() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .assistant(_, blocks, _, _) = event else {
            Issue.record("expected .assistant")
            return
        }
        #expect(blocks.isEmpty)
    }

    // MARK: - user / tool_result

    @Test func userDecodesToolResultBlocks() throws {
        let line = """
        {"type":"user","message":{"content":[\
        {"type":"tool_result","tool_use_id":"tu1","is_error":false,"content":"ok output"}\
        ]}}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .user(blocks) = event else {
            Issue.record("expected .user, got \(event)")
            return
        }
        #expect(blocks.count == 1)
        guard case let .toolResult(result) = blocks[0] else {
            Issue.record("expected toolResult block")
            return
        }
        #expect(result.toolUseId == "tu1")
        #expect(result.content == "ok output")
        #expect(result.isError == false)
    }

    @Test func toolResultArrayContentJoinsTextItems() throws {
        let line = """
        {"type":"user","message":{"content":[\
        {"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}\
        ]}}
        """
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .user(blocks) = event, case let .toolResult(result) = blocks[0] else {
            Issue.record("expected user/toolResult")
            return
        }
        #expect(result.content == "line1\nline2")
    }

    // MARK: - result

    @Test func resultSuccessHasNoErrorMessage() throws {
        let line = #"{"type":"result","is_error":false,"session_id":"s","total_cost_usd":0.12,"usage":{"input_tokens":3}}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .result(isError, sessionId, errorMessage, cost, usage) = event else {
            Issue.record("expected .result, got \(event)")
            return
        }
        #expect(isError == false)
        #expect(sessionId == "s")
        #expect(errorMessage == nil)
        #expect(cost == 0.12)
        #expect(usage?.inputTokens == 3)
    }

    @Test func resultErrorPullsMessageFromErrorThenResult() throws {
        let line = #"{"type":"result","is_error":true,"result":"it broke"}"#
        let event = try #require(try ClaudeStreamEvent.parse(line: line))
        guard case let .result(isError, _, errorMessage, _, _) = event else {
            Issue.record("expected .result")
            return
        }
        #expect(isError == true)
        #expect(errorMessage == "it broke")
    }

    // MARK: - ChatTokenUsage

    @Test func tokenUsageTotalsAndContextWindow() {
        let usage = ChatTokenUsage(
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationInputTokens: 10,
            cacheReadInputTokens: 5
        )
        #expect(usage.total == 165)
        // contextWindow excludes output tokens.
        #expect(usage.contextWindowTokens == 115)
    }

    @Test func tokenUsageDecodeDefaultsMissingFieldsToZero() throws {
        let usage = try #require(ChatTokenUsage.decode(["input_tokens": 7]))
        #expect(usage.inputTokens == 7)
        #expect(usage.outputTokens == 0)
        #expect(usage.cacheCreationInputTokens == 0)
        #expect(usage.cacheReadInputTokens == 0)
    }

    @Test func tokenUsageDecodeNilForNilDict() {
        #expect(ChatTokenUsage.decode(nil) == nil)
    }

    @Test func tokenUsageAddition() {
        let a = ChatTokenUsage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
        let b = ChatTokenUsage(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 30, cacheReadInputTokens: 40)
        let sum = a + b
        #expect(sum == ChatTokenUsage(inputTokens: 11, outputTokens: 22, cacheCreationInputTokens: 33, cacheReadInputTokens: 44))
    }
}
