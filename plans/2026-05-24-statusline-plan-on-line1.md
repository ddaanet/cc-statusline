# Statusline: Plan Status on Line 1

**Goal:** Move plan rate-limit status from line 2 to the right side of line 1 (always visible). Add burn rate and cache expiry indicators. Add timing instrumentation. Line 2 becomes sparkline-only (self-suppressed when idle).

---

## Layout

**Busy (tool_use in progress):**
```
Line 1: ❷ Sonnet   home  main  $0.05  ⛁ 15k ▁    Plan 5h 78% ▮ ×1.5 15:59 / 7d 45% ▮ ×0.8 Mon   14:35
Line 2: [sparkline]
```

**Idle (end_turn — sparkline self-suppresses):**
```
Line 1: ❷ Sonnet   home  main  $0.05  ⛁ 15k ▁    Plan 5h 78% ▮ ×1.5 15:59 / 7d 45% ▮ ×0.8 Mon   14:35
```

Cache expiry symbol:  = `nf-fa-hourglass_half` U+F252 (single-width Nerd Font).

---

## Progressive Narrowing (line 1)

Six tiers before `vis_truncate`. Each tier tries to fit within `EFFECTIVE_COLS`; step down only when the previous tier is still too wide.

| Tier | Drop | Example right side |
|------|------|--------------------|
| 1 | — (full) | `Plan 5h 78% ▮ ×1.5 15:59 / 7d 45% ▮ ×0.8 Mon   14:35` |
| 2 | model name → ❷ only | ← same right |
| 3 | "Plan" label | `5h 78% ▮ ×1.5 15:59 / 7d 45% ▮ ×0.8 Mon   14:35` |
| 4 | "5h"/"7d" period labels | `78% ▮ ×1.5 15:59 / 45% ▮ ×0.8 Mon   14:35` |
| 5 | context bar | ← same, no bar |
| 6 | price | ← same, no price |
| 7 | `vis_truncate` safety net | — |

The cache expiry field (`  HH:MM`) is always kept within the plan section (not independently dropped). The plan section itself is never dropped entirely — the terminal must be very narrow before `vis_truncate` clips it.

---

## New Metrics

### Burn Rate

Displayed as `×1.5` between the vertical bar and the reset time.

**Calculation:**
```
window_start = resets_at_epoch - window_seconds   (18000 for 5h, 604800 for 7d)
elapsed      = now - window_start
elapsed_frac = elapsed / window_seconds
burn_rate    = used_pct / (elapsed_frac × 100)
```

- Skip (emit nothing) when `elapsed_frac < 0.05` (too early to be meaningful) or `used_pct == 0`
- Format: `×N.N` (one decimal place)
- Color: red when `burn_rate > 1.2` (heading for early limit)

**Function:** `format_burn_rate <used_pct> <resets_at_epoch> <window_secs>` → added to `format-utils.sh`

### Cache Expiry

Displayed as ` HH:MM` at the end of the plan section. Source: last assistant entry timestamp in transcript + 300 s (5-minute prompt cache TTL).

- Empty output if no transcript, no timestamp, or cache already expired
- HH:MM is local time

**Function:** `format_cache_expiry <transcript_path>` → added to `context-display.sh`

---

## Implementation: Files Changed

### `claude/lib/format-utils.sh`

Add `format_burn_rate`:

```bash
format_burn_rate() {
    local used_pct=$1 resets_at=$2 window_secs=$3
    [[ -z "$used_pct" || "$used_pct" == "0" || "$used_pct" == "null" ]] && return
    [[ -z "$resets_at" || "$resets_at" == "null" || "$resets_at" == "0" ]] && return
    local now; now=$(date +%s)
    local window_start=$(( resets_at - window_secs ))
    local elapsed=$(( now - window_start ))
    (( elapsed <= 0 )) && return
    local elapsed_pct=$(( elapsed * 100 / window_secs ))
    (( elapsed_pct < 5 )) && return
    local burn
    burn=$(bc -l <<< "scale=1; $used_pct / ($elapsed / $window_secs) / 100")
    printf '×%s' "$burn"
}
```

*(Exact arithmetic: use `bc -l` for float division, same pattern as existing `kilos`.)*

### `claude/lib/context-display.sh`

Add `format_cache_expiry`:

```bash
format_cache_expiry() {
    local transcript_path=$1
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return
    local last_ts
    last_ts=$(jq -r '
        select(.type == "assistant" and (.isSidechain // false | not)) |
        (.timestamp // "") |
        if . == "" then empty else . end
    ' "$transcript_path" 2>/dev/null | tail -1)
    [[ -z "$last_ts" ]] && return
    local last_epoch
    last_epoch=$(date -d "${last_ts}" +%s 2>/dev/null || \
                 date -j -f "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" +%s 2>/dev/null)
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

### `claude/lib/account-display.sh`

Replace `display_plan_usage` with three render variants. All three take the same rate-limit data (pre-computed by the orchestrator or re-read from `$input`) and the cache expiry string.

**Signature:** `render_plan_right <style> <cache_expiry>`
- `style`: `full` | `no_plan_label` | `no_period_labels`
- `cache_expiry`: pre-formatted `HH:MM` string (or empty); function prepends ` ` icon internally

Internally calls `format_burn_rate` for each window and `display_vertical_bar` / `display_plan_limit_percent` as before.

Remove `render_account` (or keep for API mode — see note below).

**API mode:** `render_account` currently handles both Plan and API modes. For this change, Plan mode moves to line 1; API mode display is out of scope and stays on line 2 unchanged. The orchestrator checks `MODE` before the cascade: if Plan mode, use the six-tier cascade with plan sections; if API mode, use the existing four-tier cascade (no plan section) and keep the line-2 `emit_truncated account_buf` block.

### `claude/statusline-command.sh`

Changes:
1. **Timing start** at top: `_sl_start_ms=$(date +%s%3N 2>/dev/null || echo 0)`
2. **Extract stop_reason** (not needed for display — sparkline handles it internally)
3. **Compute plan section variants** before cascade:
   ```bash
   CACHE_EXPIRY=$(format_cache_expiry "$TRANSCRIPT_PATH")
   PLAN_FULL=$(render_plan_right full "$CACHE_EXPIRY")
   PLAN_NO_LABEL=$(render_plan_right no_plan_label "$CACHE_EXPIRY")
   PLAN_NO_PERIODS=$(render_plan_right no_period_labels "$CACHE_EXPIRY")
   ```
4. **Six-tier cascade** for line 1 (see narrowing table above)
5. **Remove** `render_account` / `emit_truncated account_buf` / `echo` for line 2 account section — replaced by nothing for Plan mode (API mode: keep existing line 2)
6. **Keep** `display_turn_sparkline` call unchanged
7. **Timing end** at bottom:
   ```bash
   _sl_end_ms=$(date +%s%3N 2>/dev/null || echo 0)
   if (( _sl_start_ms > 0 && _sl_end_ms > 0 )); then
       echo "$(date -Iseconds) $(( _sl_end_ms - _sl_start_ms ))ms" \
           >> /tmp/claude/statusline-timing.log
   fi
   ```

---

## Out of Scope

- API mode plan section on line 1 (stays on line 2 as before)
- Cache expiry symbol color changes (always default fg)
- Dropping cache expiry as a separate narrowing tier
- Log rotation for timing log
