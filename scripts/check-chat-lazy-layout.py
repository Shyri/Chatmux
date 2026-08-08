#!/usr/bin/env python3
"""Guard the chat transcript's lazy-layout contract.

Sibling of ``check-sidebar-lazy-layout.py``. The sidebar earned its guard the
hard way — five separate livelocks in the same class (#2586, #5323, #5764,
#5845, #6210, #6556) — and the chat panel then reproduced the family three more
times in a week:

* 2026-08-04  ``ChatDropContainer`` had no ``sizeThatFits``, so SwiftUI sized
  the representable through AppKit's fitting size and the nested hosting view
  measured the whole ``LazyVStack``. 17% of the main thread in
  ``LazyStack.measureEstimates``.  (a9712e8b90)
* 2026-08-05  A ``GeometryReader`` wrapped the entire chat to read one width,
  mediating every measurement of the transcript below it. 17% in
  ``GeometryReaderLayout.placeSubviews``.  (1746ae85c0)
* 2026-08-08  The nested ``NSHostingView`` kept an ``intrinsicContentSize`` in
  sync with its content despite being pinned to four edges, so each update
  invalidated constraints, posted that to the window, and the resulting display
  cycle re-fired the lazy list's prefetch. **55%** of the main thread in
  ``signalPrefetch -> requestUpdate -> _postWindowNeedsUpdateConstraints``.
  (0732d68bc5)

Each was found by sampling a hung app in the wild, which costs a working day
and requires the user to lose their session. This catches the same shapes at
PR time instead.

The rules are not stylistic. Every pattern below is one of those three bugs.

Exit codes:
    0  the scanned files satisfy the contract
    1  an anti-pattern was found, a required primitive is missing, or a guarded
       region could not be located (a rename must fail loudly rather than let
       the guard rot into a no-op)
"""

import argparse
import importlib.util
import os
import re
import sys


def _load_sidebar_guard():
    """Reuse the sibling guard's Swift-neutralizing engine.

    Comment/string neutralization and brace-matched region extraction are the
    genuinely hard parts and are already tested by
    ``tests/test_ci_sidebar_lazy_layout_guard.py``. Importing them keeps one
    implementation instead of two that drift.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "check-sidebar-lazy-layout.py")
    spec = importlib.util.spec_from_file_location("_sidebar_lazy_layout_guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_engine = _load_sidebar_guard()
neutralize_swift = _engine.neutralize_swift
extract_type_body = _engine.extract_type_body
_extract_func_body = _engine.extract_function_body


def _extract_property_body(neutralized, name):
    """Body of a computed property — ``var <name>: some View { ... }``.

    The sidebar's regions are functions; the chat's are computed properties, so
    the imported extractor alone finds nothing. Matching a bare `var` would also
    catch stored properties, hence the requirement of a `{` before any `=` or
    newline-terminated declaration.
    """
    match = re.search(r"\bvar\s+" + re.escape(name) + r"\s*:", neutralized)
    if not match:
        return None
    i = match.end()
    n = len(neutralized)
    while i < n and neutralized[i] != "{":
        # A stored property (`var x: Int = 3`) or the end of the declaration
        # means there is no body to scan.
        if neutralized[i] in "=;\n" and neutralized[i] != "\n":
            return None
        if neutralized[i] == "}":
            return None
        i += 1
    if i >= n:
        return None
    depth = 0
    start = i
    while i < n:
        if neutralized[i] == "{":
            depth += 1
        elif neutralized[i] == "}":
            depth -= 1
            if depth == 0:
                return neutralized[start:i + 1]
        i += 1
    return None


def extract_region(neutralized, name):
    """A guarded region, whether it is written as a function or a property.

    Accepting both means converting `var chatContent` to `func chatContent()`
    does not silently drop it out of the guard.
    """
    body = _extract_func_body(neutralized, name)
    if body is not None:
        return body
    return _extract_property_body(neutralized, name)


# Container regions that define the transcript's steady-state layout. All three
# must exist; a rename fails the guard rather than silently skipping.
GUARDED_FUNCTIONS = ("chatContent", "chatColumn", "messageList")

CONTAINER_FORBIDDEN = (
    (re.compile(r"\bGeometryReader\b"),
     "GeometryReader (1746ae85c0: wrapping the chat to read a length makes it "
     "mediate every measurement of the transcript below — 17% of the main "
     "thread. Use .containerRelativeFrame, and never route geometry through "
     "@State)"),
    (re.compile(r"\.sizeThatFits\s*\("),
     "manual .sizeThatFits( call (measuring the transcript by hand realizes "
     "every lazy row; let SwiftUI size the stack)"),
    (re.compile(r"\bProposedViewSize\s*\([^)]*\bnil\b"),
     "ProposedViewSize(..., nil) (proposing nil on an axis asks the LazyVStack "
     "for its natural size, realizing every row)"),
    (re.compile(r"\bonGeometryChange\b"),
     "onGeometryChange (geometry-driven state writes re-trigger layout, the "
     "same feedback shape as the GeometryReader probes)"),
)

# Row views inside the transcript's LazyVStack. A row that measures or publishes
# its own geometry defeats virtualization for the whole list — this is the
# #5323 shape that cost the sidebar one of its five incidents.
GUARDED_ROW_TYPES = (
    "TextBlockRow",
    "ToolUseCard",
    "ToolBatchView",
    "ToolResultCard",
    "SlashCommandRow",
    "ApprovalRequestCard",
    "UserQuestionCard",
)

ROW_FORBIDDEN = (
    (re.compile(r"\bGeometryReader\b"),
     "GeometryReader in a chat row (a row measuring itself forces SwiftUI to "
     "realize every row per pass; row heights are implicit)"),
    (re.compile(r"\bonGeometryChange\b"),
     "onGeometryChange in a chat row (geometry-driven state writes re-trigger "
     "layout)"),
    (re.compile(r"\.anchorPreference\s*\("),
     ".anchorPreference( in a chat row (per-row frame publication aggregated "
     "by an ancestor is the #5323 virtualization defeat)"),
    (re.compile(r"\.overlayPreferenceValue\s*\("),
     ".overlayPreferenceValue( in a chat row (consuming aggregated row "
     "geometry inside a row is the same feedback shape)"),
    (re.compile(r"\.sizeThatFits\s*\("),
     "manual .sizeThatFits( call in a chat row (measuring from a row realizes "
     "its lazy siblings)"),
)

# Primitives the three fixes depend on. Each must remain present, so removing
# one fails here instead of in the wild.
REQUIRED_PRIMITIVES = (
    ("messageList", re.compile(r"\bLazyVStack\s*\("),
     "LazyVStack( — the transcript must stay lazy; a plain VStack realizes "
     "every row on each pass"),
)

# `ChatDropContainer` hosts SwiftUI inside AppKit inside SwiftUI. Both of its
# defences are invisible one-liners that look removable, and removing either
# reintroduces a livelock that no test reproduces — a scale test mounting the
# panel standalone cannot recreate the sandwich. So they are pinned here.
DROP_CONTAINER_MARKERS = (
    (re.compile(r"func\s+sizeThatFits\s*\("),
     "ChatDropContainer.sizeThatFits (a9712e8b90: without it SwiftUI sizes the "
     "representable via AppKit's fitting size, and the nested NSHostingView "
     "measures the entire transcript)"),
    (re.compile(r"\bsizingOptions\s*="),
     "NSHostingView.sizingOptions (0732d68bc5: pinned to four edges the host "
     "needs no content-derived constraints, and keeping them made every update "
     "post setNeedsUpdateConstraints to the window, re-entering the display "
     "cycle — 55% of the main thread)"),
)


def check_source(source, path_label):
    """Return a list of human-readable violation strings (empty == clean)."""
    violations = []
    neutralized = neutralize_swift(source)

    for name in GUARDED_FUNCTIONS:
        body = extract_region(neutralized, name)
        if body is None:
            violations.append(
                "%s: guarded function `%s` not found. If it was renamed, update "
                "GUARDED_FUNCTIONS in this guard — do not let it become a no-op."
                % (path_label, name)
            )
            continue
        for pattern, reason in CONTAINER_FORBIDDEN:
            if pattern.search(body):
                violations.append("%s: `%s` contains %s" % (path_label, name, reason))

    for func_name, pattern, reason in REQUIRED_PRIMITIVES:
        body = extract_region(neutralized, func_name)
        if body is None:
            continue  # already reported above
        if not pattern.search(body):
            violations.append(
                "%s: `%s` is missing %s" % (path_label, func_name, reason)
            )

    for type_name in GUARDED_ROW_TYPES:
        body = extract_type_body(neutralized, type_name)
        if body is None:
            continue  # rows may legitimately move to another file
        for pattern, reason in ROW_FORBIDDEN:
            if pattern.search(body):
                violations.append("%s: `%s` contains %s" % (path_label, type_name, reason))

    container = extract_type_body(neutralized, "ChatDropContainer")
    if container is None:
        violations.append(
            "%s: `ChatDropContainer` not found. It hosts the chat inside AppKit "
            "inside SwiftUI and carries two livelock defences; if it moved, "
            "point this guard at its new home." % path_label
        )
    else:
        for pattern, reason in DROP_CONTAINER_MARKERS:
            if not pattern.search(container):
                violations.append(
                    "%s: `ChatDropContainer` is missing %s" % (path_label, reason)
                )

    return violations


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_targets():
    return (os.path.join(repo_root_dir(), "Sources", "Panels", "ClaudeChatPanelView.swift"),)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file",
        default=None,
        help="Swift source to scan (defaults to Sources/Panels/ClaudeChatPanelView.swift).",
    )
    args = parser.parse_args(argv)

    targets = (args.file,) if args.file else default_targets()

    all_violations = []
    for path in targets:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
        except OSError as exc:
            print("check-chat-lazy-layout: cannot read %s: %s" % (path, exc), file=sys.stderr)
            return 1
        label = os.path.relpath(path, repo_root_dir())
        all_violations.extend(check_source(source, label))

    if all_violations:
        print("check-chat-lazy-layout: FAILED", file=sys.stderr)
        for violation in all_violations:
            print("  - %s" % violation, file=sys.stderr)
        print(
            "\nThese are not style rules. Each pattern is one of the three chat "
            "livelocks of 2026-08-04, 08-05 and 08-08, every one of which was "
            "found by sampling a hung app in production.",
            file=sys.stderr,
        )
        return 1

    print("check-chat-lazy-layout: ok (%d file(s))" % len(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
