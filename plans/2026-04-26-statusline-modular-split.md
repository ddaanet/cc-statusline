# Statusline modular split (issues 2-5)

Follow-up plan for `claude/statusline-command.sh` after issues 0+1 (commits
1d9fb27, db0f7ab) shipped. Each issue is independent; can be done in any
order, but issue 3 should land before issue 4 so shellcheck targets the
final layout.

## Issue 2 — idle-mode info on line 1's spare width

**Goal:** in user-stop mode the sparkline is suppressed (`stop_reason ==
"end_turn"` check). Repurpose the spare width on line 1's right side
(after cost/ctx/bar) to show idle-relevant info: running-turn duration,
time of last call, cache freshness.

**Useful pairing:** `statusLine.refreshInterval` setting (min 1s) lets the
script re-render on a timer without user input. A "running" duration
could update live during long turns. Confirm cost is acceptable — each
render parses the transcript, runs jq, etc.

## Issue 3 — split into `claude/lib/` modules

`claude/statusline-command.sh` is currently ~38 KB / >9 ktok. Target:
each shell file under 4 ktok. Source, don't fork.

**Proposed split** (functional grouping, no micro-optimizations):

| File | Functions / content |
|------|--------------------|
| `claude/lib/colors.sh` | SGR constants (RED, GREEN, …, RESET, …) |
| `claude/lib/format-utils.sh` | `vislen`, `vis_truncate`, `emit_truncated`, `get_cols`, `kilos`, `format_duration`, `format_age`, `format_5h_reset`, `format_7d_reset` |
| `claude/lib/sparkline.sh` | `_SPARK_*`, `spark_char`, `_spark_*`, `display_turn_sparkline` (biggest single function) |
| `claude/lib/context-display.sh` | `get_token_color`, `display_token_bar`, `get_transcript_context` |
| `claude/lib/account-display.sh` | `display_plan_limit_percent`, `display_vertical_bar`, `display_plan_usage`, `display_api_usage`, `render_account` |
| `claude/statusline-command.sh` | orchestrator only — parse JSON, source modules, assemble + emit |

After split: update `claude/test-statusline-helpers.sh` to `source
claude/lib/format-utils.sh` instead of awk-extracting bodies from the
script.

## Issue 4 — wire shellcheck + tests into precommit

Pre-existing shellcheck warnings to triage (none introduced by issue 1):
- Unused `BRRED`, `BRGREEN`, `BRYELLOW`, `BRCYAN`, `BRMAGENTA`, `BLINK`,
  `DIM` color constants
- `SC2086` (quoting) around `kilos`, `format_duration`
- `SC2046` (word splitting) in `kilos`'s `bc` substitution
- `SC2016` (single-quoted expressions) in test (intentional)

**Open decision:** fix all vs add `.shellcheckrc` with disable-list. Lean
toward fixing — most are trivial.

Wire `bash claude/test-statusline-helpers.sh` and `shellcheck claude/**/*.sh`
into precommit (current hook setup unknown — check `.git/hooks/` and any
project-level pre-commit framework).

## Issue 5 — centered ellipsis on hard-truncate

When `vis_truncate` cuts visible content (i.e. would have emitted more
cells than `max`), replace the last visible char of the output with a
centered ellipsis `…` (U+2026) so the cut is visually obvious.

**Thorny bits to handle carefully in `vis_truncate`:**
- Detect "did we actually truncate" (vs. input was already short).
- The replaced char's color must be preserved — track the active SGR
  state at the moment of replacement and emit the ellipsis in that
  state.
- The ellipsis itself is a 3-byte UTF-8 codepoint; emit its bytes
  verbatim, not via the per-byte loop.
- Edge case: `max == 0` shouldn't emit an ellipsis (no room for one).
- Edge case: `max == 1` and content was longer — emit ellipsis only.

Update `claude/test-statusline-helpers.sh` to cover the ellipsis cases
once implemented.
