import AppKit
import Bonsplit
import CmuxSidebar
import Combine
import Foundation

/// Status of the chat conversation.
enum ChatStatus: Equatable {
    case idle
    case sending
    case error(String)
}

/// A file attached to the next user message. The file lives on disk so
/// Claude Code can read it through `@<path>` expansion (which produces
/// multimodal image blocks for image files).
struct ChatAttachment: Identifiable, Equatable {
    let id: UUID
    /// Path to the (cmux-managed) copy of the file.
    let url: URL
    /// Human-readable name shown in the preview chip.
    let displayName: String
    /// True for `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, etc.
    let isImage: Bool

    init(url: URL, displayName: String, isImage: Bool) {
        self.id = UUID()
        self.url = url
        self.displayName = displayName
        self.isImage = isImage
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tiff", "tif"
    ]

    static func isImageFile(at url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Build the user-visible text for a turn that may include attached
    /// files. Attachments are surfaced as `@<path>` mentions which Claude
    /// Code expands into multimodal content blocks (images become image
    /// blocks; other files are read as text).
    static func composeUserMessage(text: String, attachments: [ChatAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let mentions = attachments.map { "@\($0.url.path)" }.joined(separator: " ")
        if text.isEmpty {
            return mentions
        }
        return "\(mentions)\n\n\(text)"
    }
}

/// Permission modes mapped 1:1 to Claude Code's four canonical modes.
/// (Claude Code interactive uses Shift+Tab to cycle through them.)
/// Which Claude model the chat tells the CLI to use via `--model`.
/// `default` means we don't pass `--model` and let the `claude` binary
/// pick (whatever `~/.claude/settings.json` or `$ANTHROPIC_MODEL` says,
/// otherwise the CLI's hard-coded default — Sonnet 5 since Claude Code
/// 2.1.197).
///
/// The CLI bakes `--model` into argv at spawn time, but unlike
/// `--permission-mode` it can be changed afterwards: `ClaudeChatRunner`
/// tracks `launchedModel` and sends a `set_model` control request over
/// stdin when the selection differs (Claude Code 2.1.212+), keeping the
/// process and its MCP connections alive. Switching back to `default`
/// still respawns with `--resume <sessionId>`, since no control request
/// restores "whatever the CLI would have picked".
enum ChatModelSelection: String, CaseIterable, Identifiable {
    case `default`
    case fable5
    case opus5
    case opus5Long
    case opus48
    case opus48Long
    case opus
    case opusLong
    case sonnet5
    case sonnet
    case haiku

    var id: String { rawValue }

    /// The value passed to `claude --model`. `nil` means "don't pass
    /// `--model` at all" (the `default` case).
    ///
    /// Fable 5 is Anthropic's Mythos-class flagship. Per the Claude Code
    /// docs (`code.claude.com/docs/en/model-config`) the Anthropic API
    /// always runs `claude-fable-5` with the 1M context window, so there
    /// is no separate `[1m]` variant the way Opus 4.7/4.8 have. Requires
    /// Claude Code v2.1.170+ at runtime.
    ///
    /// Opus 5 became the default Opus in Claude Code 2.1.219 and keeps the
    /// `[1m]` long-context variant. Sonnet 5 (2.1.197) is the CLI's default
    /// model and is natively 1M, so like Fable 5 it has no `[1m]` twin.
    var claudeFlag: String? {
        switch self {
        case .default: return nil
        case .fable5: return "claude-fable-5"
        case .opus5: return "claude-opus-5"
        case .opus5Long: return "claude-opus-5[1m]"
        case .opus48: return "claude-opus-4-8"
        case .opus48Long: return "claude-opus-4-8[1m]"
        case .opus: return "claude-opus-4-7"
        case .opusLong: return "claude-opus-4-7[1m]"
        case .sonnet5: return "claude-sonnet-5"
        case .sonnet: return "claude-sonnet-4-6"
        case .haiku: return "claude-haiku-4-5"
        }
    }

    var label: String {
        switch self {
        case .default:
            return String(localized: "claudeChat.model.default", defaultValue: "Default")
        case .fable5:
            return String(localized: "claudeChat.model.fable5", defaultValue: "Fable 5")
        case .opus5:
            return String(localized: "claudeChat.model.opus5", defaultValue: "Opus 5")
        case .opus5Long:
            return String(localized: "claudeChat.model.opus5Long", defaultValue: "Opus 5 (1M)")
        case .opus48:
            return String(localized: "claudeChat.model.opus48", defaultValue: "Opus 4.8")
        case .opus48Long:
            return String(localized: "claudeChat.model.opus48Long", defaultValue: "Opus 4.8 (1M)")
        case .opus:
            return String(localized: "claudeChat.model.opus", defaultValue: "Opus 4.7")
        case .opusLong:
            return String(localized: "claudeChat.model.opusLong", defaultValue: "Opus 4.7 (1M)")
        case .sonnet5:
            return String(localized: "claudeChat.model.sonnet5", defaultValue: "Sonnet 5")
        case .sonnet:
            return String(localized: "claudeChat.model.sonnet", defaultValue: "Sonnet 4.6")
        case .haiku:
            return String(localized: "claudeChat.model.haiku", defaultValue: "Haiku 4.5")
        }
    }

    var iconName: String {
        switch self {
        case .default: return "wand.and.stars"
        case .fable5: return "crown.fill"
        case .opus5, .opus48, .opus: return "sparkles"
        case .opus5Long, .opus48Long, .opusLong: return "infinity"
        case .sonnet5, .sonnet: return "circle.hexagongrid"
        case .haiku: return "leaf"
        }
    }
}

/// Thinking effort the chat passes to the CLI via `--effort <level>`.
/// `default` means we don't pass `--effort`, letting the binary fall
/// back to its own default (typically `medium`).
///
/// Just like `--permission-mode` and `--model`, `--effort` is baked into
/// argv at spawn time — `ClaudeChatRunner` tracks `launchedEffort` and
/// respawns with `--resume <sessionId>` when the selection changes.
enum ChatThinkingEffort: String, CaseIterable, Identifiable {
    case `default`
    case low
    case medium
    case high
    case xhigh
    case max

    /// What `default` resolves to when the user has not picked an explicit
    /// `--effort` flag. Precedence mirrors the CLI:
    ///   1. `~/.claude/settings.json` → `effortLevel`
    ///   2. CLI built-in (Claude Code 2.1+ defaults to `high`)
    /// `nil` here means we couldn't read settings.json so we surface the
    /// CLI built-in as a fallback in the UI.
    static func resolveCLIDefault() -> ChatThinkingEffort? {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        return resolveCLIDefault(settingsURL: url)
    }

    /// Same as `resolveCLIDefault()` but takes an explicit settings.json URL
    /// so tests (and callers that read non-default locations) can drive it
    /// without depending on `$HOME`.
    static func resolveCLIDefault(settingsURL: URL) -> ChatThinkingEffort? {
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = parseEffortLevel(from: data),
           parsed != .default {
            return parsed
        }
        // Recent claude releases ship with a built-in default of `high`
        // (see the binary string "Now defaults to high effort").
        return .high
    }

    /// Decode `effortLevel` out of `settings.json` bytes. Returns `nil` when
    /// the file is not JSON, the top-level is not a dictionary, the field
    /// is absent, or the value is not a known `ChatThinkingEffort` raw value.
    static func parseEffortLevel(from data: Data) -> ChatThinkingEffort? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["effortLevel"] as? String
        else { return nil }
        return ChatThinkingEffort(rawValue: raw)
    }

    var id: String { rawValue }

    /// The value passed to `claude --effort`. `nil` means "don't pass
    /// `--effort` at all" (the `default` case).
    var claudeFlag: String? {
        switch self {
        case .default: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        }
    }

    var label: String {
        switch self {
        case .default:
            return String(localized: "claudeChat.thinking.default", defaultValue: "Default")
        case .low:
            return String(localized: "claudeChat.thinking.low", defaultValue: "Low")
        case .medium:
            return String(localized: "claudeChat.thinking.medium", defaultValue: "Medium")
        case .high:
            return String(localized: "claudeChat.thinking.high", defaultValue: "High")
        case .xhigh:
            return String(localized: "claudeChat.thinking.xhigh", defaultValue: "Extra")
        case .max:
            return String(localized: "claudeChat.thinking.max", defaultValue: "Max")
        }
    }

    /// Label shown on the collapsed picker button (vs. the static `label`
    /// used for the menu items themselves). For `.default` we append the
    /// resolved fall-through value in parentheses so the user always
    /// sees the effort that's actually in play — even when they haven't
    /// pinned an explicit `--effort`. e.g. `Default (xhigh)`.
    func activeLabel(resolvedDefault: ChatThinkingEffort?) -> String {
        guard self == .default, let resolved = resolvedDefault else {
            return label
        }
        return "\(label) (\(resolved.label))"
    }

    var iconName: String {
        switch self {
        case .default: return "brain"
        case .low: return "tortoise"
        case .medium: return "brain.head.profile"
        case .high: return "bolt"
        case .xhigh: return "bolt.fill"
        case .max: return "flame.fill"
        }
    }
}

enum ChatPermissionMode: String, CaseIterable, Identifiable {
    /// `--permission-mode plan`. Claude can read and reason but cannot
    /// modify the workspace (no Edit/Write/Bash side effects).
    case plan
    /// `--permission-mode default` + our `--permission-prompt-tool`. Claude
    /// asks before every tool use; the inline Allow/Deny card appears in
    /// the chat. Equivalent of Claude Code's "Normal" mode.
    case normal
    /// `--permission-mode acceptEdits` + our `--permission-prompt-tool`.
    /// File edits (Edit/Write/NotebookEdit) auto-allow; everything else
    /// (Bash, etc.) still surfaces an Allow/Deny card.
    case acceptEdits
    /// `--permission-mode bypassPermissions`. All tools auto-execute; no
    /// approval card surfaces. Mirrors Claude Code 2.x's "Auto mode" —
    /// the panel also auto-resolves any in-flight approvals as soon as
    /// the user flips the picker into this mode, so it takes effect
    /// without waiting for the next turn.
    case auto

    var id: String { rawValue }

    var claudeFlag: String {
        switch self {
        case .plan: return "plan"
        case .normal: return "default"
        case .acceptEdits: return "acceptEdits"
        case .auto: return "bypassPermissions"
        }
    }

    /// Whether this mode wants `--permission-prompt-tool` wired so non-
    /// auto-allowed tools get an inline Allow/Deny card.
    var usesPermissionPromptTool: Bool {
        switch self {
        case .normal, .acceptEdits: return true
        case .plan, .auto: return false
        }
    }

    var label: String {
        switch self {
        case .plan:
            return String(localized: "claudeChat.mode.plan", defaultValue: "Plan")
        case .normal:
            return String(localized: "claudeChat.mode.normal", defaultValue: "Normal")
        case .acceptEdits:
            return String(localized: "claudeChat.mode.acceptEdits", defaultValue: "Auto-edits")
        case .auto:
            return String(localized: "claudeChat.mode.auto", defaultValue: "Auto")
        }
    }

    var iconName: String {
        switch self {
        case .plan: return "list.bullet.rectangle"
        case .normal: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .auto: return "bolt.fill"
        }
    }
}

/// Decides whether an incoming MCP approval request from claude is a
/// duplicate of one we already surfaced (claude re-fires the same tool_use
/// with a fresh `tool_use_id` after a retry / re-render), in which case
/// the panel should attach the new resolver as an alias of the existing
/// card instead of showing a second Allow/Deny prompt.
///
/// Pure logic, extracted from `ClaudeChatPanel.server(_:didReceiveApproval:)`
/// so it can be unit-tested without booting the whole MainActor panel.
enum ChatApprovalDedupePolicy {
    /// A row from the pending-approvals queue, narrowed to just the fields
    /// dedup looks at (id + the (toolName, inputJSON) match key).
    struct PendingApprovalKey: Equatable {
        let id: String
        let toolName: String
        let inputJSON: String
    }

    enum Decision: Equatable {
        /// No pending card matches; surface as a new primary card.
        case newPrimary
        /// A pending card already matches; attach as an alias whose
        /// resolver drains when the user resolves `primaryID`.
        case followsExisting(primaryID: String)
    }

    static func decide(
        incomingToolName: String,
        incomingInputJSON: String,
        pendingApprovals: [PendingApprovalKey]
    ) -> Decision {
        if let existing = pendingApprovals.first(where: {
            $0.toolName == incomingToolName && $0.inputJSON == incomingInputJSON
        }) {
            return .followsExisting(primaryID: existing.id)
        }
        return .newPrimary
    }
}

/// A panel that renders a conversation with Claude Code. The MVP fase 1 does
/// not yet wire up the subprocess or the MCP approval helper — it stands up
/// the panel, the SwiftUI view, and a mock transcript so the rest of the
/// integration (menu, persistence, focus, layout) can be exercised first.
@MainActor
final class ClaudeChatPanel: Panel, ObservableObject, ChatMcpHttpServerDelegate {
    let id: UUID
    let panelType: PanelType = .claudeChat
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Working directory the UI shows in the header and that drives the
    /// git probe + permission-rules lookup. Mutates with `EnterWorktree`
    /// or `mcp__cmux__set_cwd` so the chip and path reflect where Claude
    /// is logically working right now.
    @Published private(set) var workingDirectory: String

    /// Immutable `cwd` the `claude` process was launched in. Claude Code
    /// stores resumable sessions under `~/.claude/projects/<encoded-cwd>/`
    /// keyed by the cwd at creation, so respawn/--resume must always use
    /// this path — even after `EnterWorktree` moved the effective cwd
    /// elsewhere. Persisted across app restarts via `SessionPersistence`
    /// so resume keeps finding the session.
    let sessionCwd: String

    /// Current git branch of `workingDirectory`, mirrored from
    /// `Workspace.panelGitBranches[id]` so the chat header can render it
    /// without depending on `Workspace` directly. `nil` when the working
    /// directory is not inside a git repo or the probe has not run yet.
    /// El refresh del summary detallado se dispara desde
    /// `updateGitBranchState`, no desde aquí: el workspace probe completa en
    /// cada evento del FS watcher aunque la tupla `(branch, isDirty)` no
    /// cambie, y queremos recomputar ahead/behind/staged/modified/untracked/
    /// stash en cada uno.
    @Published private(set) var gitBranchState: SidebarGitBranchState?

    /// Resumen de cambios git pendientes sobre `workingDirectory`:
    /// commits ahead/behind del upstream, ficheros staged/modified/
    /// untracked y stashes locales. Se refresca cuando cambia el branch
    /// state o el working directory, ejecutando `git` off-main.
    @Published private(set) var gitPendingSummary: GitPendingSummary?

    /// Task de debounce para `refreshGitPendingSummary`. Se cancela y
    /// reasigna en cada llamada para coalesce ráfagas (`npm install`, build,
    /// edición masiva por agente) en una única ejecución de `git status` al
    /// terminar la quietud.
    private var gitPendingSummaryRefreshTask: Task<Void, Never>?

    /// Chat transcript. Fase 1 ships with a small mock transcript; fase 2
    /// will replace this with live events from `ClaudeChatRunner`.
    ///
    /// `didSet` keeps `visibleMessageWindow` aligned with the new array
    /// size: when the conversation grows (append/streaming), the window
    /// grows by the same amount so the first visible message stays the
    /// same (no "old messages slipping off the top" effect for a user
    /// scrolled mid-transcript). When the conversation shrinks (rewind /
    /// clear), the window clamps down so we don't render past the end.
    @Published private(set) var messages: [ChatMessage] {
        didSet {
            let delta = messages.count - oldValue.count
            if delta > 0 {
                visibleMessageWindow += delta
            } else if delta < 0 {
                visibleMessageWindow = max(0, min(visibleMessageWindow, messages.count))
            }
        }
    }

    /// How many trailing messages the view layer should render. The chat
    /// transcript keeps every turn in memory, but rendering every message
    /// as eager SwiftUI rows (Markdown, syntax highlighting, tool cards)
    /// makes the whole panel sluggish once a conversation grows. We cap
    /// the visible window to the tail of the transcript and expose a
    /// "load older" affordance for the rest.
    @Published private(set) var visibleMessageWindow: Int = ClaudeChatPanel.defaultVisibleMessageWindow

    /// Initial window size when a panel is first created or `clearTranscript`
    /// runs. Picked to comfortably cover typical conversations while still
    /// keeping the SwiftUI tree small. Note: a single multi-tool turn can
    /// produce 4-6 ChatMessage instances on the assistant side (stream-json
    /// splits responses across events), so 60 covers roughly 8-10 turns.
    static let defaultVisibleMessageWindow: Int = 60

    /// How many additional older messages each "load older" click reveals.
    static let visibleMessageWindowStep: Int = 60

    /// Session id emitted by Claude on the first `system/init` event of a
    /// conversation. Required for `--resume` on subsequent turns.
    @Published private(set) var sessionId: String?

    /// Active model name, sourced from `system/init`. Displayed as a chip
    /// in the chat header so the user can tell which Claude variant they
    /// are talking to.
    @Published private(set) var modelName: String?

    /// Every slash command the CLI says it recognises, from the last
    /// `system/init`. Merged into the autocomplete list on top of the
    /// `.claude/commands/` scan, which cannot see skills, plugin commands
    /// or the CLI's own built-ins (`/compact`, `/context`, `/usage`).
    /// Empty until the first process has started.
    @Published private(set) var cliSlashCommands: [String] = []

    /// Stdout of the user's `statusLine.command` (project or user
    /// settings). `nil` when the user hasn't configured a status line
    /// or the command failed; refreshed after every turn.
    @Published private(set) var statusLineText: String?

    /// Conversation status drives input affordances (send/cancel/error banner).
    @Published private(set) var status: ChatStatus = .idle

    /// Set when the user explicitly stops the current turn (the stop
    /// button → `cancel()`). The graceful interrupt makes the CLI abort the
    /// turn and emit a `result` with `is_error: true` (terminal_reason
    /// "aborted_streaming") while keeping the process alive — so this flag
    /// lets `handle(event:)` treat that error as the expected stop instead
    /// of surfacing a Claude error banner. It also covers the SIGINT
    /// fallback path (process exits non-zero) in `handle(processExit:)`.
    /// Stays set until the next turn is dispatched so both arrival orders
    /// are covered.
    private var pendingCancel = false

    /// In-progress message the user is composing. Lives on the panel
    /// (rather than as `@State` on the view) so it survives workspace
    /// switches and other moments when SwiftUI tears down and rebuilds
    /// the view tree — without this the user loses everything they
    /// typed every time they peek at another workspace.
    @Published var draft: String = ""

    /// Tool-use requests waiting for the user to allow/deny.
    @Published var pendingApprovals: [ChatApprovalRequest] = []

    /// User-question prompts (ask_user_question) waiting for an answer.
    @Published var pendingQuestions: [ChatUserQuestionRequest] = []

    /// Tool results indexed by their `tool_use_id`. The transcript view
    /// looks up the result for each `tool_use` block from this map and
    /// renders both inside one collapsible row, instead of showing the
    /// command and its output as separate sibling rows.
    @Published private(set) var toolResultsByToolUseId: [String: ChatMessageBlock.ToolResult] = [:]

    /// Resolvers waiting for the panel to call them with the user's reply.
    /// Keyed by request id.
    private var approvalResolvers: [String: (ChatApprovalResponse) -> Void] = [:]
    private var questionResolvers: [String: (ChatUserQuestionResponse) -> Void] = [:]
    /// Maps the `id` of a primary pending question to the ids of any
    /// later questions claude fired with identical content. We keep the
    /// resolvers alive so we can answer claude's duplicate `tool_use`
    /// calls with the same answer when the user replies once — without
    /// surfacing the duplicate in the UI. (Claude occasionally re-issues
    /// `mcp__cmux__ask_user_question` mid-turn before the first call has
    /// returned, producing the "duplicate question" the user sees.)
    private var questionDedupeAliases: [String: [String]] = [:]
    /// Same idea for `approval_prompt`: claude can re-fire the same tool
    /// approval with a fresh `tool_use_id` while the first card is still
    /// pending (resume races, stream-json retries, model emitting two
    /// `tool_use` blocks for the same call). Track the followers so when
    /// the user clicks Allow/Deny on the primary card, we drain every
    /// aliased resolver with the same response — no duplicate card
    /// surfaces in the UI.
    private var approvalDedupeAliases: [String: [String]] = [:]

    /// Tools the user marked "Allow always" within this chat. Future
    /// approval requests for these tools auto-allow without surfacing the
    /// card. Cleared on `clearTranscript()`. In-memory only (phase 4 will
    /// persist this alongside the session).
    @Published private(set) var alwaysAllowedTools: Set<String> = []

    /// Pending file attachments that will be referenced in the next user
    /// turn. Files are copied into the panel's temp dir and surfaced to
    /// claude via `@<path>` mentions, which Claude Code expands into
    /// multimodal content blocks.
    @Published private(set) var pendingAttachments: [ChatAttachment] = []

    /// Edits (Edit/MultiEdit/Write/NotebookEdit tool_use blocks) emitted
    /// during the current — or just-finished — turn. Cleared when the user
    /// sends a new message so the side pane always reflects "what claude
    /// did since I last spoke."
    @Published private(set) var lastTurnEdits: [TurnEdit] = []

    /// Whether the right-hand "this turn's edits" side pane is currently
    /// open. Lives on the panel (not on the view) so the user's open/close
    /// choice survives view re-instantiation. SwiftUI rebuilds
    /// `ClaudeChatPanelView` whenever its identity changes (workspace
    /// switching, bonsplit tab churn, …) and a `@State` here would reset
    /// to its default and lose the user's last action.
    @Published var diffPaneOpen: Bool = false

    /// True once this panel session has auto-opened the diff pane for the
    /// first edit-producing turn. Sticky for the rest of the session: even
    /// if the user closes the pane and a later turn produces more edits,
    /// we do not re-auto-open it. Reset only on `clearTranscript()`
    /// (treated as a brand-new session). Same rationale as `diffPaneOpen`
    /// — must live on the panel so view re-creation doesn't drop the
    /// memo and trigger a phantom re-open.
    @Published var hasAutoOpenedDiffPaneThisSession: Bool = false

    /// Stack of rewind checkpoints, one per finished turn (oldest first).
    /// The view layer reads this to expose a "↶" button next to every
    /// user message. Each checkpoint anchors itself to the user message
    /// that started the turn so the user can rewind to *just before
    /// claude replied to this prompt*.
    @Published private(set) var undoCheckpoints: [RewindCheckpoint] = []

    /// Drafts the user submitted while the previous turn was still in
    /// flight. Each entry carries the runner-bound text (with attachment
    /// `@<path>` expansion) and the chat-message id that already appears
    /// in the transcript (rendered as a "queued" bubble). Drained
    /// first-in-first-out as soon as the `result` event transitions
    /// the status back to `.idle`. Survives Stop so cancelling the
    /// current turn does not silently throw away queued follow-ups.
    @Published private(set) var pendingDrafts: [PendingDraft] = []

    struct PendingDraft: Identifiable, Equatable {
        /// Same UUID as the transcript ChatMessage so the view layer can
        /// match them up and render the queued state on the right bubble.
        let id: UUID
        let userText: String
        let attachmentURLs: [URL]
    }

    /// Latest todo list emitted by Claude's `TodoWrite` (Claude Code 1.x)
    /// or the cumulative state of per-task `TaskCreate`/`TaskUpdate`
    /// calls (Claude Code 2.x). `TodoWrite` carries the full list each
    /// time so we replace `currentTodos` outright; the per-task tools
    /// only carry one task at a time, so we accumulate them into
    /// `taskRegistryById` and rederive `currentTodos` after every
    /// mutation. `nil` until Claude calls either family at least once.
    @Published private(set) var currentTodos: [TodoItem]?

    struct TodoItem: Equatable, Identifiable {
        let id: Int
        let content: String
        let activeForm: String?
        /// Raw status string ("pending" / "in_progress" / "completed").
        let status: String
    }

    /// Cumulative task state for Claude Code 2.x `TaskCreate`/`TaskUpdate`.
    /// Keyed by the integer id the tool_result reports
    /// (`Task #<id> created successfully: …`).
    private var taskRegistryById: [Int: TodoItem] = [:]

    /// Pending `TaskCreate` calls waiting for their tool_result to land
    /// so we can learn the real id assigned by the harness. Keyed by
    /// the assistant `tool_use.id` so we can match by id when the
    /// matching `tool_result` arrives.
    private var pendingTaskCreates: [String: PendingTaskCreate] = [:]

    private struct PendingTaskCreate {
        let subject: String
        let activeForm: String?
    }

    /// Pending `EnterWorktree` calls whose target path we extracted from
    /// the tool_use. When the matching tool_result lands without error
    /// we mirror the new cwd into `workingDirectory` so the header and
    /// git-branch chip follow Claude into the new worktree. Keyed by
    /// `tool_use.id`.
    private var pendingEnterWorktreeByToolUseId: [String: String] = [:]

    struct RewindCheckpoint: Identifiable, Equatable {
        let id: UUID
        let userMessageId: UUID
        let userMessageIndex: Int
        let backupPaths: [String]
        /// Internal handle used to actually restore. Equatable wraps the
        /// session id + paths only; backup URLs are not part of identity.
        fileprivate let backups: ClaudeSessionHistory.TurnFileBackups?

        init(
            userMessageId: UUID,
            userMessageIndex: Int,
            backups: ClaudeSessionHistory.TurnFileBackups?
        ) {
            self.id = UUID()
            self.userMessageId = userMessageId
            self.userMessageIndex = userMessageIndex
            self.backupPaths = backups?.backups.keys.sorted() ?? []
            self.backups = backups
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.userMessageId == rhs.userMessageId
                && lhs.userMessageIndex == rhs.userMessageIndex
                && lhs.backupPaths == rhs.backupPaths
        }
    }

    struct TurnEdit: Identifiable, Equatable {
        let id: UUID
        let toolName: String
        let inputJSON: String

        init(toolName: String, inputJSON: String) {
            self.id = UUID()
            self.toolName = toolName
            self.inputJSON = inputJSON
        }
    }

    private static let editToolNames: Set<String> = [
        "Edit", "MultiEdit", "Write", "NotebookEdit"
    ]

    /// Parse the JSON-encoded input of a `TodoWrite` tool call into the
    /// typed `TodoItem` list the banner consumes. Returns `nil` if the
    /// payload is malformed; callers leave the previous list intact when
    /// that happens.
    fileprivate static func parseTodos(fromInputJSON inputJSON: String) -> [TodoItem]? {
        guard
            let data = inputJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawTodos = obj["todos"] as? [[String: Any]]
        else { return nil }
        return rawTodos.enumerated().map { idx, raw in
            TodoItem(
                id: idx,
                content: (raw["content"] as? String) ?? "",
                activeForm: raw["activeForm"] as? String,
                status: (raw["status"] as? String) ?? "pending"
            )
        }
    }

    /// Parse the JSON-encoded input of a Claude Code 2.x `TaskCreate`
    /// tool call into a pending entry, waiting on the matching
    /// `tool_result` to learn the real task id. Returns `nil` for
    /// payloads without a usable subject.
    private static func parsePendingTaskCreate(
        fromInputJSON inputJSON: String
    ) -> PendingTaskCreate? {
        guard
            let data = inputJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let subject = (obj["subject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !subject.isEmpty else { return nil }
        let activeForm = (obj["activeForm"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PendingTaskCreate(
            subject: subject,
            activeForm: (activeForm?.isEmpty == false) ? activeForm : nil
        )
    }

    /// Extract the absolute `path` argument out of an `EnterWorktree`
    /// tool_use payload. The CLI ships paths as a plain string in the
    /// compact JSON we get from the stream (`{"path":"/abs/path"}`).
    /// Returns nil for any other shape or when the path is empty/blank.
    private static func parseEnterWorktreePath(
        fromInputJSON inputJSON: String
    ) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = dict["path"] as? String
        else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extract the task id the harness assigned out of the standard
    /// `Task #<id> created successfully: …` tool_result body. Returns
    /// nil for any other shape.
    private static func parseTaskCreateResultId(
        fromContent content: String
    ) -> Int? {
        // Cheap regex: capture digits after "Task #".
        guard let range = content.range(
            of: #"Task #(\d+) created"#,
            options: .regularExpression
        ) else { return nil }
        let match = content[range]
        guard let hashIdx = match.firstIndex(of: "#") else { return nil }
        let digits = match[match.index(after: hashIdx)...]
            .prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// Parse a Claude Code 2.x `TaskUpdate` payload into the fields
    /// the banner cares about (id, status, optional subject/activeForm
    /// overrides). Returns nil if the payload doesn't carry a numeric
    /// `taskId`.
    private struct ParsedTaskUpdate {
        let taskId: Int
        let status: String?
        let subject: String?
        let activeForm: String?
    }

    private static func parseTaskUpdate(
        fromInputJSON inputJSON: String
    ) -> ParsedTaskUpdate? {
        guard
            let data = inputJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let rawId = obj["taskId"]
        let taskId: Int?
        if let int = rawId as? Int {
            taskId = int
        } else if let str = rawId as? String, let parsed = Int(str) {
            taskId = parsed
        } else {
            taskId = nil
        }
        guard let taskId else { return nil }
        let status = (obj["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (obj["subject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activeForm = (obj["activeForm"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTaskUpdate(
            taskId: taskId,
            status: (status?.isEmpty == false) ? status : nil,
            subject: (subject?.isEmpty == false) ? subject : nil,
            activeForm: (activeForm?.isEmpty == false) ? activeForm : nil
        )
    }

    /// Project `taskRegistryById` (id → TodoItem) into the
    /// id-ordered list the banner consumes. The `deleted` status is
    /// filtered out — Claude Code 2.x exposes it as a real terminal
    /// state but the banner only shows live work.
    private func rebuildTodosFromRegistry() {
        let live = taskRegistryById
            .values
            .filter { $0.status != "deleted" }
            .sorted(by: { $0.id < $1.id })
        currentTodos = live.isEmpty ? nil : live
    }

    /// Pre-staged turn anchor: the id and index of the user message that
    /// started the in-flight turn. Filled in `send()` and consumed in
    /// `handle(.result)` once we know which file backups claude wrote.
    private var pendingTurnStaging: (userMessageId: UUID, userMessageIndex: Int)?

    /// Buffer of assistant/user messages parsed from the streaming
    /// claude output but not yet visible to SwiftUI. Drained into
    /// `@Published var messages` in batched flushes (`streamedFlushInterval`)
    /// so the chat view doesn't re-evaluate its body — and the streaming
    /// assistant bubble's `Markdown` widget doesn't re-parse the
    /// ever-growing text — once per NDJSON event. Always touched on the
    /// main actor (same as the stream handler).
    private var streamedMessageBuffer: [ChatMessage] = []
    private var streamedFlushScheduled = false
    /// 400 ms ≈ 2.5 Hz visible-update cadence. Picked so the in-progress
    /// assistant bubble re-parses its Markdown roughly once per 2–3
    /// visible lines instead of once per token — the user has explicitly
    /// opted into chunkier streaming in exchange for the CPU savings on
    /// long replies. Tweakable; sub-100 ms returns to a token-paced feel,
    /// >1 s starts to feel laggy.
    private static let streamedFlushInterval: TimeInterval = 0.400

    /// Buffer of tool_result blocks parsed off the stream but not yet
    /// pushed to `toolResultsByToolUseId`. A turn with many tool calls
    /// otherwise publishes one @Published mutation per tool_result,
    /// invalidating the chat body repeatedly even though SwiftUI just
    /// needs to see the final dict at the end of the turn (or at a
    /// human-perceptible cadence). Shares the streamed-message flush
    /// timer so both buffers drain in the same main-actor hop.
    private var pendingToolResultsBuffer: [String: ChatMessageBlock.ToolResult] = [:]

    /// Cached rules from `.claude/settings*.json`. Reloaded on every
    /// approval request so changes to the file are picked up live.
    private var cachedRulesCwd: String?
    private var cachedRulesMtimes: [String: Date] = [:]
    private var cachedRules: ChatPermissionRules = .empty

    /// HTTP MCP server for inline allow/deny + ask-user-question. Created on
    /// demand (first turn that runs in `.allowDeny` mode) and reused for the
    /// life of the panel.
    private var mcpServer: ChatMcpHttpServer?
    private var mcpConfigPath: String?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Token bumped to ask the chat input view to claim first-responder.
    /// Driven by `focus()` (called by bonsplit when the pane becomes
    /// active) and by attachment drops, so keystrokes always land in the
    /// chat — not in a sibling terminal pane.
    @Published private(set) var inputFocusRequestToken: Int = 0

    /// Bumped whenever an `ExitPlanMode` tool_use arrives. The view uses
    /// it to re-assert composer focus AFTER SwiftUI has mounted the
    /// plan-approval card — the card's `.borderedProminent`
    /// "Auto-accept edits" button otherwise steals first-responder on
    /// macOS as soon as it appears, yanking focus away from the user
    /// who's typing their follow-up. Distinct from the generic
    /// `inputFocusRequestToken` so we can dispatch the re-focus async
    /// (one runloop later) only for this specific case.
    @Published private(set) var exitPlanModePresentedToken: Int = 0

    /// User-overridable title (e.g. via tab "Rename"). When nil we derive
    /// the title from the first user message.
    @Published private(set) var customTitleOverride: String?

    /// Permission mode used for the next turn. Persists across turns within
    /// the same panel; the UI exposes a 4-way picker in the input bar.
    /// When the user flips the picker into `.auto` mid-turn, the panel
    /// blanket-allows every approval still waiting in the chat — claude
    /// `-p` cannot change its `--permission-mode` after launch, so the
    /// panel applies the new policy itself by short-circuiting the
    /// approval pipeline.
    /// Model selection for the next turn. Persisted globally via
    /// `UserDefaults` so the same choice applies the next time the user
    /// opens a fresh chat. `claude -p` bakes `--model` into argv at spawn
    /// time, so changing this mid-session triggers a runner respawn (the
    /// `--resume <sessionId>` flag keeps the conversation intact).
    @Published var modelSelection: ChatModelSelection {
        didSet {
            UserDefaults.standard.set(modelSelection.rawValue, forKey: Self.modelSelectionDefaultsKey)
        }
    }

    private static let modelSelectionDefaultsKey = "cmux.claudeChat.modelSelection"

    static func loadInitialModelSelection() -> ChatModelSelection {
        let raw = UserDefaults.standard.string(forKey: modelSelectionDefaultsKey) ?? ""
        return ChatModelSelection(rawValue: raw) ?? .default
    }

    /// Thinking effort for the next turn. Persisted globally via
    /// `UserDefaults`. Same lifecycle as `modelSelection`: changing
    /// mid-session triggers a runner respawn because `--effort` bakes
    /// into argv at spawn time.
    @Published var thinkingEffort: ChatThinkingEffort {
        didSet {
            UserDefaults.standard.set(thinkingEffort.rawValue, forKey: Self.thinkingEffortDefaultsKey)
        }
    }

    private static let thinkingEffortDefaultsKey = "cmux.claudeChat.thinkingEffort"

    static func loadInitialThinkingEffort() -> ChatThinkingEffort {
        let raw = UserDefaults.standard.string(forKey: thinkingEffortDefaultsKey) ?? ""
        return ChatThinkingEffort(rawValue: raw) ?? .default
    }

    /// The effort level the CLI will fall back to when the user has not
    /// pinned an explicit `--effort` value. Resolved from
    /// `~/.claude/settings.json → effortLevel`, with a Claude Code 2.1+
    /// built-in of `high` as a backup. The composer's tooltip displays
    /// this so picking "Default" doesn't feel like a black box.
    @Published private(set) var resolvedCLIDefaultEffort: ChatThinkingEffort? =
        ChatThinkingEffort.resolveCLIDefault()

    @Published var permissionMode: ChatPermissionMode = .normal {
        didSet {
            guard permissionMode == .auto else { return }
            // Defer the flush so we don't mutate other @Published
            // properties (`pendingApprovals`) inside this @Published's
            // didSet — Swift's exclusive-access checker treats that as
            // a reentrant write and aborts the process.
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingApprovalsAsAutoAllow()
            }
        }
    }

    /// Resolve every approval still waiting and clear the UI list,
    /// mirroring what Claude Code does when you flip into Auto mode.
    /// Made nonprivate so it can be called from the deferred dispatch
    /// in the `permissionMode` didSet.
    private func flushPendingApprovalsAsAutoAllow() {
        guard !pendingApprovals.isEmpty else { return }
        let snapshot = pendingApprovals
        pendingApprovals.removeAll()
        let aliasesSnapshot = approvalDedupeAliases
        approvalDedupeAliases.removeAll()
        for request in snapshot {
            if let resolver = approvalResolvers.removeValue(forKey: request.id) {
                resolver(.allow)
            }
            for aliasId in aliasesSnapshot[request.id] ?? [] {
                if let aliasResolver = approvalResolvers.removeValue(forKey: aliasId) {
                    aliasResolver(.allow)
                }
            }
        }
    }

    /// Most recent MCP server status snapshot from the running `claude`
    /// process. Keyed by server name (as it appears in `--mcp-config`,
    /// i.e. the keys of `mcpServers`). Repopulated on every `system/init`
    /// event, which fires after a fresh spawn and after `--mcp-config`
    /// changes that required a respawn.
    @Published private(set) var mcpRuntimeStatus: [String: McpServerInitStatus] = [:] {
        didSet {
            var connected = 0
            var failed = 0
            for value in mcpRuntimeStatus.values {
                let lowered = value.status.lowercased()
                if lowered == "connected" {
                    connected &+= 1
                } else if lowered == "failed" || lowered == "error" {
                    failed &+= 1
                }
            }
            if mcpConnectedCount != connected { mcpConnectedCount = connected }
            if mcpFailedCount != failed { mcpFailedCount = failed }
        }
    }

    /// Pre-computed counts driven by `mcpRuntimeStatus` so the chat
    /// header's badges read a cheap property instead of re-running a
    /// `.filter` over the dict on every body evaluation. The counts
    /// only change when the snapshot changes — not when unrelated
    /// `@Published` properties on the panel fire.
    @Published private(set) var mcpConnectedCount: Int = 0
    @Published private(set) var mcpFailedCount: Int = 0

    /// Same idea for the background-shells badge: keep the live count
    /// outside `body` so window-focus re-renders don't pay the linear
    /// scan over `backgroundShells`.
    @Published private(set) var backgroundShellLiveCount: Int = 0

    /// Bash shells that claude launched with `run_in_background: true`,
    /// surfaced here so the user can see what is alive and kill it from
    /// the chat header. Updated by `handle(event:)`:
    ///   * a `Bash` `tool_use` with `run_in_background: true` appends a
    ///     row (status `unknown` until the matching `tool_result` lands)
    ///   * the `tool_result` carries the `shell_id` string and the
    ///     initial status (we set running)
    ///   * a `KillShell` `tool_use` and its result move the targeted row
    ///     to `.killed`
    /// Output is intentionally NOT cached here — the user said they only
    /// want to see and kill them, not view what each shell is doing.
    /// Body font size of the chat transcript, in points. Adjusted by
    /// Cmd-+/Cmd-- (zoomIn/zoomOut) on the focused chat panel; the value is
    /// persisted as the default so it's remembered across panels/sessions.
    @Published private(set) var fontSize: Double = ChatFontSizeSettings.resolvedDefault()

    @Published private(set) var backgroundShells: [BackgroundShell] = [] {
        didSet {
            var live = 0
            for shell in backgroundShells {
                switch shell.status {
                case .starting, .running, .unknown: live &+= 1
                case .completed, .killed: break
                }
            }
            if backgroundShellLiveCount != live { backgroundShellLiveCount = live }
        }
    }

    struct BackgroundShell: Identifiable, Equatable {
        /// Tool-use id of the originating `Bash` call. Used to pair the
        /// row with its later `tool_result` (which carries the
        /// `shell_id` the rest of the workflow uses).
        let toolUseId: String
        /// Shell id assigned by `claude` once the bash actually starts.
        /// Nil between the `Bash` tool_use landing and the matching
        /// `tool_result`.
        var shellId: String?
        /// The command claude requested, truncated to keep the row
        /// readable in the popover. Mutable because a row can start life
        /// named only by its task id — when we hear about the shell before
        /// its `tool_use` — and get upgraded once a real name shows up.
        var commandPreview: String
        let startedAt: Date
        var status: Status
        /// Whether this is a command the user's agent explicitly ran, or one of
        /// the harness' own background-task output wrappers. Lets the popover
        /// visually separate "your commands" from internal plumbing.
        var kind: Kind = .userCommand
        /// Absolute path of the file the harness streams this shell's output to
        /// (scraped from the initial `tool_result`). Backs the "View output"
        /// window. Nil until the tool_result with the path lands.
        var outputFilePath: String?

        var id: String { toolUseId }

        enum Status: Equatable {
            case starting
            case running
            case completed(exitCode: String?)
            case killed
            case unknown
        }

        enum Kind: Equatable {
            case userCommand
            case agentTask
        }
    }

    /// Terminal background/foreground sourced from `~/.config/ghostty/config`
    /// so the chat panel matches whatever theme the user uses for terminals.
    /// Refreshed when `Notification.Name.ghosttyConfigDidReload` fires.
    @Published private(set) var terminalBackgroundColor: NSColor = NSColor(srgbRed: 0x2B/255.0, green: 0x2B/255.0, blue: 0x2B/255.0, alpha: 1.0)
    @Published private(set) var terminalForegroundColor: NSColor = NSColor(srgbRed: 0xBB/255.0, green: 0xBB/255.0, blue: 0xBB/255.0, alpha: 1.0)
    private var ghosttyConfigObserver: NSObjectProtocol?

    var displayTitle: String {
        if let custom = customTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let first = messages.first(where: { $0.role == .user })?.plainText
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return String(first.prefix(40))
        }
        return String(localized: "claudeChat.newTab.title", defaultValue: "Claude Chat")
    }

    var displayIcon: String? {
        "bubble.left.and.bubble.right"
    }

    var isDirty: Bool { false }

    private let runner = ClaudeChatRunner()

    init(
        workspaceId: UUID,
        workingDirectory: String,
        sessionId: String? = nil,
        initialMessages: [ChatMessage] = ClaudeChatPanel.welcomeMessages()
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory
        self.sessionCwd = workingDirectory
        self.sessionId = sessionId
        self.messages = initialMessages
        self.modelSelection = ClaudeChatPanel.loadInitialModelSelection()
        self.thinkingEffort = ClaudeChatPanel.loadInitialThinkingEffort()
        // Cap the initial render window so opening a chat with a long
        // history doesn't have to lay out every prior message at once.
        // If the transcript is shorter than the default, we just show
        // everything (no banner appears).
        self.visibleMessageWindow = min(
            ClaudeChatPanel.defaultVisibleMessageWindow,
            initialMessages.count
        )

        bootstrapAlwaysAllowedFromSettings()
        refreshTerminalColors()
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTerminalColors()
            }
        }
        refreshStatusLine()
    }

    deinit {
        if let observer = ghosttyConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Drop any rows the view's `ChatRowBuilderCache` may still be
        // holding for this panel id, so a panel created with the same
        // UUID later (e.g. session restore) doesn't see stale rows.
        ChatRowBuilderCache.shared.clear(panelId: id)
        gitPendingSummaryRefreshTask?.cancel()
    }

    /// Replace the panel's transcript with one loaded from a Claude
    /// Code JSONL — used when opening a Claude Chat panel from the
    /// upstream Sessions panel. The panel was created empty (welcome
    /// messages) so the UI mounts immediately; this swaps in the real
    /// history asynchronously and sets the `sessionId` so the next
    /// user message picks up the conversation via `--resume`.
    func applyResumedTranscript(sessionId: String, messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        // Replacing the transcript wholesale — drop any in-flight
        // streamed buffer so a stale flush can't smear yesterday's
        // chunks on top of the resumed history.
        streamedMessageBuffer.removeAll(keepingCapacity: false)
        pendingToolResultsBuffer.removeAll(keepingCapacity: false)
        streamedFlushScheduled = false
        self.sessionId = sessionId
        self.messages = messages
        // Replay the transcript's `Bash` tool_use/tool_result blocks
        // through the same bookkeeping the live stream uses, so the
        // background-shells popover shows real commands instead of
        // "(background shell)" placeholders after a resume. This also
        // consumes the harness' `<task-notification>` blocks for shell
        // status, so it must run before we strip them below.
        rebuildBackgroundShellsFromTranscript()
        // Those `<task-notification>` blocks persist in the JSONL as `.user`
        // messages. Now that their status has been consumed, drop them from
        // the visible transcript — otherwise the raw XML shows up as a user
        // bubble in place of the real conversation after a resume.
        self.messages.removeAll { Self.isTaskNotificationNoise($0) }
        // Cap the visible window the same way `init` does so a long
        // resumed transcript doesn't materialize every row at once.
        self.visibleMessageWindow = min(
            ClaudeChatPanel.defaultVisibleMessageWindow,
            self.messages.count
        )
    }

    /// True when a message is nothing but harness-injected `<task-notification>`
    /// text (plus whitespace) — a system shell-status update with no real user
    /// content. Messages that mix a notification with actual text are kept.
    static func isTaskNotificationNoise(_ message: ChatMessage) -> Bool {
        guard !message.blocks.isEmpty else { return false }
        var sawNotification = false
        for block in message.blocks {
            guard case .text(let value) = block else { return false }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("<task-notification>") {
                sawNotification = true
            } else if !trimmed.isEmpty {
                return false
            }
        }
        return sawNotification
    }

    /// After `applyResumedTranscript` swaps in a historic transcript,
    /// re-run the same `noteBashToolUseIfBackground` / `noteBackgroundShellResult`
    /// path the live stream uses so any shell that was launched in a
    /// prior session ends up in `backgroundShells` with its real
    /// command preview and resolved status. Without this, a later
    /// `task_started` for a still-alive shell would fall into the
    /// orphan branch in `applyBackgroundTaskEvent` and synthesise a
    /// row with the anonymous "(background shell)" preview.
    private func rebuildBackgroundShellsFromTranscript() {
        for message in messages {
            for block in message.blocks {
                if case .toolUse(let toolUse) = block, toolUse.name == "Bash" {
                    noteBashToolUseIfBackground(toolUse, startedAt: message.createdAt)
                }
            }
        }
        for message in messages {
            for block in message.blocks {
                if case .toolResult(let result) = block {
                    noteBackgroundShellResult(result)
                }
            }
        }
        // Third pass: reconcile terminal state from the harness'
        // `<task-notification>` blocks, which persist in the JSONL as `.text`
        // of `role: .user` messages. Runs last so the shells created by the
        // Bash passes above already exist and match. Without this every shell
        // resurrects as `.running` on resume even after it exited.
        for message in messages where message.role == .user {
            for block in message.blocks {
                if case .text(let value) = block {
                    applyTaskNotifications(inText: value)
                }
            }
        }
    }

    /// Hydrate `alwaysAllowedTools` from `<cwd>/.claude/settings.local.json`
    /// only — that's the file cmux owns and writes to via "Allow always".
    /// Rules in `<cwd>/.claude/settings.json` (project shared) and
    /// `~/.claude/settings.json` (global) are still honoured by the rule
    /// engine for auto-allow, but they are NOT surfaced as revocable chips
    /// (the user authored those elsewhere; cmux should not offer to delete
    /// them from its UI).
    private func bootstrapAlwaysAllowedFromSettings() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsLocalPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any],
              let allowList = permissions["allow"] as? [String]
        else {
            alwaysAllowedTools = []
            return
        }
        let plain: [String] = allowList
            .compactMap(ChatPermissionPattern.parse)
            .compactMap { $0.argument == nil ? $0.toolName : nil }
        alwaysAllowedTools = Set(plain)
    }

    private func refreshTerminalColors() {
        let config = GhosttyConfig.load()
        if terminalBackgroundColor != config.backgroundColor {
            terminalBackgroundColor = config.backgroundColor
        }
        if terminalForegroundColor != config.foregroundColor {
            terminalForegroundColor = config.foregroundColor
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Bonsplit calls this when the chat tab becomes the active pane.
        // Without an explicit focus pull the workspace's last-focused
        // terminal can keep first-responder and steal subsequent keystrokes.
        inputFocusRequestToken &+= 1
    }

    func unfocus() {
        // No-op.
    }

    func close() {
        runner.terminate()
        mcpServer?.stop()
        mcpServer = nil
        if let path = mcpConfigPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        mcpConfigPath = nil
        // Drop the panel's attachments dir too — the files were copies we
        // owned for this chat's lifetime.
        let attachmentsBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claudechat-\(id.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: attachmentsBase)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Workspace coordination

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func updateWorkingDirectory(_ newWorkingDirectory: String) {
        let trimmed = newWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workingDirectory else { return }
        workingDirectory = trimmed
        refreshStatusLine()
        refreshGitPendingSummary()
    }

    func updateGitBranchState(_ newState: SidebarGitBranchState?) {
        if gitBranchState != newState {
            gitBranchState = newState
        }
        refreshGitPendingSummary()
    }

    func setCustomTitle(_ title: String?) {
        customTitleOverride = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Conversation

    /// Send the body of a custom slash-command markdown file as a normal
    /// prompt to claude, while showing the user a tool-card-style row in
    /// the transcript labelled with the original `/<name>` and the body
    /// initially collapsed. Headless `claude -p` does not process slash
    /// commands itself (those are an interactive-mode feature), so we
    /// expand the file ourselves and forward the contents.
    func sendSlashCommand(name: String, expandedText: String) {
        let trimmed = expandedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .sending = status { return }

        // Local transcript entry: collapsed by default with the slash
        // command name in the header.
        var localMessage = ChatMessage(
            role: .user,
            blocks: [.text(trimmed)],
            isCollapsedByDefault: true,
            slashCommandName: name
        )
        // Stable id so the row is deterministic in the transcript.
        _ = localMessage.id
        // Drain any pending streamed chunks before appending so the new
        // user message lands at the actual tail of the transcript, not
        // before un-flushed assistant tokens from the previous turn.
        flushStreamedMessages()
        messages.append(localMessage)
        lastTurnEdits.removeAll()
        pendingTurnStaging = (userMessageId: localMessage.id, userMessageIndex: messages.count)
        status = .sending

        let cwd = sessionCwd
        let resumeId = sessionId
        let mode = permissionMode
        let model = modelSelection.claudeFlag
        let effort = thinkingEffort.claudeFlag

        Task { @MainActor [weak self] in
            guard let self else { return }
            let mcpConfigPath: String?
            do {
                mcpConfigPath = try await self.ensureMcpServerStarted()
            } catch {
                self.status = .error(error.localizedDescription)
                return
            }
            guard case .sending = self.status else { return }
            self.runner.ensureStarted(
                cwd: cwd,
                sessionId: resumeId,
                permissionMode: mode.claudeFlag,
                model: model,
                effort: effort,
                mcpConfigPath: mcpConfigPath,
                permissionPromptTool: mode.usesPermissionPromptTool ? "mcp__cmux__approval_prompt" : nil,
                appendSystemPrompt: ClaudeChatPanel.cmuxToolsSystemPrompt,
                onEvent: { event in
                    Task { @MainActor [weak self] in
                        self?.handle(event: event)
                    }
                },
                onExit: { result in
                    Task { @MainActor [weak self] in
                        self?.handle(processExit: result)
                    }
                }
            )
            self.runner.sendUserTurn(trimmed)
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumedAttachments = pendingAttachments
        // Allow sending an attachment-only message (e.g. drag a screenshot
        // and just hit Enter) — claude can describe / OCR it without a
        // text prompt.
        guard !trimmed.isEmpty || !consumedAttachments.isEmpty else { return }

        // The text claude sees is the user's prompt prefixed with @<path>
        // mentions for each attachment — that triggers Claude Code's
        // multimodal expansion. The local transcript stores only the
        // user's own text plus a sidecar list of attachments, so the UI
        // can render thumbnails instead of long file paths.
        let userText = ChatAttachment.composeUserMessage(text: trimmed, attachments: consumedAttachments)
        let visibleText = trimmed
        let attachmentURLs = consumedAttachments.map { $0.url }
        var localMessage = ChatMessage(role: .user, blocks: visibleText.isEmpty ? [] : [.text(visibleText)])
        localMessage.attachmentURLs = attachmentURLs
        flushStreamedMessages()
        messages.append(localMessage)
        pendingAttachments.removeAll()

        if case .sending = status {
            // Previous turn still in flight: stash this prompt and let
            // the result-event handler drain it once we go idle. The
            // transcript already shows the bubble (marked as queued by
            // the view).
            pendingDrafts.append(PendingDraft(
                id: localMessage.id,
                userText: userText,
                attachmentURLs: attachmentURLs
            ))
            return
        }

        dispatchTurn(messageId: localMessage.id, userText: userText)
    }

    /// Kick off a Claude turn for the given user message. Handles MCP
    /// startup, status bookkeeping, and turn-edit/staging resets. Shared
    /// between `send(_:)` and the queued-drafts drain in
    /// the drain logic invoked when a `result` event flips status to idle.
    private func dispatchTurn(messageId: UUID, userText: String) {
        // Each user prompt starts a new "turn" — drop the previous turn's
        // edit list so the diff side pane always shows what claude did in
        // response to the most recent message.
        lastTurnEdits.removeAll()
        // Stage a checkpoint anchored just AFTER the user message — an
        // undo will keep the user prompt visible and remove only what
        // claude streams below it. The file-backups are filled in once
        // the turn finishes (we read them out of claude's session JSONL).
        let messageIndex = messages.firstIndex(where: { $0.id == messageId }).map { $0 + 1 }
            ?? messages.count
        pendingTurnStaging = (userMessageId: messageId, userMessageIndex: messageIndex)
        // A fresh turn clears any prior stop request — from here on, errors
        // are real again.
        pendingCancel = false
        status = .sending

        let cwd = sessionCwd
        let resumeId = sessionId
        let mode = permissionMode
        let model = modelSelection.claudeFlag
        let effort = thinkingEffort.claudeFlag

        // The MCP server is started for every chat (regardless of mode) so
        // we can disable Claude Code's built-in `AskUserQuestion` (which
        // self-denies in headless mode) and route questions through our
        // own MCP tool. The HTTP listener is async — hop off main while it
        // binds so the UI stays responsive.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mcpConfigPath: String?
            do {
                mcpConfigPath = try await self.ensureMcpServerStarted()
            } catch {
                self.status = .error(error.localizedDescription)
                return
            }
            // Re-check status — user may have hit Clear or Cancel while we
            // were waiting for the server to bind.
            guard case .sending = self.status else { return }
            self.runner.ensureStarted(
                cwd: cwd,
                sessionId: resumeId,
                permissionMode: mode.claudeFlag,
                model: model,
                effort: effort,
                mcpConfigPath: mcpConfigPath,
                permissionPromptTool: mode.usesPermissionPromptTool ? "mcp__cmux__approval_prompt" : nil,
                appendSystemPrompt: ClaudeChatPanel.cmuxToolsSystemPrompt,
                onEvent: { event in
                    Task { @MainActor [weak self] in
                        self?.handle(event: event)
                    }
                },
                onExit: { result in
                    Task { @MainActor [weak self] in
                        self?.handle(processExit: result)
                    }
                }
            )
            self.runner.sendUserTurn(userText)
        }
    }

    func cancel() {
        // Only a turn that is actually in flight can be "stopped". Marking
        // this lets `handle(event:)` / `handle(processExit:)` treat the
        // interruption as expected instead of surfacing an error banner.
        if case .sending = status {
            pendingCancel = true
        }
        runner.cancel()
    }

    /// Rewind the conversation to *just after* `userMessageId` was sent
    /// — the prompt itself stays visible, every claude reply since is
    /// removed, and the matching file-history backup is replayed onto
    /// disk. Returns the number of files restored, or `nil` if no
    /// checkpoint matches that message id.
    ///
    /// Side effects:
    ///   - Drops every checkpoint at or after the rewind point (those
    ///     futures no longer exist).
    ///   - Clears the session id so the next prompt starts a fresh
    ///     conversation (Claude Code's CLI does not expose a way to
    ///     rewind its own memory mid-session).
    @discardableResult
    func rewindTo(userMessageId: UUID) -> Int? {
        guard let checkpointIdx = undoCheckpoints.firstIndex(
            where: { $0.userMessageId == userMessageId }
        ) else { return nil }
        let checkpoint = undoCheckpoints[checkpointIdx]

        var restoredFiles = 0
        if let backups = checkpoint.backups {
            restoredFiles = ClaudeSessionHistory.restore(backups).count
        }
        // Drain any pending streamed chunks before we slice the
        // transcript — otherwise a stale flush would re-introduce
        // messages we just rolled back.
        flushStreamedMessages()
        if checkpoint.userMessageIndex < messages.count {
            messages.removeSubrange(checkpoint.userMessageIndex ..< messages.count)
        }
        // Drop this checkpoint and every later one — they describe a
        // future that no longer exists.
        undoCheckpoints.removeSubrange(checkpointIdx ..< undoCheckpoints.count)

        lastTurnEdits.removeAll()
        toolResultsByToolUseId.removeAll()
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        approvalResolvers.removeAll()
        questionResolvers.removeAll()
        questionDedupeAliases.removeAll()
        approvalDedupeAliases.removeAll()
        sessionId = nil
        pendingTurnStaging = nil
        if case .sending = status { status = .idle }
        return restoredFiles
    }

    /// Convenience: rewind to the most recent checkpoint.
    @discardableResult
    func undoLastTurn() -> Int? {
        guard let last = undoCheckpoints.last else { return nil }
        return rewindTo(userMessageId: last.userMessageId)
    }

    // MARK: - Attachments

    /// Copy `sourceURL` into the panel's attachment temp dir and add it
    /// to `pendingAttachments`. The original file is left untouched.
    @discardableResult
    func attachFile(at sourceURL: URL) -> ChatAttachment? {
        do {
            let dir = try ensureAttachmentDirectory()
            let ext = sourceURL.pathExtension
            let filename = ext.isEmpty
                ? UUID().uuidString
                : "\(UUID().uuidString).\(ext)"
            let dest = dir.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            let attachment = ChatAttachment(
                url: dest,
                displayName: sourceURL.lastPathComponent,
                isImage: ChatAttachment.isImageFile(at: sourceURL)
            )
            pendingAttachments.append(attachment)
            return attachment
        } catch {
            #if DEBUG
            NSLog("ClaudeChatPanel.attachFile failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Persist arbitrary image data (e.g. from a clipboard / drop NSImage
    /// representation) to the attachments dir as a PNG.
    @discardableResult
    func attachImageData(_ data: Data, suggestedExtension: String = "png", baseName: String = "image") -> ChatAttachment? {
        do {
            let dir = try ensureAttachmentDirectory()
            let filename = "\(baseName)-\(UUID().uuidString.prefix(6)).\(suggestedExtension)"
            let dest = dir.appendingPathComponent(filename)
            try data.write(to: dest, options: .atomic)
            let attachment = ChatAttachment(
                url: dest,
                displayName: filename,
                isImage: true
            )
            pendingAttachments.append(attachment)
            return attachment
        } catch {
            #if DEBUG
            NSLog("ClaudeChatPanel.attachImageData failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    private func ensureAttachmentDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claudechat-\(id.uuidString)", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func ensureMcpServerStarted() async throws -> String {
        if let existing = mcpConfigPath, mcpServer != nil {
            return existing
        }
        let server = try ChatMcpHttpServer()
        try await server.start()
        server.delegate = self
        mcpServer = server

        let mergedServers = McpServerCatalog.mergedForRuntime(
            cwd: sessionCwd,
            builtinEndpoint: server.endpointURL
        )

        let config: [String: Any] = ["mcpServers": mergedServers]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        let tmpDir = NSTemporaryDirectory()
        let path = (tmpDir as NSString).appendingPathComponent("cmux-claudechat-\(id.uuidString).json")
        try data.write(to: URL(fileURLWithPath: path))
        mcpConfigPath = path
        return path
    }

    /// Snapshot of the cmux-builtin MCP server that backs inline approvals
    /// and ask-user-question, for the MCP manager UI to render alongside
    /// the project/user-local entries. Nil before the first turn (the
    /// HTTP listener is started on demand).
    func builtinMcpServerConfig() -> McpServerConfig? {
        guard let server = mcpServer else { return nil }
        return McpServerConfig(
            name: "cmux",
            scope: .builtin,
            transport: .http(url: server.endpointURL.absoluteString, headers: [:])
        )
    }

    /// Refresh `mcpRuntimeStatus` by spawning `claude mcp list` and
    /// folding the result in. Used by the popover's onAppear and the
    /// Refresh button so the badges reflect the *current* MCP health,
    /// not just the snapshot from the long-running process' initial
    /// `system/init`. Does NOT touch the chat's `claude` process.
    func refreshMcpStatus() {
        let cwd = sessionCwd
        Task.detached { [weak self] in
            guard let self else { return }
            let path: String
            do {
                path = try self.runner.resolveClaudeBinaryPath()
            } catch {
                return
            }
            let snapshots = await McpHealthProber.probeAll(claudePath: path, cwd: cwd)
            guard !snapshots.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var merged = self.mcpRuntimeStatus
                for snapshot in snapshots {
                    merged[snapshot.name] = snapshot
                }
                self.mcpRuntimeStatus = merged
            }
        }
    }

    /// Re-run the health check for a single MCP server via
    /// `claude mcp get <name>` and update its badge. Note this does
    /// not "reconnect" the server inside the running `claude` chat
    /// process — that would require a respawn. It only refreshes
    /// what we display so the user can confirm whether a recovery
    /// effort outside cmux (auth, network) succeeded.
    func reconnectMcpServer(name: String) {
        guard !name.isEmpty else { return }
        let cwd = sessionCwd
        // Show "Connecting…" in the meantime so the click feels
        // responsive.
        mcpRuntimeStatus[name] = McpServerInitStatus(
            name: name,
            status: "connecting",
            error: nil
        )
        Task.detached { [weak self] in
            guard let self else { return }
            let path: String
            do {
                path = try self.runner.resolveClaudeBinaryPath()
            } catch {
                return
            }
            let snapshot = await McpHealthProber.probeOne(name: name, claudePath: path, cwd: cwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let snapshot {
                    var merged = self.mcpRuntimeStatus
                    merged[name] = snapshot
                    self.mcpRuntimeStatus = merged
                } else {
                    // Probe returned nothing — fall back to unknown.
                    var merged = self.mcpRuntimeStatus
                    merged[name] = McpServerInitStatus(name: name, status: "unknown", error: nil)
                    self.mcpRuntimeStatus = merged
                }
            }
        }
    }

    /// Tear down the running `claude` process and the inline MCP HTTP
    /// server, then drop the cached `--mcp-config` temp file. The next
    /// `sendUserMessage` calls `ensureMcpServerStarted` again, which
    /// regenerates the temp file from disk (picking up any edits the
    /// user just made via the MCP manager) and `ensureStarted` respawns
    /// `claude` with the new config. The session id we already captured
    /// (`--resume <sid>`) means the new process picks the conversation
    /// up exactly where the old one left off — only the MCP wiring
    /// changes.
    func reloadMcpRuntime() {
        runner.terminate()
        mcpServer?.stop()
        mcpServer = nil
        if let path = mcpConfigPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        mcpConfigPath = nil
        // Clear the in-memory status snapshot so the UI shows
        // "Unknown" until the fresh `system/init` lands. Otherwise we
        // would briefly imply that the just-edited servers are still
        // connected.
        mcpRuntimeStatus = [:]
    }

    /// Append a synthetic system message to the transcript. Used by the
    /// slash-command dispatcher (e.g. `/cost`, `/help`, `/model`) to show
    /// the user a one-shot informational message without involving claude.
    /// Markdown is rendered with the chat's normal theme.
    func appendSystemNotice(_ text: String) {
        flushStreamedMessages()
        messages.append(.text(.system, text))
    }

    /// Serialize the current transcript into Markdown so the user can copy
    /// the entire conversation to the clipboard. SwiftUI's per-Text
    /// `textSelection(.enabled)` does not let drags cross views, so this
    /// is the only way to grab the whole thing in one shot. Tool calls /
    /// results are emitted as fenced blocks; attachments and pending
    /// (queued) messages are surfaced too so the dump matches what the
    /// user sees on screen.
    func transcriptAsMarkdown() -> String {
        var out: [String] = []
        for message in messages {
            let roleLabel: String
            switch message.role {
            case .user: roleLabel = "User"
            case .assistant: roleLabel = "Assistant"
            case .system: roleLabel = "System"
            }
            out.append("### \(roleLabel)")
            if !message.attachmentURLs.isEmpty {
                let names = message.attachmentURLs.map { $0.lastPathComponent }.joined(separator: ", ")
                out.append("_Attachments: \(names)_")
            }
            for block in message.blocks {
                switch block {
                case .text(let value):
                    out.append(value)
                case .toolUse(let use):
                    out.append("**Tool: `\(use.name)`**")
                    out.append("```json")
                    out.append(use.inputJSON)
                    out.append("```")
                case .toolResult(let result):
                    out.append(result.isError ? "**Tool error:**" : "**Tool result:**")
                    out.append("```")
                    out.append(result.content)
                    out.append("```")
                }
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// Reveal more of the older transcript that the initial render window
    /// kept hidden. Each call uncovers `visibleMessageWindowStep` more
    /// messages; when there are fewer than that left, the rest are
    /// revealed in one go and the "load older" banner disappears.
    func revealOlderMessages(by step: Int = ClaudeChatPanel.visibleMessageWindowStep) {
        let next = visibleMessageWindow + max(1, step)
        visibleMessageWindow = min(next, messages.count)
    }

    /// Reveal the entire transcript at once. Used by the "show all"
    /// affordance for users who'd rather pay the layout cost than click
    /// through several pages of older history.
    func revealAllMessages() {
        visibleMessageWindow = messages.count
    }

    // MARK: - Streamed-batch coalescing

    /// Append a stream-derived message (assistant chunk, user passthrough
    /// from the model, system warning emitted while parsing an event)
    /// without publishing yet. The accumulated buffer is flushed
    /// `streamedFlushInterval` later, so a burst of stream-json events
    /// from claude produces a single `@Published var messages` mutation
    /// — one body re-evaluation in the chat view, one markdown re-parse
    /// of the in-progress assistant bubble.
    ///
    /// Stream-json splits a single assistant response across many events
    /// that share `claudeMessageId`; if the previous buffered entry is
    /// also an assistant chunk with the same id we fold the new blocks
    /// into it instead of appending a new `ChatMessage`. This keeps the
    /// visible bubble count low on long replies (otherwise a 30 s
    /// response would land as dozens of separate bubbles).
    private func enqueueStreamedMessage(_ message: ChatMessage) {
        if Self.canMergeAssistantChunk(into: streamedMessageBuffer.last, from: message),
           let lastIdx = streamedMessageBuffer.indices.last {
            var merged = streamedMessageBuffer[lastIdx]
            merged.blocks.append(contentsOf: message.blocks)
            streamedMessageBuffer[lastIdx] = merged
        } else {
            streamedMessageBuffer.append(message)
        }
        scheduleStreamedFlushIfNeeded()
    }

    /// Two-arg sibling of the merge check used at flush time too —
    /// returns `true` only when both messages are assistant chunks
    /// sharing a non-empty `claudeMessageId`.
    private static func canMergeAssistantChunk(
        into previous: ChatMessage?,
        from new: ChatMessage
    ) -> Bool {
        guard let previous,
              previous.role == .assistant,
              new.role == .assistant,
              let prevCmid = previous.claudeMessageId, !prevCmid.isEmpty,
              let newCmid = new.claudeMessageId, !newCmid.isEmpty,
              prevCmid == newCmid
        else { return false }
        return true
    }

    /// Stage a tool_result for `toolResultsByToolUseId` without
    /// publishing yet. Shares the streamed-batch flush so the dict
    /// updates land in the same main-actor hop as the matching
    /// assistant message chunks.
    private func enqueueStreamedToolResult(_ result: ChatMessageBlock.ToolResult) {
        pendingToolResultsBuffer[result.toolUseId] = result
        scheduleStreamedFlushIfNeeded()
    }

    private func scheduleStreamedFlushIfNeeded() {
        guard !streamedFlushScheduled else { return }
        streamedFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamedFlushInterval) { [weak self] in
            self?.flushStreamedBatches()
        }
    }

    /// Drain both streamed buffers (messages + tool results) into their
    /// @Published containers. Safe to call multiple times: clears the
    /// scheduled flag and no-ops on whichever buffer is empty.
    ///
    /// Cross-flush merge: if the first buffered message is an assistant
    /// chunk that shares `claudeMessageId` with the last already-
    /// published message, fold its blocks into the published one via
    /// whole-element replacement (`messages[i] = …`, which `@Published`
    /// tolerates, unlike `messages[i].blocks.append(…)`).
    private func flushStreamedBatches() {
        streamedFlushScheduled = false
        if !streamedMessageBuffer.isEmpty {
            var toAppend = streamedMessageBuffer
            streamedMessageBuffer.removeAll(keepingCapacity: true)

            if let first = toAppend.first,
               let lastPublishedIdx = messages.indices.last,
               Self.canMergeAssistantChunk(into: messages[lastPublishedIdx], from: first) {
                var merged = messages[lastPublishedIdx]
                merged.blocks.append(contentsOf: first.blocks)
                messages[lastPublishedIdx] = merged
                toAppend.removeFirst()
            }
            if !toAppend.isEmpty {
                messages.append(contentsOf: toAppend)
            }
        }
        if !pendingToolResultsBuffer.isEmpty {
            let toMerge = pendingToolResultsBuffer
            pendingToolResultsBuffer.removeAll(keepingCapacity: true)
            toolResultsByToolUseId.merge(toMerge) { _, new in new }
        }
    }

    /// Compatibility shim — callers that historically only cared about
    /// the message buffer keep working; both buffers drain together.
    private func flushStreamedMessages() {
        flushStreamedBatches()
    }

    /// Reset the conversation: terminate the running claude (so its
    /// in-memory session id is forgotten), drop the messages transcript,
    /// forget the session id (so the next turn starts a fresh
    /// claude session, not a `--resume`), and clear errors.
    func clearTranscript() {
        runner.terminate()
        ChatRowBuilderCache.shared.clear(panelId: id)
        // Drop any in-flight streamed messages before we replace the
        // transcript — otherwise the next flush would re-introduce them
        // on top of the welcome messages.
        streamedMessageBuffer.removeAll(keepingCapacity: false)
        pendingToolResultsBuffer.removeAll(keepingCapacity: false)
        streamedFlushScheduled = false
        messages = ClaudeChatPanel.welcomeMessages()
        sessionId = nil
        modelName = nil
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        questionDedupeAliases.removeAll()
        approvalDedupeAliases.removeAll()
        toolResultsByToolUseId.removeAll()
        pendingAttachments.removeAll()
        lastTurnEdits.removeAll()
        undoCheckpoints.removeAll()
        // `/clear` is a brand-new session: drop the diff-pane memo so
        // the first edit-producing turn after this re-triggers the
        // one-time auto-open behavior, and close the pane itself.
        diffPaneOpen = false
        hasAutoOpenedDiffPaneThisSession = false
        pendingTurnStaging = nil
        currentTodos = nil
        taskRegistryById.removeAll()
        pendingTaskCreates.removeAll()
        pendingDrafts.removeAll()
        backgroundShells.removeAll()
        // Note: alwaysAllowedTools is intentionally preserved — it's persisted
        // in `.claude/settings.local.json` and represents user preferences
        // that should outlive a single conversation.
        status = .idle
    }

    /// Hide the persistent todos banner without affecting the underlying
    /// `TodoWrite` history — the next call from Claude repopulates it.
    /// Used by the X button on the banner so the user can reclaim the
    /// vertical real estate when the checklist is no longer interesting.
    ///
    /// Note: with Claude Code 2.x `TaskCreate`/`TaskUpdate` we also clear
    /// `taskRegistryById` so the next batch of per-task tools rebuilds
    /// from scratch rather than re-rendering the same dismissed list.
    func dismissTodos() {
        currentTodos = nil
        taskRegistryById.removeAll()
        pendingTaskCreates.removeAll()
    }

    func approve(toolUseId: String) {
        guard let resolver = approvalResolvers.removeValue(forKey: toolUseId) else {
            pendingApprovals.removeAll { $0.id == toolUseId }
            return
        }
        pendingApprovals.removeAll { $0.id == toolUseId }
        // Resolve any duplicate calls claude fired with identical
        // tool_name/input that we silently aliased onto this card.
        let aliasIds = approvalDedupeAliases.removeValue(forKey: toolUseId) ?? []
        resolver(.allow)
        for aliasId in aliasIds {
            if let aliasResolver = approvalResolvers.removeValue(forKey: aliasId) {
                aliasResolver(.allow)
            }
        }
    }

    /// Approve this request and add the tool to the workspace's
    /// `.claude/settings.local.json` so subsequent calls to the same tool
    /// skip the UI prompt — both for the rest of this chat and for any
    /// future chat in the same workspace.
    func approveAlways(toolUseId: String, toolName: String) {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            alwaysAllowedTools.insert(trimmed)
            try? ChatPermissionRules.writeAllowEntry(trimmed, toFileAt: settingsLocalPath)
            invalidatePermissionRulesCache()
        }
        approve(toolUseId: toolUseId)
    }

    func deny(toolUseId: String, reason: String?) {
        guard let resolver = approvalResolvers.removeValue(forKey: toolUseId) else {
            pendingApprovals.removeAll { $0.id == toolUseId }
            return
        }
        pendingApprovals.removeAll { $0.id == toolUseId }
        let aliasIds = approvalDedupeAliases.removeValue(forKey: toolUseId) ?? []
        resolver(.deny(reason: reason))
        for aliasId in aliasIds {
            if let aliasResolver = approvalResolvers.removeValue(forKey: aliasId) {
                aliasResolver(.deny(reason: reason))
            }
        }
    }

    /// Revoke a tool from the "always allow" set (UI exposes this as a
    /// chip in the header). Also removes it from the workspace's
    /// `.claude/settings.local.json`.
    func revokeAlwaysAllowed(toolName: String) {
        alwaysAllowedTools.remove(toolName)
        try? ChatPermissionRules.removeAllowEntry(toolName, fromFileAt: settingsLocalPath)
        invalidatePermissionRulesCache()
    }

    private var settingsLocalPath: String {
        (workingDirectory as NSString).appendingPathComponent(".claude/settings.local.json")
    }

    private func invalidatePermissionRulesCache() {
        cachedRulesCwd = nil
        cachedRulesMtimes = [:]
    }

    func answer(questionId: String, answers: [[String]]) {
        let response = ChatUserQuestionResponse(answers: answers)
        // Resolve the primary, then any deduped duplicates claude fired
        // with the same content — they all expect the same answer.
        let aliasIds = questionDedupeAliases.removeValue(forKey: questionId) ?? []
        if let resolver = questionResolvers.removeValue(forKey: questionId) {
            resolver(response)
        }
        for aliasId in aliasIds {
            if let resolver = questionResolvers.removeValue(forKey: aliasId) {
                resolver(response)
            }
        }
        pendingQuestions.removeAll { $0.id == questionId }
    }

    // MARK: - Background shells

    /// Ask claude to kill a background shell by its `shell_id`. There is
    /// no CLI surface to send commands to the running `claude` process
    /// other than user turns, so we forward this as a slash-command-
    /// style prompt that asks claude to invoke the `KillShell` tool. The
    /// transcript shows the request collapsed (same pattern as `/clear`
    /// and other built-ins) — the row is then moved to `.killed` by the
    /// resulting `KillShell` tool_use we observe in the next assistant
    /// event.
    func killBackgroundShell(shellId: String) {
        guard !shellId.isEmpty else { return }
        // Optimistic flip so the popover shows the badge change right
        // away. The actual transition is confirmed when claude emits
        // the `KillShell` tool_use / tool_result a moment later.
        if let idx = backgroundShells.firstIndex(where: { $0.shellId == shellId }) {
            if case .completed = backgroundShells[idx].status { /* leave */ }
            else if case .killed = backgroundShells[idx].status { /* leave */ }
            else {
                backgroundShells[idx].status = .killed
            }
        }
        let expanded = String(
            format: String(
                localized: "claudeChat.bashes.kill.prompt",
                defaultValue: "Use the KillShell tool to terminate shell_id=%@. Do not run any other commands."
            ),
            shellId
        )
        sendSlashCommand(name: "kill-shell", expandedText: expanded)
    }

    /// Drop the bookkeeping for a single shell row — used by the popover
    /// when the user wants to hide entries claude already reported as
    /// completed. Does not touch the underlying claude state.
    func dismissBackgroundShell(toolUseId: String) {
        backgroundShells.removeAll { $0.toolUseId == toolUseId }
    }

    fileprivate func noteBashToolUseIfBackground(
        _ toolUse: ChatMessageBlock.ToolUse,
        startedAt: Date = Date()
    ) {
        guard let input = parseJSONObject(toolUse.inputJSON) else { return }
        let runInBackground = (input["run_in_background"] as? Bool) ?? false
        guard runInBackground else { return }
        if backgroundShells.contains(where: { $0.toolUseId == toolUse.id }) {
            return
        }
        let rawCmd = (input["command"] as? String) ?? ""
        let trimmed = rawCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = Self.classifyBackgroundCommand(trimmed)
        backgroundShells.append(BackgroundShell(
            toolUseId: toolUse.id,
            shellId: nil,
            commandPreview: Self.backgroundCommandPreview(trimmed, kind: kind),
            startedAt: startedAt,
            status: .starting,
            kind: kind
        ))
    }

    /// Tell the user's real commands apart from the harness' own background
    /// task wrappers, which redirect output to `…/claude-<n>/…/tasks/<id>`.
    static func classifyBackgroundCommand(_ command: String) -> BackgroundShell.Kind {
        if command.range(of: #"/claude-[^/]*/.*/tasks/"#, options: .regularExpression) != nil {
            return .agentTask
        }
        return .userCommand
    }

    /// Readable one-liner for the popover: agent-task wrappers get a friendly
    /// "Agent task output (<id>)" instead of the raw redirect blob; user
    /// commands are shown verbatim, truncated.
    private static func backgroundCommandPreview(
        _ command: String,
        kind: BackgroundShell.Kind
    ) -> String {
        if kind == .agentTask,
           let range = command.range(of: #"/tasks/([A-Za-z0-9_\-]+)"#, options: .regularExpression) {
            let idPart = command[range].replacingOccurrences(of: "/tasks/", with: "")
            return String(
                format: String(
                    localized: "claudeChat.bashes.agentTaskPreview",
                    defaultValue: "Agent task output (%@)"
                ),
                idPart
            )
        }
        return command.count > 120 ? String(command.prefix(117)) + "…" : command
    }

    /// Bulk-remove every shell that has finished (completed or killed), leaving
    /// the ones still live (starting/running/unknown). Backs the popover's
    /// "clear finished" action.
    // MARK: - Font size / zoom

    /// Increases the chat font size by one step. Returns `true` if it changed.
    @discardableResult
    func zoomIn() -> Bool {
        setFontSize(fontSize + ChatFontSizeSettings.stepPointSize)
    }

    /// Decreases the chat font size by one step. Returns `true` if it changed.
    @discardableResult
    func zoomOut() -> Bool {
        setFontSize(fontSize - ChatFontSizeSettings.stepPointSize)
    }

    /// Resets the chat font size to the configured `claudeChat.fontSize` default.
    @discardableResult
    func resetZoom() -> Bool {
        setFontSize(ChatFontSizeSettings.defaultPointSize)
    }

    /// Sets the chat font size to an explicit point value (clamped) and persists
    /// it as the default so new/reopened panels inherit it. Returns `true` if
    /// the size actually changed.
    @discardableResult
    func setFontSize(_ candidate: Double) -> Bool {
        let clamped = ChatFontSizeSettings.clamp(candidate)
        guard abs(clamped - fontSize) > 0.0001 else { return false }
        fontSize = clamped
        ChatFontSizeSettings.setDefault(clamped)
        return true
    }

    func dismissFinishedBackgroundShells() {
        backgroundShells.removeAll { shell in
            switch shell.status {
            case .completed, .killed:
                return true
            case .starting, .running, .unknown:
                return false
            }
        }
    }

    fileprivate func noteKillShellToolUse(_ toolUse: ChatMessageBlock.ToolUse) {
        guard let input = parseJSONObject(toolUse.inputJSON) else { return }
        guard let shellId = input["shell_id"] as? String, !shellId.isEmpty else { return }
        if let idx = backgroundShells.firstIndex(where: { $0.shellId == shellId }) {
            backgroundShells[idx].status = .killed
        }
    }

    /// Internal rather than fileprivate so the tests can replay the live
    /// event order, where this lands *after* the task notification.
    func noteBackgroundShellResult(_ result: ChatMessageBlock.ToolResult) {
        guard let idx = backgroundShells.firstIndex(where: { $0.toolUseId == result.toolUseId }) else {
            return
        }
        if let shellId = Self.parseShellId(fromContent: result.content) {
            backgroundShells[idx].shellId = shellId
        }
        if backgroundShells[idx].outputFilePath == nil,
           let path = Self.parseOutputFilePath(fromContent: result.content) {
            backgroundShells[idx].outputFilePath = path
        }
        // The Bash `tool_result` ("Command running in background with ID: …")
        // arrives *after* the harness' task_notification, and says nothing
        // about the process actually exiting — it only reports the launch. So
        // once a shell has reached a terminal state, this must not drag it
        // back to .running.
        switch backgroundShells[idx].status {
        case .killed, .completed:
            return
        case .starting, .running, .unknown:
            break
        }
        if result.isError {
            backgroundShells[idx].status = .completed(exitCode: "error")
            return
        }
        let lower = result.content.lowercased()
        if lower.contains("status: completed") || lower.contains("exit code") {
            let code = Self.parseExitCode(fromContent: result.content)
            backgroundShells[idx].status = .completed(exitCode: code)
        } else if lower.contains("status: killed") {
            backgroundShells[idx].status = .killed
        } else {
            backgroundShells[idx].status = .running
        }
    }

    private func parseJSONObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Best-effort scrape of the `shell_id` claude emits in the Bash
    /// background tool_result. The harness today returns a preamble
    /// like `Command running in background with ID: <id>. Output is
    /// being written to: …`; older builds also use `shell_id: …` /
    /// `Shell ID: …` / a JSON-ish blob with `"shell_id":"…"`. We
    /// accept all four.
    private static func parseShellId(fromContent content: String) -> String? {
        // `... in background with ID: <id>...`
        if let range = content.range(
            of: #"with\s+ID:\s*([A-Za-z0-9_\-]+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let slice = content[range]
            // Strip everything up to and including the colon, then trim
            // trailing punctuation/whitespace.
            if let colon = slice.firstIndex(of: ":") {
                let after = slice[slice.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .\t\"'"))
                if !after.isEmpty { return String(after) }
            }
        }
        if let range = content.range(of: #"shell[_-]?id"\s*:\s*"([^"]+)""#, options: [.regularExpression, .caseInsensitive]),
           let inner = content[range].split(separator: "\"").last {
            return String(inner)
        }
        // `Shell ID: bash_<n>` / `shell_id: <something>` line.
        for line in content.split(separator: "\n") {
            let lower = line.lowercased()
            if lower.contains("shell id") || lower.contains("shell_id") || lower.contains("bash id") {
                if let colon = line.firstIndex(of: ":") {
                    let after = line[line.index(after: colon)...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                    if !after.isEmpty {
                        return String(after)
                    }
                }
            }
        }
        return nil
    }

    private static func parseExitCode(fromContent content: String) -> String? {
        guard let range = content.range(of: #"exit\s*code\s*[:=]\s*(-?\d+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let slice = content[range]
        let digits = slice.unicodeScalars.filter { ("0"..."9").contains(Character($0)) || $0 == "-" }
        return digits.isEmpty ? nil : String(String.UnicodeScalarView(digits))
    }

    /// Scrape the harness' `Output is being written to: <path>` line from the
    /// initial Bash background `tool_result`, so we can tail that file in the
    /// "View output" window.
    private static func parseOutputFilePath(fromContent content: String) -> String? {
        if let path = Self.firstRegexCapture(
            #"Output is being written to:\s*(\S+\.output)"#, in: content
        ) {
            return path
        }
        guard let raw = Self.firstRegexCapture(
            #"Output is being written to:\s*(\S+)"#, in: content
        ) else {
            return nil
        }
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".\"' \t\n"))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Event handling

    private func handle(event: ClaudeStreamEvent) {
        switch event {
        case .systemInit(let sid, let model, _, let mcpServers, let slashCommands):
            if !sid.isEmpty, sessionId != sid {
                sessionId = sid
            }
            // The CLI's own command list — skills and plugin commands
            // included, none of which a scan of `.claude/commands/` can see.
            if !slashCommands.isEmpty, cliSlashCommands != slashCommands {
                cliSlashCommands = slashCommands
            }
            if let model, !model.isEmpty, modelName != model {
                modelName = model
            }
            var snapshot: [String: McpServerInitStatus] = [:]
            for entry in mcpServers {
                snapshot[entry.name] = entry
            }
            mcpRuntimeStatus = snapshot
        case .assistant(let claudeMid, let blocks, _, let subagent):
            guard !blocks.isEmpty else { return }
            // Forwarded subagent output (`--forward-subagent-text`). Every
            // handler below reacts to the *lead's* tool calls and mutates
            // panel state accordingly — background-shell rows, the worktree
            // chip, the todo banner, plan-mode focus. A subagent runs its
            // own tools in its own context, so feeding them through here
            // would let somebody else's Bash or EnterWorktree move this
            // session's UI. Render the text and stop.
            if let subagent {
                let textOnly = blocks.filter { block -> Bool in
                    if case .text = block { return true }
                    return false
                }
                guard !textOnly.isEmpty else { return }
                enqueueStreamedMessage(ChatMessage(
                    role: .assistant,
                    blocks: textOnly,
                    claudeMessageId: claudeMid,
                    subagentType: subagent.subagentType
                ))
                return
            }
            // Detect attempts to call the non-functional built-in
            // `AskUserQuestion` and warn the user. Surface the tool name so
            // we can refine the disallow-list / system prompt if needed.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "AskUserQuestion" {
                let warning = String(
                    localized: "claudeChat.builtinAskUserQuestion.warning",
                    defaultValue:
                        "⚠ The model invoked the non-functional built-in `AskUserQuestion` tool. cmux cannot answer it. Try rephrasing the request or restarting the chat — see the chat log for diagnostics."
                )
                enqueueStreamedMessage(.text(.system, warning))
            }
            // Plan-mode approval card carries a `.borderedProminent`
            // "Auto-accept edits" button that AppKit promotes to default
            // responder when it mounts, stealing focus from the
            // composer the user is typing in. Notify the view so it
            // can re-assert composer focus AFTER the card materialises.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "ExitPlanMode" {
                _ = toolUse
                exitPlanModePresentedToken &+= 1
                break
            }
            // Track background bash shells so the header popover knows
            // what's alive and can offer a Kill button. We only register
            // Bash invocations that asked for background execution; the
            // shell_id arrives later in the tool_result.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "Bash" {
                noteBashToolUseIfBackground(toolUse)
            }
            // A KillShell tool_use coming from claude itself moves the
            // matching row to `.killed` so the UI reflects it before the
            // result lands.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "KillShell" {
                noteKillShellToolUse(toolUse)
            }
            // `EnterWorktree` is a Claude Code built-in that swaps the
            // model's effective cwd to another git worktree but does NOT
            // affect the host `Process.currentDirectoryURL` cmux launched
            // it with. Stash the target path now and apply it once the
            // matching tool_result confirms success — so a failed
            // EnterWorktree never moves the header chip.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "EnterWorktree" {
                if let path = Self.parseEnterWorktreePath(fromInputJSON: toolUse.inputJSON) {
                    pendingEnterWorktreeByToolUseId[toolUse.id] = path
                }
            }
            // Pull every edit-shaped tool_use into the side-pane feed.
            for case .toolUse(let toolUse) in blocks
                where Self.editToolNames.contains(toolUse.name) {
                lastTurnEdits.append(TurnEdit(
                    toolName: toolUse.name,
                    inputJSON: toolUse.inputJSON
                ))
            }
            // Refresh the persistent todo banner whenever Claude rewrites
            // the list. We replace the whole array in place so the banner
            // mirrors the in-place semantics of the Claude Code TUI.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "TodoWrite" {
                if let parsed = Self.parseTodos(fromInputJSON: toolUse.inputJSON) {
                    currentTodos = parsed
                }
            }
            // Claude Code 2.x emits per-task tools instead of TodoWrite:
            // TaskCreate adds a task (id assigned by the harness; we
            // learn it from the matching tool_result later) and
            // TaskUpdate mutates an existing one. Both rebuild the
            // banner from `taskRegistryById`.
            for case .toolUse(let toolUse) in blocks {
                switch toolUse.name {
                case "TaskCreate":
                    if let pending = Self.parsePendingTaskCreate(
                        fromInputJSON: toolUse.inputJSON
                    ) {
                        pendingTaskCreates[toolUse.id] = pending
                    }
                case "TaskUpdate":
                    guard let update = Self.parseTaskUpdate(
                        fromInputJSON: toolUse.inputJSON
                    ) else { continue }
                    if var existing = taskRegistryById[update.taskId] {
                        let newStatus = update.status ?? existing.status
                        let newContent = update.subject ?? existing.content
                        let newActiveForm = update.activeForm ?? existing.activeForm
                        existing = TodoItem(
                            id: existing.id,
                            content: newContent,
                            activeForm: newActiveForm,
                            status: newStatus
                        )
                        taskRegistryById[update.taskId] = existing
                        rebuildTodosFromRegistry()
                    } else if let subject = update.subject {
                        // Update for a task we never saw the create
                        // for (e.g. session resumed mid-flow). Seed it.
                        taskRegistryById[update.taskId] = TodoItem(
                            id: update.taskId,
                            content: subject,
                            activeForm: update.activeForm,
                            status: update.status ?? "pending"
                        )
                        rebuildTodosFromRegistry()
                    }
                default:
                    break
                }
            }
            // Stream-json sometimes splits a single assistant response
            // across several events that share the same `message.id`.
            // `enqueueStreamedMessage` folds consecutive assistant
            // chunks with matching `claudeMessageId` into one
            // `ChatMessage` (in-buffer or via whole-element replacement
            // at flush time — both are safe under `@Published`;
            // `messages[i].blocks.append(…)` would NOT be, since that
            // mutation trips SwiftUI's reentrant-layout guard mid-
            // render). Net effect: one bubble per assistant response,
            // not one bubble per NDJSON event.
            enqueueStreamedMessage(ChatMessage(
                role: .assistant,
                blocks: blocks,
                claudeMessageId: claudeMid
            ))
        case .user(let blocks):
            guard !blocks.isEmpty else { return }
            // Synthetic user messages from claude are mostly tool_result
            // wrappers. Stash those in `toolResultsByToolUseId` so the
            // matching `ToolUseCard` can render them inline; only append a
            // user-row message if there are non-result blocks left over.
            var passthrough: [ChatMessageBlock] = []
            for block in blocks {
                switch block {
                case .toolResult(let result):
                    enqueueStreamedToolResult(result)
                    // Claude Code 2.x TaskCreate: the harness reports
                    // the assigned task id inside the tool_result body
                    // as `Task #<id> created successfully: …`. When we
                    // find a match for a pending TaskCreate, fold it
                    // into the live registry.
                    if let pending = pendingTaskCreates.removeValue(forKey: result.toolUseId),
                       let realId = Self.parseTaskCreateResultId(fromContent: result.content) {
                        taskRegistryById[realId] = TodoItem(
                            id: realId,
                            content: pending.subject,
                            activeForm: pending.activeForm,
                            status: "pending"
                        )
                        rebuildTodosFromRegistry()
                    }
                    // EnterWorktree confirmation: only apply the cwd
                    // change when the tool actually succeeded. If the
                    // tool_use never made it (failed path, denied, etc.)
                    // the entry is silently dropped.
                    if let pendingPath = pendingEnterWorktreeByToolUseId.removeValue(forKey: result.toolUseId),
                       !result.isError {
                        updateWorkingDirectory(pendingPath)
                    }
                    // Background-shell bookkeeping: a Bash tool_result
                    // carries the shell_id (and sometimes an exit
                    // status); a KillShell tool_result confirms the
                    // matching shell was terminated.
                    noteBackgroundShellResult(result)
                default:
                    // After a `--resume`, background-shell exits that happened
                    // while the process was down are replayed as `.user` text
                    // (`<task-notification>`), not as a `system/task_notification`
                    // event. Reconcile those for shell status and drop them
                    // rather than rendering the raw XML as a chat bubble.
                    if case .text(let value) = block, value.contains("<task-notification>") {
                        applyTaskNotifications(inText: value)
                    } else {
                        passthrough.append(block)
                    }
                }
            }
            if !passthrough.isEmpty {
                // These come from the stream (typically claude's
                // expansion of a slash command), not from the human
                // typing in the input — collapse by default so the
                // transcript stays readable.
                enqueueStreamedMessage(ChatMessage(
                    role: .user,
                    blocks: passthrough,
                    isCollapsedByDefault: true
                ))
            }
        case .result(let isError, let sid, let errorMessage, _, _):
            if let sid, !sid.isEmpty, sessionId != sid {
                sessionId = sid
            }
            // Persist a checkpoint for this turn so the user can rewind
            // to it later (along with all the others piled up).
            if let staging = pendingTurnStaging, let activeSid = sessionId {
                let backups = ClaudeSessionHistory.latestTurnBackups(
                    sessionId: activeSid,
                    cwd: sessionCwd
                )
                undoCheckpoints.append(RewindCheckpoint(
                    userMessageId: staging.userMessageId,
                    userMessageIndex: staging.userMessageIndex,
                    backups: backups
                ))
                pendingTurnStaging = nil
            }
            // The turn just finished. Drain any pending streamed chunks
            // so the transcript settles before we flip status, then move
            // the panel back to idle (or surface the error). The claude
            // process itself stays alive — the next turn reuses it via
            // stdin.
            flushStreamedMessages()
            if isError && pendingCancel {
                // The user stopped this turn — the CLI's `is_error` result is
                // the expected fallout of the interrupt, not a real failure.
                // Settle quietly back to idle without an error banner.
                status = .idle
            } else if isError {
                let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let message, !message.isEmpty {
                    status = .error(message)
                    let prefix = String(
                        localized: "claudeChat.errorMessage.prefix",
                        defaultValue: "**Error:**"
                    )
                    messages.append(.text(.system, "\(prefix) \(message)"))
                } else {
                    status = .error(String(
                        localized: "claudeChat.errorMessage.unknown",
                        defaultValue: "Claude reported an error."
                    ))
                }
            } else if case .error = status {
                // Keep the previous error chrome visible.
            } else {
                status = .idle
            }
            drainPendingDraftIfAny()
            refreshStatusLine()
        case .backgroundTask(let phase, let taskId, let toolUseId, let taskType, let status, let exitCode, _, let description):
            applyBackgroundTaskEvent(
                phase: phase,
                taskId: taskId,
                toolUseId: toolUseId,
                taskType: taskType,
                status: status,
                exitCode: exitCode,
                description: description
            )
        case .other:
            break
        }
    }

    /// Update `backgroundShells` from a `task_started` / `task_updated` /
    /// `task_notification` event. These are the only reliable signal we
    /// get for "the shell finished" — the original Bash `tool_result`
    /// just reports "Command running in background" and never updates
    /// when the actual process exits.
    /// Internal rather than private so the tests can drive it directly with
    /// the exact event shapes seen on the wire.
    func applyBackgroundTaskEvent(
        phase: BackgroundTaskPhase,
        taskId: String,
        toolUseId: String?,
        taskType: String?,
        status: String?,
        exitCode: String?,
        description: String? = nil
    ) {
        guard !taskId.isEmpty else { return }
        // Only background shells flow through `backgroundShells`. Other
        // task types (e.g. subagents) reuse the same event family but
        // belong to other UI surfaces.
        if let taskType, !taskType.isEmpty, taskType != "local_bash" {
            return
        }
        // Find the matching row. Prefer the tool_use_id (set on
        // task_started + task_notification); fall back to task_id ==
        // shell_id (set after we already saw the started event).
        let matchedIndex: Int? = {
            if let toolUseId, !toolUseId.isEmpty,
               let i = backgroundShells.firstIndex(where: { $0.toolUseId == toolUseId }) {
                return i
            }
            return backgroundShells.firstIndex(where: { $0.shellId == taskId })
        }()
        guard let index = matchedIndex else {
            // No matching row. This is the normal path, not an edge case:
            // claude stopped setting `run_in_background` on the Bash input
            // and now moves commands to the background on its own, so
            // `noteBashToolUseIfBackground` never sees them and these events
            // are the first we hear of the shell. It also covers the original
            // case — a `--resume` where we missed the `assistant` tool_use.
            //
            // Synthesise the row on any phase: a `task_notification` can be
            // the first event we match, and dropping it would leave a shell
            // that already exited showing as live.
            let resolved = resolveBackgroundShellStatus(rawStatus: status, exitCode: exitCode)
            let initialStatus: BackgroundShell.Status = {
                if case .set(let value) = resolved { return value }
                return phase == .started ? .running : .unknown
            }()
            let preview = backgroundShellPreview(toolUseId: toolUseId, description: description, taskId: taskId)
            backgroundShells.append(BackgroundShell(
                toolUseId: toolUseId ?? "task:\(taskId)",
                shellId: taskId,
                commandPreview: preview.text,
                startedAt: Date(),
                status: initialStatus,
                kind: preview.kind
            ))
            return
        }
        // A later event can carry a better name than the one we settled on
        // (the tool_use may have streamed in after `task_started`), so keep
        // upgrading the placeholder until we have something real.
        if backgroundShells[index].commandPreview == Self.anonymousShellPreview(taskId: taskId) {
            let preview = backgroundShellPreview(toolUseId: toolUseId, description: description, taskId: taskId)
            backgroundShells[index].commandPreview = preview.text
            backgroundShells[index].kind = preview.kind
        }
        if backgroundShells[index].shellId == nil {
            backgroundShells[index].shellId = taskId
        }
        let resolved = resolveBackgroundShellStatus(rawStatus: status, exitCode: exitCode)
        if case .set(let newStatus) = resolved {
            backgroundShells[index].status = newStatus
        }
    }

    /// Name for a shell we learned about from a `task_*` event, best source
    /// first: the real command from the originating `Bash` tool_use, then the
    /// harness' own `description` ("Fast-forward de dev, tag 5.32.1 y push"),
    /// then an anonymous placeholder. Only the last one is useless to read,
    /// and it is now genuinely the last resort.
    private func backgroundShellPreview(
        toolUseId: String?,
        description: String?,
        taskId: String
    ) -> (text: String, kind: BackgroundShell.Kind) {
        if let command = bashCommand(forToolUseId: toolUseId), !command.isEmpty {
            let kind = Self.classifyBackgroundCommand(command)
            return (Self.backgroundCommandPreview(command, kind: kind), kind)
        }
        if let description, !description.isEmpty {
            return (description, .userCommand)
        }
        return (Self.anonymousShellPreview(taskId: taskId), .userCommand)
    }

    /// The command of a `Bash` tool_use already in the transcript. The events
    /// arrive interleaved with the `assistant` message that carries it, so by
    /// the time `task_started` lands the block is usually there.
    private func bashCommand(forToolUseId toolUseId: String?) -> String? {
        guard let toolUseId, !toolUseId.isEmpty else { return nil }
        for message in messages.reversed() {
            for block in message.blocks {
                guard case .toolUse(let toolUse) = block,
                      toolUse.id == toolUseId,
                      toolUse.name == "Bash",
                      let input = parseJSONObject(toolUse.inputJSON),
                      let command = input["command"] as? String
                else { continue }
                return command.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func anonymousShellPreview(taskId: String) -> String {
        String(
            format: String(
                localized: "claudeChat.bashes.unknownCommand",
                defaultValue: "(background shell %@)"
            ),
            taskId
        )
    }

    private enum BackgroundShellStatusResolution {
        case keep
        case set(BackgroundShell.Status)
    }

    private func resolveBackgroundShellStatus(rawStatus: String?, exitCode: String?) -> BackgroundShellStatusResolution {
        guard let lowered = rawStatus?.lowercased(), !lowered.isEmpty else {
            return .keep
        }
        switch lowered {
        case "running", "started", "in_progress":
            return .set(.running)
        case "completed", "done", "exited", "finished":
            return .set(.completed(exitCode: exitCode))
        case "killed", "cancelled", "canceled", "terminated":
            return .set(.killed)
        case "failed", "error":
            return .set(.completed(exitCode: exitCode ?? "error"))
        default:
            return .keep
        }
    }

    /// Parse the `<task-notification>` blocks the harness injects when a
    /// background shell changes state. These arrive as the `.text` of a
    /// `role: .user` message (both live after a `--resume` and persisted in the
    /// transcript JSONL), and carry the only reliable terminal signal
    /// (`<status>completed|failed|killed</status>`). A single text can contain
    /// several notifications. Returns them verbatim for `applyBackgroundTaskEvent`.
    static func parseTaskNotifications(
        in text: String
    ) -> [(taskId: String, toolUseId: String?, status: String, exitCode: String?)] {
        guard text.contains("<task-notification>") else { return [] }
        guard let blockRegex = try? NSRegularExpression(
            pattern: "<task-notification>(.*?)</task-notification>",
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let ns = text as NSString
        var out: [(taskId: String, toolUseId: String?, status: String, exitCode: String?)] = []
        for match in blockRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let block = ns.substring(with: match.range(at: 1))
            guard let taskId = Self.firstRegexCapture(#"<task-id>\s*([^<\s]+)"#, in: block),
                  let status = Self.firstRegexCapture(#"<status>\s*([^<\s]+)"#, in: block) else {
                continue
            }
            out.append((
                taskId: taskId,
                toolUseId: Self.firstRegexCapture(#"<tool-use-id>\s*([^<\s]+)"#, in: block),
                status: status,
                exitCode: Self.firstRegexCapture(#"(?i)exit\s*code\s*[:=]?\s*(-?\d+)"#, in: block)
            ))
        }
        return out
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    /// Feed every `<task-notification>` in `text` through the same
    /// `applyBackgroundTaskEvent` path the live `system/task_notification`
    /// event uses, so the matching shell (by tool-use-id, else task-id ==
    /// shell-id) picks up its terminal status.
    private func applyTaskNotifications(inText text: String) {
        for note in Self.parseTaskNotifications(in: text) {
            applyBackgroundTaskEvent(
                phase: .notification,
                taskId: note.taskId,
                toolUseId: note.toolUseId,
                taskType: nil,
                status: note.status,
                exitCode: note.exitCode
            )
        }
    }

    /// Fired when the persistent `claude` process exits. On a clean
    /// shutdown (we called `runner.terminate()`) this is a no-op. On a
    /// crash or unexpected exit we surface the failure so the user
    /// notices something went wrong; the next prompt will respawn
    /// `claude` via `ensureStarted`, picking the session back up with
    /// `--resume`.
    private func handle(processExit: Result<Void, Error>) {
        flushStreamedMessages()
        switch processExit {
        case .success:
            // Clean exit (terminate, clearTranscript, panel close).
            if case .sending = status {
                status = .idle
            }
        case .failure(let error):
            if pendingCancel {
                // The user stopped the turn and the SIGINT fallback (used
                // only when the graceful interrupt couldn't be written)
                // killed the process with a non-zero exit. That's the
                // requested interruption, not a crash — go back to idle
                // without an error banner. The next turn respawns the
                // process automatically via `--resume`.
                if case .sending = status {
                    status = .idle
                }
                drainPendingDraftIfAny()
                break
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .error(message)
            let prefix = String(
                localized: "claudeChat.errorMessage.prefix",
                defaultValue: "**Error:**"
            )
            messages.append(.text(.system, "\(prefix) \(message)"))
            drainPendingDraftIfAny()
        }
        refreshStatusLine()
    }

    /// If the user piled up follow-up messages while the previous turn was
    /// running, pop the oldest one and start its turn. Called after every
    /// successful completion; no-op when the queue is empty.
    private func drainPendingDraftIfAny() {
        guard !pendingDrafts.isEmpty else { return }
        let next = pendingDrafts.removeFirst()
        dispatchTurn(messageId: next.id, userText: next.userText)
    }

    /// Drop a queued follow-up message that has not been dispatched yet.
    /// Removes both the `PendingDraft` and the placeholder `ChatMessage`
    /// the transcript was rendering as the dimmed "queued" bubble, so the
    /// user sees the prompt disappear in one step. No-op if `id` is not
    /// in the queue (already drained, or never matched a draft).
    func cancelPendingDraft(id: UUID) {
        guard pendingDrafts.contains(where: { $0.id == id }) else { return }
        pendingDrafts.removeAll { $0.id == id }
        messages.removeAll { $0.id == id }
    }

    /// Resolve `statusLine.command` from settings.json (project +
    /// user) and update `statusLineText` with its stdout. Runs the
    /// shell command off the main actor so a slow script does not
    /// block UI; the @Published assignment hops back to main.
    func refreshStatusLine() {
        let cwd = workingDirectory
        let info = StatusLineRunner.SessionInfo(
            sessionId: sessionId,
            transcriptPath: nil,
            cwd: cwd,
            modelId: modelName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        )
        Task.detached { [weak self] in
            guard let cfg = StatusLineRunner.loadConfig(cwd: cwd) else {
                await MainActor.run { [weak self] in self?.statusLineText = nil }
                return
            }
            let text = StatusLineRunner.run(config: cfg, info: info, userPATH: nil)
            await MainActor.run { [weak self] in self?.statusLineText = text }
        }
    }

    /// Recalcula `gitPendingSummary` ejecutando `git status --porcelain=v2
    /// --branch -z` y `git stash list -z` off-main sobre `workingDirectory`.
    /// El asterisco original solo decía "hay cambios"; este resumen describe
    /// *qué* hay pendiente (ahead/behind/staged/modified/untracked/stashed)
    /// para que el chip debajo del status line sea informativo.
    ///
    /// Se llama desde `updateGitBranchState` (cada vez que el workspace probe
    /// completa por evento del FS watcher) y desde `updateWorkingDirectory`.
    /// Aplicamos un debounce de 300 ms para que ráfagas (`npm install`,
    /// build, edición masiva por agente) coalesce en una única ejecución de
    /// `git status` cuando se calma la actividad.
    func refreshGitPendingSummary() {
        gitPendingSummaryRefreshTask?.cancel()
        let cwd = workingDirectory
        let hasBranch = gitBranchState != nil
        gitPendingSummaryRefreshTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let summary: GitPendingSummary? = hasBranch
                ? GitPendingSummary.compute(workingDirectory: cwd)
                : nil
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.gitPendingSummary != summary else { return }
                self.gitPendingSummary = summary
            }
        }
    }

    // MARK: - ChatMcpHttpServerDelegate

    func server(
        _ server: ChatMcpHttpServer,
        didReceiveApproval request: ChatApprovalRequest,
        completion: @escaping (ChatApprovalResponse) -> Void
    ) {
        // 0a. Auto mode short-circuit. The user may have flipped the
        //     picker to `.auto` after the in-flight claude was launched
        //     with a different `--permission-mode`; honour the live
        //     setting so the change takes effect without restarting
        //     the turn — same UX as Claude Code 2.x's Auto mode.
        if permissionMode == .auto {
            completion(.allow)
            return
        }
        // 0b. Auto-allow cmux's own MCP tools. Claude should not need to
        //     ask permission to use the very mechanism we exposed for it
        //     (asking the user a question, etc.). Without this, every call
        //     to `mcp__cmux__ask_user_question` first surfaces an approval
        //     card — the user has to click Allow before the actual question
        //     even appears, which feels like claude is hanging.
        if request.toolName.hasPrefix("mcp__cmux__") {
            completion(.allow)
            return
        }

        // 1. In-session "Allow always" by tool name.
        if alwaysAllowedTools.contains(request.toolName) {
            completion(.allow)
            return
        }

        // 2. `.claude/settings.local.json` / `.claude/settings.json` rules.
        let rules = loadPermissionRulesIfNeeded()
        let parsedInput = parseInput(request.inputJSON)
        switch rules.decide(toolName: request.toolName, input: parsedInput) {
        case .allow:
            completion(.allow)
            return
        case .deny:
            completion(.deny(reason: "Denied by .claude/settings permissions.deny rule."))
            return
        case .ask:
            break
        }

        // Dedupe by content: if a pending card has the same toolName +
        // inputJSON, treat the new request as a follower of the primary
        // one. Store its resolver so we can answer claude's duplicate
        // call with the same response when the user clicks Allow/Deny
        // once, but don't surface a second card.
        let dedupeKeys = pendingApprovals.map { approval in
            ChatApprovalDedupePolicy.PendingApprovalKey(
                id: approval.id,
                toolName: approval.toolName,
                inputJSON: approval.inputJSON
            )
        }
        switch ChatApprovalDedupePolicy.decide(
            incomingToolName: request.toolName,
            incomingInputJSON: request.inputJSON,
            pendingApprovals: dedupeKeys
        ) {
        case .followsExisting(let primaryID):
            approvalResolvers[request.id] = completion
            approvalDedupeAliases[primaryID, default: []].append(request.id)
        case .newPrimary:
            approvalResolvers[request.id] = completion
            pendingApprovals.append(request)
        }
    }

    private func parseInput(_ inputJSON: String) -> [String: Any] {
        guard let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Reload `.claude/settings*.json` if the cwd changed or any of the
    /// candidate files mtime drifted since the last cache fill.
    private func loadPermissionRulesIfNeeded() -> ChatPermissionRules {
        let cwd = workingDirectory
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let candidatePaths: [String] = [
            (cwd as NSString).appendingPathComponent(".claude/settings.local.json"),
            (cwd as NSString).appendingPathComponent(".claude/settings.json"),
            homeURL.appendingPathComponent(".claude/settings.json").path
        ]
        let currentMtimes: [String: Date] = candidatePaths.reduce(into: [:]) { acc, path in
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date {
                acc[path] = date
            }
        }
        if cachedRulesCwd == cwd, currentMtimes == cachedRulesMtimes {
            return cachedRules
        }
        cachedRulesCwd = cwd
        cachedRulesMtimes = currentMtimes
        cachedRules = ChatPermissionRules.load(workingDirectory: cwd)
        return cachedRules
    }

    func server(
        _ server: ChatMcpHttpServer,
        didReceiveQuestion request: ChatUserQuestionRequest,
        completion: @escaping (ChatUserQuestionResponse) -> Void
    ) {
        // Dedupe: if claude is re-firing the same content while the
        // first call is still pending, alias the new id onto the
        // existing one and don't add another bubble to the UI.
        if let existing = pendingQuestions.first(where: { Self.sameContent($0, request) }) {
            questionResolvers[request.id] = completion
            questionDedupeAliases[existing.id, default: []].append(request.id)
            return
        }
        questionResolvers[request.id] = completion
        pendingQuestions.append(request)
    }

    func server(
        _ server: ChatMcpHttpServer,
        didReceiveSetCwd path: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            completion(.failure(NSError(
                domain: "ChatMcpHttpServer.setCwd",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Path does not exist or is not a directory: \(path)"]
            )))
            return
        }
        updateWorkingDirectory(path)
        completion(.success(path))
    }

    /// Two question requests are considered "duplicates" when their
    /// sub-question payload (header + question text + options) matches
    /// exactly. Ids and the wrapping request id are ignored — claude
    /// generates a fresh `tool_use_id` every time, so identity won't
    /// help us spot retries.
    private static func sameContent(
        _ a: ChatUserQuestionRequest,
        _ b: ChatUserQuestionRequest
    ) -> Bool {
        guard a.questions.count == b.questions.count else { return false }
        for (lhs, rhs) in zip(a.questions, b.questions) {
            if lhs.header != rhs.header { return false }
            if lhs.question != rhs.question { return false }
            if lhs.multiSelect != rhs.multiSelect { return false }
            if lhs.options.map({ $0.label }) != rhs.options.map({ $0.label }) {
                return false
            }
        }
        return true
    }

    // MARK: - Welcome content

    /// Appended to claude's system prompt when running in `.allowDeny` mode
    /// so the model knows about the cmux MCP tools and is encouraged to use
    /// `ask_user_question` instead of asking ambiguous follow-ups in plain
    /// text. The signature mirrors Claude Code's built-in AskUserQuestion
    /// (the cmux build disables that built-in so this is the only path).
    static let cmuxToolsSystemPrompt: String = """
    You are running inside the cmux Claude Chat panel — a headless host that \
    cannot render the standard Claude Code interactive widgets.

    CRITICAL: DO NOT call any tool whose name is exactly `AskUserQuestion` \
    (Claude Code's built-in interactive question widget). It is non-functional \
    here — the user cannot answer it and the call will be silently cancelled. \
    INSTEAD, use the cmux-provided MCP tool described below.

    `mcp__cmux__ask_user_question` — present one or more multiple-choice \
    questions to the user in a single tool call. Argument:
      - `questions`: array (1-4 items) of objects:
          - `header`: very short label, max ~12 chars (e.g. "Auth method", "Library")
          - `question`: full question text ending with a question mark
          - `options`: array (2-4 items) of `{label: string, description?: string}` — \
            distinct, mutually exclusive choices
          - `multiSelect`: optional boolean, default false

    The reply comes back as JSON: `{"answers": [{"selected": [<labels>]}, ...]}` \
    in the same order as `questions[]`. An empty `selected` array means the \
    user dismissed without choosing.

    GUIDELINES:
    - Whenever you need to disambiguate intent, choose between approaches, \
    or get a quick decision from the user, ALWAYS call \
    `mcp__cmux__ask_user_question`. Never fall back to `AskUserQuestion` and \
    never ask multiple-choice questions in plain text when this tool is \
    available.
    - Keep `header` short and `label` concise (1-5 words). Add a one-line \
    `description` when the choice has trade-offs.
    - Group related sub-questions into one call when it's natural; otherwise \
    one question is fine.
    - Skip the tool for trivial yes/no when a yes/no answer is obvious.

    `mcp__cmux__set_cwd` — notify cmux that your effective working \
    directory changed. Arguments: `{ "path": "<absolute path>" }`. The \
    response is `{"ok": true, "path": "..."}` on success or `{"ok": false, \
    "error": "..."}` if cmux rejected it (e.g. path does not exist).

    CWD GUIDELINES:
    - Call `mcp__cmux__set_cwd` with an absolute path whenever your \
    effective working directory changes — after `EnterWorktree`, \
    `ExitWorktree`, or any other tool that swaps your cwd. The chat \
    header path and the git branch chip are driven by what you report \
    here; if you skip the call they stay stale.
    - The call is idempotent: cmux ignores duplicates of the current \
    cwd, so it is safe to call defensively after any tool that might \
    have changed your cwd.
    - Always pass an absolute path. Relative paths are rejected.
    """

    /// Resumen de cambios git pendientes en el directorio del panel. Lo
    /// renderiza la fila debajo del status line en `ClaudeChatPanelView`,
    /// sustituyendo el viejo asterisco `*` del header por una descripción
    /// concreta del trabajo sin commitear/empujar/bajar/stashear.
    struct GitPendingSummary: Equatable {
        /// Commits locales que tu branch tiene por encima de su upstream
        /// (pendientes de `git push`). `nil` cuando no hay upstream.
        var ahead: Int?
        /// Commits del upstream que tu branch no tiene aún
        /// (pendientes de `git pull`). `nil` cuando no hay upstream.
        var behind: Int?
        /// Cambios staged listos para commit.
        var staged: Int
        /// Cambios trackeados modificados pero no staged.
        var modified: Int
        /// Ficheros con conflictos de merge.
        var conflicted: Int
        /// Ficheros nuevos no trackeados.
        var untracked: Int
        /// Entradas en `git stash list`.
        var stashed: Int

        var isEmpty: Bool {
            (ahead ?? 0) == 0 && (behind ?? 0) == 0
                && staged == 0 && modified == 0 && conflicted == 0
                && untracked == 0 && stashed == 0
        }

        /// Ejecuta git en `workingDirectory` y parsea el resultado. Vuelve
        /// `nil` si el directorio no es un repo o git falla. Llamar siempre
        /// off-main: hace I/O bloqueante.
        nonisolated static func compute(workingDirectory: String) -> GitPendingSummary? {
            let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let statusOutput = runGit(
                in: trimmed,
                arguments: ["status", "--porcelain=v2", "--branch", "-z"]
            ) else { return nil }

            var ahead: Int? = nil
            var behind: Int? = nil
            var staged = 0
            var modified = 0
            var conflicted = 0
            var untracked = 0

            // `-z` separa entradas con NUL. Las cabeceras `# branch.*`
            // ocupan una entrada cada una; los registros de rename usan
            // dos entradas (record + orig path).
            let entries = statusOutput.split(separator: "\0", omittingEmptySubsequences: false)
            var index = 0
            while index < entries.count {
                let entry = entries[index]
                if entry.isEmpty {
                    index += 1
                    continue
                }
                if entry.hasPrefix("# branch.ab ") {
                    // Formato: "# branch.ab +<ahead> -<behind>"
                    let parts = entry.dropFirst("# branch.ab ".count)
                        .split(separator: " ")
                    if parts.count == 2,
                       let a = Int(parts[0].dropFirst()),
                       let b = Int(parts[1].dropFirst()) {
                        ahead = a
                        behind = b
                    }
                    index += 1
                    continue
                }
                if entry.hasPrefix("# ") {
                    index += 1
                    continue
                }
                // Registros: "1"/"2" = trackeado, "u" = unmerged, "?" =
                // untracked. Para "1" y "2" el segundo campo es "XY"
                // (X=index, Y=worktree); "." significa "sin cambio".
                let head = entry.first!
                switch head {
                case "1", "2":
                    let fields = entry.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count >= 2 {
                        let xy = fields[1]
                        let x = xy.first ?? "."
                        let y = xy.dropFirst().first ?? "."
                        if x != "." { staged += 1 }
                        if y != "." { modified += 1 }
                    }
                    if head == "2" { index += 1 }
                case "u":
                    conflicted += 1
                case "?":
                    untracked += 1
                default:
                    break
                }
                index += 1
            }

            // `git stash list` es barato pero requiere otra invocación.
            var stashed = 0
            if let stashOutput = runGit(in: trimmed, arguments: ["stash", "list", "-z"]) {
                stashed = stashOutput.split(separator: "\0", omittingEmptySubsequences: true).count
            }

            return GitPendingSummary(
                ahead: ahead,
                behind: behind,
                staged: staged,
                modified: modified,
                conflicted: conflicted,
                untracked: untracked,
                stashed: stashed
            )
        }

        private nonisolated static func runGit(
            in directory: String,
            arguments: [String]
        ) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return String(data: data, encoding: .utf8)
            } catch {
                return nil
            }
        }
    }

    nonisolated static func welcomeMessages() -> [ChatMessage] {
        [
            ChatMessage.text(
                .assistant,
                String(
                    localized: "claudeChat.welcome.message",
                    defaultValue: """
                        # Welcome to the Claude Chat tab

                        This tab spawns `claude -p --output-format stream-json` per turn. \
                        Type a message below — tool use is auto-allowed for now \
                        (phase 3 of the MVP will replace this with inline allow/deny).
                        """
                )
            )
        ]
    }
}

/// Persistent + per-panel body font size for the agent chat, mirroring
/// `MarkdownFontSizeSettings`. The value is the chat message body size in
/// points; Cmd-+/Cmd-- adjust the focused panel and persist the default so it
/// is remembered across panels and sessions.
enum ChatFontSizeSettings {
    /// UserDefaults / cmux.json key (`claudeChat.fontSize`).
    static let key = "claudeChat.fontSize"
    static let defaultPointSize: Double = 13
    static let minimumPointSize: Double = 9
    static let maximumPointSize: Double = 28
    static let stepPointSize: Double = 1

    /// Clamps a requested point size into the supported range.
    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumPointSize), maximumPointSize)
    }

    /// The persistent default point size, honoring `claudeChat.fontSize` from
    /// UserDefaults / cmux.json and falling back to ``defaultPointSize``.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultPointSize
        }
        return clamp(raw.doubleValue)
    }

    /// Persists `points` (clamped, rounded to integer points) as the default
    /// `claudeChat.fontSize` so new/reopened panels start at this size.
    static func setDefault(_ points: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(points).rounded()), forKey: key)
    }
}
