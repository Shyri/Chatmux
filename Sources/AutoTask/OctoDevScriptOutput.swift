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
    /// Every value seen for a key, in order.
    ///
    /// Some commands report a list by repeating a key rather than by emitting
    /// blocks — `init-config --auto` prints one `PROJECT=` line per
    /// sub-project — and `values` would keep only the last of them.
    private(set) var allValues: [String: [String]] = [:]
    /// `ERROR=<code>` from stderr, when present.
    private(set) var errorCode: String?
    private(set) var exitCode: Int32 = 0
    /// The block between `---OUTPUT_TAIL---` and `---END---`, used by `verify`
    /// to carry the tail of the command's own output.
    private(set) var outputTail: String?
    /// Every `---LABEL--- … ---END---` block, in order, with its raw lines.
    /// `detect-projects` emits one `PROJECT` block per sub-project; `verify`
    /// emits one `OUTPUT_TAIL`. Kept generic so a new block type does not need
    /// this parser changed.
    private(set) var blocks: [Block] = []

    /// A `---LABEL--- … ---END---` section of the output. A struct rather than
    /// a tuple because tuples do not conform to `Equatable`.
    struct Block: Equatable {
        let label: String
        let lines: [String]
    }
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

        var currentLabel: String?
        var currentLines: [String] = []
        for line in stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let label = Self.blockLabel(trimmed) {
                // A fence either closes the open block — `---END---` or the
                // matching `---X_END---`, which `verify` uses — or opens a new
                // one. Opening while a block is already open closes it first,
                // so a missing closer costs one block, not all of them.
                if let open = currentLabel, Self.closes(label, open: open) {
                    blocks.append(Block(label: open, lines: currentLines))
                    currentLabel = nil
                    currentLines = []
                    continue
                }
                // A closer with nothing open: `verify` nests `---OUTPUT_TAIL---
                // … ---END---` inside its per-project block, so by the time
                // `---VERIFY_END---` arrives that block is already closed.
                // Treating it as a new block would invent a `VERIFY_END` one.
                if label == "END" || label.hasSuffix("_END") { continue }
                if let open = currentLabel {
                    blocks.append(Block(label: open, lines: currentLines))
                }
                currentLabel = Self.normalize(label)
                currentLines = []
                continue
            }
            if currentLabel != nil {
                currentLines.append(line)
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, Self.looksLikeAKey(key) else { continue }
            let value = String(trimmed[trimmed.index(after: equals)...])
            values[key] = value
            allValues[key, default: []].append(value)
        }
        // An unterminated block still counts: a truncated script should not
        // lose everything it did emit.
        if let label = currentLabel {
            blocks.append(Block(label: label, lines: currentLines))
        }
        for block in blocks where block.label == "OUTPUT_TAIL" {
            outputTail = block.lines.joined(separator: "\n")
        }

        for line in stderr.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ERROR=") else { continue }
            errorCode = String(trimmed.dropFirst("ERROR=".count))
        }
    }

    /// Whether a fence closes the block that is currently open.
    ///
    /// `verify` brackets each sub-project with `---VERIFY_BEGIN---` and
    /// `---VERIFY_END---` rather than the generic `---END---`.
    private static func closes(_ label: String, open: String) -> Bool {
        label == "END" || label == "\(open)_END"
    }

    /// `X_BEGIN` and `X` are the same block, so callers ask for one name.
    private static func normalize(_ label: String) -> String {
        label.hasSuffix("_BEGIN") ? String(label.dropLast("_BEGIN".count)) : label
    }

    /// `---LABEL---`, tolerating a stray dash — the fence is written by hand in
    /// places and has shown up as `--END---`.
    private static func blockLabel(_ line: String) -> String? {
        var value = line
        while value.hasPrefix("-") { value.removeFirst() }
        while value.hasSuffix("-") { value.removeLast() }
        guard !value.isEmpty, value != line else { return nil }
        guard value.allSatisfy({ $0.isUppercase || $0 == "_" }) else { return nil }
        return value
    }

    /// The `KEY=VALUE` pairs inside a block, for the ones that carry them.
    func pairs(inBlocksLabelled label: String) -> [[String: String]] {
        var out: [[String: String]] = []
        for block in blocks where block.label == label {
            var values: [String: String] = [:]
            for line in block.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
                guard Self.looksLikeAKey(key) else { continue }
                values[key] = String(trimmed[trimmed.index(after: equals)...])
            }
            if !values.isEmpty { out.append(values) }
        }
        return out
    }

    /// `KEY` is upper snake case. Without this, a stray line containing `=`
    /// — a shell echo, a path, a diff — would be read as a value.
    private static func looksLikeAKey(_ key: String) -> Bool {
        guard let first = key.first, first.isUppercase || first == "_" else { return false }
        return key.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }
}
