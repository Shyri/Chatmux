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

    // MARK: - GitLab sidebar commands

    /// These names are the filenames of the user's markdown commands. A typo
    /// here is silent: `isAvailable` finds nothing, the context-menu item
    /// never renders, and there is no error anywhere.
    @Test func gitLabChatCommandNamesMatchTheirMarkdownFiles() {
        #expect(GitLabChatCommand.startTask.commandName == "start-task")
        #expect(GitLabChatCommand.reviewMergeRequest.commandName == "mr-review")
    }

    @Test func gitLabChatCommandIsAvailableOnlyWithItsFile() throws {
        try withTemporaryCwd { cwd in
            let dir = cwd.appendingPathComponent(".claude/commands", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "Review MR $ARGUMENTS".write(
                to: dir.appendingPathComponent("mr-review.md"),
                atomically: true,
                encoding: .utf8
            )
            #expect(
                GitLabChatCommandCoordinator.isAvailable(.reviewMergeRequest, directory: cwd.path)
            )
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
