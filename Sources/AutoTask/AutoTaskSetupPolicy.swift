import Foundation

/// The decisions the setup assistant makes, separated from the UI and from
/// process launching so they can be tested directly.
enum AutoTaskSetupPolicy {
    // MARK: - Preconditions

    /// Whether `path` sits inside a git working tree.
    ///
    /// Checked with the filesystem rather than by shelling out: this gates the
    /// very first screen, and a subprocess there would be both slower and
    /// pointless — every octo-dev script answers `ERROR=not_in_git_repo` for
    /// exactly this condition, so asking one only moves the same answer later.
    ///
    /// `.git` is a directory in a normal clone and a **file** in a worktree, so
    /// existence is what matters, not its kind.
    static func isInsideGitRepository(
        _ path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        var current = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !current.path.isEmpty else { return false }
        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            // `/` is its own parent; stop rather than loop.
            if parent.path == current.path { return false }
            current = parent
        }
    }

    // MARK: - Verification level

    /// What "verified" will mean for this repository from now on. This is the
    /// central question of the whole assistant: `/auto-task` never asks
    /// anything, so this choice governs every autonomous run afterwards.
    enum VerificationLevel: String, CaseIterable, Equatable {
        /// Fast. Fine when the repository already has good coverage.
        case unitTests
        /// Recommended on mobile: `./gradlew test` does **not** assemble the
        /// APK, so a broken layout passes the tests and fails the build.
        case testsAndBuild
        /// Only offered when the project actually has snapshot tests. This is
        /// the correct form of visual verification: the result is pass/fail and
        /// nobody has to interpret an image.
        case testsBuildAndSnapshots

        var title: String {
            switch self {
            case .unitTests:
                return String(localized: "autoTask.setup.level.unit", defaultValue: "Unit tests only")
            case .testsAndBuild:
                return String(localized: "autoTask.setup.level.build", defaultValue: "Tests + build the binary")
            case .testsBuildAndSnapshots:
                return String(localized: "autoTask.setup.level.snapshots", defaultValue: "Tests + build + snapshot tests")
            }
        }

        var explanation: String {
            switch self {
            case .unitTests:
                return String(
                    localized: "autoTask.setup.level.unit.why",
                    defaultValue: "Fastest. Adequate when the repository already has good test coverage."
                )
            case .testsAndBuild:
                return String(
                    localized: "autoTask.setup.level.build.why",
                    defaultValue: "On mobile, running the tests does not assemble the binary: a broken layout passes the tests and then fails to compile. Costs minutes of wall-clock, nothing else."
                )
            case .testsBuildAndSnapshots:
                return String(
                    localized: "autoTask.setup.level.snapshots.why",
                    defaultValue: "The correct form of visual verification: the result is pass/fail and nobody has to interpret an image."
                )
            }
        }
    }

    /// The default level for a stack. Mobile projects default to building the
    /// binary, per the toolkit's guidance.
    static func recommendedLevel(
        projectType: String,
        hasSnapshotTests: Bool
    ) -> VerificationLevel {
        if hasSnapshotTests { return .testsBuildAndSnapshots }
        return isMobile(projectType: projectType) ? .testsAndBuild : .unitTests
    }

    static func isMobile(projectType: String) -> Bool {
        switch projectType {
        case "android-native", "ios-native", "flutter": return true
        default: return false
        }
    }

    /// Snapshot-testing frameworks worth looking for, by the marker that gives
    /// them away in a dependency manifest.
    static let snapshotMarkers = [
        "paparazzi", "roborazzi", "iossnapshottestcase", "snapshottesting",
        "golden_toolkit", "alchemist",
    ]

    static func mentionsSnapshotTesting(_ manifestContents: String) -> Bool {
        let lowered = manifestContents.lowercased()
        for marker in snapshotMarkers where lowered.contains(marker) {
            return true
        }
        return false
    }

    // MARK: - Building the command for a level

    /// The build step to add to a test command, per stack. Empty when there is
    /// nothing meaningful to add.
    static func buildSuffix(projectType: String) -> String {
        switch projectType {
        case "android-native": return "assembleDebug"
        case "flutter": return "flutter build apk --debug"
        case "swift-package": return "swift build"
        case "rust": return "cargo build"
        case "go": return "go build ./..."
        default: return ""
        }
    }

    /// Adjust a proposed command for the chosen level.
    ///
    /// Only ever *adds* a build step, and only where the step is a real,
    /// standard task for that stack. Snapshot tests are deliberately not
    /// auto-completed: the task name depends on the framework and the module
    /// layout, and inventing one that silently does nothing is exactly the
    /// failure the toolkit refuses to risk. The user is shown the detected
    /// framework and edits the command themselves.
    static func command(
        base: String,
        projectType: String,
        level: VerificationLevel
    ) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        switch level {
        case .unitTests, .testsBuildAndSnapshots:
            return trimmed
        case .testsAndBuild:
            let suffix = buildSuffix(projectType: projectType)
            guard !suffix.isEmpty, !trimmed.isEmpty else { return trimmed }
            guard !alreadyBuilds(trimmed, suffix: suffix) else { return trimmed }
            // Gradle takes extra tasks as arguments; everything else chains.
            if projectType == "android-native", trimmed.contains("gradlew") {
                return trimmed + " " + suffix
            }
            return trimmed + " && " + suffix
        }
    }

    private static func alreadyBuilds(_ command: String, suffix: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains(suffix.lowercased()) { return true }
        return mentionsABuild(lowered)
    }

    private static func mentionsABuild(_ lowered: String) -> Bool {
        for marker in ["assemble", "xcodebuild build", "bundle", "archive", " build"] where lowered.contains(marker) {
            return true
        }
        return false
    }

    // MARK: - Timeout

    /// Minimum timeout regardless of how fast the measured run was — a cold
    /// cache, a busy machine or a network hiccup all make the real thing slower
    /// than the sample.
    static let minimumTimeout = 300

    /// `VERIFY_TIMEOUT` from a measured duration: about 3× what was actually
    /// observed, never a guess, and never below the floor.
    static func suggestedTimeout(measuredSeconds: TimeInterval) -> Int {
        max(minimumTimeout, Int((measuredSeconds * 3).rounded(.up)))
    }

    // MARK: - Post-verify findings

    enum VerifyFinding: Equatable {
        /// The most valuable thing the assistant can discover: verification
        /// already fails on the base branch, so `/auto-task` would abort on
        /// *every* issue after twenty minutes of wasted work.
        case failsOnBaseBranch
        /// Passed so fast it probably ran nothing.
        case suspiciouslyFast(TimeInterval)
        /// No `timeout`/`gtimeout` on the system, so a hung verification blocks
        /// the run indefinitely.
        case noTimeoutSupport
        case timedOut
    }

    /// Below this, a compiled project almost certainly did not run any real
    /// test — it usually means a wrong command or a no-op task name.
    static let suspiciouslyFastSeconds: TimeInterval = 2

    static func findings(
        result: String?,
        timeoutSupport: String?,
        measuredSeconds: TimeInterval,
        projectType: String
    ) -> [VerifyFinding] {
        var out: [VerifyFinding] = []
        switch result {
        case "fail": out.append(.failsOnBaseBranch)
        case "timeout": out.append(.timedOut)
        default: break
        }
        if result == "pass",
           measuredSeconds < suspiciouslyFastSeconds,
           isCompiled(projectType: projectType) {
            out.append(.suspiciouslyFast(measuredSeconds))
        }
        if timeoutSupport == "no" {
            out.append(.noTimeoutSupport)
        }
        return out
    }

    /// Projects where a sub-second verify is implausible because something has
    /// to be compiled first.
    static func isCompiled(projectType: String) -> Bool {
        switch projectType {
        case "android-native", "ios-native", "flutter", "swift-package", "rust", "go":
            return true
        default:
            return false
        }
    }

    // MARK: - Failure explanations

    /// Why `init-config --auto` refused to write, in terms of what to do next.
    ///
    /// The toolkit treats this as the normal case, not an exception: it only
    /// writes when the command was derived from something that really exists,
    /// because an invented verify command that passes produces MRs that look
    /// tested and are not — the worst possible failure of the system.
    static func explanation(forErrorCode code: String, projectType: String) -> String {
        switch code {
        case "cannot_autodetect_verify_cmd":
            switch projectType {
            case "android-native":
                return String(
                    localized: "autoTask.setup.why.android",
                    defaultValue: "No ./gradlew wrapper was found, so no test command could be derived from anything real."
                )
            case "node-js":
                return String(
                    localized: "autoTask.setup.why.node",
                    defaultValue: "package.json declares no usable scripts, so no test command could be derived from anything real."
                )
            case "ios-native":
                return String(
                    localized: "autoTask.setup.why.ios",
                    defaultValue: "No Xcode scheme could be resolved, so no test command could be derived from anything real."
                )
            default:
                return String(
                    localized: "autoTask.setup.why.generic",
                    defaultValue: "The verify command could not be derived from anything that exists in this repository. It refuses to guess: a command that passes without testing anything produces merge requests that look verified and are not."
                )
            }
        case "not_in_git_repo":
            return String(
                localized: "autoTask.setup.why.notARepo",
                defaultValue: "This directory is not inside a git repository."
            )
        default:
            return String(
                localized: "autoTask.setup.why.unknown",
                defaultValue: "The toolkit reported '\(code)'."
            )
        }
    }
}
