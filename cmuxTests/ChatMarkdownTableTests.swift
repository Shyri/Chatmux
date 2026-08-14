import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: lifting GFM tables out of MarkdownUI.
///
/// MarkdownUI draws table borders from a global rectangle, which it can only
/// know by having every cell publish an `Anchor<CGRect>` through
/// `anchorPreference`. Those anchors do not stop at the table: they climb to
/// the transcript's hosting view and get recombined on every layout pass. One
/// measured chat held 32 tables with 891 cells in 57 messages, and a sample of
/// the hung app had 6881 of 6934 stacks inside
/// `AG::Graph::UpdateStack::update()` under `GraphHost.updatePreferences`.
///
/// The splitter is the risky half of the fix: it runs on every assistant
/// message, and a wrong split corrupts what the user reads. These tests are
/// mostly about what it must **refuse** to touch.
@Suite struct ChatMarkdownSegmenterTests {
    private func tables(_ text: String) -> [ChatMarkdownTable] {
        ChatMarkdownSegmenter.segments(in: text).compactMap {
            if case .table(let table) = $0 { return table }
            return nil
        }
    }

    private func markdown(_ text: String) -> [String] {
        ChatMarkdownSegmenter.segments(in: text).compactMap {
            if case .markdown(let value) = $0 { return value }
            return nil
        }
    }

    @Test func aPlainTableIsLiftedOut() {
        let text = """
        | Name | Count |
        |------|-------|
        | a    | 1     |
        | b    | 2     |
        """
        let found = tables(text)
        #expect(found.count == 1)
        #expect(found.first?.headers == ["Name", "Count"])
        #expect(found.first?.rows == [["a", "1"], ["b", "2"]])
    }

    @Test func alignmentComesFromTheDelimiterRow() {
        let text = """
        | l | c | r |
        |:--|:-:|--:|
        | 1 | 2 | 3 |
        """
        #expect(tables(text).first?.alignments == [.leading, .center, .trailing])
    }

    /// The prose around a table has to survive intact, in order.
    @Test func textAroundTheTableIsKept() {
        let text = """
        Before the table.

        | a | b |
        |---|---|
        | 1 | 2 |

        After the table.
        """
        let segments = ChatMarkdownSegmenter.segments(in: text)
        #expect(segments.count == 3)
        if case .markdown(let first) = segments[0] {
            #expect(first.contains("Before the table."))
        } else {
            Issue.record("expected markdown first")
        }
        if case .markdown(let last) = segments[2] {
            #expect(last.contains("After the table."))
        } else {
            Issue.record("expected markdown last")
        }
    }

    /// The one that would corrupt a message: pipes inside a fenced code block
    /// are code — shell pipelines, box drawing — not a table.
    @Test func pipesInsideAFenceAreNotATable() {
        let text = """
        ```bash
        | a | b |
        |---|---|
        cat x | grep y
        ```
        """
        #expect(tables(text).isEmpty)
        #expect(markdown(text).count == 1)
    }

    @Test func aFenceAfterATableStillEndsUpAsCode() {
        let text = """
        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        let x = 1
        ```
        """
        #expect(tables(text).count == 1)
        #expect(markdown(text).contains { $0.contains("```swift") })
    }

    /// Without a delimiter row it is not a table, just text with pipes.
    @Test func aHeaderWithoutADelimiterIsNotATable() {
        #expect(tables("| a | b |\n| 1 | 2 |").isEmpty)
    }

    /// A "table" of one column is more often a stray pipe than a table, and
    /// GFM needs at least the pipe-delimited shape to be unambiguous.
    @Test func aSingleColumnIsLeftAlone() {
        #expect(tables("| a |\n|---|\n| 1 |").isEmpty)
    }

    /// Indented four spaces it is a code block, not a table.
    @Test func anIndentedTableIsLeftAlone() {
        let text = "    | a | b |\n    |---|---|\n    | 1 | 2 |"
        #expect(tables(text).isEmpty)
    }

    /// GFM pads short rows and truncates long ones. `Grid` needs the result to
    /// be rectangular or the columns stop lining up.
    @Test func raggedRowsAreSquaredOff() {
        let text = """
        | a | b | c |
        |---|---|---|
        | 1 |
        | 1 | 2 | 3 | 4 |
        """
        let found = tables(text).first
        #expect(found?.rows == [["1", "", ""], ["1", "2", "3"]])
    }

    /// `\\|` is a literal pipe inside a cell, not a column break.
    @Test func escapedPipesStayInsideTheCell() {
        let text = """
        | expr | meaning |
        |------|---------|
        | a \\| b | or |
        """
        #expect(tables(text).first?.rows == [["a | b", "or"]])
    }

    /// The outer pipes are optional in GFM.
    @Test func aTableWithoutOuterPipesIsRead() {
        let text = """
        a | b
        --|--
        1 | 2
        """
        let found = tables(text).first
        #expect(found?.headers == ["a", "b"])
        #expect(found?.rows == [["1", "2"]])
    }

    @Test func severalTablesInOneMessageAreAllLifted() {
        let text = """
        | a | b |
        |---|---|
        | 1 | 2 |

        text between

        | c | d |
        |---|---|
        | 3 | 4 |
        """
        #expect(tables(text).count == 2)
    }

    @Test func containsTableAgreesWithTheSplit() {
        #expect(ChatMarkdownSegmenter.containsTable("| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(ChatMarkdownSegmenter.containsTable("just prose") == false)
        #expect(ChatMarkdownSegmenter.containsTable("```\n| a | b |\n|---|---|\n```") == false)
    }

    /// The classifier has to send these to the new path, and everything else
    /// exactly where it went before.
    @Test func theProbeRoutesTablesToTheTabularPath() {
        let probe = ChatMarkdownComplexityProbe.shared
        #expect(probe.classify("| a | b |\n|---|---|\n| 1 | 2 |") == .tabular)
        #expect(probe.classify("plain prose") == .simple)
        #expect(probe.classify("```\ncode\n```") == .heavy)
        #expect(probe.classify("- one\n- two") == .heavy)
        // Both a table and code: still tabular, and the fenced part stays with
        // MarkdownUI inside the segments.
        #expect(probe.classify("| a | b |\n|---|---|\n| 1 | 2 |\n\n```\nx\n```") == .tabular)
    }

    /// A table shape the splitter refuses must not be routed to the tabular
    /// path — it would render as plain text and lose the table.
    @Test func aRefusedTableShapeStaysHeavy() {
        #expect(ChatMarkdownComplexityProbe.shared.classify("| a |\n|---|\n| 1 |") == .heavy)
    }

    /// Empty cells are legitimate and must not collapse the column count.
    @Test func emptyCellsKeepTheirColumn() {
        let text = """
        | a | b | c |
        |---|---|---|
        |   | 2 |   |
        """
        #expect(tables(text).first?.rows == [["", "2", ""]])
    }
}
