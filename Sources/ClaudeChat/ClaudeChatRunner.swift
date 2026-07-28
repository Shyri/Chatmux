import Foundation

/// Builds the `(executableURL, arguments)` pair for spawning `claude`
/// inside a login + interactive zsh, so the spawned process inherits the
/// same PATH / exports the user has in a real terminal (sourced from
/// `.zprofile` + `.zshrc`).
///
/// Without this, MCP servers declared in `.mcp.json` that rely on
/// `npx`/`uvx`/`pipx`/nvm/asdf/homebrew fail to start because the GUI
/// app's env is stripped down. Falls back to executing `claudePath`
/// directly when `/bin/zsh` is unavailable.
///
/// `exec "$0" "$@"` replaces the zsh process with `claude` so SIGINT /
/// SIGTERM sent via `Process.interrupt()` / `Process.terminate()` reach
/// the CLI directly instead of being trapped by the wrapper shell.
enum ClaudeLoginShellWrapper {
    static func wrap(claudePath: String, arguments: [String]) -> (URL, [String]) {
        // Note: we deliberately do NOT use `-i` (interactive). `-i`
        // forces zsh to source `.zshrc`, and `.zshrc` plugins that
        // block on TouchID / `op` (1Password) / `keychain` /
        // `nvm`-style heavy init can hang for several seconds — or
        // forever, if a prompt is waiting on stdin. The launch then
        // never reaches `exec claude` and the chat UI is stuck on
        // "Thinking…". `-l` (login) is enough: it sources
        // `.zprofile` / `.zlogin`, which is where most users put
        // their `PATH`, and the runner additionally inherits the
        // cached `cachedUserPath` extracted by `probeForClaude` so
        // claude itself sees the full interactive PATH.
        let loginShell = "/bin/zsh"
        if FileManager.default.isExecutableFile(atPath: loginShell) {
            return (
                URL(fileURLWithPath: loginShell),
                ["-l", "-c", "exec \"$0\" \"$@\"", claudePath] + arguments
            )
        }
        return (URL(fileURLWithPath: claudePath), arguments)
    }
}

/// Keeps a single `claude` subprocess alive per chat panel and streams its
/// stream-json output back to the caller. Mensajes nuevos se entregan por
/// stdin como NDJSON, así que el proceso no se relanza por turno: una sola
/// sesión persistente reusa la conexión al CLI, sus servidores MCP y su
/// contexto en memoria entre prompts. Esto es el mismo binario `claude` que
/// la app instalada del usuario — solo cambia `--input-format` para que el
/// CLI consuma mensajes desde stdin en vez de tomar el prompt como
/// argumento.
final class ClaudeChatRunner {
    enum RunnerError: Error, LocalizedError {
        case claudeNotFound
        case spawnFailed(String)
        case notRunning
        case stdinWriteFailed(String)
        case unexpectedExit(code: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return String(
                    localized: "claudeChat.error.claudeNotFound",
                    defaultValue:
                        "Claude CLI not found. Install with `npm install -g @anthropic-ai/claude-code` or set the path in Settings → Claude Code."
                )
            case .spawnFailed(let reason):
                return String(
                    localized: "claudeChat.error.spawnFailed",
                    defaultValue: "Failed to launch claude: \(reason)"
                )
            case .notRunning:
                return String(
                    localized: "claudeChat.error.notRunning",
                    defaultValue: "claude is not running. The next message will start a fresh session."
                )
            case .stdinWriteFailed(let reason):
                return String(
                    localized: "claudeChat.error.stdinWriteFailed",
                    defaultValue: "Failed to send message to claude: \(reason)"
                )
            case .unexpectedExit(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return String(
                        localized: "claudeChat.error.unexpectedExit",
                        defaultValue: "claude exited unexpectedly with code \(code)"
                    )
                }
                return "claude exited unexpectedly with code \(code):\n\(trimmed)"
            }
        }
    }

    /// Callbacks are invoked on the main thread/queue for direct binding to
    /// `@MainActor` UI state.
    typealias EventHandler = (ClaudeStreamEvent) -> Void
    /// Fired when the underlying `claude` process exits (either because we
    /// asked it to via `terminate()`, or unexpectedly because of a crash or
    /// because SIGINT escalated to an exit). `success` means the process
    /// went away cleanly; `failure` carries diagnostic detail.
    typealias ExitHandler = (Result<Void, Error>) -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    /// True between an explicit `terminate()` and the `terminationHandler`
    /// firing, so we can distinguish a user-requested shutdown from a crash.
    private var isTerminatingExplicitly = false
    /// The `--permission-mode` flag value the currently-alive process was
    /// launched with. `claude -p` bakes this into argv at spawn time and
    /// cannot change it mid-session, so `ensureStarted` compares against
    /// this on every call: if the requested mode differs, the existing
    /// process is torn down and a fresh one launched (resuming the same
    /// session via `--resume <sessionId>`). Cleared on termination.
    private var launchedPermissionMode: String?
    /// Same as `launchedPermissionMode` for `--model`. `nil` here means
    /// "the running process was launched without `--model`" (the CLI is
    /// using its own default). Compared on every `ensureStarted` so a
    /// model switch from the UI picker triggers a respawn just like a
    /// permission-mode switch.
    private var launchedModel: String?
    /// Same as `launchedModel` for `--effort` (thinking budget level).
    /// `nil` here means "launched without `--effort`" so the CLI uses
    /// whatever it considers default. A mismatch triggers a respawn.
    private var launchedEffort: String?
    private let processQueue = DispatchQueue(label: "com.cmux.claudechat.runner", qos: .userInitiated)

    /// Callbacks for the currently-running process. Replaced on each
    /// `ensureStarted` so the panel that holds the runner always wires up
    /// fresh weak-self captures.
    private var onEvent: EventHandler?
    private var onExit: ExitHandler?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Idempotent. If `claude` is already alive, this just refreshes the
    /// active callbacks; the running process keeps its in-memory session
    /// and MCP connections. If it's not running, spawn it now with the
    /// given options and wait for the first byte (which means the binary
    /// resolved and `Process.run()` succeeded).
    ///
    /// Note: `mcpConfigPath`, `permissionMode`, `appendSystemPrompt`, and
    /// `sessionId` are baked into the launch arguments — changing any of
    /// them mid-session requires a `terminate()` + next `ensureStarted`.
    func ensureStarted(
        cwd: String,
        sessionId: String?,
        permissionMode: String,
        model: String?,
        effort: String?,
        mcpConfigPath: String?,
        permissionPromptTool: String?,
        appendSystemPrompt: String?,
        onEvent: @escaping EventHandler,
        onExit: @escaping ExitHandler
    ) {
        processQueue.async { [weak self] in
            guard let self else { return }
            // Always refresh callbacks so panel-side weak-self captures
            // point at the *current* view model.
            self.onEvent = onEvent
            self.onExit = onExit
            if let existing = self.process, existing.isRunning {
                if self.launchedPermissionMode == permissionMode
                    && self.launchedModel == model
                    && self.launchedEffort == effort {
                    return
                }
                // Permission mode, model, or thinking effort changed
                // since launch (e.g. user clicked Approve on an
                // ExitPlanMode card, or picked a different model /
                // effort from the header picker). `claude -p` bakes
                // all three into argv at spawn time, so we tear down
                // and respawn. The new launch passes the same
                // `sessionId` via `--resume`, so claude reattaches to
                // the same session.
                self.tearDownForRespawn(existing: existing)
            }
            do {
                let claudePath = try self.resolveClaudePath()
                try self.launch(
                    claudePath: claudePath,
                    cwd: cwd,
                    sessionId: sessionId,
                    permissionMode: permissionMode,
                    model: model,
                    effort: effort,
                    mcpConfigPath: mcpConfigPath,
                    permissionPromptTool: permissionPromptTool,
                    appendSystemPrompt: appendSystemPrompt
                )
            } catch {
                DispatchQueue.main.async {
                    onExit(.failure(error))
                }
            }
        }
    }

    /// Synchronously (on `processQueue`) detach from the still-running
    /// `existing` process so a fresh `launch()` can take over. We null
    /// out the readability handlers on its pipes so any final bytes
    /// don't leak into the next process's `stdoutBuffer`, clear the
    /// runner-level state, then SIGTERM. The old process's
    /// `terminationHandler` is gated on `self.process === proc`, so it
    /// becomes a no-op for runner state once we overwrite `self.process`.
    private func tearDownForRespawn(existing: Process) {
        self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        try? self.stdinHandle?.close()
        self.stdinHandle = nil
        self.stdoutBuffer.removeAll(keepingCapacity: false)
        self.stderrBuffer.removeAll(keepingCapacity: false)
        self.launchedPermissionMode = nil
        self.launchedModel = nil
        self.launchedEffort = nil
        self.process = nil
        existing.terminate()
    }

    /// Send a user-side turn to the running `claude` process. The CLI
    /// expects one NDJSON object per line on stdin in streaming-input
    /// mode, mirroring the `user` event shape from `--output-format
    /// stream-json`:
    ///
    /// ```json
    /// {"type":"user","message":{"role":"user","content":"hola"},"parent_tool_use_id":null}
    /// ```
    ///
    /// If the process is not alive (crashed, terminated, or never
    /// started), the call routes a failure through the current `onExit`
    /// handler so the panel can show an error and respawn next time.
    func sendUserTurn(_ text: String) {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let stdin = self.stdinHandle,
                  let process = self.process, process.isRunning else {
                DispatchQueue.main.async {
                    self.onExit?(.failure(RunnerError.notRunning))
                }
                return
            }
            let payload: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": text
                ],
                "parent_tool_use_id": NSNull()
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                DispatchQueue.main.async {
                    self.onExit?(.failure(RunnerError.stdinWriteFailed("failed to encode user turn")))
                }
                return
            }
            var line = data
            line.append(0x0A)  // '\n'
            ChatRunnerDebugLog.shared.appendStdoutLine(
                "→ stdin user turn (bytes=\(line.count))"
            )
            do {
                try stdin.write(contentsOf: line)
            } catch {
                DispatchQueue.main.async {
                    self.onExit?(.failure(RunnerError.stdinWriteFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Interrupt the in-flight turn the way the interactive TUI's Escape
    /// key does: by writing a `control_request`/`interrupt` message to the
    /// CLI's stdin (streaming-input mode). The CLI aborts the current turn,
    /// emits a `[Request interrupted by user]` marker and a `result` with
    /// `terminal_reason: "aborted_streaming"`, then keeps the process,
    /// session, and MCP connections alive so the next `sendUserTurn`
    /// continues seamlessly — no respawn, no lost context.
    ///
    /// Wire format (matches `@anthropic-ai/claude-agent-sdk`'s
    /// `query.interrupt()`, verified against claude-code 2.1.187):
    /// ```json
    /// {"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt"}}
    /// ```
    ///
    /// Note: that `result` still carries `is_error: true`, so the panel
    /// must recognise a user-requested stop and not surface it as a Claude
    /// error. If the stdin write fails (broken pipe, dead process) we fall
    /// back to SIGINT so the user's stop still takes effect.
    func cancel() {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let stdin = self.stdinHandle,
                  let process = self.process, process.isRunning else { return }
            let payload: [String: Any] = [
                "type": "control_request",
                "request_id": UUID().uuidString.lowercased(),
                "request": ["subtype": "interrupt"]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                process.interrupt()
                return
            }
            var line = data
            line.append(0x0A)  // '\n'
            ChatRunnerDebugLog.shared.appendStdoutLine("→ stdin interrupt control_request")
            do {
                try stdin.write(contentsOf: line)
            } catch {
                // Couldn't deliver the graceful interrupt — fall back to a
                // hard SIGINT. The process may exit; the next ensureStarted
                // respawns and resumes via `--resume <id>`.
                if process.isRunning {
                    process.interrupt()
                }
            }
        }
    }

    /// Safety net: if the panel that owned this runner was released
    /// without going through `terminate()` (e.g. app quit shortcut,
    /// SwiftUI dropping the view tree on a workspace switch we missed,
    /// or a crash up the stack), still don't let the spawned `claude`
    /// outlive us. We can't dispatch async work from `deinit`, so we
    /// operate directly on the process handles. `Process.terminate()`
    /// just signals SIGTERM — the kernel reaps the subprocess. All
    /// previously-installed handlers capture `weak self`, so they
    /// become no-ops once we are gone.
    deinit {
        try? stdinHandle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    /// Terminate the process cleanly: close stdin so `claude` exits its
    /// stream-json loop, give it a beat, then SIGTERM if it's still
    /// around. Use this on panel close or `clearTranscript()`.
    func terminate() {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let process = self.process, process.isRunning else {
                self.process = nil
                self.stdinHandle = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.launchedPermissionMode = nil
                self.launchedModel = nil
                self.launchedEffort = nil
                return
            }
            self.isTerminatingExplicitly = true
            try? self.stdinHandle?.close()
            self.stdinHandle = nil
            // Give the CLI a short window to flush; if it's still
            // alive we escalate to SIGTERM.
            self.processQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if let proc = self.process, proc.isRunning {
                    proc.terminate()
                }
            }
        }
    }

    // MARK: - Private

    /// Builds the `claude -p` argv (before the login-shell wrapping) for a
    /// given launch configuration. Pure and deterministic so the flag
    /// ordering / conditional inclusion can be unit-tested without spawning
    /// a process — this is the surface that bakes `--permission-mode`,
    /// `--model`, `--effort`, `--resume` etc. into the spawn, and a wrong
    /// flag here silently changes the session (the class of bug that drove
    /// the respawn-on-change tracking).
    static func buildClaudeArguments(
        permissionMode: String,
        model: String?,
        effort: String?,
        mcpConfigPath: String?,
        permissionPromptTool: String?,
        appendSystemPrompt: String?,
        sessionId: String?
    ) -> [String] {
        var claudeArguments: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // Without this the panel goes silent for the whole length of an
            // Agent call — subagents run in the background by default since
            // Claude Code 2.1.198, and their text is dropped from the stream
            // unless asked for (2.1.211; nested spawns since 2.1.219). The
            // forwarded messages are tagged with `parent_tool_use_id`, which
            // is what keeps them out of the lead's tool bookkeeping.
            "--forward-subagent-text",
            "--permission-mode", permissionMode
        ]
        if let model, !model.isEmpty {
            claudeArguments += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            claudeArguments += ["--effort", effort]
        }
        if let mcpConfigPath, !mcpConfigPath.isEmpty {
            claudeArguments += ["--mcp-config", mcpConfigPath]
            // Disable Claude Code's built-in `AskUserQuestion` whenever our
            // MCP server is up. The built-in self-denies in `-p` (headless)
            // mode, which surfaces to the user as a "cancelled" question.
            // We always want claude to reach for `mcp__cmux__ask_user_question`
            // instead — irrespective of the permission mode.
            claudeArguments += ["--disallowed-tools", "AskUserQuestion"]
        }
        if let permissionPromptTool, !permissionPromptTool.isEmpty {
            claudeArguments += ["--permission-prompt-tool", permissionPromptTool]
        }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
            claudeArguments += ["--append-system-prompt", appendSystemPrompt]
        }
        if let sessionId, !sessionId.isEmpty {
            claudeArguments += ["--resume", sessionId]
        }
        return claudeArguments
    }

    private func launch(
        claudePath: String,
        cwd: String,
        sessionId: String?,
        permissionMode: String,
        model: String?,
        effort: String?,
        mcpConfigPath: String?,
        permissionPromptTool: String?,
        appendSystemPrompt: String?
    ) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        let claudeArguments = Self.buildClaudeArguments(
            permissionMode: permissionMode,
            model: model,
            effort: effort,
            mcpConfigPath: mcpConfigPath,
            permissionPromptTool: permissionPromptTool,
            appendSystemPrompt: appendSystemPrompt,
            sessionId: sessionId
        )
        let (executableURL, processArguments) = ClaudeLoginShellWrapper.wrap(
            claudePath: claudePath,
            arguments: claudeArguments
        )
        process.executableURL = executableURL
        process.arguments = processArguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // Ensure the spawned claude inherits a sane PATH even when launched
        // from the app sandbox context. Read the user's interactive PATH via
        // the resolver-cached value if available; otherwise fall back to
        // the parent process environment.
        var environment = ProcessInfo.processInfo.environment
        if let userPath = ClaudeChatRunner.cachedUserPath {
            environment["PATH"] = userPath
        }
        for (key, value) in ClaudeChatRunner.mcpToolEnvironmentOverrides where environment[key] == nil {
            environment[key] = value
        }
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.handleStdout(chunk: chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.processQueue.async {
                self?.stderrBuffer.append(chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.processQueue.async {
                // Always silence the closure-captured pipes (these are
                // the OLD pipes; the new process — if any — has its own).
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // If we've already replaced `self.process` with a fresh
                // one (respawn after a permission-mode change), this
                // handler is for a process the panel no longer cares
                // about — don't touch runner state and don't fire onExit,
                // since that would tear down the panel mid-session.
                guard self.process === proc else { return }
                self.flushRemainingStdout()

                let exitCode = proc.terminationStatus
                let wasExplicit = self.isTerminatingExplicitly
                self.process = nil
                self.stdinHandle = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.launchedPermissionMode = nil
                self.launchedModel = nil
                self.launchedEffort = nil
                self.isTerminatingExplicitly = false
                self.stdoutBuffer.removeAll(keepingCapacity: false)
                let stderrText = String(data: self.stderrBuffer, encoding: .utf8) ?? ""
                self.stderrBuffer.removeAll(keepingCapacity: false)

                let exitCallback = self.onExit
                DispatchQueue.main.async {
                    if wasExplicit || exitCode == 0 {
                        exitCallback?(.success(()))
                    } else {
                        exitCallback?(.failure(
                            RunnerError.unexpectedExit(code: exitCode, stderr: stderrText)
                        ))
                    }
                }
            }
        }

        // Debug: write the full claude invocation to /tmp so the user can
        // inspect what flags were actually passed. Helpful when tool-use
        // routing misbehaves (e.g. claude reaches for a built-in we tried
        // to disallow).
        ChatRunnerDebugLog.shared.appendInvocation(
            executable: executableURL.path,
            arguments: processArguments,
            cwd: cwd
        )

        do {
            try process.run()
        } catch {
            throw RunnerError.spawnFailed(error.localizedDescription)
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.launchedPermissionMode = permissionMode
        self.launchedModel = model
        self.launchedEffort = effort
    }

    /// Append a chunk to the line buffer and emit one event per complete
    /// newline-terminated NDJSON line.
    private func handleStdout(chunk: Data) {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(chunk)
            self.drainBufferedLines()
        }
    }

    private func drainBufferedLines() {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            dispatchLine(line)
        }
    }

    private func flushRemainingStdout() {
        // claude always terminates lines with \n, but if the process is
        // killed mid-line we still want to attempt a parse so partial errors
        // surface to the user.
        guard !stdoutBuffer.isEmpty else { return }
        if let line = String(data: stdoutBuffer, encoding: .utf8) {
            dispatchLine(line)
        }
        stdoutBuffer.removeAll(keepingCapacity: false)
    }

    private func dispatchLine(_ line: String) {
        ChatRunnerDebugLog.shared.appendStdoutLine(line)
        do {
            guard let event = try ClaudeStreamEvent.parse(line: line) else { return }
            let callback = self.onEvent
            DispatchQueue.main.async {
                callback?(event)
            }
        } catch {
            #if DEBUG
            NSLog("ClaudeChatRunner: failed to parse line: \(error.localizedDescription) line=\(line.prefix(200))")
            #endif
        }
    }

    // MARK: - Environment overrides

    /// Environment applied to the spawned `claude` unless the user already
    /// set the variable themselves.
    ///
    /// `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`: since Claude Code 2.1.212 an MCP
    /// tool call running longer than two minutes is moved to the background
    /// automatically so the session stays usable. That default is wrong for
    /// us: our approval cards *are* MCP tool calls (`--permission-prompt-tool`
    /// pointing at `ChatMcpHttpServer`), and they are supposed to block until
    /// the user answers — which is routinely longer than two minutes if they
    /// step away. `SseStream` already keeps the call alive against the idle
    /// timeout; this raises the wall-clock threshold to a day so an approval
    /// left open is never backgrounded out from under the panel.
    static let mcpToolEnvironmentOverrides: [String: String] = [
        "CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": String(24 * 60 * 60 * 1000)
    ]

    // MARK: - Binary resolution

    private static var cachedClaudePath: String?
    private static var cachedUserPath: String?
    private static let cacheLock = NSLock()

    /// Expose the resolved binary path so the chat panel can spawn
    /// auxiliary `claude mcp list` / `claude mcp get` probes without
    /// re-implementing the multi-shell PATH dance.
    func resolveClaudeBinaryPath() throws -> String {
        try resolveClaudePath()
    }

    private func resolveClaudePath() throws -> String {
        if let custom = UserDefaults.standard.string(forKey: "claudeCodeCustomClaudePath")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }

        Self.cacheLock.lock()
        let cached = Self.cachedClaudePath
        Self.cacheLock.unlock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        // Probe order — fast and predictable paths first, slow/hangy
        // ones only as a last resort:
        //   1. Login zsh / bash — non-interactive, won't source `.zshrc`,
        //      so they finish in <100ms even with a heavy shell init.
        //   2. Conventional install directories — direct disk lookups,
        //      no shell involved.
        //   3. Interactive zsh — only here as a final fallback. `zsh
        //      -i` sources `.zshrc`, and any `.zshrc` that blocks
        //      (TouchID-prompting keychain plugins, stray `read`,
        //      slow network mounts, etc.) would freeze this probe.
        //      `probeForClaude` enforces a hard `probeTimeout` so even
        //      that worst case can't block `processQueue` forever.
        // We accept the first probe that returns an executable path
        // OUTSIDE another `cmux.app` bundle (a sibling install often
        // ships its own `claude` in Resources/bin which is not what the
        // user means when they say "I have claude installed").

        var lastUserPath = ""

        let fastAttempts: [(shell: String, args: [String])] = [
            ("/bin/zsh", ["-l", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]),
            ("/bin/bash", ["-l", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]),
        ]
        for attempt in fastAttempts {
            let (foundPath, userPath) = try probeForClaude(shell: attempt.shell, arguments: attempt.args)
            if !userPath.isEmpty { lastUserPath = userPath }
            if !foundPath.isEmpty,
               !pathLivesInsideAnotherCmuxBundle(foundPath),
               FileManager.default.isExecutableFile(atPath: foundPath) {
                Self.cacheLock.lock()
                if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
                Self.cachedClaudePath = foundPath
                Self.cacheLock.unlock()
                return foundPath
            }
        }

        // Conventional install directories — direct disk check, no
        // shell hop. Covers users who keep claude on disk but whose
        // login shells don't include the dir in PATH (asdf shims,
        // custom shell init files, …).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        for candidate in candidates {
            if !pathLivesInsideAnotherCmuxBundle(candidate),
               FileManager.default.isExecutableFile(atPath: candidate) {
                Self.cacheLock.lock()
                if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
                Self.cachedClaudePath = candidate
                Self.cacheLock.unlock()
                return candidate
            }
        }

        // Last resort: interactive zsh. Only used when both the cheap
        // login-shell probes and the disk lookups failed. Guarded by
        // `probeTimeout` inside `probeForClaude`.
        let (foundPath, userPath) = try probeForClaude(
            shell: "/bin/zsh",
            arguments: ["-i", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]
        )
        if !userPath.isEmpty { lastUserPath = userPath }
        if !foundPath.isEmpty,
           !pathLivesInsideAnotherCmuxBundle(foundPath),
           FileManager.default.isExecutableFile(atPath: foundPath) {
            Self.cacheLock.lock()
            if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
            Self.cachedClaudePath = foundPath
            Self.cacheLock.unlock()
            return foundPath
        }

        Self.cacheLock.lock()
        if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
        Self.cacheLock.unlock()
        throw RunnerError.claudeNotFound
    }

    /// Spawn `shell` with `arguments` and parse the two-line stdout
    /// (PATH on the first line, the `command -v claude` result on the
    /// second). Returns `(foundPath, userPath)`; either may be empty.
    /// Hard ceiling on how long a single shell probe is allowed to run
    /// before we SIGTERM it and move on. The reason this matters: an
    /// interactive `zsh -i` sources `.zshrc`, and if `.zshrc` does
    /// anything that blocks waiting for user input — TouchID-prompting
    /// keychain plugins, a stray `read`, `osascript` prompts, slow
    /// network mounts — the probe never exits and `waitUntilExit()`
    /// would hang `processQueue` forever, freezing the entire chat
    /// runner. The chat UI then shows a permanent "thinking" spinner
    /// because `launch()` is queued behind a `resolveClaudePath()` that
    /// will never return.
    private static let probeTimeout: TimeInterval = 4.0

    private func probeForClaude(shell: String, arguments: [String]) throws -> (String, String) {
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return ("", "")
        }
        let probe = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = arguments
        probe.standardOutput = stdoutPipe
        probe.standardError = stderrPipe

        do {
            try probe.run()
        } catch {
            return ("", "")
        }

        // Schedule a hard kill if the probe hasn't exited within
        // `probeTimeout`. We use a DispatchWorkItem so we can cancel
        // it on clean exit and avoid a stray SIGTERM landing on an
        // unrelated process whose pid got recycled.
        let timeoutItem = DispatchWorkItem { [weak probe] in
            guard let probe, probe.isRunning else { return }
            probe.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.probeTimeout,
            execute: timeoutItem
        )
        probe.waitUntilExit()
        timeoutItem.cancel()

        // If the timeout fired, treat the probe as "no result" — the
        // stdout buffer is probably empty or partial.
        guard probe.terminationStatus == 0 else {
            return ("", "")
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let lines = stdout.split(separator: "\n").map(String.init)
        let userPath = (lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let foundPath = (lines.dropFirst().first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (foundPath, userPath)
    }

    /// True if `path` is `claude` shipped inside some other `cmux.app`
    /// bundle — i.e. it's the binary that the cmux installer drops into
    /// `Resources/bin/`. We skip those in the fork because the binary
    /// belongs to the sibling install, not to the user's "I installed
    /// claude" expectation.
    private func pathLivesInsideAnotherCmuxBundle(_ path: String) -> Bool {
        guard path.contains(".app/Contents/Resources/bin/claude") else { return false }
        let myBundlePath = Bundle.main.bundlePath
        return !path.hasPrefix(myBundlePath)
    }
}
