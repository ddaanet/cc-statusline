---
name: statusline-line2-stats
description: "Statusline second-line stats mode — implemented & merged to main 2026-06-30"
metadata: 
  node_type: memory
  type: project
  originSessionId: b2fbd920-8c52-492a-b68c-9813cca08711
  modified: 2026-07-29T07:19:57.102Z
---

A selectable second statusline line (`~/.claude/statusline-line2` = `sparkline` default | `stats`). The `stats` mode renders per-user-turn numbers (count, Σcache-read, effective input, Σoutput, duration) with `❄` cold-cache markers, alongside — not instead of — the per-call sparkline. Signed off 2026-06-29.

**Status:** shipped to main 2026-06-30 (commits 8318a2f..9db1a23). Implemented via subagent-driven-development from `plans/2026-06-30-statusline-line2-stats-impl.md`. Lives in the `~/code/cc-statusline` repo: `lib/turn-stats.sh` (`display_turn_stats`, `_turn_input`, `_turn_marker`), formatters `humanize_tokens`/`format_turn_dur` in `lib/format-utils.sh`, dispatch in `statusline-command.sh`, tests in `test-statusline-helpers.sh` (92 total). Enable with `echo stats > ~/.claude/statusline-line2`.

**Colourised 2026-07-01:** marker bold-cyan, call count bold, cache-read blue, input green, output yellow, duration default. Segments wrapped with `colors.sh` globals in `display_turn_stats`'s group builder; `vislen` strips SGR so width truncation is unaffected; a leading `RESET` clears inherited SGR and each segment self-resets. Tests strip SGR (`sed`) before text-equality asserts and add colour-presence checks (the old "monochrome (no SGR)" test was flipped).

**How to apply:** full spec/formula at `plans/2026-06-25-statusline-line2-stats.md`, rationale in `statusline-design.md`. Cold-cache detection is structural (drop>0 AND refresh≥drop) — see [[anthropic-cache-persistence-unstable]]. Known deferred nit: `format_turn_dur`/`_turn_marker` have thin edge-case test coverage; a comma-radix-locale guard is in place on `humanize_tokens`. Related: [[reference_cc_statusline]].
