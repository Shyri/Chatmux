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
    }

    // MARK: - Errors

    static func errors(in config: AutoTaskConfigFile) -> [Finding] {
        var out: [Finding] = []

        let verify = (config.value(for: .verifyCommand) ?? "").trimmingCharacters(in: .whitespaces)
        if verify.isEmpty {
            out.append(Finding(
                id: "verify.empty",
                severity: .error,
                field: .verifyCommand,
                message: String(
                    localized: "autoTask.config.error.verifyEmpty",
                    defaultValue: "VERIFY_CMD is required. Without it nothing decides whether the run is valid."
                )
            ))
        }

        if let raw = config.value(for: .maxFiles) {
            if let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
                if value < 1 || value > 200 {
                    out.append(Finding(
                        id: "maxFiles.range",
                        severity: .error,
                        field: .maxFiles,
                        message: String(
                            localized: "autoTask.config.error.maxFilesRange",
                            defaultValue: "MAX_FILES must be between 1 and 200."
                        )
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
                    )
                ))
            }
        }

        if let raw = config.value(for: .verifyTimeout) {
            if let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
                if value < 60 {
                    out.append(Finding(
                        id: "timeout.range",
                        severity: .error,
                        field: .verifyTimeout,
                        message: String(
                            localized: "autoTask.config.error.timeoutRange",
                            defaultValue: "VERIFY_TIMEOUT must be at least 60 seconds."
                        )
                    ))
                }
            } else {
                out.append(Finding(
                    id: "timeout.notANumber",
                    severity: .error,
                    field: .verifyTimeout,
                    message: String(
                        localized: "autoTask.config.error.timeoutNumber",
                        defaultValue: "VERIFY_TIMEOUT must be a whole number of seconds."
                    )
                ))
            }
        }

        let patterns = config.forbiddenPatterns
        if Set(patterns).count != patterns.count {
            out.append(Finding(
                id: "forbidden.duplicates",
                severity: .error,
                field: .forbiddenPaths,
                message: String(
                    localized: "autoTask.config.error.duplicatePatterns",
                    defaultValue: "FORBIDDEN_PATHS contains duplicate patterns."
                )
            ))
        }

        return out
    }

    // MARK: - Warnings

    /// `projectType` is the value `mr-review.sh detect-project` reports, not a
    /// cmux-side classification: the toolkit's detection is the authority, and
    /// a parallel one here would disagree with it eventually.
    static func warnings(
        in config: AutoTaskConfigFile,
        projectType: String,
        hasMRCreateFile: Bool
    ) -> [Finding] {
        var out: [Finding] = []
        let patterns = config.forbiddenPatterns
        let verify = config.value(for: .verifyCommand) ?? ""

        // Without mr-create.yaml the run aborts in its first second, so this is
        // the most useful thing this screen can tell you.
        if !hasMRCreateFile {
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

        if !patterns.contains(".gitlab-ci.yml") && !patterns.contains(".github/") {
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

        if !patterns.contains(".octo-dev/") {
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
                )
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
                )
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
                )
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
