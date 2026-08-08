import Foundation

/// Reader and writer for `.octo-dev/auto-task.conf`.
///
/// The file is `KEY=VALUE`, parsed by a bash script — **not executed by it**.
/// The rules below are the script's, and cmux has to match them exactly rather
/// than impose its own idea of an ini file:
///
/// - a key is found by `^[[:space:]]*KEY[[:space:]]*=`
/// - **if a key appears more than once, the last one wins**
/// - whitespace around the value is trimmed
/// - **one** surrounding pair of quotes (`"` or `'`) is removed, if present
/// - lines starting with `#` are comments
/// - no variable interpolation, no multi-line values, no sections
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
        case assignment(key: String, value: String, indent: String, quote: Character?)
    }

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
            if let assignment = Self.parseAssignment(line) {
                parsed.append(assignment)
            } else {
                parsed.append(.other(line))
            }
        }
        lines = parsed
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

    /// The effective value for a key — the **last** assignment wins.
    func value(for key: String) -> String? {
        var found: String?
        for line in lines {
            if case .assignment(let name, let value, _, _) = line, name == key {
                found = value
            }
        }
        return found
    }

    func value(for key: Key) -> String? { value(for: key.rawValue) }

    func intValue(for key: Key) -> Int? {
        guard let raw = value(for: key)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(raw)
    }

    var forbiddenPatterns: [String] {
        ForbiddenPathMatcher.patterns(from: value(for: .forbiddenPaths) ?? "")
    }

    /// Keys present in the file, in order of first appearance.
    var presentKeys: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            if case .assignment(let name, _, _, _) = line, seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }

    // MARK: - Writing

    /// Set a key in place. Updates the **last** assignment — the one that wins
    /// — so the effective value and the edited line are the same one. A key
    /// that is not present is appended.
    mutating func set(_ key: String, to value: String) {
        var lastIndex: Int?
        for (index, line) in lines.enumerated() {
            if case .assignment(let name, _, _, _) = line, name == key {
                lastIndex = index
            }
        }
        guard let index = lastIndex else {
            lines.append(.assignment(key: key, value: value, indent: "", quote: Self.needsQuoting(value) ? "\"" : nil))
            return
        }
        guard case .assignment(let name, _, let indent, let quote) = lines[index] else { return }
        // Keep the existing quoting style unless the new value now requires it.
        let resolvedQuote: Character? = quote ?? (Self.needsQuoting(value) ? "\"" : nil)
        lines[index] = .assignment(key: name, value: value, indent: indent, quote: resolvedQuote)
    }

    mutating func set(_ key: Key, to value: String) { set(key.rawValue, to: value) }

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
