import Foundation

/// Static description of an MCP server entry as it appears in
/// `.mcp.json` / `~/.claude.json`. The shape mirrors Claude Code's
/// `--mcp-config` schema so we can round-trip the file without losing
/// information.
struct McpServerConfig: Identifiable, Equatable {
    /// Where the entry physically lives. Drives the file we read/write
    /// and the badge we show in the UI.
    enum Scope: String, Codable, CaseIterable, Equatable {
        /// `<cwd>/.mcp.json` — shared with the team, committed to the
        /// repo.
        case project
        /// `~/.claude.json` → `projects.<cwd>.mcpServers` — private to
        /// this user, scoped to this project.
        case userLocal
        /// The cmux HTTP server we inject ourselves to back inline
        /// approval / ask-user-question. Not editable.
        case builtin
    }

    /// MCP transport. Mirrors the three shapes the CLI accepts:
    /// `stdio` (default), `http` and `sse`.
    enum Transport: Equatable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: String, headers: [String: String])
        case sse(url: String, headers: [String: String])

        var kindLabel: String {
            switch self {
            case .stdio: return "stdio"
            case .http: return "http"
            case .sse: return "sse"
            }
        }
    }

    /// Stable identity — derived from scope + name. Two MCPs with the
    /// same name can coexist under different scopes (project shadows
    /// user-local; cmux's `claude -p` runs with the merged set).
    var id: String { "\(scope.rawValue):\(name)" }
    let name: String
    let scope: Scope
    let transport: Transport
    /// Keys of the entry we don't model explicitly, kept verbatim.
    var extras: McpServerExtras = .empty
}

/// The parts of an MCP entry this catalog doesn't model as `Transport`.
///
/// They exist because the CLI's schema is wider than the four fields the
/// editor exposes, and it keeps growing: `request_timeout_ms` (honoured for
/// `--mcp-config` and `.mcp.json` entries since Claude Code 2.1.206) is one
/// example, and anything added after this comment is another. Dropping them
/// on write silently rewrote the user's config — a slow server with a raised
/// timeout would quietly fall back to the CLI's 60 s default the first time
/// any server in the file was edited.
///
/// Equality is by canonical JSON so `McpServerConfig` stays `Equatable`.
struct McpServerExtras: Equatable {
    let raw: [String: Any]

    static let empty = McpServerExtras(raw: [:])

    var isEmpty: Bool { raw.isEmpty }

    /// Keys that `Transport` already owns; never carried as extras so a
    /// stale copy can't shadow the edited transport on write.
    static let transportOwnedKeys: Set<String> = [
        "type", "command", "args", "env", "url", "headers"
    ]

    init(raw: [String: Any]) {
        self.raw = raw.filter { !Self.transportOwnedKeys.contains($0.key) }
    }

    private var canonical: Data? {
        try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    }

    static func == (lhs: McpServerExtras, rhs: McpServerExtras) -> Bool {
        if lhs.raw.isEmpty && rhs.raw.isEmpty { return true }
        guard let a = lhs.canonical, let b = rhs.canonical else {
            // Non-JSON payloads can't come from a parsed config file; treat
            // them as distinct rather than silently equal.
            return false
        }
        return a == b
    }
}

/// Connection state for a single MCP server, derived from the latest
/// `system/init` event the running `claude` process emitted. `unknown`
/// is the initial state and also what we fall back to for servers that
/// are configured but not yet seen in any `system/init` snapshot.
enum McpConnectionStatus: Equatable {
    case unknown
    case connecting
    case connected
    case failed(message: String?)
    case needsAuth

    init(rawStatus: String, errorMessage: String?) {
        switch rawStatus.lowercased() {
        case "connected", "ready", "ok":
            self = .connected
        case "connecting", "starting":
            self = .connecting
        case "failed", "error":
            self = .failed(message: errorMessage)
        case "needs-auth", "needs_auth", "auth-required":
            self = .needsAuth
        default:
            self = .unknown
        }
    }
}

/// Read/write the project-scoped (`.mcp.json`) and user-local
/// (`~/.claude.json`) MCP catalogs. Everything is best-effort: a parse
/// error is surfaced as an empty list, not as a thrown error, so the
/// UI can still render an "Add server" affordance even when the file
/// is malformed.
enum McpServerCatalog {
    /// Path to `<cwd>/.mcp.json`. The file may not exist; the caller
    /// decides whether to create it on write.
    static func projectConfigURL(cwd: String) -> URL {
        URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(".mcp.json", isDirectory: false)
    }

    /// Path to `~/.claude.json`. Claude Code itself uses this file to
    /// remember projects, MCP servers, prompt history, etc. We only
    /// touch `projects.<cwd>.mcpServers`.
    static func userClaudeJsonURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json", isDirectory: false)
    }

    // MARK: - Reading

    /// All MCP entries that affect a turn for `cwd`. Order is
    /// `project` first (highest precedence in the merged config we
    /// hand to `claude -p`), then `userLocal`, then the `builtin`
    /// `cmux` row. Entries with no usable transport are dropped.
    static func readAll(cwd: String, builtinEndpoint: URL?) -> [McpServerConfig] {
        var out: [McpServerConfig] = []
        out.append(contentsOf: readProject(cwd: cwd))
        out.append(contentsOf: readUserLocal(cwd: cwd))
        if let url = builtinEndpoint {
            out.append(McpServerConfig(
                name: "cmux",
                scope: .builtin,
                transport: .http(url: url.absoluteString, headers: [:])
            ))
        }
        return out
    }

    static func readProject(cwd: String) -> [McpServerConfig] {
        let url = projectConfigURL(cwd: cwd)
        guard let root = readJSON(at: url) else { return [] }
        guard let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return decodeServers(servers, scope: .project)
    }

    static func readUserLocal(cwd: String) -> [McpServerConfig] {
        let url = userClaudeJsonURL()
        guard let root = readJSON(at: url) else { return [] }
        guard let projects = root["projects"] as? [String: Any] else { return [] }
        guard let proj = projects[cwd] as? [String: Any] else { return [] }
        guard let servers = proj["mcpServers"] as? [String: Any] else { return [] }
        return decodeServers(servers, scope: .userLocal)
    }

    // MARK: - Writing

    /// Persist `server` to its scope-bound file. For `userLocal` we do
    /// a read-modify-write on `~/.claude.json` to preserve every other
    /// key that file carries. For `project` we round-trip
    /// `<cwd>/.mcp.json`. `builtin` is a no-op (caller error).
    static func upsert(_ server: McpServerConfig, cwd: String) throws {
        switch server.scope {
        case .project:
            try mutate(at: projectConfigURL(cwd: cwd)) { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers[server.name] = encodeServer(server)
                root["mcpServers"] = servers
            }
        case .userLocal:
            try mutate(at: userClaudeJsonURL()) { root in
                var projects = root["projects"] as? [String: Any] ?? [:]
                var proj = projects[cwd] as? [String: Any] ?? [:]
                var servers = proj["mcpServers"] as? [String: Any] ?? [:]
                servers[server.name] = encodeServer(server)
                proj["mcpServers"] = servers
                projects[cwd] = proj
                root["projects"] = projects
            }
        case .builtin:
            return
        }
    }

    /// Remove an entry. Same scope semantics as `upsert`. Missing entries
    /// are a silent no-op.
    static func remove(name: String, scope: McpServerConfig.Scope, cwd: String) throws {
        switch scope {
        case .project:
            try mutate(at: projectConfigURL(cwd: cwd)) { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: name)
                root["mcpServers"] = servers
            }
        case .userLocal:
            try mutate(at: userClaudeJsonURL()) { root in
                guard var projects = root["projects"] as? [String: Any],
                      var proj = projects[cwd] as? [String: Any],
                      var servers = proj["mcpServers"] as? [String: Any]
                else { return }
                servers.removeValue(forKey: name)
                proj["mcpServers"] = servers
                projects[cwd] = proj
                root["projects"] = projects
            }
        case .builtin:
            return
        }
    }

    // MARK: - Merging for --mcp-config

    /// Build the merged `mcpServers` dictionary that we hand to
    /// `claude -p --mcp-config <tmpfile>`. Project entries win over
    /// user-local on name collisions (matches Claude Code's CLI), and
    /// the cmux builtin is appended last unconditionally so the
    /// approval/ask-user MCP is always reachable.
    static func mergedForRuntime(cwd: String, builtinEndpoint: URL) -> [String: Any] {
        var merged: [String: Any] = [:]
        for server in readUserLocal(cwd: cwd) {
            merged[server.name] = encodeServer(server)
        }
        for server in readProject(cwd: cwd) {
            merged[server.name] = encodeServer(server)
        }
        merged["cmux"] = [
            "type": "http",
            "url": builtinEndpoint.absoluteString
        ]
        return merged
    }

    // MARK: - Codable bridge

    private static func decodeServers(_ raw: [String: Any], scope: McpServerConfig.Scope) -> [McpServerConfig] {
        raw.compactMap { (name, value) -> McpServerConfig? in
            guard let dict = value as? [String: Any] else { return nil }
            guard let transport = decodeTransport(dict) else { return nil }
            return McpServerConfig(
                name: name,
                scope: scope,
                transport: transport,
                extras: McpServerExtras(raw: dict)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func decodeTransport(_ dict: [String: Any]) -> McpServerConfig.Transport? {
        // The CLI accepts an explicit `type` field; when it's missing it
        // defaults to `stdio` (and `command` is required in that case).
        let kind = (dict["type"] as? String)?.lowercased() ?? "stdio"
        switch kind {
        case "stdio":
            let command = (dict["command"] as? String) ?? ""
            let args = (dict["args"] as? [String]) ?? []
            let env = (dict["env"] as? [String: String]) ?? [:]
            return .stdio(command: command, args: args, env: env)
        case "http":
            let url = (dict["url"] as? String) ?? ""
            let headers = (dict["headers"] as? [String: String]) ?? [:]
            return .http(url: url, headers: headers)
        case "sse":
            let url = (dict["url"] as? String) ?? ""
            let headers = (dict["headers"] as? [String: String]) ?? [:]
            return .sse(url: url, headers: headers)
        default:
            return nil
        }
    }

    /// Serialize one entry back to its `.mcp.json` / `--mcp-config` shape:
    /// the transport this catalog owns, plus every key it doesn't model,
    /// carried through untouched.
    private static func encodeServer(_ server: McpServerConfig) -> [String: Any] {
        var dict = encodeTransport(server.transport)
        for (key, value) in server.extras.raw {
            dict[key] = value
        }
        return dict
    }

    private static func encodeTransport(_ transport: McpServerConfig.Transport) -> [String: Any] {
        switch transport {
        case .stdio(let command, let args, let env):
            var dict: [String: Any] = ["type": "stdio", "command": command]
            if !args.isEmpty { dict["args"] = args }
            if !env.isEmpty { dict["env"] = env }
            return dict
        case .http(let url, let headers):
            var dict: [String: Any] = ["type": "http", "url": url]
            if !headers.isEmpty { dict["headers"] = headers }
            return dict
        case .sse(let url, let headers):
            var dict: [String: Any] = ["type": "sse", "url": url]
            if !headers.isEmpty { dict["headers"] = headers }
            return dict
        }
    }

    // MARK: - JSON read/write helpers

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Read-modify-write helper. If the file does not exist we treat
    /// the root as `{}` so a first write creates it. Output is pretty-
    /// printed with sorted keys so diffs stay reviewable in version
    /// control.
    private static func mutate(at url: URL, _ apply: (inout [String: Any]) -> Void) throws {
        var root = readJSON(at: url) ?? [:]
        apply(&root)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
