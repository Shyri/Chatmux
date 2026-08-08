import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the slash-command surface (built-ins + custom
/// markdown commands discovered under `<cwd>/.claude/commands`). Pins the
/// built-in roster, prefix filtering, project-command discovery, and the
/// frontmatter-stripping body reader the panel forwards to claude.
@Suite struct SlashCommandRegistryTests {
    // MARK: - filter

    @Test func emptyPrefixReturnsAllCommands() {
        let all = SlashCommandRegistry.builtinCommands
        #expect(SlashCommandRegistry.filter(all, byPrefix: "").count == all.count)
    }

    @Test func prefixMatchesAreCaseInsensitive() {
        let all = SlashCommandRegistry.builtinCommands
        let lower = SlashCommandRegistry.filter(all, byPrefix: "cl")
        let upper = SlashCommandRegistry.filter(all, byPrefix: "CL")
        #expect(lower.map(\.name) == ["clear"])
        #expect(upper.map(\.name) == ["clear"])
    }

    @Test func nonMatchingPrefixReturnsEmpty() {
        let all = SlashCommandRegistry.builtinCommands
        #expect(SlashCommandRegistry.filter(all, byPrefix: "zzz").isEmpty)
    }

    // MARK: - built-in roster

    @Test func builtinRosterHasExpectedCommands() {
        let names = Set(SlashCommandRegistry.builtinCommands.map(\.name))
        for expected in ["clear", "rewind", "undo", "model", "permissions", "help", "mcp", "bashes"] {
            #expect(names.contains(expected), "missing built-in /\(expected)")
        }
    }

    @Test func builtinCommandIdentityAndTitle() throws {
        let clear = try #require(SlashCommandRegistry.builtinCommands.first { $0.name == "clear" })
        #expect(clear.id == "builtin:clear")
        #expect(clear.displayTitle == "/clear")
        #expect(clear.source == .builtin)
        #expect(clear.action == .runBuiltin(SlashCommandRegistry.BuiltinKey.clear))
    }

    // MARK: - project custom command discovery

    @Test func availableCommandsListsBuiltinsFirstThenProjectCustom() throws {
        try withTemporaryCwd { cwd in
            let commandsDir = cwd
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
            try "---\ndescription: Ship it\n---\nThe release body".write(
                to: commandsDir.appendingPathComponent("start-release.md"),
                atomically: true,
                encoding: .utf8
            )

            let commands = SlashCommandRegistry.availableCommands(cwd: cwd.path)
            // Built-ins lead.
            #expect(commands.first?.source == .builtin)
            // The project command is discovered with its frontmatter description.
            let custom = try #require(commands.first { $0.name == "start-release" })
            #expect(custom.description == "Ship it")
            #expect(custom.action == .sendAsPrompt)
            if case .projectCustom = custom.source {} else {
                Issue.record("expected projectCustom source, got \(custom.source)")
            }
        }
    }

    /// The `.claude/commands/` scan can only see markdown files, so skills,
    /// plugin commands and the CLI's own built-ins never showed up in
    /// autocomplete. The init event's `slash_commands` fills that gap.
    @Test func availableCommandsMergesTheCLIReportedList() throws {
        try withTemporaryCwd { cwd in
            let commands = SlashCommandRegistry.availableCommands(
                cwd: cwd.path,
                reportedByCLI: ["compact", "context", "dataviz"]
            )
            let compact = try #require(commands.first { $0.name == "compact" })
            #expect(compact.source == .cliReported)
            #expect(compact.action == .sendAsPrompt)
            #expect(commands.contains { $0.name == "dataviz" })
        }
    }

    /// A file on disk wins: it carries a real description read from the
    /// frontmatter, and the CLI reports names only.
    @Test func cliReportedNamesNeverDuplicateScannedOrBuiltinCommands() throws {
        try withTemporaryCwd { cwd in
            let commandsDir = cwd
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
            try "---\ndescription: Ship it\n---\nbody".write(
                to: commandsDir.appendingPathComponent("start-release.md"),
                atomically: true,
                encoding: .utf8
            )

            let commands = SlashCommandRegistry.availableCommands(
                cwd: cwd.path,
                // The CLI reports both, plus a built-in the panel owns.
                reportedByCLI: ["start-release", "clear", "compact"]
            )
            #expect(commands.filter { $0.name == "start-release" }.count == 1)
            #expect(commands.first { $0.name == "start-release" }?.description == "Ship it")
            #expect(commands.filter { $0.name == "clear" }.count == 1)
            // `clear` stays the in-app action, not a prompt forwarded to claude.
            #expect(commands.first { $0.name == "clear" }?.action
                    == .runBuiltin(SlashCommandRegistry.BuiltinKey.clear))
            #expect(commands.contains { $0.name == "compact" })
        }
    }

    /// Harness plumbing the CLI lists but nobody types.
    @Test func cliReportedListHidesInternalCommands() throws {
        #expect(SlashCommandRegistry.isUserFacing("compact"))
        #expect(SlashCommandRegistry.isUserFacing("__remote-workflow") == false)
        #expect(SlashCommandRegistry.isUserFacing("workflow-launch-exec") == false)
        #expect(SlashCommandRegistry.isUserFacing("heapdump") == false)
        #expect(SlashCommandRegistry.isUserFacing("") == false)

        try withTemporaryCwd { cwd in
            let commands = SlashCommandRegistry.availableCommands(
                cwd: cwd.path,
                reportedByCLI: ["__remote-workflow", "heapdump", "usage"]
            )
            #expect(commands.contains { $0.name == "usage" })
            #expect(commands.contains { $0.name.hasPrefix("__") } == false)
            #expect(commands.contains { $0.name == "heapdump" } == false)
        }
    }

    /// Autocomplete has to keep working before any process has started,
    /// which is exactly when the CLI list is still empty.
    @Test func availableCommandsIsUnchangedWithoutACLIList() throws {
        try withTemporaryCwd { cwd in
            let withEmpty = SlashCommandRegistry.availableCommands(cwd: cwd.path, reportedByCLI: [])
            let withoutArg = SlashCommandRegistry.availableCommands(cwd: cwd.path)
            #expect(withEmpty.map(\.id) == withoutArg.map(\.id))
            #expect(withEmpty.contains { $0.name == "clear" })
            #expect(withEmpty.contains { $0.source == .cliReported } == false)
        }
    }

    @Test func availableCommandsFallsBackToFirstContentLineForDescription() throws {
        try withTemporaryCwd { cwd in
            let commandsDir = cwd
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
            // No frontmatter, leading heading skipped, first real line wins.
            try "# Title\n\nDo the thing now".write(
                to: commandsDir.appendingPathComponent("doit.md"),
                atomically: true,
                encoding: .utf8
            )
            let commands = SlashCommandRegistry.availableCommands(cwd: cwd.path)
            let custom = try #require(commands.first { $0.name == "doit" })
            #expect(custom.description == "Do the thing now")
        }
    }

    // MARK: - readBody

    @Test func readBodyStripsFrontmatter() throws {
        try withTemporaryCwd { cwd in
            let file = cwd.appendingPathComponent("cmd.md")
            try "---\ndescription: x\nmodel: opus\n---\nThis is the prompt body.".write(
                to: file, atomically: true, encoding: .utf8
            )
            let command = SlashCommand(name: "cmd", description: "x", source: .projectCustom(file), action: .sendAsPrompt)
            #expect(SlashCommandRegistry.readBody(of: command) == "This is the prompt body.")
        }
    }

    @Test func readBodyReturnsWholeFileWhenNoFrontmatter() throws {
        try withTemporaryCwd { cwd in
            let file = cwd.appendingPathComponent("cmd.md")
            try "Just a plain prompt.".write(to: file, atomically: true, encoding: .utf8)
            let command = SlashCommand(name: "cmd", description: "", source: .projectCustom(file), action: .sendAsPrompt)
            #expect(SlashCommandRegistry.readBody(of: command) == "Just a plain prompt.")
        }
    }

    @Test func readBodyOfBuiltinIsEmpty() {
        let command = SlashCommand(name: "clear", description: "", source: .builtin, action: .runBuiltin("clear"))
        #expect(SlashCommandRegistry.readBody(of: command) == "")
    }

    // MARK: - argument expansion
    //
    // Custom commands are expanded on cmux's side: headless `claude -p` is
    // handed a prompt, never a `/<name>` line, so it never substitutes the
    // placeholders itself. Before this, `/start-task 4529` reached the model
    // as a body containing a literal `$ARGUMENTS` and the issue number was
    // silently dropped.

    @Test func expandSubstitutesArguments() {
        #expect(
            SlashCommandRegistry.expand(body: "Work on issue $ARGUMENTS now.", arguments: "4529")
                == "Work on issue 4529 now."
        )
    }

    @Test func expandSubstitutesEveryOccurrence() {
        #expect(
            SlashCommandRegistry.expand(body: "$ARGUMENTS / $ARGUMENTS", arguments: "7")
                == "7 / 7"
        )
    }

    @Test func expandSubstitutesPositionalArguments() {
        #expect(
            SlashCommandRegistry.expand(body: "issue $1 onto $2", arguments: "4529 main")
                == "issue 4529 onto main"
        )
    }

    @Test func expandDropsPositionalsWithNoMatchingArgument() {
        #expect(SlashCommandRegistry.expand(body: "a $1 b $2 c", arguments: "only") == "a only b  c")
    }

    /// `$1` must not match inside `$12`, and `$0` is not a placeholder —
    /// both stay literal rather than being rewritten.
    @Test func expandLeavesNonPlaceholderDollarsAlone() {
        #expect(SlashCommandRegistry.expand(body: "cost is $12 and $0", arguments: "x")
            == "cost is $12 and $0\n\nArguments: x")
        #expect(SlashCommandRegistry.expand(body: "shell $VAR stays", arguments: "")
            == "shell $VAR stays")
    }

    /// A command whose body has no placeholder still has to see the argument
    /// the user picked — appending it beats dropping it on the floor.
    @Test func expandAppendsArgumentsWhenBodyHasNoPlaceholder() {
        #expect(
            SlashCommandRegistry.expand(body: "Do the thing.", arguments: "4529")
                == "Do the thing.\n\nArguments: 4529"
        )
    }

    @Test func expandWithoutArgumentsLeavesBodyUnchangedApartFromPlaceholders() {
        #expect(SlashCommandRegistry.expand(body: "Do the thing.", arguments: "") == "Do the thing.")
        #expect(SlashCommandRegistry.expand(body: "issue $ARGUMENTS", arguments: "") == "issue ")
    }

    // MARK: - lookup by name

    @Test func commandNamedFindsProjectCommand() throws {
        try withTemporaryCwd { cwd in
            let dir = cwd.appendingPathComponent(".claude/commands", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "Body".write(
                to: dir.appendingPathComponent("start-task.md"),
                atomically: true,
                encoding: .utf8
            )
            let found = SlashCommandRegistry.command(named: "start-task", cwd: cwd.path)
            #expect(found?.name == "start-task")
            // Project scope must win: the developer running these tests may
            // well have a user-level start-task.md too.
            #expect(found?.source == .projectCustom(dir.appendingPathComponent("start-task.md")))
        }
    }

    /// Built-ins have no body to expand, so resolving one by name would give
    /// callers an empty prompt. They must not be returned.
    ///
    /// Asserted on the source rather than on `nil` because the registry also
    /// scans the real `~/.claude/commands`, which no test can isolate.
    @Test func commandNamedIgnoresBuiltins() {
        #expect(SlashCommandRegistry.command(named: "clear", cwd: nil)?.source != .builtin)
    }

    @Test func commandNamedReturnsNilForUnknownName() throws {
        try withTemporaryCwd { cwd in
            #expect(SlashCommandRegistry.command(named: "no-such-command", cwd: cwd.path) == nil)
        }
    }

    // MARK: - helper

    private func withTemporaryCwd(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SlashCommandRegistryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

/// Chatmux-only: the shared path behind every entrypoint that runs a slash
/// command — the composer's submit, the autocomplete popup, and the GitLab
/// issues context menu's "Start Task".
@Suite struct ChatSlashCommandLauncherTests {
    private func withProjectCommand(
        named name: String,
        body: String,
        _ test: (String) throws -> Void
    ) throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChatSlashCommandLauncherTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let dir = cwd.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        try body.write(
            to: dir.appendingPathComponent("\(name).md"),
            atomically: true,
            encoding: .utf8
        )
        try test(cwd.path)
    }

    // MARK: - parse

    @Test func parseSplitsCommandFromArguments() {
        let parsed = ChatSlashCommandLauncher.parse(draft: "/start-task 4529")
        #expect(parsed?.name == "start-task")
        #expect(parsed?.arguments == "4529")
    }

    @Test func parseKeepsEverythingAfterTheFirstSpaceAsArguments() {
        #expect(ChatSlashCommandLauncher.parse(draft: "/fix  4529 on main")?.arguments == "4529 on main")
    }

    /// No arguments means the autocomplete popup owns it — `parse` must
    /// stand aside so `confirmSlashSelection` keeps its behaviour.
    @Test func parseIgnoresArgumentlessCommands() {
        #expect(ChatSlashCommandLauncher.parse(draft: "/clear") == nil)
        #expect(ChatSlashCommandLauncher.parse(draft: "/clear   ") == nil)
    }

    /// A prompt that merely opens with an absolute path is not a command.
    @Test func parseIgnoresLeadingFilePaths() {
        #expect(ChatSlashCommandLauncher.parse(draft: "/Users/me/notes.txt — read this") == nil)
    }

    @Test func parseIgnoresPlainText() {
        #expect(ChatSlashCommandLauncher.parse(draft: "start-task 4529") == nil)
    }

    // MARK: - expansion

    @Test func expansionSubstitutesArgumentsAndLabelsTheRow() throws {
        try withProjectCommand(
            named: "start-task",
            body: "---\ndescription: x\n---\nWork on issue $ARGUMENTS."
        ) { cwd in
            let expansion = ChatSlashCommandLauncher.expansion(
                name: "start-task",
                arguments: "4529",
                cwd: cwd
            )
            #expect(expansion?.text == "Work on issue 4529.")
            // The collapsed transcript row renders this as `/start-task 4529`,
            // so the invocation stays visible after the body is expanded.
            #expect(expansion?.displayName == "start-task 4529")
        }
    }

    @Test func expansionWithoutArgumentsUsesBareCommandName() throws {
        try withProjectCommand(named: "review", body: "Review the diff.") { cwd in
            let expansion = ChatSlashCommandLauncher.expansion(
                name: "review",
                arguments: "",
                cwd: cwd
            )
            #expect(expansion?.displayName == "review")
            #expect(expansion?.text == "Review the diff.")
        }
    }

    /// Unknown names must not be swallowed: the composer falls back to
    /// sending the literal text, which is what it did before.
    @Test func expansionReturnsNilForUnknownCommand() throws {
        try withProjectCommand(named: "start-task", body: "Body") { cwd in
            #expect(
                ChatSlashCommandLauncher.expansion(name: "compact", arguments: "x", cwd: cwd) == nil
            )
        }
    }

    @Test func expansionReturnsNilForEmptyCommandFile() throws {
        try withProjectCommand(named: "empty", body: "---\ndescription: x\n---\n") { cwd in
            #expect(ChatSlashCommandLauncher.expansion(name: "empty", arguments: "1", cwd: cwd) == nil)
        }
    }
}
