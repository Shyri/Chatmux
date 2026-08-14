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
    /// Whether `init-config --auto` wrote a **sectioned** file.
    ///
    /// It reports `MONOREPO=yes` and writes one `[section]` per sub-project,
    /// each with its own `VERIFY_CMD`. There is no global command to show, and
    /// — the part that matters — calling `init-config` again with
    /// `--verify-cmd` would rewrite the file flat and destroy those sections.
    @Published private(set) var wroteSectionedConfig = false
    @Published private(set) var writtenProjects: [AutoTaskSetupPolicy.WrittenProject] = []

    // Step 3–4
    @Published var level: AutoTaskSetupPolicy.VerificationLevel = .unitTests
    @Published var verifyCommand: String = ""
    @Published var forbiddenPaths: String = ""
    @Published var maxFiles: String = "25"
    @Published var verifyTimeout: String = "1800"
    @Published private(set) var detectedSnapshotFramework: String?
    /// Sub-projects as reported by `auto-task.sh detect-projects`. Empty for a
    /// conventional single-project repository, which the script signals with
    /// `MONOREPO=no`.
    @Published private(set) var subprojects: [AutoTaskSetupPolicy.DetectedProject] = []
    @Published private(set) var isMonorepo = false
    /// Which of them the user wants in the verification. Unverifiable ones are
    /// never pre-selected — there is nothing to select.
    @Published var selectedSubprojectPaths: Set<String> = []
    /// The command each sub-project will run, keyed by path, editable from the
    /// moment they are listed.
    ///
    /// Seeded with what the toolkit derived and then owned by the user. What it
    /// derives is a starting point that often does not pass — `flutter analyze`
    /// almost never does on a real project the first time — and a verification
    /// nobody can get to green blocks every autonomous run, which is worse than
    /// a laxer one that works. It is also the only way a sub-project the
    /// toolkit refused to guess for ends up with a command at all.
    @Published var subprojectCommands: [String: String] = [:]

    // Step 5
    @Published private(set) var verifyLines: [String] = []
    @Published private(set) var verifyElapsed: TimeInterval = 0
    @Published private(set) var verifyResult: String?
    @Published private(set) var verifyFindings: [AutoTaskSetupPolicy.VerifyFinding] = []
    @Published private(set) var suggestedTimeout: Int?
    @Published private(set) var isVerifying = false
    /// One row per sub-project, in the order they were verified. Empty for a
    /// single-project repository, where there is one verdict and no rows.
    @Published private(set) var projectVerifications: [ProjectVerification] = []
    private var verifyHandle: OctoDevRunHandle?
    private var verifyStart: Date?
    private var verifyTicker: Timer?
    private var pendingProjects: [AutoTaskSetupPolicy.WrittenProject] = []
    private var currentProject: AutoTaskSetupPolicy.WrittenProject?
    private var cancelledValidation = false

    /// How one sub-project's verification went.
    struct ProjectVerification: Identifiable, Equatable {
        let name: String
        let path: String
        let result: String
        let seconds: TimeInterval

        var id: String { name }
        var passed: Bool { result == "pass" }
    }

    // Step 6
    @Published var reviewerUsername: String = ""
    @Published private(set) var hasReviewerFile = false

    /// Scripts the toolkit has not installed. With no fallback by design, these
    /// are reported rather than worked around.
    @Published private(set) var missingScripts: [OctoDevScriptRunner.Script] = []

    /// Whether this project sits in a git repository at all.
    ///
    /// A project is a saved workspace, and a workspace is any directory — it
    /// may well be a folder where something has not been started yet. But
    /// `/auto-task` resolves GitLab issues, so without a repository there is
    /// nothing for it to do. Known before the first screen rather than
    /// discovered at step 2, so the assistant does not walk the user into a
    /// dead end.
    @Published private(set) var isInsideGitRepository: Bool = true

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
        isInsideGitRepository = AutoTaskSetupPolicy.isInsideGitRepository(
            repositoryPath,
            fileManager: fileManager
        )
    }

    // MARK: - Availability

    func refreshInstalledScripts() {
        missingScripts = [.autoTask, .mrReview, .mrCreate].filter { !runner.isInstalled($0) }
        isInsideGitRepository = AutoTaskSetupPolicy.isInsideGitRepository(
            repositoryPath,
            fileManager: fileManager
        )
    }

    /// Whether the assistant can do anything meaningful at all. `auto-task.sh`
    /// owns writing and validating the config; without it steps 2, 4 and 5 have
    /// no implementation, and inventing one here would be the second source of
    /// truth this design rejects.
    var canRun: Bool { !missingScripts.contains(.autoTask) && isInsideGitRepository }

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

    func detectProject() async {
        phase = .running
        switch await runner.runAsync(.mrReview, arguments: ["detect-project"], repositoryPath: repositoryPath) {
        case .failure(let failure):
            phase = .failed(Self.describe(failure))
        case .success(let out):
            projectType = out["PROJECT_TYPE"] ?? "unknown"
            platforms = (out["PLATFORMS"] ?? "")
                .split(separator: " ")
                .map(String.init)
            detectedSnapshotFramework = findSnapshotFramework()
            phase = .succeeded
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

    /// Slow on purpose to wait for: on an Xcode project this resolves the
    /// scheme with `xcodebuild -list`, measured at 25 seconds in this
    /// repository. It must never run on the main thread.
    func runAutoProposal() async {
        phase = .running
        autoFailureExplanation = nil
        let result = await runner.runAsync(
            .autoTask,
            arguments: ["init-config", "--auto"],
            repositoryPath: repositoryPath
        )
        switch result {
        case .failure(let failure):
            phase = .failed(Self.describe(failure))
        case .success(let out):
            verifyConfidence = out["VERIFY_CONFIDENCE"] ?? ""
            if let type = out["PROJECT_TYPE"], !type.isEmpty { projectType = type }

            wroteSectionedConfig = !out.failed && out["MONOREPO"] == "yes"
            writtenProjects = out.allValues["PROJECT", default: []]
                .compactMap(AutoTaskSetupPolicy.WrittenProject.init(initConfigLine:))

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
                if wroteSectionedConfig {
                    // `--auto` has just written the file with its own derived
                    // commands; the ones edited in step 1 have to land on top,
                    // and the sub-projects it skipped have to be added.
                    applyEditedSubprojectCommands()
                    reloadWrittenProjects()
                }
            }
            level = AutoTaskSetupPolicy.recommendedLevel(
                projectType: effectiveProjectType,
                hasSnapshotTests: detectedSnapshotFramework != nil
            )
            phase = .succeeded
        }
    }

    /// Write the sectioned configuration from what step 1 says.
    ///
    /// Runs `init-config --auto` — the toolkit owns writing the file, and a
    /// second writer here would be the parallel implementation this design
    /// rejects — and then reconciles the result with the choices and the edited
    /// commands.
    @discardableResult
    func writeSectionedConfiguration() async -> Bool {
        await runAutoProposal()
        if case .failed = phase { return false }
        return autoProposalSucceeded
    }

    /// Ask the toolkit what this repository contains.
    ///
    /// Separate from `detectProject()` because it answers a different question:
    /// that one classifies the root, this one enumerates sub-projects. On a
    /// conventional repo it reports `MONOREPO=no` and a single entry.
    func detectSubprojects() async {
        switch await runner.runAsync(
            .autoTask, arguments: ["detect-projects"], repositoryPath: repositoryPath
        ) {
        case .failure:
            subprojects = []
            isMonorepo = false
        case .success(let out):
            isMonorepo = out["MONOREPO"] == "yes"
            subprojects = out.pairs(inBlocksLabelled: "PROJECT")
                .compactMap(AutoTaskSetupPolicy.DetectedProject.init)
            // Everything the toolkit is confident about starts selected; the
            // rest needs a human, so it does not.
            selectedSubprojectPaths = Set(
                subprojects.filter(\.isConfident).map(\.path)
            )
            subprojectCommands = Dictionary(
                subprojects.map { ($0.path, $0.verifyCommand) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// The sub-projects the user picked, in the order the script reported them.
    var chosenSubprojects: [AutoTaskSetupPolicy.DetectedProject] {
        subprojects.filter { selectedSubprojectPaths.contains($0.path) }
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
    func writeConfiguration() async -> Bool {
        // `init-config --verify-cmd` rewrites the whole file in single-project
        // form. Against a sectioned file that silently deletes every
        // sub-project's command, so it is refused rather than guarded only by
        // the navigation not reaching this step.
        guard !wroteSectionedConfig else { return false }
        phase = .running
        var arguments = ["init-config", "--verify-cmd", verifyCommand]
        if !forbiddenPaths.isEmpty { arguments += ["--forbidden", forbiddenPaths] }
        if !maxFiles.isEmpty { arguments += ["--max-files", maxFiles] }
        if !verifyTimeout.isEmpty { arguments += ["--timeout", verifyTimeout] }

        switch await runner.runAsync(.autoTask, arguments: arguments, repositoryPath: repositoryPath) {
        case .failure(let failure):
            phase = .failed(Self.describe(failure))
            return false
        case .success(let out):
            if out.failed {
                phase = .failed(out.errorCode ?? out.rawStandardError)
                return false
            }
            phase = .succeeded
            return true
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
        projectVerifications = []
        suggestedTimeout = nil
        verifyElapsed = 0
        isVerifying = true
        phase = .running

        let start = Date()
        startElapsedTicker(from: start)

        if wroteSectionedConfig, !writtenProjects.isEmpty {
            pendingProjects = writtenProjects
            runNextProject(overallStart: start)
        } else {
            run(project: nil, overallStart: start, startedAt: start)
        }
    }

    /// A build can run for fifteen minutes; the elapsed counter is the only
    /// sign of life during that time.
    private func startElapsedTicker(from start: Date) {
        verifyStart = start
        verifyTicker?.invalidate()
        verifyTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.verifyStart else { return }
                self.verifyElapsed = Date().timeIntervalSince(started)
            }
        }
    }

    /// Verify one sub-project, or the whole repository when `project` is nil.
    ///
    /// **`--project` is not optional here.** Without it the script derives the
    /// scope from what the branch changed, and during setup the branch has
    /// changed nothing — it would answer `no_project_affected` and verify
    /// nothing at all, while looking like it ran.
    private func run(project: String?, overallStart: Date, startedAt: Date) {
        var arguments = ["verify"]
        if let project { arguments += ["--project", project] }

        verifyHandle = runner.stream(
            .autoTask,
            arguments: arguments,
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
                if project == nil {
                    self.finishValidation(result, startedAt: startedAt)
                } else {
                    self.finishProject(result, startedAt: startedAt, overallStart: overallStart)
                }
            }
        )
        if verifyHandle == nil {
            let failure = Result<OctoDevScriptOutput, OctoDevScriptRunner.Failure>
                .failure(.notInstalled(.autoTask))
            if project == nil {
                finishValidation(failure, startedAt: startedAt)
            } else {
                finishProject(failure, startedAt: startedAt, overallStart: overallStart)
            }
        }
    }

    private func runNextProject(overallStart: Date) {
        guard let next = pendingProjects.first else {
            finishMultiValidation(overallStart: overallStart)
            return
        }
        pendingProjects.removeFirst()
        currentProject = next
        verifyLines.append("── \(next.name) ──")
        run(project: next.name, overallStart: overallStart, startedAt: Date())
    }

    private func finishProject(
        _ result: Result<OctoDevScriptOutput, OctoDevScriptRunner.Failure>,
        startedAt: Date,
        overallStart: Date
    ) {
        verifyHandle = nil
        let elapsed = Date().timeIntervalSince(startedAt)
        guard let project = currentProject else { return }
        currentProject = nil

        let verdict: String
        switch result {
        case .failure:
            verdict = "fail"
        case .success(let out):
            // The per-project verdict lives in the block, not at the top level:
            // the trailing VERIFY_RESULT is the aggregate of the whole run.
            verdict = out.pairs(inBlocksLabelled: "VERIFY").first?["VERIFY_RESULT"]
                ?? out["VERIFY_RESULT"]
                ?? "fail"
        }
        projectVerifications.append(ProjectVerification(
            name: project.name,
            path: project.path,
            result: verdict,
            seconds: elapsed
        ))
        // Keep the file's order: a retry appends, and rows jumping around
        // between runs makes the list hard to read.
        let order = writtenProjects.map(\.name)
        projectVerifications.sort {
            (order.firstIndex(of: $0.name) ?? 0) < (order.firstIndex(of: $1.name) ?? 0)
        }

        // Cancelling mid-queue must stop the queue, not move on to the next
        // sub-project — the button says Cancel, not Skip.
        if cancelledValidation {
            finishMultiValidation(overallStart: overallStart)
            return
        }
        runNextProject(overallStart: overallStart)
    }

    private func finishMultiValidation(overallStart: Date) {
        verifyTicker?.invalidate()
        verifyTicker = nil
        verifyHandle = nil
        isVerifying = false
        cancelledValidation = false
        pendingProjects = []
        verifyElapsed = Date().timeIntervalSince(overallStart)

        let results = projectVerifications.map(\.result)
        if results.isEmpty {
            verifyResult = nil
        } else if results.contains("fail") || results.contains("no_verify_cmd") {
            verifyResult = "fail"
        } else if results.contains("timeout") {
            verifyResult = "timeout"
        } else {
            verifyResult = "pass"
        }

        // The timeout is per sub-project and each gets the global one unless it
        // overrides it, so the slowest is what has to fit.
        let slowest = projectVerifications.map(\.seconds).max() ?? 0
        suggestedTimeout = AutoTaskSetupPolicy.suggestedTimeout(measuredSeconds: slowest)
        verifyFindings = AutoTaskSetupPolicy.findings(
            result: verifyResult,
            timeoutSupport: nil,
            measuredSeconds: slowest,
            projectType: effectiveProjectType
        )
        phase = .succeeded
    }

    func cancelValidation() {
        cancelledValidation = true
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
    func applySuggestedTimeout() async -> Bool {
        guard let suggested = suggestedTimeout else { return false }
        verifyTimeout = String(suggested)
        // A sectioned file cannot go through `init-config`, which would flatten
        // it. The timeout is a global key, so it is edited in place — the same
        // path the config editor uses, comments and sections intact.
        guard wroteSectionedConfig else { return await writeConfiguration() }
        return editConfigInPlace { $0.set(.verifyTimeout, to: String(suggested)) }
    }

    // MARK: - What each sub-project runs

    /// Apply the commands edited in step 1 to the file `init-config --auto`
    /// just wrote.
    ///
    /// `--auto` derives its own commands and only writes the sub-projects it
    /// was confident about, so this does two things: it replaces a derived
    /// command the user rewrote, and it **adds the sections that were skipped**
    /// but now have a command. Without the second part, filling in the command
    /// for an undetected sub-project in step 1 would silently do nothing.
    ///
    /// Written through `AutoTaskConfigFile`, never `init-config --verify-cmd`,
    /// which rewrites the file as a single-project config and deletes every
    /// section.
    private func applyEditedSubprojectCommands() {
        let chosen = chosenSubprojects
        guard !chosen.isEmpty else { return }
        let commands = subprojectCommands
        _ = editConfigInPlace {
            AutoTaskSetupPolicy.apply(commands: commands, chosen: chosen, to: &$0)
        }
    }

    /// Re-read the roster from the file after the edits.
    ///
    /// The validation step runs one verification per entry, so a sub-project
    /// the edits added has to appear here or it never gets verified — and one
    /// they removed must not.
    private func reloadWrittenProjects() {
        guard let config = currentConfig() else { return }
        var types: [String: String] = [:]
        for subproject in subprojects { types[subproject.path] = subproject.projectType }
        writtenProjects = config.sections.compactMap { section in
            guard let path = config.path(ofSection: section), !path.isEmpty else { return nil }
            return AutoTaskSetupPolicy.WrittenProject(
                name: section,
                path: path,
                projectType: types[path] ?? "unknown"
            )
        }
    }

    /// The file as it is on disk right now.
    private func currentConfig() -> AutoTaskConfigFile? {
        let path = AutoTaskConfigPath.path(inRepository: repositoryPath)
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return AutoTaskConfigFile(text: text)
    }

    /// Apply an edit to the existing file without rewriting it.
    private func editConfigInPlace(_ edit: (inout AutoTaskConfigFile) -> Void) -> Bool {
        let path = AutoTaskConfigPath.path(inRepository: repositoryPath)
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            phase = .failed(String(
                localized: "autoTask.setup.error.configUnreadable",
                defaultValue: "Could not read .octo-dev/auto-task.conf."
            ))
            return false
        }
        var config = AutoTaskConfigFile(text: text)
        edit(&config)
        do {
            try config.serialized().write(toFile: path, atomically: true, encoding: .utf8)
            phase = .succeeded
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Step 6: reviewer

    @discardableResult
    func setReviewer() async -> Bool {
        let username = reviewerUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return false }
        phase = .running
        let result = await runner.runAsync(
            .mrCreate,
            arguments: ["set-reviewer", username],
            repositoryPath: repositoryPath
        )
        switch result {
        case .failure(let failure):
            phase = .failed(Self.describe(failure))
            return false
        case .success(let out):
            if out.failed {
                phase = .failed(out.errorCode ?? out.rawStandardError)
                return false
            }
            refreshReviewerFile()
            phase = .succeeded
            return true
        }
    }

    // MARK: - Navigation

    /// The steps this repository actually goes through.
    ///
    /// A sectioned file skips the level question and the four global fields:
    /// the toolkit already wrote the configuration, one command per
    /// sub-project, and those two screens describe a shape this repository does
    /// not have. Worse than useless — the write step would call `init-config`
    /// again and flatten the file.
    /// Whether this repository is being configured as sections.
    ///
    /// Known from step 1 — `detect-projects` runs when the assistant opens —
    /// so the flow can be shortened before anything is written.
    var usesSections: Bool { isMonorepo || wroteSectionedConfig }

    var steps: [Step] { Self.steps(sectioned: usesSections) }

    /// Static so the skip is testable without a repository or a subprocess.
    ///
    /// A sectioned repository skips three of the seven steps:
    ///
    /// - **propose** asked "can the toolkit derive this on its own?", which
    ///   step 1 already answered per sub-project, and then showed its own list
    ///   of the same names as if the choice had not been made
    /// - **level** and **write** describe a single global command and would
    ///   flatten the file if they ran
    static func steps(sectioned: Bool) -> [Step] {
        guard sectioned else { return Step.allCases }
        return Step.allCases.filter { $0 != .propose && $0 != .level && $0 != .write }
    }

    /// Sub-projects ticked with no command. They would be written with no
    /// `VERIFY_CMD`, and every run touching them would report `no_verify_cmd`.
    var chosenSubprojectsWithoutCommand: [AutoTaskSetupPolicy.DetectedProject] {
        chosenSubprojects.filter {
            (subprojectCommands[$0.path] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func step(after step: Step, sectioned: Bool) -> Step? {
        let steps = steps(sectioned: sectioned)
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    static func step(before step: Step, sectioned: Bool) -> Step? {
        let steps = steps(sectioned: sectioned)
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    func advance() {
        guard let next = Self.step(after: step, sectioned: wroteSectionedConfig) else { return }
        step = next
        phase = .idle
    }

    func goBack() {
        guard let previous = Self.step(before: step, sectioned: wroteSectionedConfig) else { return }
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
