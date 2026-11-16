# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `just test` — run the suite (`bash test-statusline-helpers.sh`). It is one
  flat script of `assert` calls under `## <section>` headings; there is no
  per-test filter. Grep the output for a section or `FAIL`.
- `just lint` — `shellcheck -x` over both entry points, `lib/*.sh` and the tests.
- `just test-bash32` — the suite again under macOS `/bin/bash` (3.2), with a
  PATH shim so the entry points it spawns run under 3.2 too; `#!/usr/bin/env
  bash` and `just test` otherwise pick up a Homebrew bash 5. Skips when
  `/bin/bash` is not 3.2.
- `just precommit` — lint + test + test-bash32.
- `just install` / `just uninstall` — symlink `~/.claude/statusline-command.sh`
  and `~/.claude/subagent-statusline.sh` to this checkout.
- Manual render: pipe a payload into the script, isolated from the real home
  and cache, the same way the suite's `_sp_run` does:
  `printf '%s' '{"model":{"display_name":"Opus 4.8"}}' | HOME=$TMPDIR/h COLUMNS=200 CC_STATUSLINE_STATE_DIR=$TMPDIR/st bash statusline-command.sh`
  The last payload Claude Code sent is dumped to `statusbar.json` in the state
  dir (for debugging only, never a data source). The subagent renderer takes
  the same isolation (`CC_STATUSLINE_STATE_DIR=$TMPDIR/st bash
  subagent-statusline.sh < payload.json`) and dumps `subagent-payload.json`.

## Architecture

Plain bash, rendered by Claude Code on every redraw. `statusline-command.sh`
reads the JSON payload from stdin, resolves its own directory through the
`~/.claude` symlink (manual `readlink` walk, no `readlink -f`), sources
`lib/*.sh` relative to it, then emits line 1 (identity + cost/context/timer,
plus plan limits in plan mode; `$` is the payload's `cost.total_cost_usd`
as-is, main-thread only — no cost is estimated), the account line in API mode, and an optional
last line (`sparkline` per API call or `stats` per user turn, selected by
`~/.claude/statusline-line2`).

`subagent-statusline.sh` is a second entry point, for `subagentStatusLine`: it
resolves its directory and sources `lib/` the same way, parses the panel payload
(`columns`, `tasks[]`) in one `jq` fork, and writes one `{"id","content"}` JSON
line per agent row, built by `lib/subagent-display.sh` (status, agent type,
model/effort, context gauge, a sparkline of the agent's last 16 calls read from
`<session>/subagents/agent-<id>.jsonl`). Any failure prints nothing, which keeps
Claude Code's default rows. It runs every tick for every agent: assemble with
the `_v` helpers (assign, don't `$( )`) and fit widths arithmetically.

- **One payload fork.** Every payload field is extracted in a single `jq` call,
  joined by U+001F and split with `read`. Add new fields to that one call, not
  a new `jq` fork.
- **Private state dir.** The payload dump, timing log and transcript cache live in
  `${CC_STATUSLINE_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/cc-statusline}`,
  resolved once per render by `cc_state_dir_init` (`lib/format-utils.sh`) into
  `CC_STATE_DIR`: created 0700, accepted only if owned by the user and not a
  symlink (`_cc_private_dir`), else empty and everything runs uncached. Never
  write state anywhere else, and never under `/tmp`.
- **Transcript work is cached.** Anything derived from the session `.jsonl`
  goes through `_tx_cached` in `lib/transcript-cache.sh` (keyed on size +
  mtime, under the state dir's `tx-cache/`, or `$TX_CACHE_DIR`). A hit is still
  only accepted after a per-kind `_tx_valid_<kind>` validator (defence in
  depth); a new cache kind without a validator is always a miss.
- **Width.** Claude Code does not pass the column count; `get_cols` probes it
  and a chrome reservation is subtracted to form `EFFECTIVE_COLS`, which bounds
  every row. Line 1 reflows through tiers in `lib/line1-layout.sh`
  (`layout_line1`) rather than dropping segments; `vislen` / `vis_truncate`
  measure and cut SGR-laden UTF-8 strings.
- **External account lib.** `account-validation.sh` (`get_mode`,
  `get_api_provider`, `validate_state`) lives in `../cc-switch`, located via
  `$CC_STATUSLINE_ACCOUNT_LIB` → `~/.claude/statusline-account-lib` → default
  path; absent, no-op fallbacks apply (mode `plan`).
- Display logic is kept in pure functions so the test file can source `lib/`
  and assert on them directly; regressions get a fixture there.

## Invariants

- **Always exit 0.** A non-zero exit makes Claude Code hide the statusline. A
  helper whose last command is a failing test leaks a non-zero status.
- **Colour:** the CLI renders the line dim. Close segments with `RESET_DIM` or
  `RESET_FG`, not `RESET` (which clears the dim for the rest of the line);
  only `lib/sparkline.sh` uses `RESET` on purpose. `BOLD` is
  `\033[22m\033[1m` because the CLI does not let bare `\033[1m` override dim.
  16 base ANSI colours only (sole exception: bright magenta, in the context bar
  and the subagent sparkline's top bands). The subagent row never changes
  intensity: its entry point binds `RESET_DIM` to `RESET_FG`.
- **Defensive arithmetic:** validate every number (`^[0-9]+$`, not empty, not
  `unset`) before `$(( ))`; empty transcript values are normal.
- **bash 3.2 compatible** (macOS `/bin/bash`): no `${var,,}`, associative
  arrays, `readlink -f`; GNU and BSD `date`/`stat` both have to work.
- jq booleans: use `== true` / `!= false`, never `//` (it treats `false` as
  missing).

## Docs

`statusline-design.md` is the living design doc and the authority on behaviour
and rationale (§4 decisions, §5 rejected alternatives, §6 limitations). When
behaviour changes, update the relevant section and add a row to its §7
changelog. `docs/decisions/statusline.md` is a quick-reference summary that
points into the design doc; keep it in step when a format it shows changes.
`plans/` holds dated, frozen specs and implementation plans.
