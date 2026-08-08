import Foundation

/// The output contract every octo-dev script follows: `KEY=VALUE` lines on
/// stdout, `ERROR=<code>` on stderr, and a meaningful exit code.
///
/// Parsing is deliberately tolerant. These scripts are maintained outside this
/// repository and will grow keys; an unrecognized line must not invalidate the
/// ones cmux does understand.
struct OctoDevScriptOutput: Equatable {
    /// Every `KEY=VALUE` pair seen on stdout. A repeated key keeps the last
    /// value, matching how the shell config itself resolves duplicates.
    private(set) var values: [String: String] = [:]
    /// `ERROR=<code>` from stderr, when present.
    private(set) var errorCode: String?
    private(set) var exitCode: Int32 = 0
    /// The block between `---OUTPUT_TAIL---` and `---END---`, used by `verify`
    /// to carry the tail of the command's own output.
    private(set) var outputTail: String?
    /// Anything on stderr that was not the `ERROR=` line, kept for display when
    /// a script fails in a way the contract does not cover.
    private(set) var rawStandardError: String = ""

    subscript(key: String) -> String? { values[key] }

    /// Whether the run should be treated as a failure. `verify` is the
    /// exception the contract calls out: it always exits 0 and reports its
    /// verdict in `VERIFY_RESULT`, so exit code alone is not the signal.
    var failed: Bool { exitCode != 0 || errorCode != nil }

    init(stdout: String, stderr: String, exitCode: Int32) {
        self.exitCode = exitCode
        rawStandardError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        var insideTail = false
        var tail: [String] = []
        for line in stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The briefing shows the opening fence with a variable number of
            // leading dashes, so match on the label rather than an exact rule.
            if trimmed.hasSuffix("OUTPUT_TAIL---") || trimmed.hasSuffix("OUTPUT_TAIL--") {
                insideTail = true
                continue
            }
            if insideTail {
                if trimmed == "---END---" || trimmed == "--END---" {
                    insideTail = false
                    continue
                }
                tail.append(line)
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, Self.looksLikeAKey(key) else { continue }
            values[key] = String(trimmed[trimmed.index(after: equals)...])
        }
        if !tail.isEmpty {
            outputTail = tail.joined(separator: "\n")
        }

        for line in stderr.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ERROR=") else { continue }
            errorCode = String(trimmed.dropFirst("ERROR=".count))
        }
    }

    /// `KEY` is upper snake case. Without this, a stray line containing `=`
    /// — a shell echo, a path, a diff — would be read as a value.
    private static func looksLikeAKey(_ key: String) -> Bool {
        guard let first = key.first, first.isUppercase || first == "_" else { return false }
        return key.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }
}
