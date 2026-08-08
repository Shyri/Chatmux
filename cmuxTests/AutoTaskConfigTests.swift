import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: `FORBIDDEN_PATHS` matching.
///
/// This reproduces a **bash `case` pattern**, which is neither a gitignore rule
/// nor `fnmatch` with `FNM_PATHNAME`. Getting it wrong is not cosmetic: the list
/// is what stops an unattended agent from rewriting CI config or signing keys,
/// and a pattern that silently matches nothing looks exactly like one that
/// works.
///
/// The first version of this matcher fed a regex fragment (`/.*`) into the glob
/// translator, which escaped the dot — so *every* directory-prefix pattern
/// protected nothing at all. These are the cases that caught it.
@Suite struct ForbiddenPathMatcherTests {
    // MARK: - `*` crosses directory separators

    @Test func starCrossesSeparators() {
        #expect(ForbiddenPathMatcher.matches(path: "app/build.gradle", pattern: "*/build.gradle"))
        #expect(ForbiddenPathMatcher.matches(path: "a/b/c/build.gradle", pattern: "*/build.gradle"))
    }

    /// The trap the stack templates exist to work around: `*/build.gradle` does
    /// **not** cover a root-level `build.gradle`, which is why they ship both
    /// forms.
    @Test func starSlashDoesNotMatchARootLevelFile() {
        #expect(ForbiddenPathMatcher.matches(path: "build.gradle", pattern: "*/build.gradle") == false)
        #expect(ForbiddenPathMatcher.matches(path: "build.gradle", pattern: "build.gradle"))
    }

    // MARK: - trailing slash is a root-anchored directory prefix

    @Test func directoryPrefixMatchesEverythingBeneathIt() {
        #expect(ForbiddenPathMatcher.matches(path: "fastlane/Fastfile", pattern: "fastlane/"))
        #expect(ForbiddenPathMatcher.matches(path: ".github/workflows/ci.yml", pattern: ".github/"))
        #expect(ForbiddenPathMatcher.matches(path: ".octo-dev/auto-task.conf", pattern: ".octo-dev/"))
    }

    /// The second trap: `fastlane/` is anchored at the repository root, so a
    /// nested one is unprotected until you write `*/fastlane/`.
    @Test func directoryPrefixIsAnchoredAtTheRoot() {
        #expect(ForbiddenPathMatcher.matches(path: "android/fastlane/Fastfile", pattern: "fastlane/") == false)
        #expect(ForbiddenPathMatcher.matches(path: "android/fastlane/Fastfile", pattern: "*/fastlane/"))
    }

    @Test func directoryPrefixRequiresSomethingBeneath() {
        #expect(ForbiddenPathMatcher.matches(path: "fastlane", pattern: "fastlane/") == false)
    }

    @Test func directoryPrefixCombinesWithAGlob() {
        #expect(
            ForbiddenPathMatcher.matches(
                path: "a/b/MyApp.xcworkspace/contents.xcworkspacedata",
                pattern: "*.xcworkspace/"
            )
        )
    }

    // MARK: - plain patterns

    @Test func plainPatternIsAnchoredAtTheRoot() {
        #expect(ForbiddenPathMatcher.matches(path: ".gitlab-ci.yml", pattern: ".gitlab-ci.yml"))
        #expect(ForbiddenPathMatcher.matches(path: "src/.gitlab-ci.yml", pattern: ".gitlab-ci.yml") == false)
    }

    @Test func extensionGlobsMatchAtAnyDepth() {
        #expect(ForbiddenPathMatcher.matches(path: "release.keystore", pattern: "*.keystore"))
        #expect(ForbiddenPathMatcher.matches(path: "keys/release.keystore", pattern: "*.keystore"))
        #expect(
            ForbiddenPathMatcher.matches(
                path: "MyApp.xcodeproj/project.pbxproj",
                pattern: "*.xcodeproj/project.pbxproj"
            )
        )
    }

    @Test func unrelatedPathIsNotBlocked() {
        #expect(ForbiddenPathMatcher.matches(path: "src/main/App.kt", pattern: "*/build.gradle") == false)
    }

    @Test func leadingDotSlashIsNormalized() {
        #expect(ForbiddenPathMatcher.matches(path: "./app/build.gradle", pattern: "*/build.gradle"))
    }

    // MARK: - lists

    @Test func patternsAreSplitAndTrimmed() {
        let parsed = ForbiddenPathMatcher.patterns(from: " .gitlab-ci.yml, .github/ ,, *.keystore ")
        #expect(parsed == [".gitlab-ci.yml", ".github/", "*.keystore"])
    }

    @Test func blockedReportsWhichPatternDidIt() {
        let patterns = [".gitlab-ci.yml", ".github/", "*/build.gradle"]
        #expect(ForbiddenPathMatcher.isBlocked(path: "app/build.gradle", patterns: patterns))
        #expect(
            ForbiddenPathMatcher.matchingPatterns(path: "app/build.gradle", patterns: patterns)
                == ["*/build.gradle"]
        )
        #expect(ForbiddenPathMatcher.isBlocked(path: "src/App.kt", patterns: patterns) == false)
    }
}

/// Chatmux-only: reading and writing `.octo-dev/auto-task.conf`.
///
/// The file is parsed by a bash script and committed to the repository, so two
/// things are non-negotiable: the parse rules are the script's, and writing it
/// back must not reformat a file the whole team shares.
@Suite struct AutoTaskConfigFileTests {
    private let sample = """
    # Config for /auto-task (octo-dev). KEY=VALUE, same format as release.conf.
    # VERIFY_CMD runs from the repo root; a non-zero exit blocks the MR.
    VERIFY_CMD="./gradlew testDebugUnitTest assembleDebug"
    # Paths the autonomous run must never modify (comma-separated globs).
    FORBIDDEN_PATHS=".gitlab-ci.yml,.github/,.octo-dev/,*/build.gradle,fastlane/,*.keystore"
    # Abort if the run touches more files than this.
    MAX_FILES=25
    # Seconds before VERIFY_CMD is considered hung.
    VERIFY_TIMEOUT=1800

    """

    @Test func readsEveryParameter() {
        let config = AutoTaskConfigFile(text: sample)
        #expect(config.value(for: .verifyCommand) == "./gradlew testDebugUnitTest assembleDebug")
        #expect(config.intValue(for: .maxFiles) == 25)
        #expect(config.intValue(for: .verifyTimeout) == 1800)
        #expect(config.forbiddenPatterns.count == 6)
    }

    /// The file is committed. An edit has to show up in review as the one line
    /// that changed, not as a reformatted file.
    @Test func roundTripIsByteIdentical() {
        #expect(AutoTaskConfigFile(text: sample).serialized() == sample)
    }

    @Test func lastAssignmentWins() {
        #expect(AutoTaskConfigFile(text: "MAX_FILES=10\nMAX_FILES=99\n").intValue(for: .maxFiles) == 99)
    }

    @Test func commentedKeyIsNotAValue() {
        #expect(AutoTaskConfigFile(text: "#MAX_FILES=1\n").value(for: .maxFiles) == nil)
    }

    @Test func whitespaceAroundKeyAndValueIsTrimmed() {
        #expect(AutoTaskConfigFile(text: "   MAX_FILES  =  7  \n").value(for: .maxFiles) == "7")
    }

    /// Exactly one surrounding pair, per the script.
    @Test func onlyOneQuotePairIsStripped() {
        #expect(AutoTaskConfigFile(text: "VERIFY_CMD=\"\"x\"\"\n").value(for: .verifyCommand) == "\"x\"")
        #expect(AutoTaskConfigFile(text: "VERIFY_CMD='make test'\n").value(for: .verifyCommand) == "make test")
    }

    @Test func editingPreservesCommentsAndOrder() {
        var config = AutoTaskConfigFile(text: sample)
        config.set(.maxFiles, to: "40")
        #expect(config.serialized() == sample.replacingOccurrences(of: "MAX_FILES=25", with: "MAX_FILES=40"))
    }

    /// With a duplicated key, the edit must land on the line that actually
    /// takes effect — otherwise the UI shows one value and the script reads
    /// another.
    @Test func editingTargetsTheWinningAssignment() {
        var config = AutoTaskConfigFile(text: "MAX_FILES=10\nMAX_FILES=99\n")
        config.set(.maxFiles, to: "50")
        #expect(config.serialized() == "MAX_FILES=10\nMAX_FILES=50\n")
    }

    /// An unquoted command with spaces would be read truncated by the script.
    @Test func appendedValueIsQuotedWhenItNeedsToBe() {
        var config = AutoTaskConfigFile(text: "MAX_FILES=25\n")
        config.set(.verifyCommand, to: "make test && make build")
        #expect(config.serialized() == "MAX_FILES=25\nVERIFY_CMD=\"make test && make build\"\n")
    }

    @Test func missingTrailingNewlineIsNotInvented() {
        #expect(AutoTaskConfigFile(text: "MAX_FILES=25").serialized() == "MAX_FILES=25")
    }

    @Test func presentKeysAreReportedInOrder() {
        #expect(AutoTaskConfigFile(text: sample).presentKeys
                == ["VERIFY_CMD", "FORBIDDEN_PATHS", "MAX_FILES", "VERIFY_TIMEOUT"])
    }
}

/// Chatmux-only: validation and advice for `auto-task.conf`.
///
/// The split matters: errors block saving, warnings never do. A warning is a
/// judgement call about someone else's project, and this code does not get to
/// veto it.
@Suite struct AutoTaskConfigDiagnosticsTests {
    private func config(_ text: String) -> AutoTaskConfigFile { AutoTaskConfigFile(text: text) }

    private var valid: String {
        """
        VERIFY_CMD="./gradlew test assembleDebug"
        FORBIDDEN_PATHS=".gitlab-ci.yml,.github/,.octo-dev/"
        MAX_FILES=25
        VERIFY_TIMEOUT=1800
        """
    }

    // MARK: - errors

    @Test func validConfigHasNoErrors() {
        #expect(AutoTaskConfigDiagnostics.errors(in: config(valid)).isEmpty)
    }

    /// Without it nothing decides whether the run's work is valid — the worst
    /// possible failure of the system, per the briefing.
    @Test func emptyVerifyCommandIsAnError() {
        let found = AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=\"\"\n"))
        #expect(found.contains { $0.id == "verify.empty" })
    }

    @Test func maxFilesOutOfRangeIsAnError() {
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nMAX_FILES=0\n"))
            .contains { $0.id == "maxFiles.range" })
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nMAX_FILES=500\n"))
            .contains { $0.id == "maxFiles.range" })
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nMAX_FILES=25\n"))
            .contains { $0.id.hasPrefix("maxFiles") } == false)
    }

    @Test func nonNumericLimitsAreErrors() {
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nMAX_FILES=lots\n"))
            .contains { $0.id == "maxFiles.notANumber" })
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nVERIFY_TIMEOUT=soon\n"))
            .contains { $0.id == "timeout.notANumber" })
    }

    @Test func shortTimeoutIsAnError() {
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nVERIFY_TIMEOUT=30\n"))
            .contains { $0.id == "timeout.range" })
    }

    @Test func duplicatePatternsAreAnError() {
        #expect(AutoTaskConfigDiagnostics.errors(in: config("VERIFY_CMD=x\nFORBIDDEN_PATHS=\"a/,b,a/\"\n"))
            .contains { $0.id == "forbidden.duplicates" })
    }

    // MARK: - warnings

    private func warnings(
        _ text: String,
        stack: AutoTaskConfigTemplate.Stack = .androidNative,
        hasMRCreate: Bool = true
    ) -> [String] {
        AutoTaskConfigDiagnostics
            .warnings(in: config(text), stack: stack, hasMRCreateFile: hasMRCreate)
            .map(\.id)
    }

    /// The single most useful thing this screen can say: without the file the
    /// run aborts in its first second.
    @Test func missingMRCreateFileWarns() {
        #expect(warnings(valid, hasMRCreate: false).contains("mrCreate.missing"))
        #expect(warnings(valid, hasMRCreate: true).contains("mrCreate.missing") == false)
    }

    @Test func unprotectedCIWarns() {
        #expect(warnings("VERIFY_CMD=x\nFORBIDDEN_PATHS=\".octo-dev/\"\n").contains("forbidden.noCI"))
        #expect(warnings(valid).contains("forbidden.noCI") == false)
    }

    @Test func unprotectedOwnConfigWarns() {
        #expect(warnings("VERIFY_CMD=x\nFORBIDDEN_PATHS=\".github/\"\n").contains("forbidden.noOctoDev"))
    }

    /// The glob hole the templates work around: `*/x` leaves a root-level `x`
    /// editable.
    @Test func starSlashPatternWithoutItsRootFormWarns() {
        let ids = warnings("VERIFY_CMD=x\nFORBIDDEN_PATHS=\".gitlab-ci.yml,.octo-dev/,*/build.gradle\"\n")
        #expect(ids.contains("forbidden.missingRoot.*/build.gradle"))

        let both = warnings("VERIFY_CMD=x\nFORBIDDEN_PATHS=\".gitlab-ci.yml,.octo-dev/,*/build.gradle,build.gradle\"\n")
        #expect(both.contains { $0.hasPrefix("forbidden.missingRoot") } == false)
    }

    @Test func testsOnlyVerifyWarnsOnMobileOnly() {
        let mobile = warnings("VERIFY_CMD=\"./gradlew test\"\n", stack: .androidNative)
        #expect(mobile.contains("verify.testsOnly"))

        let assembling = warnings("VERIFY_CMD=\"./gradlew test assembleDebug\"\n", stack: .androidNative)
        #expect(assembling.contains("verify.testsOnly") == false)

        let backend = warnings("VERIFY_CMD=\"cargo test\"\n", stack: .rust)
        #expect(backend.contains("verify.testsOnly") == false)
    }

    /// It runs unattended on other people's machines, so it is worth saying out
    /// loud — but it is still only a warning.
    @Test func destructiveVerifyCommandWarns() {
        #expect(warnings("VERIFY_CMD=\"rm -rf build && make\"\n").contains("verify.destructive"))
        #expect(warnings("VERIFY_CMD=\"git push origin main\"\n").contains("verify.destructive"))
        #expect(warnings(valid).contains("verify.destructive") == false)
    }

    @Test func warningsNeverBlockSaving() {
        // A config with every warning firing still has no errors.
        let text = "VERIFY_CMD=\"./gradlew test\"\nFORBIDDEN_PATHS=\"*/build.gradle\"\nMAX_FILES=25\nVERIFY_TIMEOUT=1800\n"
        #expect(AutoTaskConfigDiagnostics.errors(in: config(text)).isEmpty)
        #expect(warnings(text, hasMRCreate: false).count >= 3)
    }
}

/// Chatmux-only: stack detection and the starter templates.
///
/// The values are octo-dev's, copied verbatim — a FORBIDDEN_PATHS that diverges
/// from what the toolkit expects leaves real files unprotected.
@Suite struct AutoTaskConfigTemplateTests {
    private func withRepository(_ files: [String], _ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTaskTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        try body(root.path)
    }

    @Test func detectsCommonStacks() throws {
        try withRepository(["gradlew"]) { #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .androidNative) }
        try withRepository(["Cargo.toml"]) { #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .rust) }
        try withRepository(["go.mod"]) { #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .go) }
        try withRepository(["package.json"]) { #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .nodeJS) }
        try withRepository(["pyproject.toml"]) { #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .python) }
        try withRepository(["README.md"]) { #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .unknown) }
    }

    /// A Flutter repository contains an Android project too, so order matters.
    @Test func flutterWinsOverTheAndroidProjectInsideIt() throws {
        try withRepository(["pubspec.yaml", "android/gradlew"]) {
            #expect(AutoTaskConfigTemplate.detectStack(inRepository: $0) == .flutter)
        }
    }

    @Test func everyTemplateProtectsCIAndItsOwnConfig() {
        for stack in AutoTaskConfigTemplate.Stack.allCases {
            let patterns = ForbiddenPathMatcher.patterns(from: AutoTaskConfigTemplate.forbiddenPaths(for: stack))
            #expect(patterns.contains(".gitlab-ci.yml"), "\(stack.rawValue) leaves GitLab CI unprotected")
            #expect(patterns.contains(".github/"), "\(stack.rawValue) leaves GitHub Actions unprotected")
            #expect(patterns.contains(".octo-dev/"), "\(stack.rawValue) lets a run rewrite its own rules")
        }
    }

    /// The Android template ships both `*/build.gradle` and `build.gradle`
    /// precisely because the first does not cover a root-level file.
    @Test func androidTemplateCoversBothGradleForms() {
        let patterns = ForbiddenPathMatcher.patterns(
            from: AutoTaskConfigTemplate.forbiddenPaths(for: .androidNative)
        )
        #expect(ForbiddenPathMatcher.isBlocked(path: "app/build.gradle", patterns: patterns))
        #expect(ForbiddenPathMatcher.isBlocked(path: "build.gradle", patterns: patterns))
        #expect(ForbiddenPathMatcher.isBlocked(path: "release.keystore", patterns: patterns))
    }

    /// A generated file has to parse back into the same values.
    @Test func starterFileRoundTrips() {
        for stack in AutoTaskConfigTemplate.Stack.allCases {
            let text = AutoTaskConfigTemplate.starterFile(for: stack)
            let parsed = AutoTaskConfigFile(text: text)
            #expect(parsed.serialized() == text, "\(stack.rawValue) does not round-trip")
            #expect(parsed.intValue(for: .maxFiles) == 25)
            #expect(parsed.intValue(for: .verifyTimeout) == 1800)
            #expect(parsed.value(for: .verifyCommand) == AutoTaskConfigTemplate.verifyCommand(for: stack))
        }
    }

    /// Generated files must be valid by construction — except the unknown
    /// stack, which deliberately leaves VERIFY_CMD empty for a human.
    @Test func generatedFilesValidateCleanly() {
        for stack in AutoTaskConfigTemplate.Stack.allCases where stack != .unknown {
            let parsed = AutoTaskConfigFile(text: AutoTaskConfigTemplate.starterFile(for: stack))
            #expect(AutoTaskConfigDiagnostics.errors(in: parsed).isEmpty, "\(stack.rawValue) generates an invalid file")
        }
        let unknown = AutoTaskConfigFile(text: AutoTaskConfigTemplate.starterFile(for: .unknown))
        #expect(AutoTaskConfigDiagnostics.errors(in: unknown).contains { $0.id == "verify.empty" })
    }
}
