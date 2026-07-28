import Foundation

/// One decoded line of `claude -p --output-format stream-json --verbose`.
///
/// The stream contains four interesting top-level shapes:
/// - `system` (subtype "init"): emitted once at the start of every turn,
///   carries the session id we need for `--resume` on subsequent turns.
/// - `assistant`: a single assistant message with one or more content
///   blocks (text or tool_use). With `--include-partial-messages` enabled
///   each block can be split across multiple `stream_event` deltas, but
///   phase 2 keeps things simple by consuming whole messages.
/// - `user`: a synthetic user message containing tool_result blocks for
///   each tool the assistant invoked.
/// - `result`: emitted once at the end of the turn with the success flag,
///   total cost and the final text answer.
///
/// Anything else is mapped to `.other` so future schema additions never
/// crash the chat.
enum ClaudeStreamEvent {
    case systemInit(sessionId: String, model: String?, cwd: String?, mcpServers: [McpServerInitStatus])
    case assistant(messageId: String?, blocks: [ChatMessageBlock], usage: ChatTokenUsage?)
    case user(blocks: [ChatMessageBlock])
    case result(isError: Bool, sessionId: String?, errorMessage: String?, totalCostUSD: Double?, usage: ChatTokenUsage?)
    /// Lifecycle event for a background task (today, only `local_bash`
    /// shells via `run_in_background: true`). The `task_started`,
    /// `task_updated` and `task_notification` subtypes all decode here
    /// — see `phase` for which one. `taskId` is the same identifier
    /// Claude Code exposes through its `/bashes` UI and `KillShell`
    /// tool.
    case backgroundTask(
        phase: BackgroundTaskPhase,
        taskId: String,
        toolUseId: String?,
        taskType: String?,
        status: String?,
        exitCode: String?,
        summary: String?
    )
    case other(typeName: String)
}

enum BackgroundTaskPhase: Equatable {
    case started
    case updated
    case notification
}

/// One entry of the `mcp_servers` array carried in the `system/init`
/// event that `claude -p --output-format stream-json --verbose` emits
/// when it has finished spinning up. The exact statuses Claude Code
/// reports today are `connected`, `failed`, and `needs-auth`; we keep
/// the raw string around so the UI can colour-code any future addition
/// without code changes.
///
/// Servers the CLI rejected while validating `--mcp-config` arrive in a
/// separate `mcp_server_errors` array (Claude Code 2.1.219) and are folded
/// in here too, carrying their reason as the status (`invalid_config`,
/// `unknown_type`, …).
struct McpServerInitStatus: Equatable {
    let name: String
    let status: String
    /// Free-form error blob the CLI sometimes includes alongside a
    /// `failed` status. Nil when the server connected cleanly.
    let error: String?
}

/// Token-usage snapshot reported by claude on each `assistant` message
/// and the final `result`. The four counters mirror Anthropic's
/// `Usage` object verbatim.
struct ChatTokenUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int

    /// Sum of all four counters — what we display as "tokens consumed
    /// in this turn" / running total.
    var total: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    /// Tokens currently in claude's context window, i.e. everything in
    /// the prompt for the request in question. Excludes `output_tokens`
    /// (those are generated AFTER the prompt and don't sit in the
    /// context window for this request).
    ///
    /// Use this for "X / 200k" style chips. Note the field is only
    /// meaningful when the snapshot is per-request (assistant events);
    /// the `result` event aggregates usage across every internal
    /// round of the turn, so its `cache_read_input_tokens` happily
    /// exceeds the model's context window after a long turn.
    var contextWindowTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    static let zero = ChatTokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationInputTokens: 0,
        cacheReadInputTokens: 0
    )

    static func +(lhs: ChatTokenUsage, rhs: ChatTokenUsage) -> ChatTokenUsage {
        ChatTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    /// Decode from claude's stream-json `usage` dictionary. Missing
    /// fields fall back to 0.
    static func decode(_ dict: [String: Any]?) -> ChatTokenUsage? {
        guard let dict else { return nil }
        return ChatTokenUsage(
            inputTokens: (dict["input_tokens"] as? Int) ?? 0,
            outputTokens: (dict["output_tokens"] as? Int) ?? 0,
            cacheCreationInputTokens: (dict["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheReadInputTokens: (dict["cache_read_input_tokens"] as? Int) ?? 0
        )
    }
}

extension ClaudeStreamEvent {

    enum ParseError: Error {
        case notJSON
        case missingType
        case malformed(String)
    }

    /// Parse a single NDJSON line. Empty/whitespace lines return nil.
    static func parse(line: String) throws -> ClaudeStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            throw ParseError.notJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ParseError.notJSON
        }
        guard let dict = object as? [String: Any] else {
            throw ParseError.malformed("top level is not an object")
        }
        guard let type = dict["type"] as? String else {
            throw ParseError.missingType
        }
        switch type {
        case "system":
            return parseSystem(dict)
        case "assistant":
            return parseAssistant(dict)
        case "user":
            return parseUser(dict)
        case "result":
            return parseResult(dict)
        default:
            return .other(typeName: type)
        }
    }

    // MARK: - Type-specific parsers

    private static func parseSystem(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let subtype = dict["subtype"] as? String
        let sessionId = dict["session_id"] as? String ?? ""
        let model = dict["model"] as? String
        let cwd = dict["cwd"] as? String
        if subtype == "init" {
            var servers = parseMcpServers(dict["mcp_servers"])
            servers.append(contentsOf: parseMcpServerErrors(dict["mcp_server_errors"], alreadyListed: servers))
            return .systemInit(sessionId: sessionId, model: model, cwd: cwd, mcpServers: servers)
        }
        if subtype == "task_started" || subtype == "task_updated" || subtype == "task_notification" {
            return parseBackgroundTask(dict, subtype: subtype ?? "")
        }
        return .other(typeName: "system." + (subtype ?? "?"))
    }

    /// Decode a `task_*` system message. Shape (across the three
    /// subtypes seen in the wild):
    ///
    /// ```json
    /// {type:"system", subtype:"task_started", task_id:"…",
    ///  tool_use_id:"…", task_type:"local_bash", description:"…", …}
    /// {type:"system", subtype:"task_updated", task_id:"…",
    ///  patch:{status:"completed", end_time:…}, …}
    /// {type:"system", subtype:"task_notification", task_id:"…",
    ///  tool_use_id:"…", status:"completed",
    ///  summary:"… completed (exit code 0)", …}
    /// ```
    private static func parseBackgroundTask(_ dict: [String: Any], subtype: String) -> ClaudeStreamEvent {
        let taskId = (dict["task_id"] as? String) ?? ""
        let toolUseId = dict["tool_use_id"] as? String
        let taskType = dict["task_type"] as? String
        let phase: BackgroundTaskPhase
        var status: String?
        switch subtype {
        case "task_started":
            phase = .started
            status = "running"
        case "task_updated":
            phase = .updated
            if let patch = dict["patch"] as? [String: Any] {
                status = patch["status"] as? String
            }
        default:
            phase = .notification
            status = dict["status"] as? String
        }
        let summary = dict["summary"] as? String
        let exitCode = parseExitCode(fromSummary: summary)
        return .backgroundTask(
            phase: phase,
            taskId: taskId,
            toolUseId: toolUseId,
            taskType: taskType,
            status: status,
            exitCode: exitCode,
            summary: summary
        )
    }

    /// Pull "(exit code 0)" / "(exit code -1)" out of a task_notification
    /// summary string. Returns nil when the summary is missing or has no
    /// such fragment.
    private static func parseExitCode(fromSummary summary: String?) -> String? {
        guard let summary,
              let range = summary.range(of: #"exit\s*code\s*(-?\d+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let slice = summary[range]
        let digits = slice.unicodeScalars.filter { ("0"..."9").contains(Character($0)) || $0 == "-" }
        return digits.isEmpty ? nil : String(String.UnicodeScalarView(digits))
    }

    /// Pull the array of MCP server status entries out of a `system/init`
    /// dict. Claude Code reports `[{name, status, error?}]` today, but
    /// older builds may use slightly different keys — we accept both
    /// `error` and `message` for the failure blob.
    private static func parseMcpServers(_ raw: Any?) -> [McpServerInitStatus] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let status = (item["status"] as? String) ?? "unknown"
            let error = (item["error"] as? String) ?? (item["message"] as? String)
            return McpServerInitStatus(name: name, status: status, error: error)
        }
    }

    /// Pull the `mcp_server_errors` array out of a `system/init` dict and
    /// fold it into the same status list the panel already renders.
    ///
    /// Added in Claude Code 2.1.219: entries the CLI dropped while validating
    /// `--mcp-config` never reach `mcp_servers` at all, so before this they
    /// were invisible — a server with a typo in its config simply didn't
    /// exist as far as the panel was concerned. Verified shape against
    /// claude-code 2.1.220:
    ///
    /// ```json
    /// {"name":"broken-type", "type":"unknown_type",
    ///  "message":"Skipped — unknown MCP server type \"nonsense\" for server …"}
    /// ```
    ///
    /// `type` is reported as the status so the UI colour-codes it like any
    /// other non-`connected` state, and entries already present in
    /// `mcp_servers` are skipped so a future CLI that lists them in both
    /// places can't produce duplicate rows.
    private static func parseMcpServerErrors(
        _ raw: Any?,
        alreadyListed: [McpServerInitStatus]
    ) -> [McpServerInitStatus] {
        guard let array = raw as? [[String: Any]] else { return [] }
        let known = Set(alreadyListed.map(\.name))
        return array.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            guard !known.contains(name) else { return nil }
            let status = (item["type"] as? String) ?? "invalid-config"
            let error = (item["message"] as? String) ?? (item["error"] as? String)
            return McpServerInitStatus(name: name, status: status, error: error)
        }
    }

    private static func parseAssistant(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let message = dict["message"] as? [String: Any] ?? [:]
        let messageId = message["id"] as? String
        let contentArray = message["content"] as? [[String: Any]] ?? []
        let blocks = contentArray.compactMap { decodeContentBlock($0) }
        let usage = ChatTokenUsage.decode(message["usage"] as? [String: Any])
        return .assistant(messageId: messageId, blocks: blocks, usage: usage)
    }

    private static func parseUser(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let message = dict["message"] as? [String: Any] ?? [:]
        let contentArray = message["content"] as? [[String: Any]] ?? []
        let blocks = contentArray.compactMap { decodeContentBlock($0) }
        return .user(blocks: blocks)
    }

    private static func parseResult(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let isError = (dict["is_error"] as? Bool) ?? false
        let sessionId = dict["session_id"] as? String
        let errorMessage: String?
        if isError {
            errorMessage = (dict["error"] as? String) ?? (dict["result"] as? String)
        } else {
            errorMessage = nil
        }
        let totalCostUSD = dict["total_cost_usd"] as? Double
        let usage = ChatTokenUsage.decode(dict["usage"] as? [String: Any])
        return .result(
            isError: isError,
            sessionId: sessionId,
            errorMessage: errorMessage,
            totalCostUSD: totalCostUSD,
            usage: usage
        )
    }

    // MARK: - Content block decoding

    private static func decodeContentBlock(_ block: [String: Any]) -> ChatMessageBlock? {
        guard let type = block["type"] as? String else { return nil }
        switch type {
        case "text":
            guard let text = block["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(text)
        case "tool_use":
            let id = (block["id"] as? String) ?? ""
            let name = (block["name"] as? String) ?? "unknown"
            let inputAny = block["input"] ?? [:]
            let inputJSON = encodeJSON(inputAny)
            return .toolUse(.init(id: id, name: name, inputJSON: inputJSON))
        case "tool_result":
            let toolUseId = (block["tool_use_id"] as? String) ?? ""
            let isError = (block["is_error"] as? Bool) ?? false
            let content = stringifyToolResultContent(block["content"])
            return .toolResult(.init(toolUseId: toolUseId, content: content, isError: isError))
        default:
            return nil
        }
    }

    private static func stringifyToolResultContent(_ raw: Any?) -> String {
        if let string = raw as? String { return string }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if let type = item["type"] as? String, type == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            .joined(separator: "\n")
        }
        return encodeJSON(raw ?? "")
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            // JSONSerialization rejects scalars at top level. Wrap in an array
            // and unwrap so we still get a stable JSON string for primitives.
            if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
               let wrapped = String(data: data, encoding: .utf8),
               wrapped.hasPrefix("["), wrapped.hasSuffix("]") {
                return String(wrapped.dropFirst().dropLast())
            }
            return ""
        }
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: opts) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
