# Statusline Line-1 Wrap/Reflow + Subagent Cost Aggregation — Design

**Date**: 2026-07-12
**Status**: Design (awaiting review)
**Related**: `claude/design-decisions.md` (Plan Display Rework, Width-aware truncation);
`plans/2026-07-02-plan-display-rework-design.md`

## Problem

Line 1 of the statusline currently uses a **drop** model: when the assembled
line exceeds the width budget, sections are progressively removed
(`statusline-command.sh:228-270`). On narrow terminals this discards useful
information (cost, context, plan) rather than relocating it.

Two changes are wanted:

1. **Reflow instead of drop.** On narrow displays, wrap sections onto
   additional rows in defined tiers (A → B → C) before dropping anything. A
   near-fixed set of "identity + cost + context + timer" is never dropped.
2. **Aggregate subagent cost.** The payload's `total_cost_usd` covers only the
   main thread. Sum the cost of subagents spawned this session into the
   displayed cost figure.

These are independent code paths and will be built as **two phases** under one
spec.

---

## Component 1 — Line-1 tiered wrap/reflow

### Section inventory

| Section | Var (current) | Droppable? | Notes |
|---------|---------------|-----------|-------|
| model indicator | `MODEL_COMPACT` (`❶`) | never | name degrades full→compact |
| model name | part of `MODEL_FULL` | degrade only | dropped from *display*, indicator stays |
| pyenv | `PYENV_SEC` | **never** (changed) | shown only when a venv is active |
| dir | `DIRGIT_SEC` | never | |
| branch | `DIRGIT_SEC` | never | |
| cost | `COST_SEC` | **never** (changed) | now rendered **before** context |
| context value | `CTX_SEC` | never | `⛁ 42k` |
| context bar | `BAR_SEC` | **droppable** | the only droppable metric |
| timer | (extracted, see below) | **never** (changed) | `⏳ HH:MM` cache-expiry, glued after context |
| plan | `render_plan_right` | wrap → omit | never wraps internally |
| stats/sparkline | line 2 renderers | never | always the last row(s) |

### Two travel-together groups

- **identity** = model + pyenv + dir + branch
- **context group** = `cost ⛁ctx [bar] ⏳timer` — an ordered unit: cost first,
  then context value, then the (droppable) bar, then the timer. The group moves
  as a whole when it wraps to another row.

Plan and the stats line are handled separately.

### Ordering (wide case)

```
❶ Opus  🐍 home  main   $0.42 ⛁42k ▁▃▅ ⏳16:20   Plan 5h 12%/40%▃ 7d 8%/60%▁
```

Cost is **before** context (was after). Timer is **after** context usage and
**before** plan (was glued to the end of the plan section). Pyenv sits with the
identity group and is never dropped.

### Ladder

Each step fires only when **row 1 still exceeds its budget** after the previous
step. Rows below row 1 are shown in the "Rows below" column; the stats/sparkline
row is implicit and always last.

| Step | Row 1 | Rows below | Tier |
|------|-------|-----------|------|
| 0 | `model pyenv dir branch · cost ⛁ctx ▁▃▅ ⏳timer · plan` | — | L0 |
| 1 | `model pyenv dir branch · cost ⛁ctx ▁▃▅ ⏳timer` | **plan** | **A** |
| 2 | drop bar → `… cost ⛁ctx ⏳timer` | plan | |
| 3 | model → compact `❶` | plan | |
| 4 | `model pyenv dir` | **branch · cost ⛁ctx ⏳timer**, plan | **B** |
| 5 | `model pyenv dir` | **branch**, **cost ⛁ctx ⏳timer**, plan | **C** |
| 6 | model compact if `model pyenv dir` overflows; then `vis_truncate` net | — | |

Notes:
- **Always kept:** model indicator, pyenv, dir, branch, cost, context value,
  timer. Only the context **bar** and **plan** are droppable.
- Between tiers the context group travels intact; in B it trails `branch` on a
  shared row, in C it gets its own row.
- `vis_truncate` (ellipsis) remains the final per-row safety net for degenerate
  widths where even a minimal row overflows.

### Plan row

Plan **never wraps internally**. Whenever plan is on its own row it renders at
the richest `render_plan_right` style that fits `EFFECTIVE_COLS`:
`full → no_plan_label → no_period_labels → no_bars`. If even `no_bars`
overflows its row, **plan is omitted entirely** (the "too narrow → drop plan"
rule). This naturally lands around tiers B/C on very narrow panes.

### Budgets

- **Row 1 budget** = `EFFECTIVE_COLS − 4`. The extra 4 columns reserve the
  right-edge chrome Claude Code overlays on the **first** statusline row only
  (system notifications / MCP errors / the `/rc` marker; confirmed line-1-only
  in the Claude Code docs).
- **Every continuation row** = full `EFFECTIVE_COLS` (no chrome there).
- `EFFECTIVE_COLS` itself already reserves the existing `cols − 3` TUI chrome.

### Timer extraction

The cache-expiry timer currently renders **inside** `render_plan_right`
(`account-display.sh:232-236`) and therefore only appears in plan mode. Extract
it into its own section (`render_timer`, fed by the existing
`format_cache_expiry "$TRANSCRIPT_PATH"` already computed at
`statusline-command.sh:229`) so it can render in **any** mode whenever it has a
value, and stay on row 1 while plan wraps down. `render_plan_right` loses its
`cache_expiry` parameter.

### Emission

The line-1 block is restructured to build a **list of rows** (strings), each
`vis_truncate`'d to its budget (row 0 → `cols−4`, rest → `cols`), then emitted
newline-separated. The API-mode account row and the stats/sparkline row are
appended after the content rows exactly as today. No documented cap on row
count (each `echo` = one row).

### Implementation shape

A new pure helper — proposed `lib/line1-layout.sh` — takes the pre-rendered
sections and their visible widths and returns the chosen row list, implementing
the ladder as an ordered list of candidate layouts (widest first; pick the
first whose every row fits). Keeping it pure (sections in, rows out) makes it
unit-testable without a terminal. `statusline-command.sh` shrinks to: render
sections → call layout → emit rows.

---

## Component 2 — Subagent cost aggregation

### Data source

Subagent transcripts live at
`~/.claude/projects/<proj>/<session>/subagents/agent-<id>.jsonl` (plus
`agent-<id>.meta.json` with `agentType`). Each assistant entry carries
`.message.model` and `.message.usage`, but **no cost field** — cost must be
computed from tokens.

The main-thread cost is authoritative from the payload
(`.cost.total_cost_usd`); we do **not** recompute it. We compute only the
**subagent** costs and add them:

```
displayed_cost = payload.total_cost_usd + Σ subagent_cost
```

### Cost formula (validated)

For each subagent transcript:

1. **Dedup by `message.id`.** Streaming writes the same assistant message
   multiple times with *cumulative* usage. Keep one entry per `message.id`
   (the final/max). Skipping this ≈ 7× overcount.
2. For each deduped assistant entry, with the entry's `.message.model` base
   input price `Pin` and base output price `Pout`:

```
cost = input_tokens                              * Pin
     + cache_read_input_tokens                   * Pin * 0.10
     + cache_creation.ephemeral_5m_input_tokens  * Pin * 1.25
     + cache_creation.ephemeral_1h_input_tokens  * Pin * 2.00
     + output_tokens                             * Pout
```

Multipliers are official, uniform across all models, and identical for
subagents (Anthropic pricing + prompt-caching docs, verified 2026-07-12).

### Validation

Applying the same formula to the **main** session transcript reproduces the
payload's `total_cost_usd` to within the live-transcript-vs-snapshot race
(computed ≈ payload; the residual is new turns written after the payload
snapshot). This proves the formula and the dedup step are correct before we
trust them on subagents.

**Critical:** the per-model base price must be right. `claude-model-info.py`
currently returns Opus **4.5** at $15/$75; Opus **4.8** is **$5/$25**. A wrong
price is a silent 3× error. The pricing source used for aggregation must cover
every model a subagent may run (opus-4-8 $5/$25, sonnet-4-5 $3/$15,
haiku-4-5 $0.8/$4, and any OpenRouter model classes). Approach: extend the
existing `claude-model-info.py` / litellm lookup, with a small static fallback
table for models litellm lacks.

### Performance

The statusline renders frequently and logs its own timing
(`/tmp/claude/statusline-timing.log`); parsing subagent JSONLs on every render
is a risk. Strategy:

- A **completed** subagent's file is static → its computed cost can be cached
  keyed on `path + size + mtime`.
- Only re-sum a file whose `(size, mtime)` changed (running agents only).
- Cache location: a small JSON under `/tmp/claude/` (regenerable, not
  session-critical).

### Display

The aggregated total replaces the current `COST` value inside the context
group. No format change to the `$` section itself. When there are no subagents,
the value equals the payload cost (current behavior).

---

## Non-goals / caveats

- **1M-context surcharge.** The `[1m]` model applies a >200k-token premium
  (roughly 2× input / 1.5× output above 200k). Approximated as flat base
  pricing; acceptable while subagent contexts stay under 200k. Documented, not
  handled.
- **Fast mode** (Opus 4.8/4.7) uses a higher base price (detectable via
  `usage.speed`). Out of scope for v1; note as a known approximation.
- **Batch / data-residency modifiers** (0.5× / 1.1×) don't apply to plain
  Claude Code transcripts; ignored.
- **OpenRouter** subagent pricing may differ from Anthropic list; best-effort
  via the existing provider config.

---

## Testing

**Component 1** (`test-statusline-helpers.sh`): drive the pure layout helper
with synthetic section widths at representative `EFFECTIVE_COLS` values and
assert the exact row list for L0, A, B, C, plan-omission, and the
`vis_truncate` safety net. Assert row-1 budget uses `cols−4` and continuation
rows use `cols`.

**Component 2**: a fixture `subagents/` dir with two `agent-*.jsonl` files
(different models, streaming duplicates present) → assert the deduped
per-model token sums and the computed cost. A regression test that recomputes a
captured main-session transcript and asserts it matches that session's recorded
`total_cost_usd` within tolerance (guards the dedup + pricing pair).

---

## Files touched (anticipated)

- `claude/statusline-command.sh` — replace line-1 drop ladder with layout call;
  compute aggregated cost; render extracted timer section.
- `claude/lib/line1-layout.sh` — **new**, pure ladder/packing helper.
- `claude/lib/account-display.sh` — remove `cache_expiry` param from
  `render_plan_right`; add `render_timer`.
- `claude/lib/format-utils.sh` — cost helpers if needed.
- `claude/lib/subagent-cost.sh` — **new**, subagent enumeration + formula +
  cache.
- `claude/claude-model-info.py` — ensure opus-4-8 and other current models
  resolve to correct base prices; static fallback table.
- `claude/test-statusline-helpers.sh` — tests for both components.
- `claude/design-decisions.md` — record the rework.

## Phasing

- **Phase 1** — Line-1 wrap/reflow + reordering + timer extraction (Component 1).
  Self-contained, independently verifiable.
- **Phase 2** — Subagent cost aggregation (Component 2). Depends only on the
  cost value feeding the (already-placed) cost section.
