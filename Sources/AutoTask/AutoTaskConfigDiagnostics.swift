import Foundation

/// Validation and advice for `auto-task.conf`.
///
/// Two distinct severities, and the distinction is deliberate:
///
/// - **Errors** block saving. They are cases where the file would be
///   malformed or a value out of range.
/// - **Warnings** never block. They are judgement calls — a verify command
///   that looks too weak, a glob that probably has a hole — and the person
///   editing knows their project better than this code does.
///
/// Every check runs **per scope**. In a monorepo the same rule has a different
/// answer for the preamble and for each `[section]`, and a finding that does
/// not say which one it is about is not actionable.
enum AutoTaskConfigDiagnostics {
    enum Severity: Equatable {
        case error
        case warning
    }

    struct Finding: Identifiable, Equatable {
        let id: String
        let severity: Severity
        let field: AutoTaskConfigFile.Key?
        let message: String
        /// Which part of the file this is about: `nil` is the global preamble,
        /// otherwise the section name.
        let scope: String?

        init(
            id: String,
            severity: Severity,
            field: AutoTaskConfigFile.Key?,
            message: String,
            scope: String? = nil
        ) {
            // Scoped into the id as well: the same rule firing for `lore` and
            // for `functions` is two findings, and `ForEach` needs them to be
            // distinguishable.
            self.id = scope.map { "\($0)/\(id)" } ?? id
            self.severity = severity
            self.field = field
            self.message = message
            self.scope = scope
        }
    }

    /// Extra facts the file itself cannot answer, resolved by the caller.
    ///
    /// Passed in rather than looked up here so this stays pure and testable:
    /// no `FileManager`, no subprocess.
    struct Context {
        var projectType: String = ""
        var hasMRCreateFile: Bool = true
        /// Section paths that do not exist on disk.
        var missingSectionPaths: Set<String> = []
        /// Section path → project type, as reported by `detect-projects`.
        var sectionProjectTypes: [String: String] = [:]

        init(
            projectType: String = "",
            hasMRCreateFile: Bool = true,
            missingSectionPaths: Set<String> = [],
            sectionProjectTypes: [String: String] = [:]
        ) {
            self.projectType = projectType
            self.hasMRCreateFile = hasMRCreateFile
            self.missingSectionPaths = missingSectionPaths
            self.sectionProjectTypes = sectionProjectTypes
        }
    }

    // MARK: - Errors

    static func errors(in config: AutoTaskConfigFile) -> [Finding] {
        var out: [Finding] = []

        // In a monorepo the preamble legitimately has no VERIFY_CMD: each
        // section carries its own and the script never reads a global one.
        // Requiring it here would flag a correct file as broken.
        if !config.isMonorepo {
            out += verifyCommandErrors(in: config, scope: nil)
        }
        out += limitErrors(in: config, scope: nil)
        out += forbiddenErrors(in: config, scope: nil)

        for section in config.sections {
            if (config.path(ofSection: section) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Finding(
                    id: "section.noPath",
                    severity: .error,
                    field: nil,
                    message: String(
                        localized: "autoTask.config.error.sectionNoPath",
                        defaultValue: "[\(section)] has no PATH. Without it the section is skipped entirely: its verification never runs and its forbidden paths protect nothing."
                    ),
                    scope: section
                ))
            }
            out += verifyCommandErrors(in: config, scope: section)
            // Only the timeout is per-section; MAX_FILES is repository-wide.
            out += timeoutErrors(in: config, scope: section)
            out += forbiddenErrors(in: config, scope: section)
        }

        return out
    }

    private static func verifyCommandErrors(
        in config: AutoTaskConfigFile,
        scope: AutoTaskConfigFile.Scope
    ) -> [Finding] {
        let verify = (config.value(for: .verifyCommand, in: scope) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard verify.isEmpty else { return [] }
        let message = scope == nil
            ? String(
                localized: "autoTask.config.error.verifyEmpty",
                defaultValue: "VERIFY_CMD is required. Without it nothing decides whether the run is valid."
            )
            : String(
                localized: "autoTask.config.error.sectionVerifyEmpty",
                defaultValue: "[\(scope ?? "")] has no VERIFY_CMD. A run that touches it reports no_verify_cmd and fails."
            )
        return [Finding(
            id: "verify.empty",
            severity: .error,
            field: .verifyCommand,
            message: message,
            scope: scope
        )]
    }

    private static func limitErrors(
        in config: AutoTaskConfigFile,
        scope: AutoTaskConfigFile.Scope
    ) -> [Finding] {
        var out: [Finding] = []
        if let raw = config.value(for: .maxFiles, in: scope) {
            if let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
                if value < 1 || value > 200 {
                    out.append(Finding(
                        id: "maxFiles.range",
                        severity: .error,
                        field: .maxFiles,
                        message: String(
                            localized: "autoTask.config.error.maxFilesRange",
                            defaultValue: "MAX_FILES must be between 1 and 200."
                        ),
                        scope: scope
                    ))
                }
            } else {
                out.append(Finding(
                    id: "maxFiles.notANumber",
                    severity: .error,
                    field: .maxFiles,
                    message: String(
                        localized: "autoTask.config.error.maxFilesNumber",
                        defaultValue: "MAX_FILES must be a whole number."
                    ),
                    scope: scope
                ))
            }
        }
        out += timeoutErrors(in: config, scope: scope)
        return out
    }

    private static func timeoutErrors(
        in config: AutoTaskConfigFile,
        scope: AutoTaskConfigFile.Scope
    ) -> [Finding] {
        guard let raw = config.value(for: .verifyTimeout, in: scope) else { return [] }
        if let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            guard value < 60 else { return [] }
            return [Finding(
                id: "timeout.range",
                severity: .error,
                field: .verifyTimeout,
                message: String(
                    localized: "autoTask.config.error.timeoutRange",
                    defaultValue: "VERIFY_TIMEOUT must be at least 60 seconds."
                ),
                scope: scope
            )]
        }
        return [Finding(
            id: "timeout.notANumber",
            severity: .error,
            field: .verifyTimeout,
            message: String(
                localized: "autoTask.config.error.timeoutNumber",
                defaultValue: "VERIFY_TIMEOUT must be a whole number of seconds."
            ),
            scope: scope
        )]
    }

    private static func forbiddenErrors(
        in config: AutoTaskConfigFile,
        scope: AutoTaskConfigFile.Scope
    ) -> [Finding] {
        let patterns = config.forbiddenPatterns(in: scope)
        guard Set(patterns).count != patterns.count else { return [] }
        return [Finding(
            id: "forbidden.duplicates",
            severity: .error,
            field: .forbiddenPaths,
            message: String(
                localized: "autoTask.config.error.duplicatePatterns",
                defaultValue: "FORBIDDEN_PATHS contains duplicate patterns."
            ),
            scope: scope
        )]
    }

    // MARK: - Warnings

    /// `context.projectType` is the value `mr-review.sh detect-project`
    /// reports, not a cmux-side classification: the toolkit's detection is the
    /// authority, and a parallel one here would disagree with it eventually.
    static func warnings(in config: AutoTaskConfigFile, context: Context) -> [Finding] {
        var out: [Finding] = []

        // Without mr-create.yaml the run aborts in its first second, so this is
        // the most useful thing this screen can tell you.
        if !context.hasMRCreateFile {
            out.append(Finding(
                id: "mrCreate.missing",
                severity: .warning,
                field: nil,
                message: String(
                    localized: "autoTask.config.warn.mrCreateMissing",
                    defaultValue: "No .octo-dev/mr-create.yaml. /auto-task aborts immediately without it."
                )
            ))
        }

        // CI and the toolkit's own directory live at the repository root, so
        // only the global list can protect them — a section's globs are
        // rewritten under its PATH and can never reach them.
        let globalPatterns = config.forbiddenPatterns(in: nil)
        if !globalPatterns.contains(".gitlab-ci.yml") && !globalPatterns.contains(".github/") {
            out.append(Finding(
                id: "forbidden.noCI",
                severity: .warning,
                field: .forbiddenPaths,
                message: String(
                    localized: "autoTask.config.warn.noCIProtection",
                    defaultValue: "CI configuration is not protected. Consider adding .gitlab-ci.yml and .github/."
                )
            ))
        }

        if !globalPatterns.contains(".octo-dev/") {
            out.append(Finding(
                id: "forbidden.noOctoDev",
                severity: .warning,
                field: .forbiddenPaths,
                message: String(
                    localized: "autoTask.config.warn.noOctoDevProtection",
                    defaultValue: "This configuration is not protected. Consider adding .octo-dev/ so runs cannot rewrite their own rules."
                )
            ))
        }

        // A leftover from before the repository was split into sections: with
        // sections present the script never reads the global VERIFY_CMD, so it
        // reads as the repository's verification and is not run at all.
        if config.isMonorepo,
           let global = config.value(for: .verifyCommand),
           !global.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Finding(
                id: "verify.deadGlobal",
                severity: .warning,
                field: .verifyCommand,
                message: String(
                    localized: "autoTask.config.warn.deadGlobalVerify",
                    defaultValue: "A global VERIFY_CMD is set but this file has sub-projects, and the script only reads theirs. It never runs — remove it or the file claims a verification it does not have."
                )
            ))
        }

        out += scopeWarnings(in: config, scope: nil, projectType: context.projectType)

        var pathOwners: [String: [String]] = [:]
        for section in config.sections {
            let path = (config.path(ofSection: section) ?? "")
                .trimmingCharacters(in: .whitespaces)
            pathOwners[path, default: []].append(section)

            out += sectionPathWarnings(section: section, path: path, context: context)
            out += scopeWarnings(
                in: config,
                scope: section,
                projectType: context.sectionProjectTypes[path] ?? ""
            )
            out += doublePrefixWarnings(in: config, section: section, path: path)
        }

        for (path, owners) in pathOwners where owners.count > 1 && !path.isEmpty {
            out.append(Finding(
                id: "section.duplicatePath",
                severity: .warning,
                field: nil,
                message: String(
                    localized: "autoTask.config.warn.duplicateSectionPath",
                    defaultValue: "\(owners.joined(separator: ", ")) all point at \(path). Which one a change resolves to is not defined, and its verification runs more than once."
                ),
                scope: owners.sorted().first
            ))
        }

        return out
    }

    /// Checks that apply the same way to the preamble and to a section.
    private static func scopeWarnings(
        in config: AutoTaskConfigFile,
        scope: AutoTaskConfigFile.Scope,
        projectType: String
    ) -> [Finding] {
        var out: [Finding] = []
        let patterns = config.forbiddenPatterns(in: scope)
        let verify = config.value(for: .verifyCommand, in: scope) ?? ""

        // `*/x` does not cover a root-level `x` — the single most common hole.
        for pattern in patterns where pattern.hasPrefix("*/") && !pattern.hasSuffix("/") {
            let rootForm = String(pattern.dropFirst(2))
            guard !rootForm.isEmpty, !rootForm.contains("*"), !patterns.contains(rootForm) else { continue }
            out.append(Finding(
                id: "forbidden.missingRoot.\(pattern)",
                severity: .warning,
                field: .forbiddenPaths,
                message: String(
                    localized: "autoTask.config.warn.missingRootForm",
                    defaultValue: "\(pattern) does not cover a root-level \(rootForm). Add that form to the list too."
                ),
                scope: scope
            ))
        }

        if AutoTaskSetupPolicy.isMobile(projectType: projectType), !verify.isEmpty,
           !mentionsABinaryBuild(verify) {
            out.append(Finding(
                id: "verify.testsOnly",
                severity: .warning,
                field: .verifyCommand,
                message: String(
                    localized: "autoTask.config.warn.testsOnly",
                    defaultValue: "This looks like unit tests only. On a mobile project a broken layout passes tests and fails to build — consider assembling the binary too."
                ),
                scope: scope
            ))
        }

        if let destructive = destructiveFragment(in: verify) {
            out.append(Finding(
                id: "verify.destructive",
                severity: .warning,
                field: .verifyCommand,
                message: String(
                    localized: "autoTask.config.warn.destructive",
                    defaultValue: "VERIFY_CMD contains '\(destructive)'. It runs on every teammate's machine, unattended."
                ),
                scope: scope
            ))
        }

        return out
    }

    private static func sectionPathWarnings(
        section: String,
        path: String,
        context: Context
    ) -> [Finding] {
        var out: [Finding] = []
        guard !path.isEmpty else { return out }

        // `PATH=.` is not the harmless spelling of "the root" it looks like:
        // the script prefixes the section's globs with it literally, producing
        // `./x`, which never matches a path from `git diff --name-only`.
        if path == "." || path == "./" {
            out.append(Finding(
                id: "section.dotPath",
                severity: .warning,
                field: nil,
                message: String(
                    localized: "autoTask.config.warn.sectionDotPath",
                    defaultValue: "PATH=. makes this section's forbidden paths read ./x, which never matches a real path. Put repository-wide rules in the global block instead."
                ),
                scope: section
            ))
        } else if context.missingSectionPaths.contains(path) {
            out.append(Finding(
                id: "section.missingPath",
                severity: .warning,
                field: nil,
                message: String(
                    localized: "autoTask.config.warn.sectionMissingPath",
                    defaultValue: "\(path) does not exist in this repository. No change can ever resolve to this section, so its verification never runs."
                ),
                scope: section
            ))
        }
        return out
    }

    /// A glob inside `[lore]` written as `lore/pubspec.lock` becomes
    /// `lore/lore/pubspec.lock` once the script prefixes it — a hole that reads
    /// as protection.
    private static func doublePrefixWarnings(
        in config: AutoTaskConfigFile,
        section: String,
        path: String
    ) -> [Finding] {
        guard !path.isEmpty, path != "." else { return [] }
        let prefix = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/"
        var out: [Finding] = []
        for pattern in config.forbiddenPatterns(in: section) where pattern.hasPrefix(prefix) {
            out.append(Finding(
                id: "forbidden.doublePrefix.\(pattern)",
                severity: .warning,
                field: .forbiddenPaths,
                message: String(
                    localized: "autoTask.config.warn.doublePrefix",
                    defaultValue: "\(pattern) is already relative to \(path), so it is enforced as \(prefix)\(pattern) and matches nothing. Drop the \(prefix) prefix."
                ),
                scope: section
            ))
        }
        return out
    }

    /// Whether the command produces an artifact rather than only running tests.
    static func mentionsABinaryBuild(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let markers = [
            "assemble", "xcodebuild build", "build ", "bundle", "archive",
            "flutter build", "compile",
        ]
        for marker in markers where lowered.contains(marker) {
            return true
        }
        return false
    }

    /// Fragments worth flagging before this runs unattended on other people's
    /// machines.
    static func destructiveFragment(in command: String) -> String? {
        let lowered = command.lowercased()
        let dangerous = ["rm -rf", "--force", "-f ", "git push", "reset --hard", "clean -fd"]
        for fragment in dangerous where lowered.contains(fragment) {
            return fragment.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
