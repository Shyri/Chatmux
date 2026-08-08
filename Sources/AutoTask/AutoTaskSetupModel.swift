import Combine
import Foundation

/// Drives the one-time setup that makes a repository ready for `/auto-task`.
///
/// `/auto-task` never asks anything: it opens a Draft MR or aborts. All the
/// interaction the system will ever have lives here, once per repository, and
/// every autonomous run afterwards depends on what is decided now.
@MainActor
final class AutoTaskSetupModel: ObservableObject {
    enum Step: Int, CaseIterable, Comparable {
        case detect      // 1 — what kind of project is this
        case propose     // 2 — let the toolkit try on its own
        case level       // 3 — the central question
        case write       // 4 — write the config
        case validate    // 5 — run the verification for real
        case reviewer    // 6 — without mr-create.yaml nothing starts
        case done        // 7 — close, with the shared-file reminder

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .detect: return String(localized: "autoTask.setup.step.detect", defaultValue: "Project")
            case .propose: return String(localized: "autoTask.setup.step.propose", defaultValue: "Proposal")
            case .level: return String(localized: "autoTask.setup.step.level", defaultValue: "Verification")
            case .write: return String(localized: "autoTask.setup.step.write", defaultValue: "Configuration")
            case .validate: return String(localized: "autoTask.setup.step.validate", defaultValue: "Validation")
            case .reviewer: return String(localized: "autoTask.setup.step.reviewer", defaultValue: "Reviewer")
            case .done: return String(localized: "autoTask.setup.step.done", defaultValue: "Done")
            }
        }
    }

    /// A step's outcome, so the UI can show progress without inventing state.
    enum Phase: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    let repositoryPath: String
    private let runner: OctoDevScriptRunner
    private let fileManager: FileManager

    @Published private(set) var step: Step = .detect
    @Published private(set) var phase: Phase = .idle

    // Step 1
    @Published private(set) var projectType: String = ""
    @Published private(set) var platforms: [String] = []
    /// Set by the user when detection returns `unknown` — a monorepo, or a
    /// layout the root-only scan cannot classify.
    @Published var manualProjectType: String = ""

    // Step 2
    @Published private(set) var autoProposalSucceeded = false
    @Published private(set) var autoFailureExplanation: String?
    @Published private(set) var verifyConfidence: String = ""

    // Step 3–4
    @Published var level: AutoTaskSetupPolicy.VerificationLevel = .unitTests
    @Published var verifyCommand: String = ""
    @Published var forbiddenPaths: String = ""
    @Published var maxFiles: String = "25"
    @Published var verifyTimeout: String = "1800"
    @Published private(set) var detectedSnapshotFramework: String?

    // Step 5
    @Published private(set) var verifyLines: [String] = []
    @Published private(set) var verifyElapsed: TimeInterval = 0
    @Published private(set) var verifyResult: String?
    @Published private(set) var verifyFindings: [AutoTaskSetupPolicy.VerifyFinding] = []
    @Published private(set) var suggestedTimeout: Int?
    @Published private(set) var isVerifying = false
    private var verifyHandle: OctoDevRunHandle?
    private var verifyStart: Date?
    private var verifyTicker: Timer?

    // Step 6
    @Published var reviewerUsername: String = ""
    @Published private(set) var hasReviewerFile = false

    /// Scripts the toolkit has not installed. With no fallback by design, these
    /// are reported rather than worked around.
    @Published private(set) var missingScripts: [OctoDevScriptRunner.Script] = []

    init(
        repositoryPath: String,
        runner: OctoDevScriptRunner = OctoDevScriptRunner(),
        fileManager: FileManager = .default
    ) {
        self.repositoryPath = repositoryPath
        self.runner = runner
        self.fileManager = fileManager
        refreshInstalledScripts()
        refreshReviewerFile()
    }

    // MARK: - Availability

    func refreshInstalledScripts() {
        missingScripts = [.autoTask, .mrReview, .mrCreate].filter { !runner.isInstalled($0) }
    }

    /// Whether the assistant can do anything meaningful at all. `auto-task.sh`
    /// owns writing and validating the config; without it steps 2, 4 and 5 have
    /// no implementation, and inventing one here would be the second source of
    /// truth this design rejects.
    var canRun: Bool { !missingScripts.contains(.autoTask) }

    private func refreshReviewerFile() {
        hasReviewerFile = fileManager.fileExists(
            atPath: (AutoTaskConfigPath.directory(inRepository: repositoryPath) as NSString)
                .appendingPathComponent(AutoTaskConfigPath.mrCreateFileName)
        )
    }

    /// The project type in effect: what was detected, or what the user said
    /// when detection came back `unknown`.
    var effectiveProjectType: String {
        if projectType == "unknown" || projectType.isEmpty {
            return manualProjectType
        }
        return projectType
    }

    // MARK: - Step 1: detect

    func detectProject() {
        phase = .running
        do {
            let out = try runner.run(.mrReview, arguments: ["detect-project"], repositoryPath: repositoryPath)
            projectType = out["PROJECT_TYPE"] ?? "unknown"
            platforms = (out["PLATFORMS"] ?? "")
                .split(separator: " ")
                .map(String.init)
            detectedSnapshotFramework = findSnapshotFramework()
            phase = .succeeded
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Look for a snapshot-testing framework in the repository's manifests.
    /// Only then is the third verification level offered — suggesting snapshot
    /// tests to a project that has none is noise.
    private func findSnapshotFramework() -> String? {
        let manifests = [
            "build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts",
            "pubspec.yaml", "Package.swift", "package.json", "Podfile",
        ]
        for relative in manifests {
            let path = (repositoryPath as NSString).appendingPathComponent(relative)
            guard let data = fileManager.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8),
                  AutoTaskSetupPolicy.mentionsSnapshotTesting(text) else { continue }
            let lowered = text.lowercased()
            for marker in AutoTaskSetupPolicy.snapshotMarkers where lowered.contains(marker) {
                return marker
            }
        }
        return nil
    }

    // MARK: - Step 2: let the toolkit try

    func runAutoProposal() {
        phase = .running
        autoFailureExplanation = nil
        do {
            let out = try runner.run(
                .autoTask,
                arguments: ["init-config", "--auto"],
                repositoryPath: repositoryPath
            )
            verifyConfidence = out["VERIFY_CONFIDENCE"] ?? ""
            if let type = out["PROJECT_TYPE"], !type.isEmpty { projectType = type }

            if out.failed {
                // The documented normal case, not an exception: it refuses to
                // write a verify command it could not derive from something
                // real. This is exactly where the assistant earns its keep.
                autoProposalSucceeded = false
                autoFailureExplanation = AutoTaskSetupPolicy.explanation(
                    forErrorCode: out.errorCode ?? "unknown",
                    projectType: effectiveProjectType
                )
            } else {
                autoProposalSucceeded = true
                verifyCommand = out["VERIFY_CMD"] ?? ""
                forbiddenPaths = out["FORBIDDEN_PATHS"] ?? ""
                maxFiles = out["MAX_FILES"] ?? "25"
                verifyTimeout = out["VERIFY_TIMEOUT"] ?? "1800"
            }
            level = AutoTaskSetupPolicy.recommendedLevel(
                projectType: effectiveProjectType,
                hasSnapshotTests: detectedSnapshotFramework != nil
            )
            phase = .succeeded
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Re-derive the command when the level changes, keeping any edit the user
    /// already made as the base.
    func applyLevel() {
        verifyCommand = AutoTaskSetupPolicy.command(
            base: verifyCommand,
            projectType: effectiveProjectType,
            level: level
        )
    }

    // MARK: - Step 4: write

    @discardableResult
    func writeConfiguration() -> Bool {
        phase = .running
        var arguments = ["init-config", "--verify-cmd", verifyCommand]
        if !forbiddenPaths.isEmpty { arguments += ["--forbidden", forbiddenPaths] }
        if !maxFiles.isEmpty { arguments += ["--max-files", maxFiles] }
        if !verifyTimeout.isEmpty { arguments += ["--timeout", verifyTimeout] }

        do {
            let out = try runner.run(.autoTask, arguments: arguments, repositoryPath: repositoryPath)
            if out.failed {
                phase = .failed(out.errorCode ?? out.rawStandardError)
                return false
            }
            phase = .succeeded
            return true
        } catch {
            phase = .failed(Self.describe(error))
            return false
        }
    }

    // MARK: - Step 5: validate by running it

    /// Run the real verification on the base branch and time it.
    ///
    /// Not optional, and not a formality: a verify command that already fails
    /// here means `/auto-task` would abort on every issue after twenty minutes
    /// of wasted work. Finding that now is the most valuable thing this
    /// assistant does.
    func startValidation() {
        guard !isVerifying else { return }
        verifyLines = []
        verifyResult = nil
        verifyFindings = []
        suggestedTimeout = nil
        verifyElapsed = 0
        isVerifying = true
        phase = .running

        let start = Date()
        verifyStart = start
        // A build can run for fifteen minutes; the elapsed counter is the only
        // sign of life during that time.
        verifyTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.verifyStart else { return }
                self.verifyElapsed = Date().timeIntervalSince(started)
            }
        }

        verifyHandle = runner.stream(
            .autoTask,
            arguments: ["verify"],
            repositoryPath: repositoryPath,
            onLine: { [weak self] line in
                guard let self else { return }
                // Bounded: a noisy build can emit tens of thousands of lines and
                // the panel only ever shows the tail.
                self.verifyLines.append(line)
                if self.verifyLines.count > 400 {
                    self.verifyLines.removeFirst(self.verifyLines.count - 400)
                }
            },
            onFinish: { [weak self] result in
                guard let self else { return }
                self.finishValidation(result, startedAt: start)
            }
        )
        if verifyHandle == nil {
            finishValidation(.failure(.notInstalled(.autoTask)), startedAt: start)
        }
    }

    func cancelValidation() {
        verifyHandle?.cancel()
    }

    private func finishValidation(
        _ result: Result<OctoDevScriptOutput, OctoDevScriptRunner.Failure>,
        startedAt: Date
    ) {
        verifyTicker?.invalidate()
        verifyTicker = nil
        verifyHandle = nil
        isVerifying = false
        let elapsed = Date().timeIntervalSince(startedAt)
        verifyElapsed = elapsed

        switch result {
        case .failure(let failure):
            phase = .failed(Self.describe(failure))
        case .success(let out):
            verifyResult = out["VERIFY_RESULT"]
            if let tail = out.outputTail, !tail.isEmpty {
                verifyLines = tail.components(separatedBy: "\n")
            }
            verifyFindings = AutoTaskSetupPolicy.findings(
                result: out["VERIFY_RESULT"],
                timeoutSupport: out["TIMEOUT_SUPPORT"],
                measuredSeconds: elapsed,
                projectType: effectiveProjectType
            )
            // Never leave the timeout at a guess: it comes from what was just
            // measured.
            suggestedTimeout = AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: elapsed)
            phase = .succeeded
        }
    }

    /// Adopt the measured timeout and rewrite the config with it.
    @discardableResult
    func applySuggestedTimeout() -> Bool {
        guard let suggested = suggestedTimeout else { return false }
        verifyTimeout = String(suggested)
        return writeConfiguration()
    }

    // MARK: - Step 6: reviewer

    @discardableResult
    func setReviewer() -> Bool {
        let username = reviewerUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return false }
        phase = .running
        do {
            let out = try runner.run(
                .mrCreate,
                arguments: ["set-reviewer", username],
                repositoryPath: repositoryPath
            )
            if out.failed {
                phase = .failed(out.errorCode ?? out.rawStandardError)
                return false
            }
            refreshReviewerFile()
            phase = .succeeded
            return true
        } catch {
            phase = .failed(Self.describe(error))
            return false
        }
    }

    // MARK: - Navigation

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        phase = .idle
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
        phase = .idle
    }

    func go(to step: Step) {
        self.step = step
        phase = .idle
    }

    // MARK: - Bits

    private static func describe(_ error: Error) -> String {
        guard let failure = error as? OctoDevScriptRunner.Failure else {
            return error.localizedDescription
        }
        return describe(failure)
    }

    private static func describe(_ failure: OctoDevScriptRunner.Failure) -> String {
        switch failure {
        case .notInstalled(let script):
            return String(
                localized: "autoTask.setup.error.notInstalled",
                defaultValue: "\(script.rawValue) is not installed in ~/.claude/scripts/."
            )
        case .couldNotLaunch(let detail):
            return detail
        }
    }
}
