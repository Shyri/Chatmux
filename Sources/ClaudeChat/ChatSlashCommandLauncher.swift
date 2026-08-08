import Foundation

/// One path for "run `/<name> <args>` in a chat", shared by every entrypoint
/// that offers it: the composer's own submit, the autocomplete popup, and
/// context menus elsewhere in the app that start a task from an object they
/// already have (the GitLab issues sidebar).
///
/// The expansion has to happen on this side. Headless `claude -p` is handed a
/// prompt, never a `/<name>` line, so it never runs a custom command's
/// markdown body — cmux reads the file, substitutes the argument
/// placeholders, and forwards the result as the prompt.
enum ChatSlashCommandLauncher {
    struct Expansion: Equatable {
        /// What the collapsed transcript row shows: `start-task 4529`,
        /// rendered as `/start-task 4529`.
        let displayName: String
        /// The prompt actually handed to claude.
        let text: String
    }

    /// Expand a command already resolved by the caller (the autocomplete
    /// popup has one in hand and should not re-scan the filesystem).
    /// Returns `nil` for commands with no readable body — built-ins,
    /// CLI-reported ones, and empty files — so callers can fall back to
    /// their previous behaviour instead of sending an empty prompt.
    static func expansion(command: SlashCommand, arguments: String) -> Expansion? {
        let body = SlashCommandRegistry.readBody(of: command)
        guard !body.isEmpty else { return nil }
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return Expansion(
            displayName: args.isEmpty ? command.name : "\(command.name) \(args)",
            text: SlashCommandRegistry.expand(body: body, arguments: args)
        )
    }

    /// Resolve `/<name> <arguments>` against the commands visible from `cwd`.
    static func expansion(name: String, arguments: String, cwd: String?) -> Expansion? {
        guard let command = SlashCommandRegistry.command(named: name, cwd: cwd) else { return nil }
        return expansion(command: command, arguments: arguments)
    }

    struct Invocation: Equatable {
        let name: String
        let arguments: String
    }

    /// Split a submitted draft into command name + arguments, when it looks
    /// like a slash-command invocation that carries arguments.
    ///
    /// Returns `nil` for anything that is not one, including a draft that
    /// merely opens with an absolute path (`/Users/me/notes.txt — read this`):
    /// a command name never contains a slash.
    static func parse(draft: String) -> Invocation? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let name = String(body[..<space])
        let arguments = String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !arguments.isEmpty else { return nil }
        return Invocation(name: name, arguments: arguments)
    }

    /// Open a new chat tab in the selected workspace and run the command in
    /// it. Returns `false` when there is no workspace to open into.
    ///
    /// When the command cannot be expanded — no such file, or an empty one —
    /// the chat still opens with the invocation left in the composer, so the
    /// user sees what was attempted instead of an empty chat or a prompt
    /// claude cannot act on.
    @MainActor
    @discardableResult
    static func openChat(
        running name: String,
        arguments: String,
        workingDirectory: String?,
        tabManager: TabManager
    ) -> Bool {
        guard let panel = tabManager.openClaudeChatPanel(workingDirectory: workingDirectory) else {
            return false
        }
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expansion = expansion(name: name, arguments: args, cwd: panel.workingDirectory) else {
            panel.draft = args.isEmpty ? "/\(name)" : "/\(name) \(args)"
            return true
        }
        panel.sendSlashCommand(name: expansion.displayName, expandedText: expansion.text)
        return true
    }
}
