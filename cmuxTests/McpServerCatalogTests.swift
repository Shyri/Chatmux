import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the project-scoped (`<cwd>/.mcp.json`) read/upsert/
/// remove round-trip. The user-local (`~/.claude.json`) branch goes through
/// `homeDirectoryForCurrentUser`, which we deliberately don't override here.
@Suite struct McpServerCatalogTests {
    // MARK: - readProject

    @Test func readProjectReturnsEmptyForMissingFile() throws {
        try withTemporaryDirectory { cwd in
            let servers = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(servers.isEmpty)
        }
    }

    @Test func readProjectDecodesStdioTransport() throws {
        try withTemporaryDirectory { cwd in
            let json: [String: Any] = [
                "mcpServers": [
                    "filesystem": [
                        "type": "stdio",
                        "command": "/usr/local/bin/mcp-fs",
                        "args": ["--root", "/tmp"],
                        "env": ["FOO": "bar"]
                    ]
                ]
            ]
            try writeJSON(json, to: cwd.appendingPathComponent(".mcp.json"))

            let servers = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(servers.count == 1)
            let server = try #require(servers.first)
            #expect(server.name == "filesystem")
            #expect(server.scope == .project)
            guard case let .stdio(command, args, env) = server.transport else {
                Issue.record("expected .stdio transport, got \(server.transport)")
                return
            }
            #expect(command == "/usr/local/bin/mcp-fs")
            #expect(args == ["--root", "/tmp"])
            #expect(env == ["FOO": "bar"])
        }
    }

    @Test func readProjectDecodesHttpAndSseTransports() throws {
        try withTemporaryDirectory { cwd in
            let json: [String: Any] = [
                "mcpServers": [
                    "remote-http": [
                        "type": "http",
                        "url": "https://mcp.example.com",
                        "headers": ["Authorization": "Bearer abc"]
                    ],
                    "remote-sse": [
                        "type": "sse",
                        "url": "https://mcp.example.com/sse"
                    ]
                ]
            ]
            try writeJSON(json, to: cwd.appendingPathComponent(".mcp.json"))

            let servers = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(servers.count == 2)
            // Alphabetic sort: remote-http before remote-sse.
            #expect(servers.map(\.name) == ["remote-http", "remote-sse"])

            guard case let .http(url, headers) = servers[0].transport else {
                Issue.record("expected http transport, got \(servers[0].transport)")
                return
            }
            #expect(url == "https://mcp.example.com")
            #expect(headers == ["Authorization": "Bearer abc"])

            guard case let .sse(sseURL, sseHeaders) = servers[1].transport else {
                Issue.record("expected sse transport, got \(servers[1].transport)")
                return
            }
            #expect(sseURL == "https://mcp.example.com/sse")
            #expect(sseHeaders.isEmpty)
        }
    }

    @Test func readProjectDefaultsToStdioWhenTypeIsMissing() throws {
        try withTemporaryDirectory { cwd in
            let json: [String: Any] = [
                "mcpServers": [
                    "implicit": [
                        "command": "/usr/local/bin/mcp"
                    ]
                ]
            ]
            try writeJSON(json, to: cwd.appendingPathComponent(".mcp.json"))

            let servers = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(servers.count == 1)
            if case let .stdio(command, args, env) = servers[0].transport {
                #expect(command == "/usr/local/bin/mcp")
                #expect(args.isEmpty)
                #expect(env.isEmpty)
            } else {
                Issue.record("expected implicit stdio transport, got \(servers[0].transport)")
            }
        }
    }

    @Test func readProjectSkipsUnknownTransportType() throws {
        try withTemporaryDirectory { cwd in
            let json: [String: Any] = [
                "mcpServers": [
                    "bogus": [
                        "type": "carrier-pigeon",
                        "url": "pigeon://"
                    ],
                    "valid": [
                        "type": "http",
                        "url": "https://example.com"
                    ]
                ]
            ]
            try writeJSON(json, to: cwd.appendingPathComponent(".mcp.json"))

            let servers = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(servers.map(\.name) == ["valid"])
        }
    }

    // MARK: - upsert + remove

    @Test func upsertProjectCreatesFileAndRoundTrips() throws {
        try withTemporaryDirectory { cwd in
            let server = McpServerConfig(
                name: "fs",
                scope: .project,
                transport: .stdio(
                    command: "/usr/local/bin/mcp-fs",
                    args: ["--root", "/tmp"],
                    env: ["X": "1"]
                )
            )
            try McpServerCatalog.upsert(server, cwd: cwd.path)

            let url = cwd.appendingPathComponent(".mcp.json")
            #expect(FileManager.default.fileExists(atPath: url.path))

            let decoded = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(decoded == [server])
        }
    }

    @Test func upsertProjectMutatesExistingEntryInPlace() throws {
        try withTemporaryDirectory { cwd in
            try McpServerCatalog.upsert(
                McpServerConfig(name: "fs", scope: .project, transport: .stdio(command: "/old", args: [], env: [:])),
                cwd: cwd.path
            )
            try McpServerCatalog.upsert(
                McpServerConfig(name: "fs", scope: .project, transport: .stdio(command: "/new", args: ["--v"], env: [:])),
                cwd: cwd.path
            )

            let decoded = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(decoded.count == 1)
            if case let .stdio(command, args, _) = decoded[0].transport {
                #expect(command == "/new")
                #expect(args == ["--v"])
            } else {
                Issue.record("expected stdio transport")
            }
        }
    }

    @Test func upsertProjectPreservesUnrelatedRootKeys() throws {
        try withTemporaryDirectory { cwd in
            let url = cwd.appendingPathComponent(".mcp.json")
            try writeJSON(["someOtherKey": "preserveMe"], to: url)

            try McpServerCatalog.upsert(
                McpServerConfig(name: "fs", scope: .project, transport: .stdio(command: "/x", args: [], env: [:])),
                cwd: cwd.path
            )

            let data = try Data(contentsOf: url)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(root["someOtherKey"] as? String == "preserveMe")
            #expect(root["mcpServers"] != nil)
        }
    }

    /// Claude Code 2.1.206 made `request_timeout_ms` effective for
    /// `--mcp-config` and `.mcp.json` entries. It isn't part of `Transport`,
    /// so re-writing the file must carry it through instead of dropping it
    /// back to the CLI's 60 s default.
    @Test func upsertPreservesPerServerFieldsTheCatalogDoesNotModel() throws {
        try withTemporaryDirectory { cwd in
            let url = cwd.appendingPathComponent(".mcp.json")
            try writeJSON([
                "mcpServers": [
                    "slow": [
                        "type": "http",
                        "url": "https://example.test/mcp",
                        "request_timeout_ms": 300_000
                    ]
                ]
            ], to: url)

            let loaded = try #require(McpServerCatalog.readProject(cwd: cwd.path).first)
            #expect(loaded.extras.raw["request_timeout_ms"] as? Int == 300_000)

            // Editing the entry must not silently drop the timeout.
            try McpServerCatalog.upsert(loaded, cwd: cwd.path)

            let data = try Data(contentsOf: url)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let servers = try #require(root["mcpServers"] as? [String: Any])
            let slow = try #require(servers["slow"] as? [String: Any])
            #expect(slow["request_timeout_ms"] as? Int == 300_000)
            #expect(slow["url"] as? String == "https://example.test/mcp")
        }
    }

    /// The same fields have to reach the CLI, not just survive on disk.
    @Test func mergedForRuntimeCarriesUnmodeledPerServerFields() throws {
        try withTemporaryDirectory { cwd in
            try writeJSON([
                "mcpServers": [
                    "slow": [
                        "type": "http",
                        "url": "https://example.test/mcp",
                        "request_timeout_ms": 300_000
                    ]
                ]
            ], to: cwd.appendingPathComponent(".mcp.json"))

            let merged = McpServerCatalog.mergedForRuntime(
                cwd: cwd.path,
                builtinEndpoint: URL(string: "http://127.0.0.1:1234/mcp")!
            )
            let slow = try #require(merged["slow"] as? [String: Any])
            #expect(slow["request_timeout_ms"] as? Int == 300_000)
        }
    }

    /// Extras must never shadow the transport being written: an edit that
    /// changes the URL has to win over the copy read from disk.
    @Test func transportOwnedKeysAreNeverCarriedAsExtras() throws {
        let extras = McpServerExtras(raw: [
            "url": "https://stale.test",
            "type": "http",
            "request_timeout_ms": 1000
        ])
        #expect(extras.raw["url"] == nil)
        #expect(extras.raw["type"] == nil)
        #expect(extras.raw["request_timeout_ms"] as? Int == 1000)
    }

    @Test func removeProjectIsNoOpWhenMissing() throws {
        try withTemporaryDirectory { cwd in
            // No file yet — should not throw.
            try McpServerCatalog.remove(name: "fs", scope: .project, cwd: cwd.path)
            // File exists but no matching entry — also no-op.
            try writeJSON(["mcpServers": [String: Any]()], to: cwd.appendingPathComponent(".mcp.json"))
            try McpServerCatalog.remove(name: "fs", scope: .project, cwd: cwd.path)
        }
    }

    @Test func removeProjectDeletesNamedEntry() throws {
        try withTemporaryDirectory { cwd in
            try McpServerCatalog.upsert(
                McpServerConfig(name: "keep", scope: .project, transport: .stdio(command: "/keep", args: [], env: [:])),
                cwd: cwd.path
            )
            try McpServerCatalog.upsert(
                McpServerConfig(name: "drop", scope: .project, transport: .stdio(command: "/drop", args: [], env: [:])),
                cwd: cwd.path
            )

            try McpServerCatalog.remove(name: "drop", scope: .project, cwd: cwd.path)

            let remaining = McpServerCatalog.readProject(cwd: cwd.path)
            #expect(remaining.map(\.name) == ["keep"])
        }
    }

    // MARK: - mergedForRuntime

    @Test func mergedForRuntimeAlwaysAppendsBuiltinCmuxServer() throws {
        try withTemporaryDirectory { cwd in
            let endpoint = URL(string: "http://127.0.0.1:12345/mcp")!
            let merged = McpServerCatalog.mergedForRuntime(cwd: cwd.path, builtinEndpoint: endpoint)

            let cmuxEntry = try #require(merged["cmux"] as? [String: Any])
            #expect(cmuxEntry["type"] as? String == "http")
            #expect(cmuxEntry["url"] as? String == endpoint.absoluteString)
        }
    }

    @Test func mergedForRuntimeProjectShadowsUserLocalOnNameCollision() throws {
        // We can't easily fake `~/.claude.json` without overriding home, so
        // this test just verifies the dictionary structure when only project
        // entries exist alongside the cmux builtin.
        try withTemporaryDirectory { cwd in
            try McpServerCatalog.upsert(
                McpServerConfig(name: "fs", scope: .project, transport: .stdio(command: "/proj", args: [], env: [:])),
                cwd: cwd.path
            )
            let endpoint = URL(string: "http://127.0.0.1:1/mcp")!
            let merged = McpServerCatalog.mergedForRuntime(cwd: cwd.path, builtinEndpoint: endpoint)

            let fsEntry = try #require(merged["fs"] as? [String: Any])
            #expect(fsEntry["command"] as? String == "/proj")
            #expect(merged["cmux"] != nil)
        }
    }

    // MARK: - readAll

    @Test func readAllOmitsBuiltinWhenEndpointIsNil() throws {
        try withTemporaryDirectory { cwd in
            try McpServerCatalog.upsert(
                McpServerConfig(name: "fs", scope: .project, transport: .stdio(command: "/x", args: [], env: [:])),
                cwd: cwd.path
            )

            let withoutBuiltin = McpServerCatalog.readAll(cwd: cwd.path, builtinEndpoint: nil)
            #expect(withoutBuiltin.map(\.name) == ["fs"])
            #expect(withoutBuiltin.contains { $0.scope == .builtin } == false)

            let withBuiltin = McpServerCatalog.readAll(
                cwd: cwd.path,
                builtinEndpoint: URL(string: "http://127.0.0.1:1/mcp")
            )
            #expect(withBuiltin.contains { $0.scope == .builtin && $0.name == "cmux" })
        }
    }

    // MARK: - helpers

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "McpServerCatalogTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }
}
