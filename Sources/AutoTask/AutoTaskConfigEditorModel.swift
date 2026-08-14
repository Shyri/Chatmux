import Combine
import Foundation

/// Editing state for one repository's `auto-task.conf`.
///
/// Holds the parsed file plus the in-progress field values, so validation is
/// live and the diff shown before saving is the real one — serialized from the
/// same object that will be written.
///
/// The file has two shapes and this model carries both: a single-project
/// repository, where everything lives in the preamble, and a monorepo, where
/// the preamble holds only the repository-wide rules and each sub-project is a
/// `[section]` with its own verification.
@MainActor
final class AutoTaskConfigEditorModel: ObservableObject {
    enum LoadState: Equatable {
        case missing
        case loaded
        case unreadable(String)
    }

    /// One `[section]` being edited.
    ///
    /// A value type with its own identity, so the section views below the
    /// `ForEach` take a `Binding` to a struct instead of a reference to this
    /// store — the snapshot-boundary rule that this repository has paid for
    /// five times.
    struct SectionDraft: Identifiable, Equatable {
        let id: UUID
        /// The name between brackets. Set once, at creation.
        var name: String
        var path: String
        var verifyCommand: String
        var forbiddenPaths: String
        /// Empty means "inherit the global VERIFY_TIMEOUT", which is what the
        /// script does with `${p_timeout:-$timeout_s}`.
        var verifyTimeout: String

        init(
            id: UUID = UUID(),
            name: String,
            path: String = "",
            verifyCommand: String = "",
            forbiddenPaths: String = "",
            verifyTimeout: String = ""
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.verifyCommand = verifyCommand
            self.forbiddenPaths = forbiddenPaths
            self.verifyTimeout = verifyTimeout
        }
    }

    let repositoryPath: String

    @Published private(set) var loadState: LoadState = .loaded
    @Published var verifyCommand: String = ""
    @Published var forbiddenPathsRaw: String = ""
    @Published var maxFiles: String = ""
    @Published var verifyTimeout: String = ""
    @Published var sections: [SectionDraft] = []
    /// Paths typed into the tester, one per line.
    @Published var pathProbe: String = ""
    @Published private(set) var hasMRCreateFile: Bool = false
    @Published private(set) var saveError: String?

    private var original: AutoTaskConfigFile
    /// Whether the file on disk carried a global `VERIFY_CMD`.
    ///
    /// In a monorepo the preamble has none — the sections do — and writing an
    /// empty one back would add a key the file never had.
    private var hadGlobalVerifyCommand = false
    private let fileManager: FileManager
    private let runner: OctoDevScriptRunner

    init(
        repositoryPath: String,
        fileManager: FileManager = .default,
        runner: OctoDevScriptRunner = OctoDevScriptRunner()
    ) {
        self.repositoryPath = repositoryPath
        self.fileManager = fileManager
        self.runner = runner
        original = AutoTaskConfigFile(text: "")
        reload()
    }

    // MARK: - Loading

    func reload() {
        saveError = nil
        hasMRCreateFile = fileManager.fileExists(
            atPath: (AutoTaskConfigPath.directory(inRepository: repositoryPath) as NSString)
                .appendingPathComponent(AutoTaskConfigPath.mrCreateFileName)
        )

        let path = AutoTaskConfigPath.path(inRepository: repositoryPath)
        guard fileManager.fileExists(atPath: path) else {
            loadState = .missing
            original = AutoTaskConfigFile(text: "")
            applyFields(from: original)
            return
        }
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            loadState = .unreadable(path)
            return
        }
        original = AutoTaskConfigFile(text: text)
        applyFields(from: original)
        loadState = .loaded
    }

    /// Ask the toolkit, off the main thread, and accept not knowing.
    ///
    /// An empty answer simply means the stack-specific warnings do not fire —
    /// better than firing them off a second, cmux-side classification that
    /// could disagree with the one `/auto-task` actually uses.
    ///
    /// Deliberately not called from `init`/`reload`: shelling out while a view
    /// is being constructed blocks the main thread, and these scripts are not
    /// fast. The view kicks this off from `.task`.
    func refreshProjectType() async {
        switch await runner.runAsync(
            .mrReview, arguments: ["detect-project"], repositoryPath: repositoryPath
        ) {
        case .success(let out):
            projectType = out["PROJECT_TYPE"] ?? ""
        case .failure:
            projectType = ""
        }
        await refreshSectionProjectTypes()
    }

    /// What kind of project sits at each section's `PATH`.
    ///
    /// Only meaningful in a monorepo, where the root type says nothing about a
    /// Flutter module three directories down — and the mobile-specific advice
    /// is precisely the advice that section needs.
    private func refreshSectionProjectTypes() async {
        guard !sections.isEmpty else {
            detectedProjects = []
            return
        }
        switch await runner.runAsync(
            .autoTask, arguments: ["detect-projects"], repositoryPath: repositoryPath
        ) {
        case .failure:
            detectedProjects = []
        case .success(let out):
            detectedProjects = out.pairs(inBlocksLabelled: "PROJECT")
                .compactMap(AutoTaskSetupPolicy.DetectedProject.init)
        }
    }

    /// Sub-projects the toolkit found that the file does not describe.
    ///
    /// These are the ones `init-config --auto` reported as `SKIPPED_PROJECTS`
    /// because it could not derive a verify command for them. They are invisible
    /// to `/auto-task`: a change touching one resolves to no section and passes
    /// as `no_project_affected`.
    var undeclaredProjects: [AutoTaskSetupPolicy.DetectedProject] {
        let known = Set(sections.map { $0.path.trimmingCharacters(in: .whitespaces) })
        return detectedProjects.filter { !known.contains($0.path) }
    }

    private func applyFields(from config: AutoTaskConfigFile) {
        hadGlobalVerifyCommand = config.value(for: .verifyCommand) != nil
        verifyCommand = config.value(for: .verifyCommand) ?? ""
        forbiddenPathsRaw = config.value(for: .forbiddenPaths) ?? ""
        maxFiles = config.value(for: .maxFiles) ?? "25"
        verifyTimeout = config.value(for: .verifyTimeout) ?? "1800"
        sections = config.sections.map { name in
            SectionDraft(
                name: name,
                path: config.value(for: "PATH", in: name) ?? "",
                verifyCommand: config.value(for: .verifyCommand, in: name) ?? "",
                forbiddenPaths: config.value(for: .forbiddenPaths, in: name) ?? "",
                verifyTimeout: config.value(for: .verifyTimeout, in: name) ?? ""
            )
        }
    }

    // MARK: - Derived state

    var isMonorepo: Bool { !sections.isEmpty }

    /// The file as it would be written right now.
    var edited: AutoTaskConfigFile {
        var config = original

        // Sections first: adding one appends at the end of the file, and a
        // global key must land before the first section, so the order of these
        // two steps is not interchangeable.
        let names = sections.map(\.name)
        for existing in config.sections where !names.contains(existing) {
            config.removeSection(named: existing)
        }
        for draft in sections where !config.sections.contains(draft.name) {
            config.addSection(named: draft.name, path: draft.path)
        }

        if hadGlobalVerifyCommand || !isMonorepo {
            config.set(.verifyCommand, to: verifyCommand)
        }
        config.set(.forbiddenPaths, to: forbiddenPathsRaw)
        config.set(.maxFiles, to: maxFiles.trimmingCharacters(in: .whitespaces))
        config.set(.verifyTimeout, to: verifyTimeout.trimmingCharacters(in: .whitespaces))

        for draft in sections {
            config.set("PATH", to: draft.path.trimmingCharacters(in: .whitespaces), in: draft.name)
            config.set(.verifyCommand, to: draft.verifyCommand, in: draft.name)
            config.set(.forbiddenPaths, to: draft.forbiddenPaths, in: draft.name)
            let timeout = draft.verifyTimeout.trimmingCharacters(in: .whitespaces)
            if timeout.isEmpty {
                // Absent, not empty: the script's fallback keys off the key not
                // being there.
                config.removeKey(AutoTaskConfigFile.Key.verifyTimeout.rawValue, in: draft.name)
            } else {
                config.set(.verifyTimeout, to: timeout, in: draft.name)
            }
        }
        return config
    }

    /// Reported by `mr-review.sh detect-project`, resolved once per load.
    /// Empty when the toolkit is not installed — the warnings that depend on it
    /// simply do not fire, rather than firing on a guess.
    @Published private(set) var projectType: String = ""
    /// Everything `auto-task.sh detect-projects` found, declared or not.
    @Published private(set) var detectedProjects: [AutoTaskSetupPolicy.DetectedProject] = []

    /// Section `PATH` → project type, for the stack-specific advice.
    var sectionProjectTypes: [String: String] {
        Dictionary(
            detectedProjects.map { ($0.path, $0.projectType) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var errors: [AutoTaskConfigDiagnostics.Finding] {
        AutoTaskConfigDiagnostics.errors(in: edited)
    }

    var warnings: [AutoTaskConfigDiagnostics.Finding] {
        AutoTaskConfigDiagnostics.warnings(in: edited, context: diagnosticsContext)
    }

    private var diagnosticsContext: AutoTaskConfigDiagnostics.Context {
        var missing: Set<String> = []
        for draft in sections {
            let path = draft.path.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path != "." else { continue }
            let full = (repositoryPath as NSString).appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: full, isDirectory: &isDirectory) {
                missing.insert(path)
            }
        }
        return AutoTaskConfigDiagnostics.Context(
            projectType: projectType,
            hasMRCreateFile: hasMRCreateFile,
            missingSectionPaths: missing,
            sectionProjectTypes: sectionProjectTypes
        )
    }

    /// Every finding, grouped by the block it belongs to.
    ///
    /// Grouped in one pass rather than filtered per section: each access
    /// re-parses and re-validates the whole file, and asking once per block
    /// would make that quadratic in the number of sub-projects on every
    /// keystroke.
    var findingsByScope: [String?: [AutoTaskConfigDiagnostics.Finding]] {
        Dictionary(grouping: errors + warnings, by: \.scope)
    }

    var canSave: Bool {
        guard case .loaded = loadState else { return false }
        return errors.isEmpty && hasChanges
    }

    var hasChanges: Bool {
        edited.serialized() != original.serialized()
    }

    /// Line-level diff of what saving would change, for the confirmation step.
    var pendingDiff: [(marker: Character, text: String)] {
        let before = original.serialized().components(separatedBy: "\n")
        let after = edited.serialized().components(separatedBy: "\n")
        var out: [(Character, String)] = []
        for (index, line) in after.enumerated() {
            let previous = index < before.count ? before[index] : nil
            if previous == line {
                continue
            }
            if let previous {
                out.append(("-", previous))
            }
            out.append(("+", line))
        }
        // Lines removed off the end.
        if before.count > after.count {
            for line in before[after.count...] {
                out.append(("-", line))
            }
        }
        return out
    }

    /// One probe path and what blocks it.
    struct ProbeResult: Identifiable, Equatable {
        var id: String { path }
        let path: String
        /// The pattern as enforced, and the section it came from.
        let blockedBy: [AutoTaskConfigFile.EffectivePattern]
    }

    /// Which probe paths the configuration would block, and by which pattern.
    ///
    /// This is the most useful thing the editor does, and in a monorepo it is
    /// the *only* honest answer: the guard enforces the global globs plus every
    /// section's rewritten under its `PATH`, so testing against the global list
    /// alone would show a repository as wide open when it is not.
    var probeResults: [ProbeResult] {
        let patterns = edited.effectiveForbiddenPatterns()
        var out: [ProbeResult] = []
        var seen = Set<String>()
        for line in pathProbe.components(separatedBy: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let hits = patterns.filter {
                ForbiddenPathMatcher.matches(path: path, pattern: $0.pattern)
            }
            out.append(ProbeResult(path: path, blockedBy: hits))
        }
        return out
    }

    // MARK: - Actions

    func save() {
        guard errors.isEmpty else { return }
        let config = edited
        do {
            try fileManager.createDirectory(
                atPath: AutoTaskConfigPath.directory(inRepository: repositoryPath),
                withIntermediateDirectories: true
            )
            try config.serialized().write(
                toFile: AutoTaskConfigPath.path(inRepository: repositoryPath),
                atomically: true,
                encoding: .utf8
            )
            original = config
            applyFields(from: config)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func revert() {
        applyFields(from: original)
        saveError = nil
    }

    // MARK: - Sections

    /// Add a sub-project. `/auto-task init-config --auto` only writes the ones
    /// it is confident about and reports the rest as `SKIPPED_PROJECTS`; this
    /// is how those get in.
    func addSection(named name: String, path: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !sections.contains(where: { $0.name == name }) else { return }
        sections.append(SectionDraft(
            name: name,
            path: path.trimmingCharacters(in: .whitespaces)
        ))
    }

    /// Add a sub-project `detect-projects` found, prefilled with whatever the
    /// toolkit derived. A low-confidence entry arrives with an empty command,
    /// which the diagnostics then flag as the error it is.
    func addSection(from project: AutoTaskSetupPolicy.DetectedProject) {
        guard !sections.contains(where: { $0.path == project.path }) else { return }
        sections.append(SectionDraft(
            name: availableSectionName(base: project.name),
            path: project.path,
            verifyCommand: project.verifyCommand,
            forbiddenPaths: project.forbiddenPaths
        ))
    }

    func removeSection(id: UUID) {
        sections.removeAll { $0.id == id }
    }

    /// A name that is not taken yet, for the "add" button.
    func availableSectionName(base: String = "project") -> String {
        guard sections.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while sections.contains(where: { $0.name == "\(base)\(index)" }) { index += 1 }
        return "\(base)\(index)"
    }

    /// Prefill the tester with paths from the repository that the current
    /// patterns are most likely to have opinions about.
    func suggestProbePaths() {
        let interesting = [
            ".gitlab-ci.yml", ".github/workflows/ci.yml", ".octo-dev/auto-task.conf",
            "build.gradle", "app/build.gradle", "settings.gradle",
            "fastlane/Fastfile", "android/fastlane/Fastfile",
            "package-lock.json", "Package.resolved", "Cargo.lock", "go.sum",
            "pubspec.lock",
        ]
        var candidates = interesting.filter {
            fileManager.fileExists(atPath: (repositoryPath as NSString).appendingPathComponent($0))
        }
        // In a monorepo the interesting files live inside the sub-projects, and
        // those are exactly the paths whose protection is easiest to get wrong.
        for draft in sections {
            let path = draft.path.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path != "." else { continue }
            for relative in interesting {
                let candidate = "\(path)/\(relative)"
                let full = (repositoryPath as NSString).appendingPathComponent(candidate)
                if fileManager.fileExists(atPath: full) { candidates.append(candidate) }
            }
        }
        if candidates.isEmpty {
            candidates = ["app/build.gradle", "build.gradle", "fastlane/Fastfile", "src/App.swift"]
        }
        pathProbe = candidates.joined(separator: "\n")
    }
}
