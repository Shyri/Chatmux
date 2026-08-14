import MarkdownUI
import SwiftUI

/// Renders a GFM table with `Grid` and per-cell borders.
///
/// The whole point is what it does **not** do: no `anchorPreference`, no
/// `backgroundPreferenceValue`/`overlayPreferenceValue`, no `GeometryReader`.
/// `Grid` is a real `Layout`, so column widths are resolved by the layout
/// system and nothing about this table travels up the preference tree — which
/// is what made scrolling a transcript full of tables peg the main thread
/// inside AttributeGraph. See `ChatMarkdownTable` for the measurements.
///
/// Borders are drawn by each cell on its trailing and bottom edge, with the
/// outer frame closing the remaining two sides. Painting them from a global
/// rectangle is exactly what forced MarkdownUI to publish anchors.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable
    let isDark: Bool
    let palette: ChatPalette
    let fontSize: CGFloat

    /// Deliberately **not** wrapped in a horizontal `ScrollView`.
    ///
    /// One per table would put a nested `NSScrollView` inside the transcript's
    /// own scroll view — 32 of them in the chat that hung — and nested scroll
    /// views in this panel are their own class of trouble. A wide table wraps
    /// its cell text instead, which is what it did before this change.
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { index, cell in
                    cellView(cell, column: index, isHeader: true, isLastRow: table.rows.isEmpty)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        cellView(
                            cell,
                            column: index,
                            isHeader: false,
                            isLastRow: rowIndex == table.rows.count - 1
                        )
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(palette.cardSubtleBg(isDark)))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }

    private var borderColor: Color {
        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }

    private func cellView(
        _ text: String,
        column: Int,
        isHeader: Bool,
        isLastRow: Bool
    ) -> some View {
        let alignment = table.alignments.indices.contains(column)
            ? table.alignments[column]
            : ChatMarkdownTable.Alignment.leading

        return Text(ChatTableCellCache.shared.attributed(for: text))
            .font(.system(size: fontSize - 1, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(palette.fg(isDark))
            .multilineTextAlignment(textAlignment(alignment))
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHeader ? palette.headerBg(isDark) : Color.clear)
            .overlay(alignment: .trailing) {
                // Trailing edge, skipped on the last column so it does not
                // double up with the outer stroke.
                if column < table.columnCount - 1 {
                    Rectangle().fill(borderColor).frame(width: 0.5)
                }
            }
            .overlay(alignment: .bottom) {
                if !isLastRow {
                    Rectangle().fill(borderColor).frame(height: 0.5)
                }
            }
    }

    private func textAlignment(_ alignment: ChatMarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ alignment: ChatMarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// A message that contains at least one GFM table.
///
/// The tables render through `ChatMarkdownTableView`; everything between them
/// keeps the existing behaviour, classified on its own — prose still takes the
/// cheap `AttributedString` path and fenced code still goes to MarkdownUI.
struct ChatTabularMessageView: View {
    let text: String
    let isDark: Bool
    let palette: ChatPalette
    let fontSize: CGFloat

    var body: some View {
        let segments = ChatMarkdownSegmentCache.shared.segments(for: text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .table(let table):
                    ChatMarkdownTableView(
                        table: table,
                        isDark: isDark,
                        palette: palette,
                        fontSize: fontSize
                    )
                case .markdown(let markdown):
                    // `detectBlock`, not `classify`: the segment has no table
                    // left in it, and asking the full classifier could route it
                    // straight back here.
                    switch ChatMarkdownComplexityProbe.detectBlock(markdown) {
                    case .simple:
                        Text(ChatSimpleMarkdownCache.shared.attributed(for: markdown))
                            .foregroundStyle(palette.fg(isDark))
                            .font(.system(size: fontSize))
                            .lineSpacing(2)
                            .tint(isDark ? ChatPalette.cyan : Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .heavy, .tabular:
                        Markdown(ChatMarkdownContentCache.shared.content(for: markdown))
                            .markdownTheme(
                                cmuxChatMarkdownTheme(
                                    isDark: isDark,
                                    palette: palette,
                                    fontSize: fontSize
                                )
                            )
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline markdown for one cell, parsed once and cached.
///
/// Cells are short but numerous — the measured chat had 891 of them — and every
/// re-render would otherwise reparse each one.
final class ChatTableCellCache {
    static let shared = ChatTableCellCache()

    private final class Box {
        let attributed: AttributedString
        init(_ attributed: AttributedString) { self.attributed = attributed }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 2048
    }

    func attributed(for text: String) -> AttributedString {
        let key = text as NSString
        if let box = cache.object(forKey: key) { return box.attributed }
        lock.lock()
        defer { lock.unlock() }
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

/// Segmentation cached by message text.
///
/// `classify` already runs per bubble on every re-render; splitting has to be
/// just as cheap or the fix trades one main-thread cost for another.
final class ChatMarkdownSegmentCache {
    static let shared = ChatMarkdownSegmentCache()

    private final class Box {
        let segments: [ChatMarkdownSegment]
        init(_ segments: [ChatMarkdownSegment]) { self.segments = segments }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 512
    }

    func segments(for text: String) -> [ChatMarkdownSegment] {
        let key = text as NSString
        if let box = cache.object(forKey: key) { return box.segments }
        lock.lock()
        defer { lock.unlock() }
        let parsed = ChatMarkdownSegmenter.segments(in: text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}
