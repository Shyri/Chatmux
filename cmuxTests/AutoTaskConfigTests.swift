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
