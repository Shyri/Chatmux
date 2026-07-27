#!/usr/bin/env python3
"""Extract a version range out of the Claude Code changelog.

Chatmux drives the `claude` CLI in headless stream-json mode, so a Claude Code
release can either break an assumption the fork makes or ship something the chat
panel should expose. `/sync-claude-code` reviews those releases; this script is
its reader.

The changelog is ~500 KB and covers 350+ releases, which is far too much to put
in an agent's context on every run. This prints only the requested range, and in
`--format json` it tags each bullet with the coupling signals it matched so the
triage step can go straight to the relevant fork surface.

Source resolution order:

    --changelog PATH             explicit file
    ~/.claude/cache/changelog.md the local Claude Code cache (read-only)
    raw.githubusercontent.com    downloaded to a temp file

The `~/.claude` cache belongs to Claude Code. This script only ever reads it.

Output is one line per changelog bullet:

    - `2.1.219#a3f1c2` Added Claude Opus 5 (`claude-opus-5`)…  `[model]`

The id is stable across runs, which is what lets the command remember decisions.

Usage:
    claude-code-changelog-delta.py --last 30
    claude-code-changelog-delta.py --since 2.1.200 --until 2.1.210
    claude-code-changelog-delta.py --since 2.1.200 --signals-only
    claude-code-changelog-delta.py --since 2.1.200 --format json
    claude-code-changelog-delta.py --installed        # print the installed version and exit
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

CACHED_CHANGELOG = Path.home() / ".claude" / "cache" / "changelog.md"
REMOTE_CHANGELOG = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
DOWNLOAD_TIMEOUT_SECONDS = 30

VERSION_HEADING = re.compile(r"^##\s+v?(\d+(?:\.\d+)*)\s*$")
BULLET = re.compile(r"^\s*[-*]\s+(.*\S)\s*$")

# Coupling signals: changelog wording -> the kind of fork surface it can affect.
# Used only to annotate bullets; the command decides what is actually relevant.
SIGNAL_PATTERNS: dict[str, str] = {
    "stream-json": r"stream[- ]json|streaming json",
    "headless": r"headless|\bclaude -p\b|--print\b|\bSDK\b|non-interactive",
    "flag": r"`--[a-z][a-z0-9-]*`|\s--[a-z][a-z0-9-]{2,}\b",
    "model": r"\bmodel\b|opus|sonnet|haiku|fable|\beffort\b|fast mode|1M context",
    "permission": r"permission|allowlist|denylist|allowed-tools|disallowed-tools|approval|trust",
    "mcp": r"\bMCP\b|mcp-config|mcp_server",
    "slash": r"slash command|/[a-z-]{3,}\b",
    "statusline": r"status ?line|statusLine",
    "session": r"\bresume\b|transcript|session id|session_id|compact|fork[- ]session|checkpoint",
    "hook": r"\bhook\b|hooks\b",
    "subagent": r"subagent|\bagent tool\b|Task tool",
    "tool": r"tool_use|tool result|tool call",
}
COMPILED_SIGNALS = {
    name: re.compile(pattern, re.IGNORECASE) for name, pattern in SIGNAL_PATTERNS.items()
}


def version_key(version: str) -> tuple[int, ...]:
    """Sort key for a dotted version. Numeric, so 2.1.9 < 2.1.10."""
    return tuple(int(part) for part in version.split("."))


def parse_version(raw: str) -> str:
    """Normalize a user-supplied version, rejecting anything non-numeric."""
    candidate = raw.strip().lstrip("v")
    if not re.fullmatch(r"\d+(?:\.\d+)*", candidate):
        raise argparse.ArgumentTypeError(f"not a version number: {raw!r}")
    return candidate


def installed_version() -> str | None:
    """The version of the `claude` binary on PATH, or None if it can't be read."""
    binary = shutil.which("claude")
    if binary is None:
        return None
    try:
        completed = subprocess.run(
            [binary, "--version"], capture_output=True, text=True, timeout=20, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"(\d+(?:\.\d+)+)", completed.stdout)
    return match.group(1) if match else None


def resolve_changelog(explicit: Path | None) -> tuple[str, str]:
    """Return (text, origin). Falls back to the published changelog on GitHub."""
    if explicit is not None:
        if not explicit.is_file():
            sys.exit(f"error: changelog not found: {explicit}")
        return explicit.read_text(encoding="utf-8"), str(explicit)

    if CACHED_CHANGELOG.is_file():
        return CACHED_CHANGELOG.read_text(encoding="utf-8"), str(CACHED_CHANGELOG)

    try:
        with urllib.request.urlopen(REMOTE_CHANGELOG, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
            text = response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        sys.exit(f"error: no local changelog and the download failed: {error}")

    # Kept out of ~/.claude on purpose: that cache belongs to Claude Code.
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix="-claude-changelog.md", delete=False
    ) as handle:
        handle.write(text)
        origin = handle.name
    return text, f"{REMOTE_CHANGELOG} (cached at {origin})"


def parse_changelog(text: str) -> list[dict]:
    """Parse `## <version>` sections into records, newest first."""
    releases: list[dict] = []
    current: dict | None = None
    for line in text.splitlines():
        heading = VERSION_HEADING.match(line)
        if heading:
            current = {"version": heading.group(1), "bullets": []}
            releases.append(current)
            continue
        if current is None:
            continue
        bullet = BULLET.match(line)
        if bullet:
            current["bullets"].append(bullet.group(1))
    return releases


def signals_for(text: str) -> list[str]:
    return [name for name, pattern in COMPILED_SIGNALS.items() if pattern.search(text)]


def bullet_id(version: str, text: str) -> str:
    """Stable id for one changelog bullet, so decisions survive across runs."""
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()[:6]
    return f"{version}#{digest}"


def select(releases: list[dict], since: str | None, until: str | None, last: int | None) -> list[dict]:
    ordered = sorted(releases, key=lambda item: version_key(item["version"]), reverse=True)
    if until is not None:
        until_key = version_key(until)
        ordered = [item for item in ordered if version_key(item["version"]) <= until_key]
    if since is not None:
        since_key = version_key(since)
        ordered = [item for item in ordered if version_key(item["version"]) > since_key]
    elif last is not None:
        ordered = ordered[:last]
    return ordered


def render_markdown(selected: list[dict], origin: str, signals_only: bool) -> str:
    """Compact rendering: one line per bullet, id first, signals last.

    This is the format the triage step reads. It carries the same information as
    --format json (id, text, signals) in roughly a quarter of the bytes.
    """
    lines = [f"<!-- source: {origin} -->"]
    for release in selected:
        rendered: list[str] = []
        for text in release["bullets"]:
            marks = signals_for(text)
            if signals_only and not marks:
                continue
            suffix = f"  `[{','.join(marks)}]`" if marks else ""
            rendered.append(f"- `{bullet_id(release['version'], text)}` {text}{suffix}")
        if signals_only and not rendered:
            continue
        lines.append("")
        lines.append(f"## {release['version']}")
        lines.append("")
        lines.extend(rendered)
    return "\n".join(lines) + "\n"


def render_json(selected: list[dict], origin: str, signals_only: bool) -> str:
    releases = []
    for release in selected:
        bullets = []
        for text in release["bullets"]:
            marks = signals_for(text)
            if signals_only and not marks:
                continue
            bullets.append(
                {
                    "id": bullet_id(release["version"], text),
                    "text": text,
                    "signals": marks,
                }
            )
        if signals_only and not bullets:
            continue
        releases.append({"version": release["version"], "bullets": bullets})
    payload = {"source": origin, "releases": releases}
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract a version range out of the Claude Code changelog.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--since", type=parse_version, help="exclusive lower bound")
    parser.add_argument("--until", type=parse_version, help="inclusive upper bound")
    parser.add_argument("--last", type=int, help="take the N newest releases (ignored with --since)")
    parser.add_argument("--changelog", type=Path, help="read this file instead of resolving a source")
    parser.add_argument("--format", choices=("md", "json"), default="md")
    parser.add_argument(
        "--signals-only",
        action="store_true",
        help="drop bullets that matched no coupling signal (smaller, but can hide "
        "a relevant entry that happens to use unexpected wording)",
    )
    parser.add_argument(
        "--installed",
        action="store_true",
        help="print the installed `claude` version and exit",
    )
    args = parser.parse_args()

    if args.installed:
        version = installed_version()
        if version is None:
            print("unknown", file=sys.stderr)
            return 1
        print(version)
        return 0

    if args.last is not None and args.last <= 0:
        parser.error("--last must be positive")
    if args.since is None and args.last is None:
        args.last = 30

    text, origin = resolve_changelog(args.changelog)
    releases = parse_changelog(text)
    if not releases:
        sys.exit(f"error: no `## <version>` sections found in {origin}")

    selected = select(releases, args.since, args.until, args.last)
    if not selected:
        newest = max(releases, key=lambda item: version_key(item["version"]))["version"]
        print(
            f"No releases in range (newest in changelog: {newest}).",
            file=sys.stderr,
        )
        return 0

    if args.format == "json":
        sys.stdout.write(render_json(selected, origin, args.signals_only))
    else:
        sys.stdout.write(render_markdown(selected, origin, args.signals_only))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
