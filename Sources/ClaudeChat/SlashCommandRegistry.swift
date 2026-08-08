import Foundation

/// A slash command that can be autocompleted in the chat input.
///
/// Two flavors live side by side:
/// - **Built-in**: cmux-side actions (clear transcript, rewind, etc.) that
///   never leave the app.
/// - **Custom**: markdown files under `~/.claude/commands/` (user) or
///   `<cwd>/.claude/commands/` (project), which Claude Code itself
///   exposes as `/<filename>`. cmux gives them the same autocomplete
///   surface and expands them locally — reading the `.md` body and
///   substituting the argument placeholders — because headless
///   `claude -p` is handed a prompt, not a `/<name>` line, and so never
///   runs the expansion itself.
struct SlashCommand: Identifiable, Equatable {
    enum Source: Equatable {
        case builtin
        /// Markdown command file under the user's home (`~/.claude/commands/`).
        case userCustom(URL)
        /// Markdown command file under the current project (`<cwd>/.claude/commands/`).
        case projectCustom(URL)
        /// Reported by the CLI in the `system/init` event's `slash_commands`
        /// array and backed by no file we can see: skills, plugin commands,
        /// and the CLI's own built-ins (`/compact`, `/context`, `/usage`…).
        /// Scanning `.claude/commands/` can never find these.
        case cliReported
    }

    enum Action: Equatable {
        /// Run a cmux-internal action when the user picks this command.
        /// The associated string is just an opaque key the panel switches
        /// on — closures don't survive `Equatable`, so we look the action
        /// up by key at dispatch time.
        case runBuiltin(String)
        /// Send the literal text (e.g. `/foo arg`) to claude as the prompt.
        case sendAsPrompt
    }

    /// The `/`-less command name (e.g. `clear`, `rewind`, `permissions`).
    let name: String
    /// One-line description shown in the dropdown row under the name.
    let description: String
    let source: Source
    let action: Action

    var id: String {
        switch source {
        case .builtin: return "builtin:\(name)"
        case .userCustom(let url): return "user:\(url.path)"
        case .projectCustom(let url): return "project:\(url.path)"
        case .cliReported: return "cli:\(name)"
        }
    }

    /// What the user sees in the dropdown title row.
    var displayTitle: String { "/\(name)" }
}

enum SlashCommandRegistry {
    /// Return the full list of commands available given the current chat
    /// `cwd`. Built-ins come first, then project-scope custom commands,
    /// then user-scope custom commands, then anything the CLI reported that
    /// we couldn't find on disk. Within each group, alphabetical.
    ///
    /// `reportedByCLI` is the `slash_commands` array from the last
    /// `system/init` event. It is the CLI's own authoritative list and is
    /// much wider than a directory scan can be — it includes skills, plugin
    /// commands and the CLI's built-ins (`/compact`, `/context`, `/usage`),
    /// none of which exist as `.md` files under `.claude/commands/`.
    ///
    /// It is merged rather than substituted because it only arrives once a
    /// process has started: the scan keeps autocomplete working from the
    /// first keystroke, and it carries the descriptions read from each
    /// file's frontmatter, which the init event does not provide.
    static func availableCommands(cwd: String?, reportedByCLI: [String] = []) -> [SlashCommand] {
        var out = builtinCommands
        if let cwd, !cwd.isEmpty {
            let projectDir = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            out.append(contentsOf: customCommands(in: projectDir, sourceForURL: { .projectCustom($0) }))
        }
        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
        out.append(contentsOf: customCommands(in: userDir, sourceForURL: { .userCustom($0) }))
        out.append(contentsOf: cliReportedCommands(reportedByCLI, alreadyListed: out))
        return out
    }

    /// Turn the init event's `slash_commands` names into commands, dropping
    /// the ones we already have (a file scan wins: it carries a real
    /// description) and the ones that aren't meant to be typed by a user.
    private static func cliReportedCommands(
        _ names: [String],
        alreadyListed: [SlashCommand]
    ) -> [SlashCommand] {
        guard !names.isEmpty else { return [] }
        let known = Set(alreadyListed.map(\.name))
        let description = String(
            localized: "claudeChat.slash.cliReported.desc",
            defaultValue: "Claude Code command"
        )
        return names
            .filter { !known.contains($0) && isUserFacing($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map {
                SlashCommand(
                    name: $0,
                    description: description,
                    source: .cliReported,
                    action: .sendAsPrompt
                )
            }
    }

    /// Internal plumbing the CLI lists but nobody should be offered:
    /// double-underscore entries are harness-internal, and these two are
    /// diagnostics/orchestration rather than commands.
    private static let hiddenCLICommands: Set<String> = [
        "workflow-launch-exec",
        "heapdump",
    ]

    static func isUserFacing(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("__") && !hiddenCLICommands.contains(name)
    }

    /// Filter `commands` by a `/`-less prefix (case-insensitive). An empty
    /// prefix returns all commands (used right after the user types `/`).
    static func filter(_ commands: [SlashCommand], byPrefix prefix: String) -> [SlashCommand] {
        if prefix.isEmpty { return commands }
        let lowered = prefix.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(lowered) }
    }

    // MARK: - Built-in commands

    /// Stable keys for the built-in dispatch table. Kept as constants so
    /// the panel and the registry agree on the spelling.
    enum BuiltinKey {
        static let clear = "clear"
        static let rewind = "rewind"
        static let undo = "undo"
        static let permissions = "permissions"
        static let model = "model"
        static let help = "help"
        static let mcp = "mcp"
        static let bashes = "bashes"
    }

    static let builtinCommands: [SlashCommand] = [
        SlashCommand(
            name: "clear",
            description: String(
                localized: "claudeChat.slash.clear.desc",
                defaultValue: "Clear the chat transcript and start a fresh session"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.clear)
        ),
        SlashCommand(
            name: "rewind",
            description: String(
                localized: "claudeChat.slash.rewind.desc",
                defaultValue: "Rewind the conversation and restore files from the last turn"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.rewind)
        ),
        SlashCommand(
            name: "undo",
            description: String(
                localized: "claudeChat.slash.undo.desc",
                defaultValue: "Alias for /rewind"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.undo)
        ),
        SlashCommand(
            name: "model",
            description: String(
                localized: "claudeChat.slash.model.desc",
                defaultValue: "Show the active Claude model"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.model)
        ),
        SlashCommand(
            name: "permissions",
            description: String(
                localized: "claudeChat.slash.permissions.desc",
                defaultValue: "Open the always-allowed tools editor"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.permissions)
        ),
        SlashCommand(
            name: "help",
            description: String(
                localized: "claudeChat.slash.help.desc",
                defaultValue: "Show available slash commands"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.help)
        ),
        SlashCommand(
            name: "mcp",
            description: String(
                localized: "claudeChat.slash.mcp.desc",
                defaultValue: "Manage MCP servers — list, edit, and reconnect"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.mcp)
        ),
        SlashCommand(
            name: "bashes",
            description: String(
                localized: "claudeChat.slash.bashes.desc",
                defaultValue: "Show background bash shells and kill them"
            ),
            source: .builtin,
            action: .runBuiltin(BuiltinKey.bashes)
        ),
    ]

    // MARK: - Custom commands (filesystem)

    /// Scan `dir` for `*.md` files and turn each into a `SlashCommand`.
    /// Description is best-effort: prefer a YAML frontmatter
    /// `description:` line if present, otherwise the first non-empty,
    /// non-frontmatter line. Returns alphabetically sorted commands;
    /// silently returns `[]` if the directory does not exist.
    private static func customCommands(
        in dir: URL,
        sourceForURL: (URL) -> SlashCommand.Source
    ) -> [SlashCommand] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let mdFiles = entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return mdFiles.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let desc = readDescription(from: url)
            return SlashCommand(
                name: name,
                description: desc,
                source: sourceForURL(url),
                action: .sendAsPrompt
            )
        }
    }

    /// Read the body of a custom slash-command file (the prompt itself),
    /// stripping any leading YAML frontmatter (between the opening `---`
    /// and the closing `---`). Returns the trimmed body, or an empty
    /// string if the file is missing/unreadable.
    static func readBody(of command: SlashCommand) -> String {
        let url: URL
        switch command.source {
        // No file to read: built-ins run in-app, and CLI-reported commands
        // are expanded by claude itself when we forward the literal text.
        case .builtin, .cliReported: return ""
        case .userCustom(let u), .projectCustom(let u): url = u
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil
        // If the file starts with `---\n`, skip everything up to (and
        // including) the matching closing `---\n`. Otherwise return the
        // whole file.
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var idx = 1
        while idx < lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                let bodyLines = lines.dropFirst(idx + 1)
                return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            idx += 1
        }
        // No closing fence — treat the whole file as body to be safe.
        _ = scanner
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Look a command up by its `/`-less name. Only commands backed by a
    /// file can be resolved: built-ins run in-app and CLI-reported ones
    /// have no body to read.
    static func command(named name: String, cwd: String?) -> SlashCommand? {
        availableCommands(cwd: cwd).first { command in
            guard command.name == name else { return false }
            switch command.source {
            case .userCustom, .projectCustom: return true
            case .builtin, .cliReported: return false
            }
        }
    }

    /// Substitute a custom command's argument placeholders, the way Claude
    /// Code does when it expands the command itself: `$ARGUMENTS` becomes
    /// the whole argument string, `$1`…`$9` the whitespace-separated
    /// positional arguments.
    ///
    /// cmux has to do this itself because headless `claude -p` never sees
    /// the `/<name>` line — the panel reads the `.md` body and forwards it
    /// as the prompt (see `confirmSlashSelection`). Without substitution a
    /// literal `$ARGUMENTS` reaches the model and the issue number the
    /// user typed is silently lost.
    ///
    /// A command whose body has no placeholder but was given arguments
    /// gets them appended as a trailing line. Claude Code drops them in
    /// that case; dropping the one number the user picked out of a context
    /// menu is worse than passing it along, and the wording keeps it
    /// unambiguous to the model.
    static func expand(body: String, arguments: String) -> String {
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let positional = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        var out = ""
        var substituted = false
        var rest = body[...]

        // Hand-rolled scan rather than `replacingOccurrences`: `$1` must not
        // also match inside `$10`, and a chained replace would rewrite text
        // that an earlier substitution had just inserted.
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[..<dollar]
            let afterDollar = rest.index(after: dollar)
            if rest[afterDollar...].hasPrefix("ARGUMENTS") {
                out += args
                substituted = true
                rest = rest[rest.index(afterDollar, offsetBy: "ARGUMENTS".count)...]
                continue
            }
            // `$1`…`$9`, but only when a single digit follows — `$12` is
            // not a placeholder Claude Code defines, so it stays literal.
            if let digit = rest[afterDollar...].first, let index = digit.wholeNumberValue,
               (1...9).contains(index) {
                let afterDigit = rest.index(after: afterDollar)
                let isSingleDigit = rest[afterDigit...].first?.isNumber != true
                if isSingleDigit {
                    if index <= positional.count {
                        out += positional[index - 1]
                    }
                    substituted = true
                    rest = rest[afterDigit...]
                    continue
                }
            }
            out.append("$")
            rest = rest[afterDollar...]
        }
        out += rest

        guard !args.isEmpty, !substituted else { return out }
        return out + "\n\nArguments: \(args)"
    }

    /// Best-effort one-line description for a custom command markdown
    /// file. Tries: frontmatter `description:` → first non-empty non-`#`
    /// content line → empty string.
    private static func readDescription(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inFrontmatter = false
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if idx == 0, line == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if line == "---" {
                    inFrontmatter = false
                    continue
                }
                if line.lowercased().hasPrefix("description:") {
                    let after = line.dropFirst("description:".count)
                    let trimmed = after.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    return String(trimmed)
                }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            // Cap at a sensible length so the dropdown row stays one line.
            return line.count > 120 ? String(line.prefix(117)) + "…" : line
        }
        return ""
    }
}
