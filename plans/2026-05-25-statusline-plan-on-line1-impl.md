# Statusline Plan-on-Line1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move plan rate-limit status to the right side of line 1 (always visible); add burn rate (×N.N) and cache expiry ( HH:MM) metrics; make line 2 sparkline-only; add timing instrumentation to `/tmp/claude/statusline-timing.log`.

**Architecture:** Extend four existing lib modules in place — no new files. `format_burn_rate` lands in `format-utils.sh` (pure math), `format_cache_expiry` in `context-display.sh` (transcript reader), `render_plan_right` in `account-display.sh` (plan display owner). The orchestrator gets a new 6-tier cascade for Plan mode and drops the line-2 account block for Plan mode. TDD: unit tests for the two pure functions before implementation.

**Tech Stack:** bash, jq, bc, shellcheck, `just precommit`.

---

## File Map

| File | Change |
|------|--------|
| `claude/lib/format-utils.sh` | Add `format_burn_rate` |
| `claude/lib/context-display.sh` | Add `format_cache_expiry` |
| `claude/lib/account-display.sh` | Add `render_plan_right`; existing functions unchanged |
| `claude/statusline-command.sh` | Move MODE detection; new 6-tier Plan cascade; drop Plan-mode line-2 account; add timing |
| `claude/test-statusline-helpers.sh` | Source `colors.sh` + `context-display.sh`; add tests for both new pure functions |

---

## Task 1: `format_burn_rate` — test then implement

**Files:**
- Modify: `claude/lib/format-utils.sh`
- Modify: `claude/test-statusline-helpers.sh`

- [ ] **Step 1: Add failing tests**

Add to `claude/test-statusline-helpers.sh` after the `## emit_truncated` block:

```bash
echo "## format_burn_rate"
# Window setup: _now=1000000, 5h window, 9000s elapsed (50% of 18000s)
_br_now=1000000
_br_resets=$(( _br_now + 9000 ))   # 9000s remaining → 9000s elapsed

assert "on-track 1.0"       "$(format_burn_rate 50 $_br_resets 18000 $_br_now)" "×1.0"
assert "overburn 1.5"       "$(format_burn_rate 75 $_br_resets 18000 $_br_now)" "×1.5"
assert "underburn 0.5"      "$(format_burn_rate 25 $_br_resets 18000 $_br_now)" "×0.5"
assert "zero usage → empty" "$(format_burn_rate 0  $_br_resets 18000 $_br_now)" ""
assert "null reset → empty" "$(format_burn_rate 50 null        18000 $_br_now)" ""
# elapsed_frac < 5%: only 360s of 18000s elapsed (2%)
_br_resets2=$(( _br_now + 17640 ))
assert "too early → empty"  "$(format_burn_rate 50 $_br_resets2 18000 $_br_now)" ""
```

- [ ] **Step 2: Verify tests fail**

```bash
bash claude/test-statusline-helpers.sh 2>&1 | tail -20
```

Expected: FAIL lines for the new `format_burn_rate` cases (function not found).

- [ ] **Step 3: Implement `format_burn_rate`**

Append to `claude/lib/format-utils.sh`:

```bash
# Burn rate: how fast the window is being consumed relative to elapsed time.
# $1=used_pct (0-100 int), $2=resets_at_epoch, $3=window_secs
# $4=now_epoch (optional override, used by tests)
# Outputs "×N.N" (e.g. "×1.5") or nothing when skip conditions apply.
# Skip when: used_pct=0, resets_at missing/null, elapsed < 5% of window.
# burn = used_pct * window_secs / (elapsed * 100); 1.0 = on track.
format_burn_rate() {
    local used_pct=$1 resets_at=$2 window_secs=$3
    local now=${4:-$(date +%s)}
    [[ -z "$used_pct" || "$used_pct" == "0" || "$used_pct" == "null" ]] && return
    [[ -z "$resets_at" || "$resets_at" == "null" || "$resets_at" == "0" ]] && return
    local elapsed=$(( now - (resets_at - window_secs) ))
    (( elapsed <= 0 )) && return
    local elapsed_pct=$(( elapsed * 100 / window_secs ))
    (( elapsed_pct < 5 )) && return
    local burn
    burn=$(printf '%.1f' "$(bc -l <<< "$used_pct * $window_secs / ($elapsed * 100)")")
    printf '×%s' "$burn"
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
bash claude/test-statusline-helpers.sh 2>&1 | tail -20
```

Expected: all `format_burn_rate` assertions show `OK`, total PASS count increases by 6.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck claude/lib/format-utils.sh
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add claude/lib/format-utils.sh claude/test-statusline-helpers.sh
git commit -m "feat(statusline): add format_burn_rate to format-utils"
```

---

## Task 2: `format_cache_expiry` — test then implement

**Files:**
- Modify: `claude/lib/context-display.sh`
- Modify: `claude/test-statusline-helpers.sh`

- [ ] **Step 1: Add source lines to test file**

In `claude/test-statusline-helpers.sh`, find the existing source block (the lines that source `format-utils.sh`) and add after it:

```bash
# shellcheck source=claude/lib/colors.sh
source "$HERE/lib/colors.sh" || { echo "FATAL: colors.sh not found"; exit 2; }
# shellcheck source=claude/lib/context-display.sh
source "$HERE/lib/context-display.sh" || { echo "FATAL: context-display.sh not found"; exit 2; }
```

- [ ] **Step 2: Add failing tests**

Append after the `## format_burn_rate` block:

```bash
echo "## format_cache_expiry"
assert "empty path → empty"      "$(format_cache_expiry "")"              ""
assert "missing file → empty"    "$(format_cache_expiry "/no/such/file")" ""

# Fresh transcript: assistant entry 59s ago → cache expires in ~4m, output is HH:MM
_ce_now=$(date +%s)
_ce_ts=$(date -d "@$(( _ce_now - 59 ))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         date -r "$(( _ce_now - 59 ))" -u +%Y-%m-%dT%H:%M:%SZ)
_ce_tf=$(mktemp)
printf '{"type":"assistant","timestamp":"%s","isSidechain":false,"message":{"usage":{"input_tokens":10,"output_tokens":5}}}\n' \
    "$_ce_ts" > "$_ce_tf"
_ce_result=$(format_cache_expiry "$_ce_tf")
rm -f "$_ce_tf"
if [[ "$_ce_result" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    echo "  OK   fresh cache returns HH:MM: $_ce_result"; (( PASS++ ))
else
    echo "  FAIL fresh cache: expected HH:MM, got '$_ce_result'"; (( FAIL++ ))
fi

# Stale transcript: assistant entry 360s ago (6 min) → cache expired → empty
_ce_ts2=$(date -d "@$(( _ce_now - 360 ))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
          date -r "$(( _ce_now - 360 ))" -u +%Y-%m-%dT%H:%M:%SZ)
_ce_tf2=$(mktemp)
printf '{"type":"assistant","timestamp":"%s","isSidechain":false,"message":{"usage":{"input_tokens":10,"output_tokens":5}}}\n' \
    "$_ce_ts2" > "$_ce_tf2"
assert "expired cache → empty" "$(format_cache_expiry "$_ce_tf2")" ""
rm -f "$_ce_tf2"
```

- [ ] **Step 3: Verify tests fail**

```bash
bash claude/test-statusline-helpers.sh 2>&1 | tail -20
```

Expected: FAIL for `format_cache_expiry` cases (function not found).

- [ ] **Step 4: Implement `format_cache_expiry`**

Append to `claude/lib/context-display.sh`:

```bash
# Expiry time of the most recent prompt cache entry.
# $1=transcript_path. Outputs HH:MM (local) or nothing if expired or unavailable.
# Cache TTL = 300s (5 minutes) from last assistant API call.
format_cache_expiry() {
    local transcript_path=$1
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return
    local last_ts
    last_ts=$(jq -r '
        select(.type == "assistant" and (.isSidechain // false | not)) |
        (.timestamp // "") | if . == "" then empty else . end
    ' "$transcript_path" 2>/dev/null | tail -1)
    [[ -z "$last_ts" ]] && return
    local last_epoch
    if [[ "$(uname -s)" == "Darwin" ]]; then
        last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" +%s 2>/dev/null)
    else
        last_epoch=$(date -d "${last_ts}" +%s 2>/dev/null)
    fi
    [[ -z "$last_epoch" ]] && return
    local expiry=$(( last_epoch + 300 ))
    local now; now=$(date +%s)
    (( now >= expiry )) && return
    if [[ "$(uname -s)" == "Darwin" ]]; then
        date -r "$expiry" +%H:%M
    else
        date -d "@$expiry" +%H:%M
    fi
}
```

- [ ] **Step 5: Run tests — expect pass**

```bash
bash claude/test-statusline-helpers.sh 2>&1 | tail -20
```

Expected: all `format_cache_expiry` assertions show `OK`.

- [ ] **Step 6: Shellcheck**

```bash
shellcheck -x claude/lib/context-display.sh
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add claude/lib/context-display.sh claude/test-statusline-helpers.sh
git commit -m "feat(statusline): add format_cache_expiry to context-display"
```

---

## Task 3: `render_plan_right` in account-display.sh

**Files:**
- Modify: `claude/lib/account-display.sh`

Integration-tested via smoke test in Task 4. No unit test here (function reads `$input` global and emits SGR).

- [ ] **Step 1: Append `render_plan_right` to account-display.sh**

```bash
# Render plan rate-limit status for the right side of line 1.
# $1=style: "full" | "no_plan_label" | "no_period_labels"
# $2=cache_expiry: pre-formatted HH:MM string (or empty); function prepends  icon.
# Reads globals: $input (JSON), color constants.
# Calls: format_burn_rate, format_5h_reset, format_7d_reset,
#        display_plan_limit_percent, display_vertical_bar.
# Outputs nothing when both rate-limit windows are at 0.
render_plan_right() {
    local style=${1:-full} cache_expiry=$2

    local five_util seven_util five_reset seven_reset
    five_util=$(echo  "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' 2>/dev/null)
    five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // "0"' 2>/dev/null)
    seven_util=$(echo  "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0' 2>/dev/null)
    seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // "0"' 2>/dev/null)

    # Nothing to show when both windows are zero
    if (( $(echo "$five_util == 0 && $seven_util == 0" | bc) )); then return; fi

    echo -n "${RESET}"
    [[ "$style" == "full" ]] && echo -n "${GREEN}Plan ${RESET}"

    # Five-hour window
    if (( $(echo "$five_util != 0" | bc) )); then
        local five_at=0
        (( $(echo "$five_util >= 100" | bc) )) && five_at=1
        (( five_at )) && echo -n "${BOLD}${RED}"
        [[ "$style" != "no_period_labels" ]] && echo -n "5h "
        display_plan_limit_percent "$five_util"
        echo -n ' '
        display_vertical_bar "$five_util"
        local five_burn; five_burn=$(format_burn_rate "$five_util" "$five_reset" 18000)
        if [[ -n "$five_burn" ]]; then
            local bcolor="${CYAN}"
            (( $(bc -l <<< "${five_burn#×} > 1.2") )) && bcolor="${RED}"
            echo -n " ${bcolor}${five_burn}${RESET}"
        fi
        local five_at_str; five_at_str=$(format_5h_reset "$five_reset")
        [[ -n "$five_at_str" ]] && echo -n " $five_at_str"
        (( five_at )) && echo -n "${RESET}"
    fi

    # Separator between windows
    if (( $(echo "$five_util != 0 && $seven_util != 0" | bc) )); then echo -n " / "; fi

    # Seven-day window
    if (( $(echo "$seven_util != 0" | bc) )); then
        local seven_at=0
        (( $(echo "$seven_util >= 100" | bc) )) && seven_at=1
        (( seven_at )) && echo -n "${BOLD}${RED}"
        [[ "$style" != "no_period_labels" ]] && echo -n "7d "
        display_plan_limit_percent "$seven_util"
        echo -n ' '
        display_vertical_bar "$seven_util"
        local seven_burn; seven_burn=$(format_burn_rate "$seven_util" "$seven_reset" 604800)
        if [[ -n "$seven_burn" ]]; then
            local bcolor="${CYAN}"
            (( $(bc -l <<< "${seven_burn#×} > 1.2") )) && bcolor="${RED}"
            echo -n " ${bcolor}${seven_burn}${RESET}"
        fi
        local seven_at_str; seven_at_str=$(format_7d_reset "$seven_reset")
        [[ -n "$seven_at_str" ]] && echo -n " $seven_at_str"
        (( seven_at )) && echo -n "${RESET}"
    fi

    # Cache expiry (nf-fa-hourglass_half U+F252)
    if [[ -n "$cache_expiry" ]]; then
        echo -n "  ${CYAN}$'\xef\x89\x92' ${cache_expiry}${RESET}"
    fi
}
```

- [ ] **Step 2: Shellcheck**

```bash
shellcheck -x claude/lib/account-display.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add claude/lib/account-display.sh
git commit -m "feat(statusline): add render_plan_right to account-display"
```

---

## Task 4: Update orchestrator

**Files:**
- Modify: `claude/statusline-command.sh`

- [ ] **Step 1: Add timing start and move MODE/PROVIDER detection**

In `claude/statusline-command.sh`:

a) After the `echo "$input" > /tmp/claude/statusbar.json` line, add:
```bash
_sl_start_ms=$(date +%s%3N 2>/dev/null || echo 0)
```

b) Find the `get_account_mode` wrapper definition block:
```bash
# Wrapper for statusline (historically uses get_account_mode)
get_account_mode() { get_mode; }

STATUSLINE_COLS=$(get_cols)
```

Replace with:
```bash
# Wrapper for statusline (historically uses get_account_mode)
get_account_mode() { get_mode; }

MODE=$(get_account_mode)
PROVIDER=$(get_api_provider)

STATUSLINE_COLS=$(get_cols)
```

- [ ] **Step 2: Replace the line-1 cascade**

Find and replace the entire cascade block (from the comment through `vis_truncate`):

```bash
# Progressive assembly — when line 1 overflows the budget, drop sections in
# order: model name → context bar → cost. Step to the next tier only when
# the previous is still too wide. Final vis_truncate is the safety net for
# anything the cascade couldn't shrink enough.
line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}"
if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
    line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}"
fi
if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
    line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}"
fi
if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
    line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${CTX_SEC}"
fi
vis_truncate "$line1" "$EFFECTIVE_COLS"
```

With:

```bash
# Progressive line-1 assembly.
# Plan mode (6 tiers): model name → Plan label → 5h/7d labels → bar → price.
# API mode (4 tiers): existing behaviour unchanged.
# vis_truncate is the final safety net in both modes.
if [[ "$MODE" == "plan" ]]; then
    CACHE_EXPIRY=$(format_cache_expiry "$TRANSCRIPT_PATH")
    PLAN_FULL=$(render_plan_right full "$CACHE_EXPIRY")
    PLAN_NO_LABEL=$(render_plan_right no_plan_label "$CACHE_EXPIRY")
    PLAN_NO_PERIODS=$(render_plan_right no_period_labels "$CACHE_EXPIRY")
    _PS="  "  # separator between left and right sides of line 1

    line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_FULL}"
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_FULL}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_NO_LABEL}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}${_PS}${PLAN_NO_PERIODS}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${_PS}${PLAN_NO_PERIODS}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${CTX_SEC}${_PS}${PLAN_NO_PERIODS}"
    fi
else
    line1="${MODEL_FULL}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}"
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}${BAR_SEC}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${COST_SEC}${CTX_SEC}"
    fi
    if (( $(vislen "$line1") > EFFECTIVE_COLS )); then
        line1="${MODEL_COMPACT}${PYENV_SEC}${DIRGIT_SEC}${CTX_SEC}"
    fi
fi
vis_truncate "$line1" "$EFFECTIVE_COLS"
```

- [ ] **Step 3: Replace the account line-2 block**

Find and replace:
```bash
# Account status — assemble into a buffer, then truncate before emitting so
# wide content (especially OpenRouter's external statusline) can't blow the
# terminal width and trigger Claude Code dropping subsequent lines.
MODE=$(get_account_mode)
PROVIDER=$(get_api_provider)

# Capture with trailing-newline guard (printf x; %x trick) so embedded
# trailing whitespace from external scripts isn't lost.
account_buf=$(render_account; printf x); account_buf=${account_buf%x}
echo
emit_truncated "$account_buf" "$EFFECTIVE_COLS"
```

With:
```bash
# API mode: emit account line 2 (Plan mode: plan status is already on line 1)
if [[ "$MODE" != "plan" ]]; then
    account_buf=$(render_account; printf x); account_buf=${account_buf%x}
    echo
    emit_truncated "$account_buf" "$EFFECTIVE_COLS"
fi
```

- [ ] **Step 4: Add timing log before `exit 0`**

Replace the final `exit 0` with:
```bash
_sl_end_ms=$(date +%s%3N 2>/dev/null || echo 0)
if (( _sl_start_ms > 0 && _sl_end_ms > 0 )); then
    printf '%s %dms\n' "$(date -Iseconds)" "$(( _sl_end_ms - _sl_start_ms ))" \
        >> /tmp/claude/statusline-timing.log
fi

exit 0
```

- [ ] **Step 5: Shellcheck**

```bash
shellcheck -x claude/statusline-command.sh
```

Expected: no output.

- [ ] **Step 6: Smoke test — Plan mode**

```bash
_now=$(date +%s)
echo "{
  \"model\":{\"display_name\":\"Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"/Users/david/code/home\"},
  \"transcript_path\":\"\",
  \"context_window\":{\"current_usage\":{\"input_tokens\":15000,\"output_tokens\":3000,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}},
  \"cost\":{\"total_cost_usd\":0.05,\"total_duration_ms\":4500,\"total_lines_added\":10,\"total_lines_removed\":2},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":78,\"resets_at\":$(( _now + 9000 ))},
    \"seven_day\":{\"used_percentage\":45,\"resets_at\":$(( _now + 302400 ))}
  }
}" | TMUX= bash claude/statusline-command.sh
```

Expected: exactly one line of output containing model, dir, cost, context, and plan rate-limit info (including `×` burn-rate values). Exit 0.

- [ ] **Step 7: Verify timing log**

```bash
tail -1 /tmp/claude/statusline-timing.log
```

Expected: a line like `2026-05-25T14:30:01+00:00 142ms`.

- [ ] **Step 8: Smoke test — API mode (no regression)**

```bash
echo '{
  "model":{"display_name":"Sonnet 4.6"},
  "workspace":{"current_dir":"/Users/david/code/home"},
  "transcript_path":"",
  "context_window":{"current_usage":{"input_tokens":15000,"output_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},
  "cost":{"total_cost_usd":0.05,"total_duration_ms":4500,"total_lines_added":10,"total_lines_removed":2},
  "rate_limits":{"five_hour":{"used_percentage":0,"resets_at":""},"seven_day":{"used_percentage":0,"resets_at":""}}
}' | MODE_FILE=/dev/null TMUX= bash claude/statusline-command.sh
```

Expected: two lines — line 1 with model/dir/cost/ctx (no plan section), line 2 with API/account info. Exit 0.

Note: `MODE_FILE=/dev/null` forces API mode detection to fall back; actual behaviour depends on local account config. The key check is that line 2 is present.

- [ ] **Step 9: Full test suite + precommit**

```bash
bash claude/test-statusline-helpers.sh && just precommit
```

Expected: `PASS  N tests` + `Precommit OK`.

- [ ] **Step 10: Commit**

```bash
git add claude/statusline-command.sh
git commit -m "feat(statusline): move plan status to line 1, add burn rate and cache expiry"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|-----------------|------|
| Plan status always on line 1 | Task 4 (cascade) |
| Line 2 sparkline-only (Plan mode) | Task 4 (remove account block) |
| Burn rate ×N.N after vertical bar | Tasks 1 + 3 |
| Burn rate red when > 1.2 | Task 3 |
| Cache expiry  HH:MM | Tasks 2 + 3 |
| 6-tier narrowing cascade | Task 4 |
| API mode line 2 unchanged | Task 4 (guarded by MODE check) |
| Timing log /tmp/claude/statusline-timing.log | Task 4 |

**Placeholder scan:** None. All code blocks are complete and executable.

**Type consistency:**
- `format_burn_rate` defined in Task 1, called in Task 3 (`render_plan_right`) ✓
- `format_cache_expiry` defined in Task 2, called in Task 4 (orchestrator) ✓
- `render_plan_right` defined in Task 3, called in Task 4 (orchestrator) ✓
- `CACHE_EXPIRY`, `PLAN_FULL`, `PLAN_NO_LABEL`, `PLAN_NO_PERIODS` all set and consumed in Task 4 ✓
- `_sl_start_ms` set at top of Task 4 step 1, read at bottom in step 4 ✓
