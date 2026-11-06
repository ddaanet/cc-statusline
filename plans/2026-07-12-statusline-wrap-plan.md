# Statusline Line-1 Wrap/Reflow + Subagent Cost — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace line 1's section-dropping with a tiered wrap/reflow layout (identity + cost + context + timer never drop), and add session-subagent cost into the displayed cost figure.

**Architecture:** A new pure helper `lib/line1-layout.sh` decides the multi-row layout from pre-rendered section strings and two width budgets; `statusline-command.sh` renders the sections, calls the helper, and emits the rows. A new `lib/subagent-cost.sh` computes subagent cost from their transcripts (token usage × per-model price) with an mtime/size cache, and the orchestrator adds it to the payload cost.

**Tech Stack:** Bash (3.2-compatible), `jq`, `awk`. Tests in `claude/test-statusline-helpers.sh` (custom `assert` harness). Design spec: `plans/2026-07-12-statusline-wrap-design.md`.

## Global Constraints

- **Bash 3.2 compatible** — runs on macOS (bash 3.2) and Linux. **No associative arrays.** Use positional args or documented globals.
- **`stat` portability** — GNU (`stat -c`) vs BSD/macOS (`stat -f`). Always try GNU then fall back to BSD.
- **`statusline-command.sh` must `exit 0`** and stay fast; avoid per-render `jq`/`python` on unchanged data (use the cache).
- **Color discipline** — close colored/bold segments with `${RESET_DIM}` (not `${RESET}`) on line 1; `${BOLD}` already emits `\033[22m\033[1m`. `vislen` strips SGR, so escapes don't affect width.
- **Width accounting** — `vislen` counts visible cells; nerd-font PUA glyphs and the specific symbols used are 1 cell each.
- **Row budgets** — row 1 = `EFFECTIVE_COLS − 4` (the `/rc` right-edge chrome, line-1 only); continuation rows = `EFFECTIVE_COLS`.
- **Cost multipliers** (validated, official): cache read ×0.1, 5-min cache write ×1.25, 1-hour cache write ×2.0, all relative to a model's base input price. Dedup assistant entries by `message.id` before summing.
- Run the full suite after every task: `bash claude/test-statusline-helpers.sh` (exits 0 on pass).
- Commits use gitmoji prefixes (repo convention). Do not commit inside `memory/`.

---

# Phase 1 — Line-1 wrap/reflow

## File Structure (Phase 1)

- **Create** `claude/lib/line1-layout.sh` — pure layout engine (`pick_plan_variant`, `layout_line1`, `emit_line1`, `_emit_rows`). Reads documented `L1_*` globals; no `jq`, no I/O beyond stdout.
- **Modify** `claude/lib/account-display.sh` — remove the `cache_expiry` parameter from `render_plan_right`; add `render_timer`.
- **Modify** `claude/statusline-command.sh` — split dir/branch/pyenv into separate section vars, assemble the two context-group variants, reorder cost before context, set `L1_*` globals, call `emit_line1`.
- **Modify** `claude/test-statusline-helpers.sh` — source the new lib; add tests.

---

### Task 1: `pick_plan_variant` — richest plan style that fits a row

**Files:**
- Create: `claude/lib/line1-layout.sh`
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Consumes: `vislen` (from `format-utils.sh`).
- Produces: `pick_plan_variant BUDGET FULL NOLABEL NOPER NOBARS` → echoes the first (richest) non-empty variant whose visible width ≤ BUDGET; echoes empty string if none fit or all are empty.

- [ ] **Step 1: Create the lib with the function**

```bash
#!/usr/bin/env bash
# Pure line-1 layout engine for the statusline. No jq, no I/O beyond stdout.
# Depends on vislen (format-utils.sh). Reads L1_* globals in layout_line1.

# Echo the richest plan variant whose visible width fits $1 columns.
# $1=budget  $2=full $3=no_plan_label $4=no_period_labels $5=no_bars
# Variants are ordered richest→leanest; returns the first that fits.
# Empty variants are skipped; echoes "" when none fit (→ caller omits plan).
pick_plan_variant() {
    local budget=$1 v
    for v in "$2" "$3" "$4" "$5"; do
        [[ -z "$v" ]] && continue
        if (( $(vislen "$v") <= budget )); then
            printf '%s' "$v"
            return 0
        fi
    done
    printf ''
}
```

- [ ] **Step 2: Source it in the test harness**

In `claude/test-statusline-helpers.sh`, after the `account-display.sh` source line (line 27), add:

```bash
# shellcheck source=claude/lib/line1-layout.sh
source "$HERE/lib/line1-layout.sh" || { echo "FATAL: line1-layout.sh not found"; exit 2; }
```

And extend the sanity block (near line 33):

```bash
type pick_plan_variant >/dev/null 2>&1 || { echo "FATAL: pick_plan_variant not loaded"; exit 2; }
```

- [ ] **Step 3: Add failing tests**

Append before the final PASS/FAIL summary block:

```bash
echo "## pick_plan_variant"
assert "picks full when it fits"    "$(pick_plan_variant 20 "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" "FULLPLAN"
assert "degrades to first fitting"  "$(pick_plan_variant 7  "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" "NOLABEL"
assert "picks nobars when tiny"     "$(pick_plan_variant 6  "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" "NOBARS"
assert "none fit → empty (omit)"    "$(pick_plan_variant 3  "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" ""
assert "all empty → empty"          "$(pick_plan_variant 40 "" "" "" "")"                              ""
```

(Widths: `FULLPLAN`=8, `NOLABEL`=7, `PERIODS`=7, `NOBARS`=6. `no_bars` is the leanest variant, so its atom must be the shortest for the tiny-budget case to reach it. Budget 7 skips the 8-wide full and takes `NOLABEL`; budget 6 skips full/nolabel/periods and takes `NOBARS`; budget 3 fits none.)

- [ ] **Step 4: Run tests**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS (new `pick_plan_variant` assertions included, total count up by 5).

- [ ] **Step 5: Commit**

```bash
git add claude/lib/line1-layout.sh claude/test-statusline-helpers.sh
git commit -m "✨ add pick_plan_variant plan-row style selector"
```

---

### Task 2: `layout_line1` + `emit_line1` — the wrap ladder

**Files:**
- Modify: `claude/lib/line1-layout.sh`
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Consumes globals (all pre-rendered strings; caller sets them): `L1_R1` (row-1 budget int), `L1_RC` (continuation budget int), `L1_IDFULL` (model_full+pyenv+dir+branch), `L1_IDFULLC` (model_compact+pyenv+dir+branch), `L1_IDHEAD` (model_full+pyenv+dir), `L1_IDHEADC` (model_compact+pyenv+dir), `L1_BRANCH` (branch), `L1_CGBAR` (cost+ctx+bar+timer), `L1_CGNOBAR` (cost+ctx+timer), `L1_PLAN_INLINE` (full plan for L0 inline, "" if none), `L1_PLANROW` (pre-picked plan row via `pick_plan_variant`, "" if omitted/none).
- Produces: `layout_line1` → echoes chosen rows joined by `\n` (structural, untruncated). `emit_line1` → same rows but row 1 truncated to `L1_R1`, continuation rows to `L1_RC`, no trailing newline. `_emit_rows ROW...` → joins non-empty args with `\n`.

- [ ] **Step 1: Add the ladder to `line1-layout.sh`**

Append to `claude/lib/line1-layout.sh`:

```bash
# Join non-empty rows with a single newline (no trailing newline).
_emit_rows() {
    local first=1 r
    for r in "$@"; do
        [[ -z "$r" ]] && continue
        (( first )) || printf '\n'
        first=0
        printf '%s' "$r"
    done
}

# Decide the multi-row line-1 layout from the L1_* globals.
# Ladder (row 1 must fit L1_R1; continuation rows must fit L1_RC):
#   L0  full identity + ctx(+bar) [+ full plan inline]
#   A   plan wraps to its own row; full identity + ctx(+bar) on row 1
#       → drop bar → compact model
#   B   [model pyenv dir] / [branch + ctx(no bar)] / [plan]
#   C   [model pyenv dir] / [branch] / [ctx(no bar)] / [plan]
# The context group (cost+ctx+[bar]+timer) never drops beyond its bar.
# The final structured row is emitted unconditionally; emit_line1 truncates.
layout_line1() {
    local r1=$L1_R1 rc=$L1_RC row1 rowb2

    # L0: everything on one row (full plan inline only — plan wraps before it degrades)
    if [[ -n "$L1_PLAN_INLINE" ]]; then
        row1="${L1_IDFULL}${L1_CGBAR}${L1_PLAN_INLINE}"
    else
        row1="${L1_IDFULL}${L1_CGBAR}"
    fi
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1"; return; fi

    # Tier A: plan (if any) drops to L1_PLANROW below; full identity + ctx(bar)
    row1="${L1_IDFULL}${L1_CGBAR}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # drop the context bar
    row1="${L1_IDFULL}${L1_CGNOBAR}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # compact the model name
    row1="${L1_IDFULLC}${L1_CGNOBAR}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # Tier B: [model pyenv dir] / [branch + ctx(no bar)]
    rowb2="${L1_BRANCH}${L1_CGNOBAR}"
    if (( $(vislen "$L1_IDHEAD") <= r1 && $(vislen "$rowb2") <= rc )); then
        _emit_rows "$L1_IDHEAD" "$rowb2" "$L1_PLANROW"; return
    fi
    if (( $(vislen "$L1_IDHEADC") <= r1 && $(vislen "$rowb2") <= rc )); then
        _emit_rows "$L1_IDHEADC" "$rowb2" "$L1_PLANROW"; return
    fi

    # Tier C: [model pyenv dir] / [branch] / [ctx(no bar)]
    if (( $(vislen "$L1_IDHEAD") <= r1 )); then
        _emit_rows "$L1_IDHEAD" "$L1_BRANCH" "$L1_CGNOBAR" "$L1_PLANROW"; return
    fi
    _emit_rows "$L1_IDHEADC" "$L1_BRANCH" "$L1_CGNOBAR" "$L1_PLANROW"
}

# Emit the chosen rows, truncating row 1 to L1_R1 and continuation rows to
# L1_RC. No trailing newline (matches the orchestrator's single-line contract).
emit_line1() {
    local rows first=1 r
    rows=$(layout_line1)
    while IFS= read -r r; do
        if (( first )); then
            vis_truncate "$r" "$L1_R1"; first=0
        else
            printf '\n'
            vis_truncate "$r" "$L1_RC"
        fi
    done <<< "$rows"
}
```

- [ ] **Step 2: Add the sanity check**

In the test harness sanity block:

```bash
type layout_line1 >/dev/null 2>&1 || { echo "FATAL: layout_line1 not loaded"; exit 2; }
```

- [ ] **Step 3: Add failing layout tests**

Append to the test file. Atoms use plain ASCII with known widths so tier selection is exact (trailing space included in each): `IDFULL `=7, `IDF `=4, `IDHEAD `=7, `IDH `=4, `BR `=3, `CGB `=4, `CGN `=4, `PLAN `=5, `PLANROW `=8.

```bash
echo "## layout_line1 — tier selection"
_L1_reset() {
    L1_IDFULL="IDFULL " L1_IDFULLC="IDF " L1_IDHEAD="IDHEAD " L1_IDHEADC="IDH "
    L1_BRANCH="BR " L1_CGBAR="CGBAR " L1_CGNOBAR="CGN " L1_PLAN_INLINE="PLAN "
    L1_PLANROW="PLANROW "
}

# L0: everything fits one row.
_L1_reset; L1_R1=100 L1_RC=100
assert "L0 single row" "$(layout_line1)" "IDFULL CGBAR PLAN "

# Tier A: L0 (with inline plan) overflows, but identity+ctx(bar) fits → plan wraps.
_L1_reset; L1_R1=13 L1_RC=100
assert "A wraps plan" "$(layout_line1)" $'IDFULL CGBAR \nPLANROW '

# Drop bar: identity+ctx(bar)=13 overflows R1=12, identity+ctx(nobar)=11 fits.
_L1_reset; L1_R1=12 L1_RC=100
assert "A drops bar" "$(layout_line1)" $'IDFULL CGN \nPLANROW '

# Compact model: identity(full)+ctx(nobar)=11 overflows R1=9, compact=8 fits.
_L1_reset; L1_R1=9 L1_RC=100
assert "A compact model" "$(layout_line1)" $'IDF CGN \nPLANROW '

# Tier B: even compact identity+ctx overflows R1=7; IDHEAD=7 fits, branch+ctx fits RC.
_L1_reset; L1_R1=7 L1_RC=100
assert "B splits identity" "$(layout_line1)" $'IDHEAD \nBR CGN \nPLANROW '

# Tier C: branch+ctx (7) overflows RC=6, but branch (3) and ctx (4) each fit alone.
_L1_reset; L1_R1=7 L1_RC=6
assert "C splits branch/ctx" "$(layout_line1)" $'IDHEAD \nBR \nCGN \nPLANROW '

# Plan omitted: L1_PLANROW empty → no plan row in tier A.
_L1_reset; L1_R1=13 L1_RC=100 L1_PLANROW=""
assert "A with plan omitted" "$(layout_line1)" "IDFULL CGBAR "

# No plan at all: L0 without inline plan.
_L1_reset; L1_R1=100 L1_RC=100 L1_PLAN_INLINE="" L1_PLANROW=""
assert "L0 no plan" "$(layout_line1)" "IDFULL CGBAR "

echo "## emit_line1 — per-row truncation budgets"
# Row 1 truncated to L1_R1, continuation to L1_RC. Force tier A.
_L1_reset; L1_R1=13 L1_RC=4
# layout row1="IDFULL CGBAR " (13, fits R1); planrow "PLANROW " (8) → truncated to 4 = "PLA…"
assert "emit truncates continuation to RC" "$(emit_line1)" $'IDFULL CGBAR \nPLA\xe2\x80\xa6'
```

- [ ] **Step 4: Run tests**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS. If a tier assertion fails, check the atom widths in `_L1_reset` against the budget in that case.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/line1-layout.sh claude/test-statusline-helpers.sh
git commit -m "✨ add layout_line1 wrap ladder + emit_line1"
```

---

### Task 3: Extract the timer from `render_plan_right` into `render_timer`

**Files:**
- Modify: `claude/lib/account-display.sh:196-237` (`render_plan_right`)
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Consumes: existing `format_cache_expiry` (already produces the `HH:MM` string), color globals.
- Produces: `render_timer CACHE_EXPIRY` → echoes ` ${CYAN}⏳ HH:MM${RESET_DIM}` (leading two-space gap) when the arg is non-empty; echoes nothing when empty. `render_plan_right STYLE` — the `cache_expiry` (2nd) parameter is removed; it no longer emits the timer.

- [ ] **Step 1: Add a failing test for `render_timer`**

```bash
echo "## render_timer"
assert "empty → nothing"     "$(render_timer "")"      ""
_rt_hg=$'\xef\x89\x92'  # nf-fa-hourglass_half U+F252
assert "value → icon + HH:MM" "$(render_timer "16:20")" "  ${CYAN}${_rt_hg} 16:20${RESET_DIM}"
```

Add the sanity check:

```bash
type render_timer >/dev/null 2>&1 || { echo "FATAL: render_timer not loaded"; exit 2; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash claude/test-statusline-helpers.sh`
Expected: FAIL — `render_timer: command not found` / sanity FATAL.

- [ ] **Step 3: Add `render_timer` and strip the timer from `render_plan_right`**

In `claude/lib/account-display.sh`, add before `render_plan_right`:

```bash
# Render the cache-expiry timer as its own section (mode-independent).
# $1 = pre-formatted HH:MM string (empty → nothing). Prepends a 2-space gap
# and the nf-fa-hourglass_half glyph (U+F252).
render_timer() {
    local cache_expiry=$1
    [[ -z "$cache_expiry" ]] && return
    local _hg=$'\xef\x89\x92'
    echo -n "  ${CYAN}${_hg} ${cache_expiry}${RESET_DIM}"
}
```

Change the `render_plan_right` signature line from:

```bash
render_plan_right() {
    local style=${1:-full} cache_expiry=$2
```

to:

```bash
render_plan_right() {
    local style=${1:-full}
```

Delete the trailing timer block (lines ~232-236):

```bash
    # Cache expiry (nf-fa-hourglass_half U+F252)
    if [[ -n "$cache_expiry" ]]; then
        local _hg=$'\xef\x89\x92'
        echo -n "  ${CYAN}${_hg} ${cache_expiry}${RESET_DIM}"
    fi
```

Update the function's doc comment (`# $2=cache_expiry ...`) to drop the `$2` line.

- [ ] **Step 4: Run tests**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS. The existing `_render_plan_window` tests are unaffected (they call `_render_plan_window` directly, not `render_plan_right`).

- [ ] **Step 5: Commit**

```bash
git add claude/lib/account-display.sh claude/test-statusline-helpers.sh
git commit -m "♻️ extract render_timer from render_plan_right"
```

---

### Task 4: Rewire `statusline-command.sh` to the wrap layout

**Files:**
- Modify: `claude/statusline-command.sh` — source the lib; split pyenv/dir/branch vars; reorder cost before context; assemble context-group variants; set `L1_*`; replace the drop ladder (lines 223-270) with `emit_line1`.

**Interfaces:**
- Consumes: `emit_line1`, `render_timer`, `render_plan_right` (new signatures), `pick_plan_variant`.
- Produces: no new callable — this is integration. Verified by a live smoke run, not unit tests.

> **Note — intentional minor change:** dir and branch are now always separate sections. The previous "dir basename == branch → show once" merge (`account-display`/orchestrator special case at the old `DIRGIT_SEC` block) is dropped, because tiers B/C need dir and branch on different rows. Cosmetic only, and only when the working-dir basename equals the branch name.

- [ ] **Step 1: Source the layout lib**

After the `account-display.sh` source line (`statusline-command.sh:107`), add:

```bash
# shellcheck source=claude/lib/line1-layout.sh
source "$HOME/code/home/claude/lib/line1-layout.sh" || exit 1
```

- [ ] **Step 2: Split pyenv / dir / branch into standalone section vars**

Replace the dir+git block (`statusline-command.sh:182-204`, the `DIRGIT_SEC` assembly) with separate `DIR_SEC` and `BRANCH_SEC`:

```bash
# Directory section (nerd-font folder). Always shown.
ICON_DIR=$''
DIR_SEC="${RESET_DIM}${CYAN}${ICON_DIR} $DIR_DISPLAY  "

# Branch section (nerd-font git branch). Green when clean, bold-yellow when dirty.
ICON_GIT=$''
BRANCH_SEC=""
if [ -n "$BRANCH" ]; then
    GIT_STATUS=$(git status --porcelain 2>/dev/null)
    if [ -n "$GIT_STATUS" ]; then
        BRANCH_SEC="${RESET_DIM}${YELLOW}${ICON_GIT}${BOLD} $BRANCH  "
    else
        BRANCH_SEC="${RESET_DIM}${GREEN}${ICON_GIT} $BRANCH  "
    fi
fi
```

`PYENV_SEC` already exists (lines 176-180) and is unchanged — it is now part of the never-drop identity group.

- [ ] **Step 3: Reorder cost before context and build the context-group variants**

The `COST_SEC` block (lines 206-211), `CTX_SEC`/`BAR_SEC` block (lines 213-221) stay as-is for computing the pieces, but are now composed into two context-group variants. After `BAR_SEC` is computed, and after the `CACHE_EXPIRY` is available, add:

```bash
# Cache-expiry timer as its own section (never dropped; glued after context).
CACHE_EXPIRY=$(format_cache_expiry "$TRANSCRIPT_PATH")
TIMER_SEC=$(render_timer "$CACHE_EXPIRY")

# Context group travels as a unit: cost → context value → [bar] → timer.
CG_BAR="${COST_SEC}${CTX_SEC}${BAR_SEC}${TIMER_SEC}"
CG_NOBAR="${COST_SEC}${CTX_SEC}${TIMER_SEC}"
```

(Note: `CACHE_EXPIRY` was previously computed only inside the plan-mode branch at line 229 — it now moves up here so the timer renders in every mode.)

- [ ] **Step 4: Replace the drop ladder with layout globals + `emit_line1`**

Replace the entire progressive-assembly block (`statusline-command.sh:223-270`, from the `# Progressive line-1 assembly` comment through `vis_truncate "$line1" "$EFFECTIVE_COLS"`) with:

```bash
# ── Line 1: tiered wrap layout ────────────────────────────────────────────
# Row 1 reserves 4 extra columns for Claude Code's right-edge chrome (system
# notifications / the /rc marker) which overlays the FIRST row only.
L1_R1=$(( EFFECTIVE_COLS > 4 ? EFFECTIVE_COLS - 4 : EFFECTIVE_COLS ))
L1_RC=$EFFECTIVE_COLS

# Identity atoms (never dropped): model + pyenv + dir + branch.
L1_IDFULL="${MODEL_FULL}${PYENV_SEC}${DIR_SEC}${BRANCH_SEC}"
L1_IDFULLC="${MODEL_COMPACT}${PYENV_SEC}${DIR_SEC}${BRANCH_SEC}"
L1_IDHEAD="${MODEL_FULL}${PYENV_SEC}${DIR_SEC}"
L1_IDHEADC="${MODEL_COMPACT}${PYENV_SEC}${DIR_SEC}"
L1_BRANCH="$BRANCH_SEC"
L1_CGBAR="$CG_BAR"
L1_CGNOBAR="$CG_NOBAR"

# Plan variants (plan-mode only). L1_PLAN_INLINE is the full plan for L0;
# L1_PLANROW is the richest style that fits a continuation row (or "" → omit).
L1_PLAN_INLINE=""
L1_PLANROW=""
if [[ "$MODE" == "plan" ]]; then
    _plan_full=$(render_plan_right full)
    if [[ -n "$_plan_full" ]]; then
        L1_PLAN_INLINE="  ${_plan_full}"
        L1_PLANROW=$(pick_plan_variant "$L1_RC" \
            "$_plan_full" \
            "$(render_plan_right no_plan_label)" \
            "$(render_plan_right no_period_labels)" \
            "$(render_plan_right no_bars)")
    fi
fi

emit_line1
```

- [ ] **Step 5: Smoke-test the real statusline at several widths**

Feed the captured payload through the script under different `COLUMNS` values and eyeball the tiers. Run:

```bash
for w in 120 60 40 28 20; do
  echo "=== COLUMNS=$w ==="
  COLUMNS=$w bash claude/statusline-command.sh < /tmp/claude/statusbar.json | cat -A | sed 's/\$$//'
done
```

Expected: at 120 a single content row (L0); as width drops, plan wraps to its own row (A), then the context group loses its bar, then identity splits across rows (B), then branch/context separate (C); plan disappears on the narrowest. No row exceeds its width (no terminal wrap). The stats/sparkline row still renders last.

- [ ] **Step 6: Run the unit suite**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS (unchanged count — Task 4 is integration, covered by the smoke run).

- [ ] **Step 7: Commit**

```bash
git add claude/statusline-command.sh
git commit -m "✨ reflow line 1 into tiered wrap layout"
```

---

# Phase 2 — Subagent cost aggregation

## File Structure (Phase 2)

- **Create** `claude/lib/subagent-cost.sh` — `model_price`, `subagent_cost` (one file), `session_subagent_cost` (whole session, cached).
- **Modify** `claude/statusline-command.sh` — add subagent cost to `COST` before `COST_SEC` is built.
- **Modify** `claude/test-statusline-helpers.sh` — source the lib; add tests with fixture subagent transcripts.

---

### Task 5: `model_price` — static per-model base prices

**Files:**
- Create: `claude/lib/subagent-cost.sh`
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Produces: `model_price MODEL` → echoes `"IN OUT"` base prices in $/M tokens for a transcript `.message.model` string. Substring match on the Anthropic tier; sensible default for unknowns.

- [ ] **Step 1: Create the lib with the pricing table**

```bash
#!/usr/bin/env bash
# Subagent cost aggregation for the statusline.
# Deps: jq, awk. Source after format-utils.sh.

# Echo "IN OUT" base prices ($/M tokens) for a transcript model string.
# Static table — litellm lacks opus-4-8; cache multipliers are uniform across
# models so only base in/out prices vary. Update when model pricing changes.
# Sources: Anthropic pricing (platform.claude.com/docs/en/about-claude/pricing).
model_price() {
    case "$1" in
        *opus-4-8*|*opus-4-7*) printf '5 25'  ;;   # Opus 4.7/4.8 tier
        *opus*)                printf '15 75' ;;   # Opus 4.5 and earlier
        *sonnet*)              printf '3 15'  ;;
        *haiku*)               printf '0.8 4' ;;
        *)                     printf '3 15'  ;;   # conservative default
    esac
}
```

- [ ] **Step 2: Source it and add sanity check**

In the test harness, after the `line1-layout.sh` source:

```bash
# shellcheck source=claude/lib/subagent-cost.sh
source "$HERE/lib/subagent-cost.sh" || { echo "FATAL: subagent-cost.sh not found"; exit 2; }
```

Sanity:

```bash
type model_price >/dev/null 2>&1 || { echo "FATAL: model_price not loaded"; exit 2; }
```

- [ ] **Step 3: Add failing tests**

```bash
echo "## model_price"
assert "opus 4.8 → 5/25"    "$(model_price "claude-opus-4-8")"          "5 25"
assert "opus 4.5 → 15/75"   "$(model_price "claude-opus-4-5-20251101")" "15 75"
assert "sonnet → 3/15"      "$(model_price "claude-sonnet-4-5-20250929")" "3 15"
assert "haiku → 0.8/4"      "$(model_price "claude-haiku-4-5-20251001")"  "0.8 4"
assert "unknown → default"  "$(model_price "gpt-something")"            "3 15"
```

- [ ] **Step 4: Run tests**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/subagent-cost.sh claude/test-statusline-helpers.sh
git commit -m "✨ add model_price static pricing table"
```

---

### Task 6: `subagent_cost` — cost of one subagent transcript

**Files:**
- Modify: `claude/lib/subagent-cost.sh`
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Consumes: `model_price`, `jq`, `awk`.
- Produces: `_subagent_tokens FILE` → echoes `"MODEL IN OUT CR C5 C1"` summed over assistant entries **deduped by `message.id`** (keeping the max-output entry per id). `subagent_cost FILE` → echoes the file's cost in USD (`%.6f`); echoes `0` for a missing/empty file.

- [ ] **Step 1: Add the token-sum + cost functions**

Append to `claude/lib/subagent-cost.sh`:

```bash
# Echo "MODEL IN OUT CR C5 C1" summed over deduped assistant entries.
# Dedup by message.id (streaming writes the same message repeatedly with
# cumulative usage — keep the max-output entry per id). Split cache-creation
# into 5m/1h TTL buckets for correct multipliers.
_subagent_tokens() {
    jq -s -r '
      [ .[] | select(.type=="assistant" and .message.id != null)
        | {id: .message.id, m: .message.model, u: .message.usage} ]
      | (map(.m) | last) as $model
      | (group_by(.id) | map(max_by(.u.output_tokens)) | map(.u)) as $us
      | ($us | reduce .[] as $u ({i:0,o:0,cr:0,c5:0,c1:0};
          { i:  (.i  + ($u.input_tokens // 0)),
            o:  (.o  + ($u.output_tokens // 0)),
            cr: (.cr + ($u.cache_read_input_tokens // 0)),
            c5: (.c5 + (($u.cache_creation.ephemeral_5m_input_tokens) // 0)),
            c1: (.c1 + (($u.cache_creation.ephemeral_1h_input_tokens) // 0)) })) as $t
      | "\($model // "unknown") \($t.i) \($t.o) \($t.cr) \($t.c5) \($t.c1)"
    ' "$1" 2>/dev/null
}

# Echo the USD cost of one subagent transcript (%.6f). Missing/empty → 0.
# cost = (in + cr*0.1 + c5*1.25 + c1*2.0) * Pin + out * Pout, per million.
subagent_cost() {
    local f=$1 line model i o cr c5 c1 pin pout
    [[ -z "$f" || ! -s "$f" ]] && { printf '0'; return; }
    line=$(_subagent_tokens "$f")
    [[ -z "$line" ]] && { printf '0'; return; }
    read -r model i o cr c5 c1 <<< "$line"
    read -r pin pout <<< "$(model_price "$model")"
    awk -v i="$i" -v o="$o" -v cr="$cr" -v c5="$c5" -v c1="$c1" \
        -v pin="$pin" -v pout="$pout" \
        'BEGIN { printf "%.6f",
                 (i*pin + cr*pin*0.1 + c5*pin*1.25 + c1*pin*2.0 + o*pout) / 1000000 }'
}
```

- [ ] **Step 2: Add a failing test with a fixture transcript**

```bash
echo "## subagent_cost"
type subagent_cost >/dev/null 2>&1 || { echo "FATAL: subagent_cost not loaded"; exit 2; }

# Fixture: one haiku subagent, streaming duplicates of a single message.id.
# Deduped usage: in=10, out=300, cr=0, c5=18887, c1=0.
# Haiku Pin=0.8, Pout=4. cost = (10 + 18887*1.25)*0.8/1e6 + 300*4/1e6
#   = (10 + 23608.75)*0.8/1e6 + 1200/1e6
#   = 23615.0/1e6 + 0.0012  (18894.2*0.8=15115.36? recompute in test note)
_sc_fix=$(mktemp "$TEST_TMP/agent-x.XXXXXX")
cat > "$_sc_fix" <<'JSONL'
{"type":"assistant","isSidechain":true,"message":{"id":"m1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":18887,"cache_creation":{"ephemeral_5m_input_tokens":18887,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","isSidechain":true,"message":{"id":"m1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":18887,"cache_creation":{"ephemeral_5m_input_tokens":18887,"ephemeral_1h_input_tokens":0}}}}
JSONL
# Deduped (max output=300): in=10,out=300,c5=18887.
# cost = (10 + 18887*1.25)*0.8/1e6 + 300*4/1e6
#      = (10 + 23608.75)*0.8/1e6 + 1200/1e6
#      = 23618.75*0.8/1e6 + 0.0012 = 18895.0/1e6 + 0.0012 = 0.018895 + 0.0012 = 0.020095
assert "one haiku subagent, deduped" "$(subagent_cost "$_sc_fix")" "0.020095"
assert "missing file → 0"            "$(subagent_cost "/no/such/file")" "0"
rm -f "$_sc_fix"
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash claude/test-statusline-helpers.sh`
Expected: FAIL — `subagent_cost` not yet sourced/typo, or arithmetic mismatch. (If the number differs, recompute by hand and fix the expected literal — the formula in the comment is the source of truth.)

- [ ] **Step 4: Run to verify it passes**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/subagent-cost.sh claude/test-statusline-helpers.sh
git commit -m "✨ add subagent_cost per-transcript estimator"
```

---

### Task 7: `session_subagent_cost` — sum the session's subagents, cached

**Files:**
- Modify: `claude/lib/subagent-cost.sh`
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Consumes: `subagent_cost`, `stat` (GNU/BSD), `awk`.
- Produces: `session_subagent_cost TRANSCRIPT_PATH` → echoes total USD (`%.6f`) across `<transcript-dir>/<session>/subagents/agent-*.jsonl`; echoes `0` when the dir is absent. `_stat_sig FILE` → echoes `size:mtime` (portable). Per-file cost is memoised in `/tmp/claude/subagent-cost-cache` keyed on `path:size:mtime` (completed files are static; only changed files re-parse).

- [ ] **Step 1: Add the enumeration + cache**

Append to `claude/lib/subagent-cost.sh`:

```bash
# Portable "size:mtime" signature (GNU stat, then BSD/macOS stat).
_stat_sig() {
    local sz mt
    sz=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
    mt=$(stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null)
    printf '%s:%s' "${sz:-0}" "${mt:-0}"
}

# Cost of one subagent file, memoised by path+size+mtime. A completed file is
# static, so its cost is cached permanently; a growing (running) file re-parses
# only when its signature changes.
_cached_subagent_cost() {
    local f=$1 key hit c
    local cache=/tmp/claude/subagent-cost-cache
    key="$f:$(_stat_sig "$f")"
    if [[ -f "$cache" ]]; then
        hit=$(grep -F "$key"$'\t' "$cache" 2>/dev/null | tail -1)
        if [[ -n "$hit" ]]; then printf '%s' "${hit##*$'\t'}"; return; fi
    fi
    c=$(subagent_cost "$f")
    mkdir -p /tmp/claude
    printf '%s\t%s\n' "$key" "$c" >> "$cache"
    printf '%s' "$c"
}

# Sum subagent cost for a session. $1 = main transcript path
# (<dir>/<session>.jsonl → subagents at <dir>/<session>/subagents/).
session_subagent_cost() {
    local transcript=$1 base subdir total f
    [[ -z "$transcript" || ! -f "$transcript" ]] && { printf '0'; return; }
    base="${transcript%.jsonl}"
    subdir="$base/subagents"
    [[ -d "$subdir" ]] || { printf '0'; return; }
    total=0
    for f in "$subdir"/agent-*.jsonl; do
        [[ -e "$f" ]] || continue
        total=$(awk -v a="$total" -v b="$(_cached_subagent_cost "$f")" \
                'BEGIN { printf "%.6f", a + b }')
    done
    printf '%s' "$total"
}
```

- [ ] **Step 2: Add a failing test with a fixture session tree**

```bash
echo "## session_subagent_cost"
type session_subagent_cost >/dev/null 2>&1 || { echo "FATAL: session_subagent_cost not loaded"; exit 2; }

# Build <dir>/<session>.jsonl + <dir>/<session>/subagents/agent-*.jsonl
_ss_dir=$(mktemp -d "$TEST_TMP/ss.XXXXXX")
: > "$_ss_dir/sess.jsonl"
mkdir -p "$_ss_dir/sess/subagents"
# agent 1: haiku, deduped in=10 out=300 c5=18887 → 0.020095 (from Task 6)
cat > "$_ss_dir/sess/subagents/agent-1.jsonl" <<'JSONL'
{"type":"assistant","isSidechain":true,"message":{"id":"m1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":18887,"cache_creation":{"ephemeral_5m_input_tokens":18887,"ephemeral_1h_input_tokens":0}}}}
JSONL
# agent 2: sonnet, in=0 out=1000 cr=100000 → (100000*0.1)*3/1e6 + 1000*15/1e6
#   = 10000*3/1e6 + 0.015 = 0.03 + 0.015 = 0.045
cat > "$_ss_dir/sess/subagents/agent-2.jsonl" <<'JSONL'
{"type":"assistant","isSidechain":true,"message":{"id":"n1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":0,"output_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSONL
# total = 0.020095 + 0.045000 = 0.065095
assert "sums both subagents" "$(session_subagent_cost "$_ss_dir/sess.jsonl")" "0.065095"

# No subagents dir → 0
: > "$_ss_dir/lonely.jsonl"
assert "no subagents dir → 0" "$(session_subagent_cost "$_ss_dir/lonely.jsonl")" "0"
rm -rf "$_ss_dir"
```

> **Cache note:** the test uses a fresh `mktemp` path each run, so `/tmp/claude/subagent-cost-cache` never collides across runs. If a maintainer re-runs with an unchanged fixture, the cache hit returns the same value — the assertion still holds.

- [ ] **Step 3: Run to verify it fails**

Run: `bash claude/test-statusline-helpers.sh`
Expected: FAIL — function missing, then (once added) confirm the summed literal.

- [ ] **Step 4: Run to verify it passes**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/subagent-cost.sh claude/test-statusline-helpers.sh
git commit -m "✨ add session_subagent_cost with mtime cache"
```

---

### Task 8: Wire aggregated cost into the statusline

**Files:**
- Modify: `claude/statusline-command.sh` — source the lib; add subagent cost to `COST` before `COST_SEC`.

**Interfaces:**
- Consumes: `session_subagent_cost`.
- Produces: integration only — verified by a live run.

- [ ] **Step 1: Source the lib**

After the `line1-layout.sh` source line added in Task 4:

```bash
# shellcheck source=claude/lib/subagent-cost.sh
source "$HOME/code/home/claude/lib/subagent-cost.sh" || exit 1
```

- [ ] **Step 2: Add subagent cost to the cost value**

Immediately before the `# Cost section` block (`statusline-command.sh:206`), add:

```bash
# Fold in the cost of this session's subagents (payload cost is main-thread
# only). Kept before COST_SEC so the displayed $ reflects the aggregate.
if [[ "$COST" != "unset" ]]; then
    _sub_cost=$(session_subagent_cost "$TRANSCRIPT_PATH")
    COST=$(awk -v a="$COST" -v b="$_sub_cost" 'BEGIN { printf "%.8f", a + b }')
fi
```

The existing `COST_SEC` block then formats `$COST` unchanged (`printf "%2.2f"`).

- [ ] **Step 3: Smoke-test that cost rises with subagents present**

```bash
# This session has a subagents/ dir; compare payload cost vs displayed.
jq -r '.cost.total_cost_usd' /tmp/claude/statusbar.json
bash claude/statusline-command.sh < /tmp/claude/statusbar.json | sed 's/\x1b\[[0-9;]*m//g' | head -1
```

Expected: the `$` shown on line 1 is ≥ the payload's `total_cost_usd` (equal only if the session has no subagents).

- [ ] **Step 4: Run the unit suite**

Run: `bash claude/test-statusline-helpers.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/statusline-command.sh
git commit -m "✨ aggregate subagent cost into statusline cost"
```

---

### Task 9: Document the rework in design-decisions

**Files:**
- Modify: `claude/design-decisions.md` — add a subsection under the statusline design notes.

- [ ] **Step 1: Append a design-decisions entry**

Add after the "Plan Display Rework" subsection:

```markdown
#### Line-1 Wrap/Reflow + Subagent Cost (2026-07-12)

Line 1 now **reflows** onto extra rows instead of dropping sections. A pure
engine `lib/line1-layout.sh` (`layout_line1`/`emit_line1`) picks the widest of
an ordered ladder of layouts whose every row fits its budget. Row 1 reserves 4
extra columns for the line-1-only right-edge chrome (`/rc` marker, system
notifications); continuation rows use full width. Never-dropped: model
indicator, pyenv, dir, branch, cost, context value, timer. Only the context
bar (droppable) and plan (wraps to its own row via `pick_plan_variant`, then
omitted if even `no_bars` won't fit) give way. Cost moved **before** context;
the cache-expiry timer was extracted from `render_plan_right` into
`render_timer` so it renders in any mode and stays glued after context. Tiers:
A wraps plan; B splits `[model pyenv dir]` / `[branch + context]`; C further
splits branch and context onto their own rows. Dropped the cosmetic
dir==branch merge (tiers need them separable).

Displayed cost now includes **subagent** cost (`lib/subagent-cost.sh`): the
payload's `total_cost_usd` is main-thread only, so per-subagent cost is
computed from `<session>/subagents/agent-*.jsonl` token usage × per-model base
price (cache read ×0.1, 5m write ×1.25, 1h write ×2.0), deduped by
`message.id`, cached by file size+mtime. Validated by reproducing this
session's main-thread `total_cost_usd` from its transcript (Opus 4.8 = $5/$25;
`claude-model-info.py` misprices it as 4.5's $15/$75, so a static table in
`subagent-cost.sh` is the source of truth). Spec:
`plans/2026-07-12-statusline-wrap-design.md`; plan:
`plans/2026-07-12-statusline-wrap-plan.md`.
```

- [ ] **Step 2: Commit**

```bash
git add claude/design-decisions.md
git commit -m "📝 document line-1 wrap + subagent cost rework"
```

---

## Self-Review

**Spec coverage:**
- Tiered wrap ladder (L0/A/B/C) → Task 2. ✓
- Never-drop set (model, pyenv, dir, branch, cost, ctx, timer) → Task 4 identity/context-group assembly; bar-only drop in Task 2. ✓
- Cost before context; timer after context before plan → Task 3 (`render_timer`) + Task 4 (`CG_*` order). ✓
- Row-1 `cols−4` budget, continuation `cols` → Task 4 (`L1_R1`/`L1_RC`), Task 2 (`emit_line1`). ✓
- Plan never wraps internally; richest style else omit → Task 1 (`pick_plan_variant`) + Task 4. ✓
- Timer extraction, mode-independent → Task 3. ✓
- Subagent cost: data source, dedup, formula, pricing, cache, add-to-payload → Tasks 5–8. ✓
- Validation that formula reproduces main cost → captured in Task 5 test rationale + design doc; the live check is the Task 8 smoke test. ✓
- Docs → Task 9. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code; every test has literal expected values.

**Type/name consistency:** `L1_*` global names match between Task 2 (consumer) and Task 4 (producer). `model_price` output `"IN OUT"` consumed by `subagent_cost` (Task 6) and `_subagent_tokens` output `"MODEL IN OUT CR C5 C1"` consumed by `subagent_cost`. `session_subagent_cost` → `_cached_subagent_cost` → `subagent_cost` chain consistent. `render_timer` (Task 3) consumed in Task 4. ✓

**Note for implementer:** the arithmetic literals in the Task 6/7 tests are computed by hand in the adjacent comments. If `jq`/`awk` produce a different value, re-derive from the commented formula rather than trusting the literal — the formula is authoritative.
