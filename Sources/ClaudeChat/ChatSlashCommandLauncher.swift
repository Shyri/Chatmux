import Foundation

/// Opens a new chat and runs `/<name> <args>` in it, for entrypoints outside
/// the composer that already have the object to act on — today, "Start Task"
/// on a GitLab issue.
///
/// The command is sent verbatim, exactly as if the user had typed it. The
/// runner drives `claude -p --input-format stream-json`, which is a streaming
/// session rather than a one-shot, and the CLI expands slash commands in the
/// turns it receives there — placeholders, `!` shell prefixes, `@` file
/// references and frontmatter included. Re-implementing any of that on this
/// side would only produce a worse copy.
enum ChatSlashCommandLauncher {
    /// Returns `false` when there is no workspace to open a chat into.
    ///
    /// `permissionMode` is applied before the command is sent. These commands
    /// drive a whole flow on their own — branch, worktree, edits, MR — so
    /// stopping at an approval card for every tool defeats the point of
    /// invoking them from a menu.
    @MainActor
    @discardableResult
    static func openChat(
        running name: String,
        arguments: String,
        workingDirectory: String?,
        tabManager: TabManager,
        permissionMode: ChatPermissionMode? = nil
    ) -> Bool {
        guard let panel = tabManager.openClaudeChatPanel(
            workingDirectory: workingDirectory,
            permissionMode: permissionMode
        ) else {
            return false
        }
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.send(args.isEmpty ? "/\(name)" : "/\(name) \(args)")
        return true
    }
}
