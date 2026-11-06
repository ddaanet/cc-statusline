# Plan Display Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the statusline line-1 plan rate-limit display to show `A%/B% C`
(used% / window-elapsed% + bar) per window with pace-based coloring, always
render windows whose data is present (even at 0%), and drop plan decorations
before the model name when space is tight.

**Architecture:** Two new pure helpers in `format-utils.sh` (`window_elapsed_pct`,
`plan_pace_color`) are unit-tested in isolation. `render_plan_right` in
`account-display.sh` is rewritten to compose them, and the plan-mode truncation
ladder in `statusline-command.sh` is reordered. The dead `format_burn_rate`,
`display_plan_limit_percent`, and `display_plan_usage` are removed.

**Tech Stack:** Bash 3.2-compatible shell, `jq`, `bc`; tests via a hand-rolled
`assert` harness in `claude/test-statusline-helpers.sh`.

## Global Constraints

- Bash must run under macOS bash 3.2 **and** Linux (dev droplet). No bash-4
  features (no associative arrays, no `${x^^}`).
- `date` calls must branch on `uname -s` (`date -r` on Darwin, `date -d @` on
  Linux) — follow the existing pattern in `format-utils.sh`.
- Every colored/bold segment must end by returning to the ambient dim baseline
  with `${RESET_DIM}` (never bare `${RESET}` outside `sparkline.sh`).
- `shellcheck -x claude/*.sh claude/lib/*.sh` must pass clean (precommit gate).
- Full test suite runs with `bash claude/test-statusline-helpers.sh`; precommit
  is `just precommit` (line-limits + shellcheck + tests).
- Color constants (`RED GREEN YELLOW CYAN BOLD RESET_DIM`) come from
  `lib/colors.sh`, already sourced by both the script and the test file.

---

## File Structure

- `claude/lib/format-utils.sh` — add `window_elapsed_pct` and `plan_pace_color`;
  remove `format_burn_rate`.
- `claude/lib/account-display.sh` — rewrite `render_plan_right`, add private
  `_render_plan_window`, change `display_vertical_bar` to take a color arg,
  remove `display_plan_limit_percent` and `display_plan_usage`, drop the dead
  plan branch in `render_account`.
- `claude/statusline-command.sh` — replace the plan-mode assembly block with the
  7-tier ladder.
- `claude/test-statusline-helpers.sh` — remove the `format_burn_rate` block; add
  `window_elapsed_pct` and `plan_pace_color` blocks.
- `claude/design-decisions.md` — document the rework.

---

## Task 1: Pure helpers — `window_elapsed_pct` + `plan_pace_color`

Two small, independent pure functions in the same file, added together because
neither is separately reviewable.

**Files:**
- Modify: `claude/lib/format-utils.sh` (add both functions near `format_burn_rate`, ~line 264)
- Test: `claude/test-statusline-helpers.sh` (two new blocks)

**Interfaces:**
- Consumes: color constants `$RED $GREEN $YELLOW` from `colors.sh`.
- Produces:
  - `window_elapsed_pct <resets_at_epoch> <window_secs> [now_epoch]` → integer
    `0`–`100`, or empty string when `resets_at` is empty/`null`/`0`.
  - `plan_pace_color <A_int> <B_int>` → a single SGR color escape.
    Precedence: `A > 94` → red; else `A < B` → green; else (`A ≥ B`) → yellow.

- [ ] **Step 1: Write the failing tests**

Add this block to `claude/test-statusline-helpers.sh` immediately **before** the
`echo "## format_burn_rate"` line (that block is removed in Task 2):

```bash
echo "## window_elapsed_pct"
# Window: now=1000000, 5h window (18000s).
_we_now=1000000
assert "50% elapsed"             "$(window_elapsed_pct $(( _we_now + 9000 ))  18000 $_we_now)" "50"
assert "0% elapsed (just reset)" "$(window_elapsed_pct $(( _we_now + 18000 )) 18000 $_we_now)" "0"
assert "100% elapsed (at reset)" "$(window_elapsed_pct $_we_now              18000 $_we_now)" "100"
assert "clamp >100 (stale past)" "$(window_elapsed_pct $(( _we_now - 5000 ))  18000 $_we_now)" "100"
assert "clamp <0 (future start)" "$(window_elapsed_pct $(( _we_now + 27000 )) 18000 $_we_now)" "0"
assert "null reset → empty"      "$(window_elapsed_pct null 18000 $_we_now)" ""
assert "zero reset → empty"      "$(window_elapsed_pct 0    18000 $_we_now)" ""
assert "empty reset → empty"     "$(window_elapsed_pct ''   18000 $_we_now)" ""

echo "## plan_pace_color"
# $RED/$GREEN/$YELLOW resolve from constants already in scope: the test file
# redefines RED to $'\033[31m' (identical to colors.sh); GREEN/YELLOW come from
# the sourced colors.sh.
assert "A>94 → red (beats pace)" "$(plan_pace_color 95 99)" "$RED"
assert "under pace → green"      "$(plan_pace_color 40 50)" "$GREEN"
assert "over pace → yellow"      "$(plan_pace_color 60 50)" "$YELLOW"
assert "tie A==B → yellow"       "$(plan_pace_color 50 50)" "$YELLOW"
assert "A>94 wins over under"    "$(plan_pace_color 95 96)" "$RED"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash claude/test-statusline-helpers.sh 2>&1 | grep -E "window_elapsed_pct|plan_pace_color|FAIL" | head`
Expected: FAIL lines — `window_elapsed_pct: command not found` /
`plan_pace_color: command not found` and mismatches.

- [ ] **Step 3: Add both implementations**

Insert into `claude/lib/format-utils.sh` just above `format_burn_rate` (which is
removed in Task 2):

```bash
# Window-elapsed percent: how far through the rate-limit window we are.
# $1=resets_at_epoch $2=window_secs $3=now_epoch (optional override for tests)
# Outputs an integer 0-100, or nothing when resets_at is missing/null/0.
window_elapsed_pct() {
    local resets_at=$1 window_secs=$2
    local now=${3:-$(date +%s)}
    [[ -z "$resets_at" || "$resets_at" == "null" || "$resets_at" == "0" ]] && return
    local elapsed=$(( now - (resets_at - window_secs) ))
    local pct=$(( elapsed * 100 / window_secs ))
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    printf '%d' "$pct"
}

# Pace color for a rate-limit window. $1=A (used %, int) $2=B (elapsed %, int).
# A>94 → red (saturation warning, wins); else A<B → green (under pace);
# else (A>=B, ties included) → yellow (at/over pace).
plan_pace_color() {
    local a=$1 b=$2
    if (( a > 94 )); then
        printf '%s' "$RED"
    elif (( a < b )); then
        printf '%s' "$GREEN"
    else
        printf '%s' "$YELLOW"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash claude/test-statusline-helpers.sh 2>&1 | grep -A8 -E "## window_elapsed_pct|## plan_pace_color"`
Expected: 8 + 5 `OK` lines, no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/format-utils.sh claude/test-statusline-helpers.sh
git commit -m "feat: add window_elapsed_pct and plan_pace_color helpers"
```

---

## Task 2: Rewrite `render_plan_right`; remove dead code

**Files:**
- Modify: `claude/lib/account-display.sh` (rewrite `render_plan_right` ~232-297;
  rewrite `display_vertical_bar` ~24-54; delete `display_plan_limit_percent`
  ~9-22 and `display_plan_usage` ~56-100; edit `render_account` ~183-223)
- Modify: `claude/lib/format-utils.sh` (delete `format_burn_rate` ~265-283)
- Modify: `claude/test-statusline-helpers.sh` (delete the `format_burn_rate`
  block, current lines 105-118)

**Interfaces:**
- Consumes: `window_elapsed_pct`, `plan_pace_color` (Task 1); `format_5h_reset`,
  `format_7d_reset` (unchanged); globals `$input`, color constants.
- Produces: `render_plan_right <style> <cache_expiry>` where `style` ∈
  `full | no_plan_label | no_period_labels | no_bars`. Emits nothing when
  neither window's `used_percentage` is present. New private
  `_render_plan_window`. `display_vertical_bar <util> <color>` now takes color.

- [ ] **Step 1: Delete `format_burn_rate` and its tests**

In `claude/lib/format-utils.sh` delete the whole `format_burn_rate` function
(the comment block starting `# Burn rate:` through its closing `}`, ~lines
265-283).

In `claude/test-statusline-helpers.sh` delete the block from `echo "## format_burn_rate"`
through the `assert "too early → empty" ...` line and its trailing blank line
(current lines 105-118 inclusive).

- [ ] **Step 2: Replace `display_plan_limit_percent` + `display_vertical_bar`**

In `claude/lib/account-display.sh`, delete `display_plan_limit_percent`
(lines 9-22) entirely, and replace `display_vertical_bar` (lines 24-54) with:

```bash
# Display vertical progress bar in a caller-supplied color.
# $1=utilization (0-100) $2=color escape
display_vertical_bar() {
    local utilization=$1 color=$2
    local util_int; util_int=$(printf "%.0f" "$utilization")
    local idx=$(( (util_int * 8 + 50) / 100 ))
    [[ $idx -gt 8 ]] && idx=8
    [[ $idx -lt 0 ]] && idx=0
    case $idx in
        0) echo -n "${color} ${RESET_DIM}" ;;  # Empty space for 0%
        1) echo -n "${color}▁${RESET_DIM}" ;;
        2) echo -n "${color}▂${RESET_DIM}" ;;
        3) echo -n "${color}▃${RESET_DIM}" ;;
        4) echo -n "${color}▄${RESET_DIM}" ;;
        5) echo -n "${color}▅${RESET_DIM}" ;;
        6) echo -n "${color}▆${RESET_DIM}" ;;
        7) echo -n "${color}▇${RESET_DIM}" ;;
        8) echo -n "${color}█${RESET_DIM}" ;;
    esac
}
```

- [ ] **Step 3: Delete `display_plan_usage`**

In `claude/lib/account-display.sh`, delete the entire `display_plan_usage`
function (lines 56-100, the comment `# Display plan usage section` through its
closing `}`). `display_api_usage` immediately below it stays.

- [ ] **Step 4: Remove the dead plan branch in `render_account`**

In `render_account`, the `if [[ "$MODE" == "plan" ]]` branch is unreachable
(`render_account` is only called in API mode) and now references the deleted
`display_plan_usage`. Replace the outer `if/else` so only the API body remains.
Change:

```bash
render_account() {
    if validate_state; then
        if [[ "$MODE" == "plan" ]]; then
            echo -n "${GREEN}Plan  "
            display_plan_usage
        else
            # API mode
            echo -n "${YELLOW}API${RESET_DIM}  "
            ...
        fi
    else
        echo -n "${RED}Auth state inconsistent - run 'claude-account status'${RESET_DIM}"
    fi
}
```

to:

```bash
render_account() {
    if validate_state; then
        # API mode (plan-mode status is rendered on line 1 by render_plan_right)
        echo -n "${YELLOW}API${RESET_DIM}  "

        if [[ "$PROVIDER" == "openrouter" ]]; then
            # OpenRouter: use custom statusline if available
            local openrouter_line_ts=$HOME/code/openrouter-examples/claude-code/statusline.ts
            if [ -r "$openrouter_line_ts" ]; then
                echo "$input" | npx tsx "$openrouter_line_ts"
            else
                display_api_usage
            fi
        else
            # Anthropic/LiteLLM: show switchback if scheduled
            if [[ "$(uname -s)" == "Darwin" ]]; then
                local launch_plist=~/Library/LaunchAgents/com.claude.account-switch.plist
                if [[ -f "$launch_plist" ]]; then
                    local switchback_time
                    switchback_time=$(python3 -c "import plistlib; p=plistlib.load(open('$launch_plist','rb')); d=p['StartCalendarInterval']; print(f\"{d['Month']}/{d['Day']} {d['Hour']:02d}:{d['Minute']:02d}\")" 2>/dev/null)
                    if [[ -n "$switchback_time" ]]; then
                        echo -n "Switchback: $switchback_time"
                    else
                        echo -n "Switchback: parse error"
                    fi
                else
                    echo -n "No auto-switchback"
                fi
            else
                echo -n "No auto-switchback"
            fi
        fi
    else
        echo -n "${RED}Auth state inconsistent - run 'claude-account status'${RESET_DIM}"
    fi
}
```

- [ ] **Step 5: Rewrite `render_plan_right` and add `_render_plan_window`**

Replace the entire `render_plan_right` function (from its comment header
`# Render plan rate-limit status...` through its closing `}`, lines ~225-297)
with:

```bash
# Render one rate-limit window: "<label> A%/B% C <reset>" with pace color.
# $1=label $2=used_raw $3=reset_epoch $4=window_secs
# $5=show_periods (0/1) $6=show_bars (0/1) $7=reset_formatter_fn name
_render_plan_window() {
    local label=$1 used_raw=$2 reset_epoch=$3 window_secs=$4
    local show_periods=$5 show_bars=$6 reset_fn=$7

    local a; a=$(printf '%.0f' "$used_raw")
    local b; b=$(window_elapsed_pct "$reset_epoch" "$window_secs")
    local at_limit=0; (( a >= 100 )) && at_limit=1

    local color
    if [[ -n "$b" ]]; then
        color=$(plan_pace_color "$a" "$b")
    elif (( a > 94 )); then
        color=$RED
    else
        color=$RESET_DIM
    fi

    echo -n "${RESET_DIM}"
    (( at_limit )) && echo -n "${BOLD}${color}"
    (( show_periods )) && echo -n "${label} "

    # A%/B% in pace color
    printf '%s%2d%%' "$color" "$a"
    [[ -n "$b" ]] && printf '/%d%%' "$b"

    if (( show_bars )) && [[ -n "$b" ]]; then
        echo -n ' '
        display_vertical_bar "$a" "$color"
        (( at_limit )) && echo -n "${BOLD}${color}"
    fi

    local reset_str; reset_str=$($reset_fn "$reset_epoch")
    if [[ -n "$reset_str" ]]; then
        (( at_limit )) || echo -n "${RESET_DIM}"
        echo -n " $reset_str"
    fi

    echo -n "${RESET_DIM}"
}

# Render plan rate-limit status for the right side of line 1.
# $1=style: "full" | "no_plan_label" | "no_period_labels" | "no_bars"
# $2=cache_expiry: pre-formatted HH:MM string (or empty); prepends  icon.
# Reads globals: $input (JSON), color constants.
# Emits nothing when neither window's used_percentage is present.
render_plan_right() {
    local style=${1:-full} cache_expiry=$2

    local five_raw seven_raw five_reset seven_reset
    five_raw=$(echo   "$input" | jq -r '.rate_limits.five_hour.used_percentage // "absent"' 2>/dev/null)
    five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // ""'             2>/dev/null)
    seven_raw=$(echo  "$input" | jq -r '.rate_limits.seven_day.used_percentage // "absent"' 2>/dev/null)
    seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // ""'            2>/dev/null)

    # Nothing to show when neither window's data is present.
    [[ "$five_raw" == "absent" && "$seven_raw" == "absent" ]] && return

    local show_periods=1 show_bars=1 show_plan_label=0
    [[ "$style" == "no_period_labels" || "$style" == "no_bars" ]] && show_periods=0
    [[ "$style" == "no_bars" ]] && show_bars=0
    [[ "$style" == "full" ]] && show_plan_label=1

    echo -n "${RESET_DIM}"
    (( show_plan_label )) && echo -n "${GREEN}Plan ${RESET_DIM}"

    local rendered_five=0
    if [[ "$five_raw" != "absent" ]]; then
        _render_plan_window "5h" "$five_raw" "$five_reset" 18000 \
            "$show_periods" "$show_bars" format_5h_reset
        rendered_five=1
    fi

    if (( rendered_five )) && [[ "$seven_raw" != "absent" ]]; then
        echo -n " / "
    fi

    if [[ "$seven_raw" != "absent" ]]; then
        _render_plan_window "7d" "$seven_raw" "$seven_reset" 604800 \
            "$show_periods" "$show_bars" format_7d_reset
    fi

    # Cache expiry (nf-fa-hourglass_half U+F252)
    if [[ -n "$cache_expiry" ]]; then
        local _hg=$'\xef\x89\x92'
        echo -n "  ${CYAN}${_hg} ${cache_expiry}${RESET_DIM}"
    fi
}
```

- [ ] **Step 6: Run shellcheck and the test suite**

Run: `shellcheck -x claude/lib/account-display.sh claude/lib/format-utils.sh && bash claude/test-statusline-helpers.sh 2>&1 | tail -3`
Expected: shellcheck clean; test summary `PASS <n> tests` with no `FAIL`.

- [ ] **Step 7: Verify rendering end-to-end with a sample payload**

Run this (drives the real `render_plan_right` through a sourced shell):

```bash
bash -c '
  cd claude
  for f in lib/colors.sh lib/format-utils.sh lib/account-validation.sh lib/account-display.sh; do source "$f"; done
  now=$(date +%s)
  input=$(jq -nc --argjson n "$now" "{rate_limits:{five_hour:{used_percentage:42,resets_at:(\$n+9000)},seven_day:{used_percentage:88,resets_at:(\$n+300000)}}}")
  export input
  for s in full no_plan_label no_period_labels no_bars; do
    printf "%-16s " "$s"; render_plan_right "$s" ""; echo
  done
  # zero-state: 5h present at 0, 7d absent
  input=$(jq -nc --argjson n "$now" "{rate_limits:{five_hour:{used_percentage:0,resets_at:(\$n+16000)}}}")
  export input
  printf "%-16s " "zero-5h"; render_plan_right full ""; echo
'
```
Expected (colors as escapes; visually): `full` shows
`Plan 5h 42%/50% ▄ HH:MM / 7d 88%/50% ▇ <day>`; `no_plan_label` drops `Plan `;
`no_period_labels` drops `5h`/`7d`; `no_bars` drops the `▄`/`▇` glyphs;
`zero-5h` shows `Plan 5h  0%/11% ▁ HH:MM` (7d absent → not shown). 42<50 → 5h
green; 88≥50 → 7d yellow. Confirm the pace colors and that 0% renders.

- [ ] **Step 8: Commit**

```bash
git add claude/lib/account-display.sh claude/lib/format-utils.sh claude/test-statusline-helpers.sh
git commit -m "feat: A%/B% pace-colored plan windows; drop burn rate"
```

---

## Task 3: Reorder the truncation ladder; document the rework

**Files:**
- Modify: `claude/statusline-command.sh` (plan-mode block, lines ~227-250)
- Modify: `claude/design-decisions.md` (statusline indicators area)

**Interfaces:**
- Consumes: `render_plan_right` with the four styles (Task 2); existing
  `MODEL_FULL MODEL_COMPACT PYENV_SEC DIRGIT_SEC COST_SEC CTX_SEC BAR_SEC vislen`.

- [ ] **Step 1: Replace the plan-mode assembly block**

Replace lines 227-250 (`if [[ "$MODE" == "plan" ]]; then` … through the last
plan-mode `fi` just before the `else` on line 251) with:

```bash
if [[ "$MODE" == "plan" ]]; then
    CACHE_EXPIRY=$(format_cache_expiry "$TRANSCRIPT_PATH")
    PLAN_FULL=$(render_plan_right full "$CACHE_EXPIRY")
    PLAN_NOLABEL=$(render_plan_right no_plan_label "$CACHE_EXPIRY")
    PLAN_NOPER=$(render_plan_right no_period_labels "$CACHE_EXPIRY")
    PLAN_NOBARS=$(render_plan_right no_bars "$CACHE_EXPIRY")
    _PS=""
    [[ -n "$PLAN_FULL" ]] && _PS="  "

    # Drop order (least essential first): Plan label → period labels →
    # plan bars → model name → context bar → cost.
    line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_FULL}"
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_NOLABEL}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_NOPER}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_NOBARS}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_NOBARS}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${_PS}${PLAN_NOBARS}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${CTX_SEC}${_PS}${PLAN_NOBARS}"
    fi
else
```

(The `else` branch for API mode below it is unchanged, as is the trailing
`vis_truncate "$line1" "$EFFECTIVE_COLS"`.)

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck -x claude/statusline-command.sh`
Expected: clean (no output).

- [ ] **Step 3: Verify the ladder shrinks in the right order**

Run:

```bash
now=$(date +%s)
payload=$(jq -nc --argjson n "$now" '{model:{display_name:"Opus 4.8"},workspace:{current_dir:"'"$PWD"'"},cost:{total_cost_usd:1.23},context_window:{current_usage:{input_tokens:60000,output_tokens:1500,cache_creation_input_tokens:500,cache_read_input_tokens:0}},rate_limits:{five_hour:{used_percentage:42,resets_at:($n+9000)},seven_day:{used_percentage:88,resets_at:($n+300000)}}}')
for w in 200 122 120 114 110 106 104; do
  printf '=== %s cols ===\n' "$w"
  echo "$payload" | COLUMNS=$w bash claude/statusline-command.sh | head -1
done
```
The payload now includes `context_window.current_usage` so the context 🧠 bar
and token count actually render (the original example payload omitted this
field, which left the context bar empty and made tiers 6-7 unobservable).

Expected, in order as width drops: at 200 the full `Plan 5h …/… ▃ … / 7d
…/… ▇ …` shows with model name `Opus`, cost `$1.23`, and context `62k █▂`;
at 122 the `Plan ` label is gone (`5h`/`7d` + bars remain); at 120 the
period labels are also gone (bars remain); at 114 the bars are gone too; at
110 the model name collapses to just the `❶` medal; at 106 the context bar
`█▂` is gone (token count `62k` remains); at 104 the cost `$1.23` is gone —
**the model name survives three plan-decoration drops before it changes,
and the context bar/cost drop only after that**, confirming the reordering.
Exact column breakpoints shift with the length of `$PWD`'s directory/branch
name (`DIRGIT_SEC`); rerun with a wider sweep first if your breakpoints
don't land on these exact numbers — the tier *order* is what matters, not
the precise widths. (If your statusline build ignores `COLUMNS` and only
reads `tput cols`, resize the terminal instead and run the script once per
width.)

- [ ] **Step 4: Run the full precommit gate**

Run: `just precommit`
Expected: `line-limits` OK, `shellcheck` OK, `statusline tests` all `OK` with
`PASS <n> tests`, `✓ Precommit OK`.

- [ ] **Step 5: Document the rework in design-decisions.md**

Under the "Statusline Indicators" area of `claude/design-decisions.md`, add:

```markdown
#### Plan Display Rework — `A%/B% C` per-window (2026-07-02)

Each rate-limit window renders `A%/B% C`: A=`used_percentage`, B=window-elapsed
percent (`window_elapsed_pct` in `lib/format-utils.sh`), C=the vertical bar.
The old burn-rate `×N` was removed — B conveys the same pace directly
(burn = A/B) — and `format_burn_rate` deleted. One pace color spans A%/B% and
the bar: red if A>94 (saturation, wins), else green if A<B (under pace), else
yellow (A≥B, ties yellow); `plan_pace_color` in `lib/format-utils.sh`. Bold
red is retained when A≥100.

A window renders whenever its `used_percentage` field is present/non-null
(shows `0%/B% ▁` at zero); the section is hidden only when neither window's
field is present. This replaced the old "both == 0 → nothing" guard.

Truncation reordered so plan decorations drop before the model name:
`render_plan_right` gained a `no_bars` style, and the plan-mode ladder in
`statusline-command.sh` drops, in order, the `Plan` label → `5h`/`7d` labels →
bars → model name → context bar → cost. The context 🧠 bar is not in the first
batch. Dead `display_plan_usage` / `display_plan_limit_percent` removed.

Spec: `plans/2026-07-02-plan-display-rework-design.md`;
plan: `plans/2026-07-02-plan-display-rework-plan.md`.
```

- [ ] **Step 6: Commit**

```bash
git add claude/statusline-command.sh claude/design-decisions.md
git commit -m "feat: drop plan decorations before model name on narrow widths"
```

---

## Self-Review Notes

- **Spec coverage:** §1 format → Tasks 1,2; §2 pace color → Tasks 1,2; §3
  zero-state/presence → Task 2 (sentinel `"absent"`); §4 truncation ladder →
  Task 3; tests → Tasks 1,2; docs → Task 3. `format_burn_rate` removal → Task 2.
- **Type consistency:** `window_elapsed_pct(resets_at, window_secs, [now])`,
  `plan_pace_color(A, B)`, `display_vertical_bar(util, color)`,
  `render_plan_right(style, cache_expiry)` with styles
  `full|no_plan_label|no_period_labels|no_bars` — used identically across tasks.
- **Presence semantics:** jq `// "absent"` yields `"absent"` for null/absent
  but keeps `0` (jq `//` passes through `0`), so 0% renders and only
  null/absent hides — matches §3.
- **Granularity:** 3 tasks, each an independent review gate — pure helpers,
  the rendering rewrite, the ladder+docs. The two trivial same-file helpers
  were merged (not separately rejectable); the doc update was folded into the
  ladder task rather than dispatched on its own.
