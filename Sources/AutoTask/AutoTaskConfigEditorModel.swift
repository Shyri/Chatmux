import Combine
import Foundation

/// Editing state for one repository's `auto-task.conf`.
///
/// Holds the parsed file plus the in-progress field values, so validation is
/// live and the diff shown before saving is the real one — serialized from the
/// same object that will be written.
@MainActor
final class AutoTaskConfigEditorModel: ObservableObject {
    enum LoadState: Equatable {
        case missing(stack: AutoTaskConfigTemplate.Stack)
        case loaded
        case unreadable(String)
    }

    let repositoryPath: String

    @Published private(set) var loadState: LoadState = .loaded
    @Published var verifyCommand: String = ""
    @Published var forbiddenPathsRaw: String = ""
    @Published var maxFiles: String = ""
    @Published var verifyTimeout: String = ""
    /// Paths typed into the tester, one per line.
    @Published var pathProbe: String = ""
    @Published private(set) var hasMRCreateFile: Bool = false
    @Published private(set) var saveError: String?

    private var original: AutoTaskConfigFile
    private let fileManager: FileManager

    init(repositoryPath: String, fileManager: FileManager = .default) {
        self.repositoryPath = repositoryPath
        self.fileManager = fileManager
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
            loadState = .missing(stack: AutoTaskConfigTemplate.detectStack(inRepository: repositoryPath))
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

    private func applyFields(from config: AutoTaskConfigFile) {
        verifyCommand = config.value(for: .verifyCommand) ?? ""
        forbiddenPathsRaw = config.value(for: .forbiddenPaths) ?? ""
        maxFiles = config.value(for: .maxFiles) ?? "25"
        verifyTimeout = config.value(for: .verifyTimeout) ?? "1800"
    }

    // MARK: - Derived state

    /// The file as it would be written right now.
    var edited: AutoTaskConfigFile {
        var config = original
        config.set(.verifyCommand, to: verifyCommand)
        config.set(.forbiddenPaths, to: forbiddenPathsRaw)
        config.set(.maxFiles, to: maxFiles.trimmingCharacters(in: .whitespaces))
        config.set(.verifyTimeout, to: verifyTimeout.trimmingCharacters(in: .whitespaces))
        return config
    }

    var stack: AutoTaskConfigTemplate.Stack {
        AutoTaskConfigTemplate.detectStack(inRepository: repositoryPath)
    }

    var errors: [AutoTaskConfigDiagnostics.Finding] {
        AutoTaskConfigDiagnostics.errors(in: edited)
    }

    var warnings: [AutoTaskConfigDiagnostics.Finding] {
        AutoTaskConfigDiagnostics.warnings(
            in: edited,
            stack: stack,
            hasMRCreateFile: hasMRCreateFile
        )
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

    /// Which probe paths `FORBIDDEN_PATHS` would block, and by which pattern.
    /// This is the most useful thing the editor does — the glob semantics have
    /// traps that reading the list does not reveal.
    var probeResults: [(path: String, blockedBy: [String])] {
        let patterns = ForbiddenPathMatcher.patterns(from: forbiddenPathsRaw)
        var out: [(String, [String])] = []
        for line in pathProbe.components(separatedBy: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            out.append((path, ForbiddenPathMatcher.matchingPatterns(path: path, patterns: patterns)))
        }
        return out
    }

    // MARK: - Actions

    /// Create the file from the detected stack's template.
    func createFromTemplate() {
        let stack = AutoTaskConfigTemplate.detectStack(inRepository: repositoryPath)
        let directory = AutoTaskConfigPath.directory(inRepository: repositoryPath)
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let text = AutoTaskConfigTemplate.starterFile(for: stack)
            try text.write(
                toFile: AutoTaskConfigPath.path(inRepository: repositoryPath),
                atomically: true,
                encoding: .utf8
            )
            reload()
        } catch {
            saveError = error.localizedDescription
        }
    }

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
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func revert() {
        applyFields(from: original)
        saveError = nil
    }

    /// Prefill the tester with paths from the repository that the current
    /// patterns are most likely to have opinions about.
    func suggestProbePaths() {
        var candidates: [String] = []
        let interesting = [
            ".gitlab-ci.yml", ".github/workflows/ci.yml", ".octo-dev/auto-task.conf",
            "build.gradle", "app/build.gradle", "settings.gradle",
            "fastlane/Fastfile", "android/fastlane/Fastfile",
            "package-lock.json", "Package.resolved", "Cargo.lock", "go.sum",
        ]
        for relative in interesting {
            let full = (repositoryPath as NSString).appendingPathComponent(relative)
            if fileManager.fileExists(atPath: full) {
                candidates.append(relative)
            }
        }
        if candidates.isEmpty {
            candidates = ["app/build.gradle", "build.gradle", "fastlane/Fastfile", "src/App.swift"]
        }
        pathProbe = candidates.joined(separator: "\n")
    }
}
