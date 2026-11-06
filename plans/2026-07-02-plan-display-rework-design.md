# Plan Display Rework — Design Spec

**Date**: 2026-07-02
**Scope**: Statusline line-1 plan rate-limit display (`render_plan_right` in
`claude/lib/account-display.sh`) and the plan-mode truncation ladder in
`claude/statusline-command.sh`.
**Status**: Approved for planning.

## Motivation

The current per-window plan display shows `5h 42% ▄ ×1.2 20:00`: used-%, a
vertical bar, a burn-rate ratio, and reset time. Three problems:

1. Windows at 0% are hidden entirely, so early in a session the plan section
   silently disappears — no confirmation the data is being read.
2. When space is tight, the model name is dropped *first*, before the less
   essential plan decorations.
3. The burn-rate `×N` is an opaque ratio; the underlying "how far through the
   window am I" (elapsed %) is more directly legible next to the used %.

## Design

### 1. Per-window format: `A%/B% C`

For each window (5h window = 18000s, 7d window = 604800s):

- **A** — `used_percentage`, rounded to integer, 2-wide (`%2d%%`).
- **B** — window-elapsed percent:
  `(window_secs − (resets_at − now)) / window_secs × 100`, clamped to `[0,100]`.
- **C** — the existing `display_vertical_bar` glyph (`▁`…`█`).
- Reset time follows, unchanged: `format_5h_reset` / `format_7d_reset`.
- The burn-rate `×N` element is **removed** — B conveys the same pace signal
  directly (burn = A/B). `format_burn_rate` becomes dead and is deleted.

Example: `Plan 5h 42%/35% ▄ 20:00 / 7d 88%/60% ▇ Fri`

**New helper** `window_elapsed_pct` in `claude/lib/format-utils.sh`:

- Signature mirrors `format_burn_rate`: `$1=resets_at_epoch $2=window_secs
  $3=now_epoch(optional override)`.
- Returns integer 0–100, or empty when `resets_at` is missing/null/0.
- Pure and unit-testable. `format_burn_rate` is removed once this lands.

### 2. Pace coloring

One color applies to the whole `A%/B% C` run (both percentages **and** the
bar C). Precedence:

1. `A > 94` → **red** (saturation warning — wins over pace).
2. else `A < B` → **green** (under pace).
3. else (`A ≥ B`, ties included) → **yellow** (at/over pace).

This replaces the old 80/90 magnitude thresholds inside
`display_plan_limit_percent` and `display_vertical_bar` **for the plan path**.
The existing bold emphasis when `A ≥ 100` is retained, layered on the red
(bold red).

Fallback: if `resets_at` is missing so B can't be computed, render just `A%`
(no `/B%`), colored red when `A > 94` else dim; the bar is omitted.

### 3. Zero-state / data-presence rules

- A window renders whenever its `used_percentage` field **exists and is
  non-null** — `0%/12% ▁` shows at zero.
- A window is hidden only when its field is absent/null (fresh session before
  any usage data).
- Top level (`render_plan_right`): emit nothing only when *both* windows'
  fields are absent/null. This replaces the current "both == 0 → return"
  guard. Distinguishing null from 0 requires reading the raw jq value
  (e.g. `// "null"`) rather than `// 0`.
- B has **no** 5%-elapsed floor. That floor existed only to avoid burn's
  division by a tiny elapsed; B itself is a plain ratio with no such issue.

### 4. Truncation ladder (plan mode)

Reordered so plan decorations drop before the model/agent name.
`render_plan_right` gains a new style tier `no_bars` (drops C only). Full
style progression: `full → no_plan_label → no_period_labels → no_bars`.

| Tier | Model    | Plan style        | Element dropped at this tier |
|------|----------|-------------------|------------------------------|
| 0    | full     | full              | —                            |
| 1    | full     | no_plan_label     | `Plan ` label                |
| 2    | full     | no_period_labels  | `5h` / `7d` labels           |
| 3    | full     | no_bars           | vertical bars C              |
| 4    | compact  | no_bars           | model name                   |
| 5    | compact  | no_bars           | context 🧠 bar (`BAR_SEC`)   |
| 6    | compact  | no_bars           | cost (`COST_SEC`)            |

`vis_truncate` remains the final safety net. The `A%/B%` core and reset time
survive to the smallest tier. The context 🧠 bar is **not** part of the first
batch — it stays until tier 5, as today.

## Files touched

- `claude/lib/format-utils.sh` — add `window_elapsed_pct`; remove
  `format_burn_rate`.
- `claude/lib/account-display.sh` — rewrite `render_plan_right`: new format,
  pace coloring, presence-based rendering, `no_bars` style. The pace color is
  computed once per window in `render_plan_right` and passed as an explicit
  argument to `display_plan_limit_percent` and `display_vertical_bar`, whose
  internal 80/90 magnitude thresholds are removed. Dead `display_plan_usage`
  may be removed opportunistically (it is already unreachable).
- `claude/statusline-command.sh` — replace the plan-mode assembly block
  (lines ~227–250) with the 7-tier ladder above.
- `claude/test-statusline-helpers.sh` — tests for `window_elapsed_pct`
  (normal, clamp >100, clamp <0, missing `resets_at`) and pace-color
  precedence (`A>94` red beats pace; `A<B` green; `A≥B` yellow incl. tie).

## Out of scope

- Cache-expiry hourglass, sparkline / stats line-2, API-mode display — untouched.
- Cost-tracking, switchback, provider logic — untouched.
