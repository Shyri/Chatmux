---
description: Review Claude Code releases since the last run and propose Chatmux improvements for approval
---

# Sync Claude Code

Chatmux drives the `claude` CLI in headless stream-json mode, so every Claude Code release can either break
an assumption this fork makes or ship something the chat panel should expose. This command reads the Claude
Code changelog delta since the last run via `scripts/claude-code-changelog-delta.py`, triages it against the
fork's real coupling surfaces, **proposes** the changes worth making, and implements only what the user
approves.

State lives in `scripts/claude-code-sync-state.json` (checked in, following the same idiom as
`scripts/claude-launch-environment-policy.json`). It records where the last run stopped and what was decided
for each changelog entry, so nothing already dismissed gets proposed again.

## Arguments

Parse `$ARGUMENTS`:

- *(empty)* — review from `lastProcessedVersion` in the state file up to the installed version. First run
  with no state file: the last 30 releases.
- `--since <version>` — force the lower bound (exclusive), ignoring the state file.
- `--report` — triage and report only. No approval gate, no code changes, **no state write**.
- `--all` — review every release in the changelog. Expensive; only on request.

## Safety contract

- **Nothing is implemented without explicit user approval** in step 6. The report alone is never a mandate.
- Never write anywhere under `~/.claude/` — the changelog cache and settings there belong to Claude Code,
  not to this repo.
- Never `git push`. Commits land on `main` and stay local for the user to dogfood.
- Never build. Do not run `reload.sh`, `xcodebuild`, or `open` — ask the user to build.
- Stop if the working tree is dirty. This command commits, and it must not sweep unrelated edits into a commit.
- Scope is fork code only: `Sources/ClaudeChat/`, the chat panel UI under `Sources/Panels/`, and tests under
  `cmuxTests/`. Do not propose edits to `~/.claude/settings.json`, `docs/`, or unrelated subsystems.
- Never propose a change without first opening the affected file and confirming the gap is real.

## Steps

### 1. Preflight

```bash
git rev-parse --show-toplevel
git branch --show-current
git status --porcelain
python3 scripts/claude-code-changelog-delta.py --installed
```

Must be the cmux repo, on `main`, clean. If dirty, **stop and tell the user** — do not stash. Record the
installed `claude` version; it is the upper bound of the review and the value written back to the state file.

### 2. Resolve the range

Read `scripts/claude-code-sync-state.json` if it exists. The lower bound is, in order of precedence:
`--since` from the arguments, then `lastProcessedVersion` from the state, then "last 30 releases".

If `lastProcessedVersion` already equals the installed version and no `--since` was passed, **report "no new
Claude Code releases since <version>" and stop** — there is nothing to triage.

### 3. Extract the delta

```bash
python3 scripts/claude-code-changelog-delta.py --since <lower-bound>
# first run instead: python3 scripts/claude-code-changelog-delta.py --last 30
```

The script resolves `~/.claude/cache/changelog.md` read-only and falls back to the published changelog on
GitHub. Each line comes out as `` - `<id>` <text>  `[signals]` `` — the stable `id` is what the state file
keys decisions on. Never read the raw changelog file directly; it is ~500 KB.

The default markdown format is the one to use. `--format json` carries the same fields at ~1.6× the size and
is only worth it for programmatic post-processing. A 30-release first run is ~105 KB; an incremental run of a
few releases is a fraction of that. `--signals-only` roughly halves it by dropping unmatched bullets, at the
cost of possibly hiding an entry that used unexpected wording — acceptable for a wide `--all` sweep, not for
a normal incremental run.

Drop every bullet whose `id` appears in the state file with decision `dismissed` or `not-applicable`.
Bullets marked `deferred` stay in the running.

### 4. Triage against the fork's coupling surfaces

The signals are a hint, not a verdict. Map each surviving bullet to the surface it would touch:

| Signal in the changelog entry | Fork surface to check |
|---|---|
| `stream-json`, new event `type`/`subtype`, `headless` | `Sources/ClaudeChat/ClaudeStreamEvent.swift`, `ClaudeChatRunner.swift` |
| new or changed CLI flags | the spawn argv in `Sources/ClaudeChat/ClaudeChatRunner.swift` |
| `model`, model aliases, fast mode, `--effort` | `ChatModelSelection` / effort enums in `Sources/Panels/ClaudeChatPanel.swift` |
| `permission` modes, `--permission-prompt-tool`, allow/deny rules | `Sources/ClaudeChat/ChatPermissionRules.swift`, `ChatMcpHttpServer.swift` |
| `mcp` config, connection errors, auth | `Sources/ClaudeChat/McpServerCatalog.swift`, `McpHealthProber.swift`, `Sources/Panels/McpManagerPopover.swift` |
| builtin `slash` commands | `Sources/ClaudeChat/SlashCommandRegistry.swift` |
| `statusline` payload fields | `Sources/ClaudeChat/StatusLineRunner.swift` |
| `session`, resume, transcript, compaction | `Sources/ClaudeChat/ClaudeSessionHistory.swift` |
| `hook` | the `ClaudeHook*` sources and their suites in `cmuxTests/` |

Discard without further analysis: interactive TUI, Vim mode, screen reader, Windows, IDE extension,
Bedrock/Vertex, sandbox, Remote Control, plugins/marketplace, telemetry — unless the entry explicitly names
headless mode or the SDK.

Classify what survives:

- **A — Compatibility.** The CLI changed something this fork assumes differently. Highest priority; these are
  latent bugs, not features.
- **B — Adoptable.** A new capability the panel could expose.
- **C — Informational.** Worth knowing, no action.

### 5. Verify each candidate against the code

For every A and B candidate, open the mapped file and confirm the gap is real — the flag really is absent
from argv, the model really is missing from the enum, the event `type` really falls through to the default
case. **Drop any candidate you cannot confirm in the code.** A proposal that turns out to already be
implemented costs more trust than a missed release does.

### 6. Report and ask

Present a table ordered A → B → C: entry, version, class, affected files, effort, whether it needs a test.
Then use `AskUserQuestion` with multi-select over the verified A and B candidates (in batches if there are
more than four) and let the user pick.

With `--report`, stop here. Write nothing.

### 7. Implement what was approved

One atomic commit per approved improvement. Repo rules that apply:

- **Localization.** Every new user-facing string goes in `Resources/Localizable.xcstrings` with **both `en`
  and `ja`**. A `defaultValue` is not a translation.
- **Tests.** Behavior changes need coverage in the fork's own suites (`Chat*`, `Claude*`), and any new test
  file must be wired into `cmux.xcodeproj/project.pbxproj` — an unwired test silently never runs. Check with
  `./scripts/lint-pbxproj-test-wiring.sh`.
- **Do not build and do not push.** Both are the user's.

Commit message style: `feat(ClaudeChat): …` / `fix(ClaudeChat): …`, with the changelog entry and Claude Code
version quoted in the body so the provenance is greppable.

### 8. Update the state

Rewrite `scripts/claude-code-sync-state.json`: `lastProcessedVersion` = the installed version, `lastRunAt` =
today, and one entry per triaged candidate with its `id`, `version`, `summary`, `surface`, `decision`
(`implemented` with the commit sha / `dismissed` with a reason / `deferred` / `not-applicable`) . Commit it
**separately** from the improvement commits, so a revert of one improvement doesn't rewind the whole review.

Only C-class entries that were explicitly judged irrelevant need recording; there is no value in persisting
every discarded TUI fix.

### 9. Report

- Range reviewed (`<from>..<to>`) and how many releases and bullets it covered.
- A/B/C breakdown, and what was dropped in step 5 for lacking evidence in the code.
- What was implemented, with commit shas; what was deferred.
- The build command for the user, since this command never builds:

  ```bash
  rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag <tag>
  ```

## Notes

- This command is fork-only, like `sync-upstream.md`. It lives in a versioned directory, so it travels with
  the next upstream sync.
- Run it *after* `/sync-upstream`, not before: a merge with upstream can already bring changes to the same
  chat sources, and triaging on top of a stale base produces proposals that conflict.
- The signals emitted by the delta script are deliberately loose (`slash` matches any `/word`). They exist to
  order the reading, never to auto-approve anything.
- If a class-A finding turns out to break the chat panel at runtime, say so plainly in the report and treat
  it as the priority, ahead of any adoptable feature in the same batch.
