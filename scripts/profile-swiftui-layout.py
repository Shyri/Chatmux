#!/usr/bin/env python3
"""Turn a `sample(1)` capture of a wedged cmux into a SwiftUI-layout verdict.

Motivation
----------
When the main thread pegs at 100% inside SwiftUI, `sample` writes tens of
thousands of lines of call tree and the interesting part is a handful of
symbols buried 40 frames deep. Reading that by hand takes hours; this script
takes seconds and answers the two questions that matter:

  1. Is the burn in SwiftUI layout, and under which container?
  2. Is a lazy list being measured in full on every pass?

It was written while diagnosing a 3.5-hour livelock of the Claude chat panel
(main thread 100%, footprint 1.0 GB -> 8.6 GB, 95.9M live allocations). The
distribution it printed is what identified the cause: three nested
`StackLayout.prioritize` levels probing a `ScrollView`, whose answer measured
the whole `LazyVStack` on every probe.

Usage
-----
    sample <pid> 15 -file /tmp/hang.txt
    python3 scripts/profile-swiftui-layout.py /tmp/hang.txt
    python3 scripts/profile-swiftui-layout.py /tmp/hang.txt --path   # heaviest chain

Reading the output
------------------
`LazyStack<>.measureEstimates` above a percent or two means a lazy list is
being realized in full per layout pass — the virtualization is defeated and
the app is one long transcript away from a livelock. `StackLayout.prioritize`
high alongside `ScrollViewLayoutComputer` means nested flexible stacks are
probing a scroll view for an intrinsic size with varying proposals, so
`ViewSizeCache` misses and each probe re-measures everything.

Percentages are *inclusive* (a symbol plus everything beneath it) and are
computed without double counting a symbol that appears more than once on the
same chain, so nested recursion cannot inflate a number past 100%.
"""

from __future__ import annotations

import argparse
import re
import sys

# `sample` indents each frame with a mix of spaces and tree-drawing glyphs,
# then prints the sample count and the symbol.
FRAME_RE = re.compile(r"^([ +!:|]*?)(\d+)\s+(.*)$")

# Symbols worth calling out, with a one-line reading of what a high number
# means. Order is the order they print in.
TELLTALES: list[tuple[str, str]] = [
    ("LazyStack<>.measureEstimates",
     "a lazy list is measured in FULL each pass; virtualization is defeated"),
    ("ScrollViewLayoutComputer",
     "a ScrollView is being asked for a content-derived size"),
    ("StackLayout.UnmanagedImplementation.prioritize",
     "nested stacks are probing children with varying proposals"),
    ("GeometryReaderLayout.placeSubviews",
     "a GeometryReader roots this subtree"),
    ("ForEachState.forEachItem",
     "the ForEach list is being expanded"),
    ("ViewSizeCache",
     "size caching is running; paired with a high probe count it is missing"),
    ("ButtonLayoutComputer",
     "SwiftUI Buttons bridging to AppKit (allocates NSAppearance per query)"),
    ("_FlexFrameLayout",
     ".frame(min/max:) negotiation"),
    ("StyledTextLayoutEngine",
     "text measurement"),
    ("AG::Graph::UpdateStack::update",
     "total AttributeGraph update cost"),
]


def parse_frames(text: str) -> list[tuple[int, int, str]]:
    """Return (indent, samples, symbol) for every frame in the call graph."""
    lines = text.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if "Call graph" in l)
    except StopIteration:
        raise SystemExit("error: no 'Call graph' section; is this a sample(1) capture?")
    end = next((i for i, l in enumerate(lines) if "Binary Images" in l), len(lines))

    frames = []
    for line in lines[start:end]:
        m = FRAME_RE.match(line)
        if m:
            frames.append((len(m.group(1)), int(m.group(2)), m.group(3)))
    return frames


def main_thread_slice(frames: list[tuple[int, int, str]]) -> tuple[int, list]:
    """Frames under the main thread only, plus its total sample count."""
    try:
        root = next(i for i, (_, _, s) in enumerate(frames) if "main-thread" in s)
    except StopIteration:
        raise SystemExit("error: no main thread in the capture.")
    total = frames[root][1]
    depth = frames[root][0]
    out = []
    for i in range(root + 1, len(frames)):
        if frames[i][0] <= depth:
            break
        out.append(frames[i])
    return total, out


def inclusive(frames: list, needles: list[str]) -> dict[str, int]:
    """Inclusive samples per needle, skipping nested re-occurrences.

    Walking with an explicit depth stack lets us know which needles are
    already on the current chain; counting a symbol only at its shallowest
    occurrence is what keeps deep recursion from inflating the total.
    """
    totals = {n: 0 for n in needles}
    stack: list[tuple[int, set]] = []
    for depth, count, symbol in frames:
        while stack and stack[-1][0] >= depth:
            stack.pop()
        ancestors = stack[-1][1] if stack else set()
        here = set(ancestors)
        for needle in needles:
            if needle in symbol:
                if needle not in ancestors:
                    totals[needle] += count
                here.add(needle)
        stack.append((depth, here))
    return totals


def heaviest_path(frames: list, root_total: int) -> list[tuple[int, str]]:
    """Follow the highest-count child from the root down to a leaf."""
    if not frames:
        return []
    path = []
    idx, cur_depth = -1, -1
    # Seed from the shallowest frames (direct children of the thread root).
    while True:
        block = []
        for j in range(idx + 1, len(frames)):
            if frames[j][0] <= cur_depth:
                break
            block.append((j, frames[j]))
        if not block:
            break
        child_depth = min(n[0] for _, n in block)
        children = [(k, n) for k, n in block if n[0] == child_depth]
        k, node = max(children, key=lambda t: t[1][1])
        path.append((node[1], node[2]))
        idx, cur_depth = k, node[0]
    return path


def tidy(symbol: str) -> str:
    symbol = re.sub(r"\s*\+ \d+\s*\[0x[0-9a-f]+\].*$", "", symbol).strip()
    symbol = re.sub(
        r"\s*\(in (SwiftUICore|SwiftUI|AttributeGraph|AppKit|CoreFoundation"
        r"|HIToolbox|libswiftCore\.dylib|dyld)\)",
        "",
        symbol,
    )
    return re.sub(r"^(specialized |partial apply for |protocol witness for )+", "", symbol)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Summarize a sample(1) capture of a SwiftUI layout hang."
    )
    ap.add_argument("capture", help="file written by `sample <pid> <secs> -file <path>`")
    ap.add_argument("--path", action="store_true", help="also print the heaviest chain")
    ap.add_argument("--app-symbols", metavar="BINARY", default="cmux",
                    help="binary name whose frames are app-owned (default: cmux)")
    args = ap.parse_args()

    try:
        text = open(args.capture, errors="replace").read()
    except OSError as exc:
        raise SystemExit(f"error: {exc}")

    frames = parse_frames(text)
    total, mt = main_thread_slice(frames)
    if total == 0:
        raise SystemExit("error: main thread has zero samples.")

    needles = [name for name, _ in TELLTALES]
    totals = inclusive(mt, needles)

    print(f"main thread: {total} samples\n")
    print(f"{'incl':>8} {'%':>7}  symbol")
    print(f"{'-' * 8} {'-' * 7}  {'-' * 52}")
    for name, meaning in TELLTALES:
        count = totals[name]
        if count == 0:
            continue
        print(f"{count:8d} {100 * count / total:6.2f}%  {name}")
        print(f"{'':>17}  ↳ {meaning}")

    # App-owned frames: what the app itself is doing, as opposed to framework
    # layout churn. Usually tiny during a layout hang — that is the point.
    app_needle = f"(in {args.app_symbols})"
    app_totals: dict[str, int] = {}
    stack: list[tuple[int, set]] = []
    for depth, count, symbol in mt:
        while stack and stack[-1][0] >= depth:
            stack.pop()
        ancestors = stack[-1][1] if stack else set()
        here = set(ancestors)
        if app_needle in symbol:
            key = re.sub(r"\s+\(in .*$", "", tidy(symbol))
            if key not in ancestors:
                app_totals[key] = app_totals.get(key, 0) + count
            here.add(key)
        stack.append((depth, here))

    ranked = sorted(app_totals.items(), key=lambda t: -t[1])[:12]
    if ranked:
        print(f"\ntop app-owned frames (in {args.app_symbols}):")
        for key, count in ranked:
            if key == "main":
                continue
            print(f"{count:8d} {100 * count / total:6.2f}%  {key[:70]}")

    if args.path:
        print("\nheaviest chain:")
        for i, (count, symbol) in enumerate(heaviest_path(mt, total)):
            print(f"{i:4d} {count:7d}  {tidy(symbol)[:96]}")

    lazy = totals["LazyStack<>.measureEstimates"]
    print()
    if lazy * 100 >= total:  # >= 1%
        print(f"VERDICT: lazy list measured in full ({100 * lazy / total:.2f}% of the main "
              f"thread). Virtualization is defeated; this is the livelock class.")
        return 1
    print("VERDICT: no whole-list measurement detected in this capture.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
