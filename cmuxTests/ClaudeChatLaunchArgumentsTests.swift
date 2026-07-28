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
        sessionId: String? = nil,
        cliVersion: String? = "2.1.220"
    ) -> [String] {
        ClaudeChatRunner.buildClaudeArguments(
            permissionMode: mode,
            model: model,
            effort: effort,
            mcpConfigPath: mcp,
            permissionPromptTool: promptTool,
            appendSystemPrompt: appendSystemPrompt,
            sessionId: sessionId,
            cliVersion: cliVersion
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

    /// `--forward-subagent-text` landed in Claude Code 2.1.211. An unknown
    /// flag is fatal — `claude -p --nope` exits 1 with "unknown option"
    /// before the session starts — so sending it to an older binary takes
    /// the entire panel down rather than degrading.
    @Test func forwardSubagentTextIsOnlySentToVersionsThatKnowIt() {
        #expect(build(cliVersion: "2.1.220").contains("--forward-subagent-text"))
        #expect(build(cliVersion: "2.1.211").contains("--forward-subagent-text"))
        #expect(build(cliVersion: "2.1.210").contains("--forward-subagent-text") == false)
        #expect(build(cliVersion: "2.0.999").contains("--forward-subagent-text") == false)
    }

    /// An undetectable version has to read as "old": losing subagent text is
    /// recoverable, a CLI that won't start is not.
    @Test func unknownCliVersionOmitsTheGatedFlag() {
        #expect(build(cliVersion: nil).contains("--forward-subagent-text") == false)
        #expect(build(cliVersion: "").contains("--forward-subagent-text") == false)
        #expect(build(cliVersion: "not-a-version").contains("--forward-subagent-text") == false)
    }

    @Test func versionComparisonIsNumericNotLexicographic() {
        // The trap: "2.1.9" > "2.1.10" as strings.
        #expect(ClaudeChatRunner.version("2.1.211", isAtLeast: "2.1.211"))
        #expect(ClaudeChatRunner.version("2.1.220", isAtLeast: "2.1.211"))
        #expect(ClaudeChatRunner.version("2.2.0", isAtLeast: "2.1.211"))
        #expect(ClaudeChatRunner.version("3.0.0", isAtLeast: "2.1.211"))
        #expect(ClaudeChatRunner.version("2.1.9", isAtLeast: "2.1.211") == false)
        #expect(ClaudeChatRunner.version("2.1.99", isAtLeast: "2.1.211") == false)
        #expect(ClaudeChatRunner.version("2.1", isAtLeast: "2.1.0"))
        #expect(ClaudeChatRunner.version("2.1", isAtLeast: "2.1.1") == false)
    }

    @Test func versionIsParsedFromTheCliBanner() {
        #expect(ClaudeChatRunner.parseVersion(fromVersionOutput: "2.1.220 (Claude Code)") == "2.1.220")
        #expect(ClaudeChatRunner.parseVersion(fromVersionOutput: "  2.1.220 (Claude Code)\n") == "2.1.220")
        #expect(ClaudeChatRunner.parseVersion(fromVersionOutput: "garbage") == nil)
        #expect(ClaudeChatRunner.parseVersion(fromVersionOutput: "") == nil)
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
