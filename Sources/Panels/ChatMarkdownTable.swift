import Foundation

/// A GFM table lifted out of a chat message, and the text around it.
///
/// **Why this exists.** MarkdownUI renders tables by having every cell publish
/// an `Anchor<CGRect>` through `anchorPreference`, merging them into one
/// dictionary that travels up the view tree, and then reading it back twice —
/// `backgroundPreferenceValue` and `overlayPreferenceValue`, each wrapping a
/// `GeometryReader` — to paint the borders (`TableBounds.swift:75`).
///
/// The layout is not the problem; the decoration is. Those anchors do not stop
/// at the table: they climb to the transcript's `NSHostingView` and get
/// recombined on **every** layout pass. A single measured chat here held 32
/// tables with 891 cells in 57 messages, so scrolling recombined a dictionary
/// of ~900 anchors per pass. A sample of the hung app had 6881 of 6934 stacks
/// inside `AG::Graph::UpdateStack::update()` under `GraphHost.updatePreferences`.
///
/// Cells can be laid out by `Grid`, which is a real `Layout` and costs nothing
/// in the preference system, and borders can be drawn **per cell** instead of
/// from a global rectangle. Then no anchors need to exist at all.
struct ChatMarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading
        case center
        case trailing
    }

    let headers: [String]
    let rows: [[String]]
    let alignments: [Alignment]

    var columnCount: Int { headers.count }
}

/// A message split into plain markdown and the tables inside it.
enum ChatMarkdownSegment: Equatable {
    case markdown(String)
    case table(ChatMarkdownTable)
}

/// Splits a message into segments, extracting only top-level GFM tables.
///
/// Deliberately conservative. A table is lifted out only when it is
/// unambiguous — flush left, outside a fenced code block, header and delimiter
/// rows agreeing on the column count. Anything else stays inside its markdown
/// segment and renders exactly as it does today: a wrong split would corrupt a
/// message, which is far worse than a slow one.
enum ChatMarkdownSegmenter {
    static func segments(in text: String) -> [ChatMarkdownSegment] {
        let lines = text.components(separatedBy: "\n")
        var out: [ChatMarkdownSegment] = []
        var pending: [String] = []
        var insideFence = false
        var index = 0

        func flushPending() {
            guard !pending.isEmpty else { return }
            let joined = pending.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.markdown(joined))
            }
            pending = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                pending.append(line)
                index += 1
                continue
            }
            // A pipe inside a fenced block is code, not a table.
            if insideFence || !isTableRow(line) {
                pending.append(line)
                index += 1
                continue
            }
            guard index + 1 < lines.count,
                  let alignments = delimiterAlignments(lines[index + 1]) else {
                pending.append(line)
                index += 1
                continue
            }
            let headers = cells(in: line)
            guard headers.count == alignments.count, headers.count > 1 else {
                pending.append(line)
                index += 1
                continue
            }

            var rows: [[String]] = []
            var cursor = index + 2
            while cursor < lines.count, isTableRow(lines[cursor]) {
                var row = cells(in: lines[cursor])
                // GFM: rows shorter than the header are padded, longer ones
                // truncated. Doing the same keeps `Grid` rectangular.
                if row.count < headers.count {
                    row += Array(repeating: "", count: headers.count - row.count)
                } else if row.count > headers.count {
                    row = Array(row.prefix(headers.count))
                }
                rows.append(row)
                cursor += 1
            }

            flushPending()
            out.append(.table(ChatMarkdownTable(
                headers: headers,
                rows: rows,
                alignments: alignments
            )))
            index = cursor
        }

        flushPending()
        return out
    }

    /// Whether the message contains something this splitter would extract.
    static func containsTable(_ text: String) -> Bool {
        for segment in segments(in: text) {
            if case .table = segment { return true }
        }
        return false
    }

    // MARK: - Row parsing

    /// A table row is flush left (up to three spaces, as GFM allows) and has a
    /// pipe. Indented further it is a code block.
    private static func isTableRow(_ line: String) -> Bool {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    /// `|---|:--:|---:|` → one alignment per column, or nil if the line is not
    /// a delimiter row.
    private static func delimiterAlignments(_ line: String) -> [ChatMarkdownTable.Alignment]? {
        guard isTableRow(line) else { return nil }
        let pieces = cells(in: line)
        guard !pieces.isEmpty else { return nil }
        var out: [ChatMarkdownTable.Alignment] = []
        for piece in pieces {
            let value = piece.trimmingCharacters(in: .whitespaces)
            guard value.count >= 1,
                  value.allSatisfy({ $0 == "-" || $0 == ":" }),
                  value.contains("-") else { return nil }
            let left = value.hasPrefix(":")
            let right = value.hasSuffix(":")
            switch (left, right) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.trailing)
            default: out.append(.leading)
            }
        }
        return out
    }

    /// Split on unescaped pipes, dropping the leading and trailing ones.
    static func cells(in line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                // Keep the pipe, drop the backslash: `\|` is a literal pipe.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                out.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if escaped { current.append("\\") }
        out.append(current)

        // `| a | b |` splits into ["", " a ", " b ", ""]; the empty ends are the
        // outer pipes, which GFM makes optional.
        if out.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeFirst() }
        if out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
