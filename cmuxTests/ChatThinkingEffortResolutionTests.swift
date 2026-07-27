import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: drives the `~/.claude/settings.json` → `effortLevel` parser
/// and the picker's "Default (xhigh)" composite label. Exercises the bug-fix
/// path where the user's CLI default effort needs to surface in the UI even
/// when they haven't pinned an explicit `--effort` flag.
@Suite struct ChatThinkingEffortResolutionTests {
    // MARK: - parseEffortLevel

    @Test func parseValidEffortLevelString() throws {
        let cases: [(String, ChatThinkingEffort)] = [
            ("low", .low),
            ("medium", .medium),
            ("high", .high),
            ("xhigh", .xhigh),
            ("max", .max),
            ("default", .default)
        ]
        for (raw, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["effortLevel": raw])
            let parsed = ChatThinkingEffort.parseEffortLevel(from: data)
            #expect(parsed == expected, "expected \(expected) for \(raw)")
        }
    }

    @Test func parseUnknownEffortLevelReturnsNil() throws {
        let data = try JSONSerialization.data(withJSONObject: ["effortLevel": "ludicrous"])
        #expect(ChatThinkingEffort.parseEffortLevel(from: data) == nil)
    }

    @Test func parseMissingEffortLevelReturnsNil() throws {
        let data = try JSONSerialization.data(withJSONObject: ["somethingElse": "ok"])
        #expect(ChatThinkingEffort.parseEffortLevel(from: data) == nil)
    }

    @Test func parseNonDictionaryRootReturnsNil() throws {
        let data = try JSONSerialization.data(withJSONObject: ["effortLevel", "high"])
        #expect(ChatThinkingEffort.parseEffortLevel(from: data) == nil)
    }

    @Test func parseInvalidJSONReturnsNil() {
        let data = Data("not json".utf8)
        #expect(ChatThinkingEffort.parseEffortLevel(from: data) == nil)
    }

    // MARK: - resolveCLIDefault(settingsURL:)

    @Test func resolveReturnsParsedEffortFromFixtureFile() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("settings.json")
            try Data(#"{"effortLevel":"xhigh"}"#.utf8).write(to: url)
            #expect(ChatThinkingEffort.resolveCLIDefault(settingsURL: url) == .xhigh)
        }
    }

    @Test func resolveFallsBackToHighWhenFileMissing() throws {
        try withTemporaryDirectory { dir in
            let absent = dir.appendingPathComponent("absent.json")
            #expect(ChatThinkingEffort.resolveCLIDefault(settingsURL: absent) == .high)
        }
    }

    @Test func resolveFallsBackToHighWhenEffortLevelIsDefault() throws {
        // `default` is not a real CLI choice — surfacing it would re-encode
        // the recursion the picker is trying to avoid. We must drop down to
        // the CLI built-in (`.high`).
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("settings.json")
            try Data(#"{"effortLevel":"default"}"#.utf8).write(to: url)
            #expect(ChatThinkingEffort.resolveCLIDefault(settingsURL: url) == .high)
        }
    }

    @Test func resolveFallsBackToHighWhenEffortLevelIsUnknown() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("settings.json")
            try Data(#"{"effortLevel":"ludicrous"}"#.utf8).write(to: url)
            #expect(ChatThinkingEffort.resolveCLIDefault(settingsURL: url) == .high)
        }
    }

    @Test func resolveFallsBackToHighWhenSettingsIsMalformed() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("settings.json")
            try Data("this is not json".utf8).write(to: url)
            #expect(ChatThinkingEffort.resolveCLIDefault(settingsURL: url) == .high)
        }
    }

    // MARK: - activeLabel

    @Test func nonDefaultEffortRendersOwnLabel() {
        let resolved: ChatThinkingEffort? = .xhigh
        #expect(ChatThinkingEffort.high.activeLabel(resolvedDefault: resolved) == ChatThinkingEffort.high.label)
        #expect(ChatThinkingEffort.max.activeLabel(resolvedDefault: nil) == ChatThinkingEffort.max.label)
    }

    @Test func defaultEffortFoldsResolvedIntoParens() {
        let label = ChatThinkingEffort.default.activeLabel(resolvedDefault: .xhigh)
        // The picker promise: user can always read which effort is in play.
        #expect(label.contains(ChatThinkingEffort.default.label))
        #expect(label.contains(ChatThinkingEffort.xhigh.label))
        #expect(label == "\(ChatThinkingEffort.default.label) (\(ChatThinkingEffort.xhigh.label))")
    }

    @Test func defaultEffortRendersPlainLabelWhenNoResolvedDefault() {
        // When `resolvedDefault` is nil (settings.json unreadable) the picker
        // shows just "Default" — no fake parens.
        let label = ChatThinkingEffort.default.activeLabel(resolvedDefault: nil)
        #expect(label == ChatThinkingEffort.default.label)
        #expect(label.contains("(") == false)
    }

    // MARK: - claudeFlag

    @Test func claudeFlagPassesNilForDefault() {
        #expect(ChatThinkingEffort.default.claudeFlag == nil)
    }

    @Test func claudeFlagMatchesRawValuesForExplicitChoices() {
        // The CLI accepts the lowercase enum names verbatim; the test pins
        // that mapping so we can't accidentally rename the flag in Swift
        // without noticing it breaks the spawn command.
        #expect(ChatThinkingEffort.low.claudeFlag == "low")
        #expect(ChatThinkingEffort.medium.claudeFlag == "medium")
        #expect(ChatThinkingEffort.high.claudeFlag == "high")
        #expect(ChatThinkingEffort.xhigh.claudeFlag == "xhigh")
        #expect(ChatThinkingEffort.max.claudeFlag == "max")
    }

    // MARK: - rawValue ↔ Codable identity

    @Test func everyEffortRoundTripsThroughRawValue() {
        for effort in ChatThinkingEffort.allCases {
            let restored = ChatThinkingEffort(rawValue: effort.rawValue)
            #expect(restored == effort)
        }
    }

    @Test func everyModelRoundTripsThroughRawValue() {
        // ChatModelSelection ships next to ChatThinkingEffort; pin the same
        // contract so the UserDefaults persistence stays stable across
        // releases (the picker keys on rawValue).
        for model in ChatModelSelection.allCases {
            let restored = ChatModelSelection(rawValue: model.rawValue)
            #expect(restored == model)
        }
    }

    @Test func modelDefaultPassesNilForClaudeFlag() {
        #expect(ChatModelSelection.default.claudeFlag == nil)
    }

    @Test func modelExplicitChoicesMapToKnownClaudeFlags() {
        #expect(ChatModelSelection.fable5.claudeFlag == "claude-fable-5")
        #expect(ChatModelSelection.opus5.claudeFlag == "claude-opus-5")
        #expect(ChatModelSelection.opus5Long.claudeFlag == "claude-opus-5[1m]")
        #expect(ChatModelSelection.opus48.claudeFlag == "claude-opus-4-8")
        #expect(ChatModelSelection.opus48Long.claudeFlag == "claude-opus-4-8[1m]")
        #expect(ChatModelSelection.opus.claudeFlag == "claude-opus-4-7")
        #expect(ChatModelSelection.opusLong.claudeFlag == "claude-opus-4-7[1m]")
        #expect(ChatModelSelection.sonnet5.claudeFlag == "claude-sonnet-5")
        #expect(ChatModelSelection.sonnet.claudeFlag == "claude-sonnet-4-6")
        #expect(ChatModelSelection.haiku.claudeFlag == "claude-haiku-4-5")
    }

    /// Only `.default` may omit `--model`; every explicit row must carry a
    /// flag, so a newly added model can't silently fall back to the CLI's
    /// default just because someone forgot the `claudeFlag` case.
    @Test func everyExplicitModelCarriesAFlag() {
        for model in ChatModelSelection.allCases where model != .default {
            #expect(model.claudeFlag?.isEmpty == false, "\(model.rawValue) has no --model flag")
        }
    }

    /// Every picker row needs a localized label; a missing entry in
    /// Localizable.xcstrings surfaces as the raw key at runtime.
    @Test func everyModelLabelIsResolved() {
        for model in ChatModelSelection.allCases {
            #expect(!model.label.isEmpty)
            #expect(model.label != "claudeChat.model.\(model.rawValue)")
        }
    }

    // MARK: - helpers

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChatThinkingEffortResolutionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
