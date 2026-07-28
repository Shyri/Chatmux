import Foundation

/// Role of a chat message. Mirrors Claude Code's stream-json `type` field.
enum ChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// A single block within a message. Claude Code emits messages whose `content`
/// is an array of blocks: text, tool_use, tool_result.
enum ChatMessageBlock: Codable, Sendable, Equatable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)

    struct ToolUse: Codable, Sendable, Equatable {
        let id: String
        let name: String
        /// JSON-encoded input as a string. We deliberately keep this as a string
        /// instead of `[String: Any]` to stay Codable; the view layer pretty-prints it.
        let inputJSON: String
    }

    struct ToolResult: Codable, Sendable, Equatable {
        let toolUseId: String
        let content: String
        let isError: Bool
    }

    private enum Kind: String, Codable {
        case text
        case toolUse
        case toolResult
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case toolUse
        case toolResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(try container.decode(ToolUse.self, forKey: .toolUse))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        case .toolUse(let value):
            try container.encode(Kind.toolUse, forKey: .kind)
            try container.encode(value, forKey: .toolUse)
        case .toolResult(let value):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(value, forKey: .toolResult)
        }
    }
}

struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let role: ChatMessageRole
    var blocks: [ChatMessageBlock]
    let createdAt: Date
    /// File paths attached to this message (only set for `.user` messages
    /// the user sent with drag-and-drop). The UI renders these as inline
    /// thumbnails above the text bubble; they are not persisted as part
    /// of the text claude sees (that goes through `@<path>` mentions on
    /// the wire).
    var attachmentURLs: [URL] = []
    /// True for messages that should render with a collapsed body and
    /// a tool-card-style header — used for slash-command expansions
    /// (we send the full prompt to claude, but don't want the entire
    /// body to fill the transcript).
    var isCollapsedByDefault: Bool = false
    /// When set, the collapsed header surfaces the original slash
    /// command name (e.g. `/start-release`) instead of a generic
    /// "Slash command prompt" label, so the user can tell at a glance
    /// which command produced the expansion.
    var slashCommandName: String?
    /// The `message.id` claude reports in the stream-json. Multiple
    /// stream events sometimes carry the same id with different
    /// content blocks (claude streams a single response in chunks);
    /// we use this to coalesce them back into one ChatMessage so
    /// adjacent tool_use blocks fall into the same batch.
    var claudeMessageId: String?
    /// Reasoning effort claude ran this message at (`low`, `medium`,
    /// `high`, `xhigh`, …). Claude Code records it on every assistant
    /// line of the session transcript as of 2.1.212, so a rehydrated
    /// conversation can show the effort each answer was produced with
    /// even when the picker has since been changed. `nil` for messages
    /// from older transcripts, and for anything the user sent.
    var effort: String?

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        blocks: [ChatMessageBlock],
        attachmentURLs: [URL] = [],
        isCollapsedByDefault: Bool = false,
        slashCommandName: String? = nil,
        claudeMessageId: String? = nil,
        effort: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.attachmentURLs = attachmentURLs
        self.isCollapsedByDefault = isCollapsedByDefault
        self.slashCommandName = slashCommandName
        self.claudeMessageId = claudeMessageId
        self.effort = effort
        self.createdAt = createdAt
    }

    /// Convenience for the common single-text-block case.
    static func text(_ role: ChatMessageRole, _ text: String) -> ChatMessage {
        ChatMessage(role: role, blocks: [.text(text)])
    }

    /// First text block, joined. Used for tab title derivation and previews.
    var plainText: String {
        blocks.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }
        .joined(separator: "\n")
    }
}
