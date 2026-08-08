import Foundation

/// Decides which repository paths `FORBIDDEN_PATHS` blocks.
///
/// This has to reproduce a **bash `case` pattern**, not a gitignore rule and
/// not `fnmatch` with `FNM_PATHNAME`, because that is what `/auto-task` uses to
/// enforce the list. The two differences that catch people out:
///
/// - **`*` crosses directory separators.** `*/build.gradle` matches
///   `a/b/c/build.gradle` but **not** a root-level `build.gradle`. That is why
///   the stack templates ship both forms.
/// - **A trailing `/` is a directory prefix anchored at the repository root.**
///   `fastlane/` protects `fastlane/Fastfile` but **not**
///   `android/fastlane/Fastfile`; that needs `*/fastlane/`.
///
/// There are no negations and no exclusions.
enum ForbiddenPathMatcher {
    /// Split a raw `FORBIDDEN_PATHS` value into patterns, dropping empties.
    static func patterns(from rawValue: String) -> [String] {
        var out: [String] = []
        for piece in rawValue.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out
    }

    /// Whether `path` — relative to the repository root, no leading `./` — is
    /// blocked by `pattern`.
    static func matches(path: String, pattern: String) -> Bool {
        let path = normalize(path)
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !path.isEmpty else { return false }

        if pattern.hasSuffix("/") {
            // Directory prefix. Anchored: the pattern before the slash must
            // match the leading portion of the path, and something must follow.
            let prefix = String(pattern.dropLast())
            guard !prefix.isEmpty else { return false }
            // Append a glob `*`, not a regex `.*`: this string is about to go
            // through the glob translator, which would escape the dot.
            guard let regex = regex(for: prefix + "/*") else { return false }
            return fullMatch(regex, path)
        }
        guard let regex = regex(for: pattern) else { return false }
        return fullMatch(regex, path)
    }

    /// Every pattern that blocks `path`.
    static func matchingPatterns(path: String, patterns: [String]) -> [String] {
        patterns.filter { matches(path: path, pattern: $0) }
    }

    static func isBlocked(path: String, patterns: [String]) -> Bool {
        for pattern in patterns where matches(path: path, pattern: pattern) {
            return true
        }
        return false
    }

    // MARK: - glob → regex

    private static func normalize(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    /// Translate a bash `case` glob. `*` is `.*` — it crosses `/` — `?` is any
    /// single character, `[...]` passes through as a character class, and
    /// everything else is literal.
    private static func regex(for pattern: String) -> NSRegularExpression? {
        var out = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*":
                out += ".*"
            case "?":
                out += "."
            case "[":
                // Copy the class verbatim up to the closing bracket. An
                // unterminated `[` is a literal, which is what bash does.
                if let close = pattern[index...].firstIndex(of: "]"), close > index {
                    out += String(pattern[index...close])
                    index = close
                } else {
                    out += NSRegularExpression.escapedPattern(for: "[")
                }
            case "\\":
                // Escape: the next character is literal.
                let next = pattern.index(after: index)
                if next < pattern.endIndex {
                    out += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                    index = next
                } else {
                    out += NSRegularExpression.escapedPattern(for: "\\")
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        return try? NSRegularExpression(pattern: "^" + out + "$", options: [])
    }

    private static func fullMatch(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
