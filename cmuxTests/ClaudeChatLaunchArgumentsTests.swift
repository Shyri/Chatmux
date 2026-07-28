import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: pins the `claude -p` argv built for each launch. The CLI
/// bakes `--permission-mode` / `--model` / `--effort` / `--resume` into argv
/// at spawn time and can't change them mid-session, so a wrong/missing flag
/// here silently launches the wrong model or loses the session — the class
/// of bug that drove the respawn-on-change tracking in the runner.
@Suite struct ClaudeChatLaunchArgumentsTests {
    private func build(
        mode: String = "default",
        model: String? = nil,
        effort: String? = nil,
        mcp: String? = nil,
        promptTool: String? = nil,
        appendSystemPrompt: String? = nil,
        sessionId: String? = nil
    ) -> [String] {
        ClaudeChatRunner.buildClaudeArguments(
            permissionMode: mode,
            model: model,
            effort: effort,
            mcpConfigPath: mcp,
            permissionPromptTool: promptTool,
            appendSystemPrompt: appendSystemPrompt,
            sessionId: sessionId
        )
    }

    @Test func baseFlagsAlwaysPresentInStreamJSONMode() {
        let args = build(mode: "plan")
        #expect(args.prefix(7) == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--forward-subagent-text",
        ])
        #expect(adjacentValue(args, flag: "--permission-mode") == "plan")
    }

    @Test func modelOmittedWhenNilOrEmpty() {
        #expect(build(model: nil).contains("--model") == false)
        #expect(build(model: "").contains("--model") == false)
    }

    @Test func modelIncludedWhenSet() {
        let args = build(model: "claude-opus-4-8")
        #expect(adjacentValue(args, flag: "--model") == "claude-opus-4-8")
    }

    @Test func effortOmittedWhenNilOrEmpty() {
        #expect(build(effort: nil).contains("--effort") == false)
        #expect(build(effort: "").contains("--effort") == false)
    }

    @Test func effortIncludedWhenSet() {
        let args = build(effort: "xhigh")
        #expect(adjacentValue(args, flag: "--effort") == "xhigh")
    }

    @Test func mcpConfigBringsDisallowedAskUserQuestion() {
        // The two always travel together: enabling our MCP server must also
        // disable claude's built-in AskUserQuestion (which self-denies in -p).
        let args = build(mcp: "/tmp/mcp.json")
        #expect(adjacentValue(args, flag: "--mcp-config") == "/tmp/mcp.json")
        #expect(adjacentValue(args, flag: "--disallowed-tools") == "AskUserQuestion")
    }

    @Test func noMcpConfigMeansNoDisallowedTools() {
        let args = build(mcp: nil)
        #expect(args.contains("--mcp-config") == false)
        #expect(args.contains("--disallowed-tools") == false)
    }

    @Test func permissionPromptToolIncludedWhenSet() {
        let args = build(promptTool: "mcp__cmux__permission_prompt")
        #expect(adjacentValue(args, flag: "--permission-prompt-tool") == "mcp__cmux__permission_prompt")
    }

    @Test func appendSystemPromptIncludedWhenSet() {
        let args = build(appendSystemPrompt: "be terse")
        #expect(adjacentValue(args, flag: "--append-system-prompt") == "be terse")
    }

    @Test func resumeOmittedWhenNilOrEmptyAndIncludedWhenSet() {
        #expect(build(sessionId: nil).contains("--resume") == false)
        #expect(build(sessionId: "").contains("--resume") == false)
        #expect(adjacentValue(build(sessionId: "sess-42"), flag: "--resume") == "sess-42")
    }

    @Test func flagOrderingIsStable() {
        // model -> effort -> mcp(+disallowed) -> prompt-tool -> append -> resume
        let args = build(
            model: "claude-opus-4-8",
            effort: "high",
            mcp: "/tmp/mcp.json",
            promptTool: "tool",
            appendSystemPrompt: "sys",
            sessionId: "s1"
        )
        let order = ["--model", "--effort", "--mcp-config", "--disallowed-tools", "--permission-prompt-tool", "--append-system-prompt", "--resume"]
        let indices = order.compactMap { args.firstIndex(of: $0) }
        #expect(indices.count == order.count)
        #expect(indices == indices.sorted())
    }

    /// Claude Code 2.1.212 started backgrounding MCP tool calls that run
    /// longer than two minutes. Our approval cards are MCP tool calls and
    /// legitimately block for as long as the user takes to answer, so the
    /// spawn has to raise that threshold well past any human response time.
    @Test func mcpAutoBackgroundThresholdIsRaisedWellPastHumanResponseTime() {
        let raw = ClaudeChatRunner.mcpToolEnvironmentOverrides["CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS"]
        let milliseconds = raw.flatMap(Int.init)
        #expect(milliseconds != nil)
        // Comfortably beyond the CLI's 2-minute default.
        #expect((milliseconds ?? 0) >= 60 * 60 * 1000)
    }

    /// Claude Code 2.1.212 lets a headless session switch models mid-flight
    /// via a `set_model` control request, so the panel no longer has to kill
    /// and resume the process on every model change. Pins the wire format
    /// captured from claude-code 2.1.220, which answered `success` and ran
    /// the following turn on the requested model.
    @Test func setModelControlRequestMatchesTheVerifiedWireFormat() throws {
        let line = try #require(ClaudeChatRunner.makeSetModelControlRequestLine(
            model: "claude-haiku-4-5",
            requestId: "req-1"
        ))
        #expect(line.last == 0x0A, "control requests are newline-delimited on stdin")

        let object = try JSONSerialization.jsonObject(with: line.dropLast())
        let payload = try #require(object as? [String: Any])
        #expect(payload["type"] as? String == "control_request")
        #expect(payload["request_id"] as? String == "req-1")
        let request = try #require(payload["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "set_model")
        #expect(request["model"] as? String == "claude-haiku-4-5")
    }

    // Returns the element immediately after `flag`, or nil if absent / last.
    private func adjacentValue(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
