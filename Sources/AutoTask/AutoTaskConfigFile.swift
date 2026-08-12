import Foundation

/// Reader and writer for `.octo-dev/auto-task.conf`.
///
/// The file is `KEY=VALUE`, parsed by a bash script — **not executed by it**.
/// The rules below are the script's, and cmux has to match them exactly rather
/// than impose its own idea of an ini file:
///
/// - a key is found by `^[[:space:]]*KEY[[:space:]]*=`
/// - **if a key appears more than once, the last one wins** (within its scope)
/// - whitespace around the value is trimmed
/// - **one** surrounding pair of quotes (`"` or `'`) is removed, if present
/// - lines starting with `#` are comments
/// - no variable interpolation and no multi-line values
/// - **`[sections]`**, one per sub-project in a monorepo. Everything before
///   the first section is the global preamble; a file with no sections behaves
///   exactly as it always did, so single-project repos are unaffected.
///
/// The file is committed and shared by the whole team, so writing it back
/// preserves the header comments and the existing key order. An edit shows up
/// in review as the one line that changed, not as a rewritten file.
struct AutoTaskConfigFile: Equatable {
    enum Key: String, CaseIterable {
        case verifyCommand = "VERIFY_CMD"
        case forbiddenPaths = "FORBIDDEN_PATHS"
        case maxFiles = "MAX_FILES"
        case verifyTimeout = "VERIFY_TIMEOUT"
    }

    /// One physical line, kept so a round-trip is faithful.
    enum Line: Equatable {
        case other(String)                                  // comment or blank
        case section(name: String, raw: String)             // `[lore]`
        case assignment(key: String, value: String, indent: String, quote: Character?)
    }

    /// Which part of the file a lookup or edit applies to.
    ///
    /// `nil` is the global preamble — everything before the first `[section]`.
    /// This mirrors the script's `read_conf KEY FILE [SECTION]` exactly: with
    /// no section it reads the preamble only, never the sections.
    typealias Scope = String?

    private(set) var lines: [Line]
    /// Whether the source ended with a newline, so a round-trip does not add or
    /// drop one.
    private let hadTrailingNewline: Bool

    // MARK: - Parsing

    init(text: String) {
        var parsed: [Line] = []
        hadTrailingNewline = text.hasSuffix("\n")
        // `omittingEmptySubsequences: false` keeps blank lines; dropping the
        // final empty piece avoids inventing a line that was never there.
        var raw = text.components(separatedBy: "\n")
        if hadTrailingNewline, raw.last == "" { raw.removeLast() }

        for line in raw {
            if let section = Self.parseSection(line) {
                parsed.append(section)
            } else if let assignment = Self.parseAssignment(line) {
                parsed.append(assignment)
            } else {
                parsed.append(.other(line))
            }
        }
        lines = parsed
    }

    /// `^[[:space:]]*\[name\][[:space:]]*$`, matching the script's awk rule.
    /// A comment is never a section header.
    private static func parseSection(_ line: String) -> Line? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return nil }
        let name = String(trimmed.dropFirst().dropLast())
        guard !name.isEmpty, !name.contains("]") else { return nil }
        return .section(name: name, raw: line)
    }

    /// `^[[:space:]]*KEY[[:space:]]*=` — a leading `#` disqualifies the line.
    private static func parseAssignment(_ line: String) -> Line? {
        let leadingCount = line.prefix { $0 == " " || $0 == "\t" }.count
        let indent = String(line.prefix(leadingCount))
        let body = line.dropFirst(leadingCount)
        guard !body.hasPrefix("#") else { return nil }
        guard let equals = body.firstIndex(of: "=") else { return nil }

        let keyPart = body[..<equals].trimmingCharacters(in: .whitespaces)
        guard !keyPart.isEmpty else { return nil }
        // A key is a shell-ish identifier; anything else is not an assignment.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard keyPart.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        let rawValue = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        let (value, quote) = Self.unquote(rawValue)
        return .assignment(key: keyPart, value: value, indent: indent, quote: quote)
    }

    /// Strip exactly one surrounding pair of quotes. `"a"b"` loses only the
    /// outer pair, matching the script.
    private static func unquote(_ value: String) -> (String, Character?) {
        guard value.count >= 2, let first = value.first, let last = value.last else {
            return (value, nil)
        }
        guard first == last, first == "\"" || first == "'" else { return (value, nil) }
        return (String(value.dropFirst().dropLast()), first)
    }

    // MARK: - Reading values

    /// The effective value for a key in a scope — the **last** assignment in
    /// that scope wins.
    ///
    /// With no section this reads the global preamble *only*, never a
    /// section's, which is what the script does. Reading them together would
    /// silently pick up a sub-project's `VERIFY_CMD` as if it were the
    /// repository's.
    func value(for key: String, in scope: Scope = nil) -> String? {
        var current: String?
        var found: String?
        for line in lines {
            switch line {
            case .section(let name, _):
                current = name
            case .assignment(let name, let value, _, _):
                if current == scope, name == key { found = value }
            case .other:
                break
            }
        }
        return found
    }

    func value(for key: Key, in scope: Scope = nil) -> String? {
        value(for: key.rawValue, in: scope)
    }

    func intValue(for key: Key, in scope: Scope = nil) -> Int? {
        guard let raw = value(for: key, in: scope)?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return Int(raw)
    }

    func forbiddenPatterns(in scope: Scope = nil) -> [String] {
        ForbiddenPathMatcher.patterns(from: value(for: .forbiddenPaths, in: scope) ?? "")
    }

    var forbiddenPatterns: [String] { forbiddenPatterns(in: nil) }

    /// Sub-project sections, in file order. Empty for a single-project repo.
    var sections: [String] {
        var out: [String] = []
        for line in lines {
            if case .section(let name, _) = line, !out.contains(name) { out.append(name) }
        }
        return out
    }

    var isMonorepo: Bool { !sections.isEmpty }

    /// A section's `PATH`, which is what its `FORBIDDEN_PATHS` are relative to.
    func path(ofSection section: String) -> String? {
        value(for: "PATH", in: section)
    }

    /// Keys present in the file, in order of first appearance.
    func presentKeys(in scope: Scope = nil) -> [String] {
        var current: String?
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            switch line {
            case .section(let name, _):
                current = name
            case .assignment(let name, _, _, _):
                if current == scope, seen.insert(name).inserted { out.append(name) }
            case .other:
                break
            }
        }
        return out
    }

    var presentKeys: [String] { presentKeys(in: nil) }

    // MARK: - Writing

    /// Set a key in place, inside a scope.
    ///
    /// Updates the **last** assignment in that scope — the one that wins — so
    /// the effective value and the edited line are the same one. A key absent
    /// from the scope is appended at the end of it, which for the global
    /// preamble means *before the first section*, not at the end of the file.
    /// Appending globally after `[lore]` would silently make it a `lore` key.
    mutating func set(_ key: String, to value: String, in scope: Scope = nil) {
        var current: String?
        var lastIndex: Int?
        var scopeEnd: Int?
        for (index, line) in lines.enumerated() {
            switch line {
            case .section(let name, _):
                if current == scope, scopeEnd == nil { scopeEnd = index }
                current = name
            case .assignment(let name, _, _, _):
                if current == scope, name == key { lastIndex = index }
            case .other:
                break
            }
        }
        if current == scope { scopeEnd = lines.count }

        if let index = lastIndex {
            guard case .assignment(let name, _, let indent, let quote) = lines[index] else { return }
            let resolvedQuote: Character? = quote ?? (Self.needsQuoting(value) ? "\"" : nil)
            lines[index] = .assignment(key: name, value: value, indent: indent, quote: resolvedQuote)
            return
        }

        let line = Line.assignment(
            key: key,
            value: value,
            indent: "",
            quote: Self.needsQuoting(value) ? "\"" : nil
        )
        if let end = scopeEnd, end <= lines.count {
            lines.insert(line, at: end)
        } else {
            lines.append(line)
        }
    }

    mutating func set(_ key: Key, to value: String, in scope: Scope = nil) {
        set(key.rawValue, to: value, in: scope)
    }

    /// A value with whitespace or shell metacharacters has to stay quoted, or
    /// the script reads a truncated command.
    static func needsQuoting(_ value: String) -> Bool {
        value.contains(where: { $0 == " " || $0 == "\t" || $0 == "#" || $0 == "&" || $0 == "|" || $0 == ";" })
    }

    /// Serialize, preserving comments, blank lines, order and indentation.
    func serialized() -> String {
        var out: [String] = []
        for line in lines {
            switch line {
            case .other(let text):
                out.append(text)
            case .section(_, let raw):
                out.append(raw)
            case .assignment(let key, let value, let indent, let quote):
                if let quote {
                    out.append("\(indent)\(key)=\(quote)\(value)\(quote)")
                } else {
                    out.append("\(indent)\(key)=\(value)")
                }
            }
        }
        var text = out.joined(separator: "\n")
        if hadTrailingNewline { text += "\n" }
        return text
    }
}
