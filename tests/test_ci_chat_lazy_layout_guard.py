#!/usr/bin/env python3
"""CI guard for ./scripts/check-chat-lazy-layout.py.

Verifies the guard reports "ok" on the real cmux repo and *fails* on every way
the chat transcript's lazy-layout contract can be broken. The negative cases are
the point: a guard that cannot fail is a guard that has rotted into a no-op, and
this class of bug has now cost eight production livelocks between the sidebar
and the chat.

Cases:
  (a) The real repo passes.
  (b) A fixture whose guarded regions are clean but whose comments and string
      literals name every forbidden token still passes — the real source
      documents the anti-patterns it forbids, so neutralization has to work.
  (c) Removing `NSHostingView.sizingOptions` fails. That is the 2026-08-08
      hang: 55% of the main thread in signalPrefetch -> requestUpdate ->
      _postWindowNeedsUpdateConstraints.
  (d) Removing `ChatDropContainer.sizeThatFits` fails. That is 2026-08-04.
  (e) A `GeometryReader` in `chatContent` fails. That is 2026-08-05.
  (f) Downgrading the transcript from `LazyVStack` to a plain `VStack` fails.
  (g) `.anchorPreference` in a chat row fails (the #5323 shape).
  (h) `GeometryReader` in a chat row fails (the #6556 shape, which shipped in
      stable v0.64.17 and livelocked in the wild).
  (i) Renaming a guarded region fails loudly rather than silently skipping it.
  (j) Removing `ChatDropContainer` entirely fails loudly.
  (k) A region written as a `func` instead of a `var` is still scanned.
"""

import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-chat-lazy-layout.py")
REAL_SOURCE = os.path.join(ROOT_DIR, "Sources", "Panels", "ClaudeChatPanelView.swift")

FAILURES = []


def run_guard(path):
    """Return (exit_code, combined_output) for a scan of ``path``."""
    result = subprocess.run(
        [sys.executable, GUARD, "--file", path],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout + result.stderr


def check(label, condition, detail=""):
    if condition:
        print("ok   %s" % label)
    else:
        FAILURES.append(label)
        print("FAIL %s%s" % (label, ("\n     " + detail) if detail else ""))


def scan_text(label, source, expect_fail, expect_substring=None):
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False, encoding="utf-8") as handle:
        handle.write(source)
        path = handle.name
    try:
        code, output = run_guard(path)
        if expect_fail:
            check(label, code != 0, "guard passed but should have failed:\n     " + output.strip())
            if expect_substring and code != 0:
                check(
                    label + " (message)",
                    expect_substring in output,
                    "expected %r in:\n     %s" % (expect_substring, output.strip()),
                )
        else:
            check(label, code == 0, output.strip())
    finally:
        os.unlink(path)


# A minimal source that satisfies every rule. Fixtures below break it one way at
# a time, so each case proves exactly one rule fires.
CLEAN = '''
import SwiftUI

struct ClaudeChatPanelView: View {
    private var chatContent: some View {
        VStack(spacing: 0) {
            chatColumn
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            messageList
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    TextBlockRow(row: row)
                }
            }
        }
    }
}

struct ChatDropContainer<Content: View>: NSViewRepresentable {
    func makeNSView(context: Context) -> ChatDropZoneNSView {
        let host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = []
        return ChatDropZoneNSView()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ChatDropZoneNSView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private struct TextBlockRow: View, Equatable {
    var body: some View {
        Text("hello")
    }
}
'''


def main():
    # (a)
    code, output = run_guard(REAL_SOURCE)
    check("(a) the real chat panel passes", code == 0, output.strip())

    # (b) neutralization: the real file documents what it forbids.
    documented = CLEAN.replace(
        "    private var chatContent: some View {",
        '''    /// Do not use GeometryReader here, and never call .sizeThatFits(
    /// or pass ProposedViewSize(width: 1, height: nil) — see the comments.
    private var chatContent: some View {
        let note = "GeometryReader .anchorPreference( onGeometryChange"
        _ = note
''',
    )
    scan_text("(b) forbidden tokens in comments and strings are ignored", documented, expect_fail=False)

    # (c) the 2026-08-08 hang
    scan_text(
        "(c) removing sizingOptions fails",
        CLEAN.replace("        host.sizingOptions = []\n", ""),
        expect_fail=True,
        expect_substring="sizingOptions",
    )

    # (d) the 2026-08-04 hang
    scan_text(
        "(d) removing ChatDropContainer.sizeThatFits fails",
        CLEAN.replace("    func sizeThatFits(", "    func somethingElse("),
        expect_fail=True,
        expect_substring="sizeThatFits",
    )

    # (e) the 2026-08-05 hang
    scan_text(
        "(e) GeometryReader in chatContent fails",
        CLEAN.replace(
            "    private var chatContent: some View {\n        VStack(spacing: 0) {",
            "    private var chatContent: some View {\n        GeometryReader { geo in",
        ),
        expect_fail=True,
        expect_substring="GeometryReader",
    )

    # (f)
    scan_text(
        "(f) LazyVStack downgraded to VStack fails",
        CLEAN.replace("LazyVStack(alignment: .leading, spacing: 12)", "VStack(alignment: .leading, spacing: 12)"),
        expect_fail=True,
        expect_substring="LazyVStack",
    )

    # (g) the #5323 shape
    scan_text(
        "(g) anchorPreference in a row fails",
        CLEAN.replace(
            "    var body: some View {\n        Text(\"hello\")",
            "    var body: some View {\n        Text(\"hello\").anchorPreference(key: K.self, value: .bounds) { $0 }",
        ),
        expect_fail=True,
        expect_substring="anchorPreference",
    )

    # (h) the #6556 shape, which shipped in a stable release
    scan_text(
        "(h) GeometryReader in a row fails",
        CLEAN.replace(
            "    var body: some View {\n        Text(\"hello\")",
            "    var body: some View {\n        GeometryReader { geo in Text(\"hello\") }",
        ),
        expect_fail=True,
        expect_substring="GeometryReader",
    )

    # (i) a rename must not silently drop a region from the guard
    scan_text(
        "(i) renaming a guarded region fails loudly",
        CLEAN.replace("private var messageList: some View", "private var transcriptList: some View"),
        expect_fail=True,
        expect_substring="messageList",
    )

    # (j) so must moving the drop container away
    scan_text(
        "(j) removing ChatDropContainer fails loudly",
        CLEAN.replace("struct ChatDropContainer<Content: View>: NSViewRepresentable {", "struct SomethingElse {"),
        expect_fail=True,
        expect_substring="ChatDropContainer",
    )

    # (k) property or function, the region is still scanned
    as_function = CLEAN.replace(
        "    private var chatContent: some View {\n        VStack(spacing: 0) {",
        "    private func chatContent() -> some View {\n        GeometryReader { geo in",
    )
    scan_text(
        "(k) a region converted to a func is still scanned",
        as_function,
        expect_fail=True,
        expect_substring="GeometryReader",
    )

    print()
    if FAILURES:
        print("test_ci_chat_lazy_layout_guard: %d FAILED" % len(FAILURES))
        for name in FAILURES:
            print("  - %s" % name)
        return 1
    print("test_ci_chat_lazy_layout_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
