# Statusline Module Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Split `claude/statusline-command.sh` (~38 KB monolith) into focused `claude/lib/` modules, each under 4 ktok, and update the test to source the new module directly instead of awk-extracting function bodies.

**Architecture:** Five new library files (colors, format-utils, sparkline, context-display, account-display) sourced in dependency order by the orchestrator. Modules declare globals they use but don't own; source order is the caller's responsibility. No cross-module sourcing.

**Tech Stack:** bash, shellcheck, existing `just precommit` hook.

---

## File map

| File | Action | Responsibility |
|------|--------|---------------|
| `claude/lib/colors.sh` | **Create** | SGR constants only |
| `claude/lib/format-utils.sh` | **Create** | Pure text/number helpers (no color deps) |
| `claude/lib/sparkline.sh` | **Create** | `spark_char`, `display_turn_sparkline`, helpers |
| `claude/lib/context-display.sh` | **Create** | `get_token_color`, `display_token_bar`, `get_transcript_context` |
| `claude/lib/account-display.sh` | **Create** | `display_plan_*`, `display_api_usage`, `render_account` |
| `claude/lib/account-validation.sh` | **No change** | Already exists |
| `claude/statusline-command.sh` | **Modify** | Orchestrator only: parse JSON, source modules, assemble + emit |
| `claude/test-statusline-helpers.sh` | **Modify** | Source `format-utils.sh` directly; remove awk extraction |

Source order in orchestrator (each `|| exit 1`):
1. `colors.sh`
2. `format-utils.sh`
3. `sparkline.sh` (needs colors + format_age)
4. `context-display.sh` (needs colors + kilos)
5. `account-validation.sh` (already sourced via its own path)
6. `account-display.sh` (needs colors + format-utils + account-validation)

---

## Task 1: Verify green baseline

**Files:** (read-only)

- [x] **Step 1: Run existing tests**

```bash
bash claude/test-statusline-helpers.sh
```

Expected: `PASS  N tests` (all pass, exit 0).

- [x] **Step 2: Run shellcheck on the current monolith**

```bash
shellcheck -x claude/statusline-command.sh claude/lib/account-validation.sh
```

Note any warnings for comparison after the split — the split should not introduce new ones.

---

## Task 2: Create `claude/lib/colors.sh`

**Files:**
- Create: `claude/lib/colors.sh`

- [x] **Step 1: Write the file**

```bash
cat > claude/lib/colors.sh << 'EOF'
#!/usr/bin/env bash
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
RESET_FG=$'\033[39m'
RESET_BG=$'\033[49m'
RESET_BOLD=$'\033[22m'
RESET_BLINK=$'\033[25m'
INVERSE=$'\033[7m'
RESET_INVERSE=$'\033[27m'
RESET=$RESET_FG$RESET_BOLD$RESET_BLINK
EOF
```

- [x] **Step 2: Shellcheck**

```bash
shellcheck claude/lib/colors.sh
```

Expected: no output (clean).

- [x] **Step 3: Commit**

```bash
git add claude/lib/colors.sh
git commit -m "refactor(statusline): extract SGR constants to claude/lib/colors.sh"
```

---

## Task 3: Create `claude/lib/format-utils.sh` and update the test

**Files:**
- Create: `claude/lib/format-utils.sh`
- Modify: `claude/test-statusline-helpers.sh`

- [x] **Step 1: Write `claude/lib/format-utils.sh`**

Create the file with exactly this content (copy verbatim — all comments from the original are preserved):

```bash
#!/usr/bin/env bash
# Pure formatting utilities for the statusline.
# No color dependencies — source before modules that use colors.

# Terminal column width. Claude Code doesn't pass this via the JSON payload
# or an env var. The statusline subprocess has no controlling tty (stdin is
# the JSON pipe, stdout is captured by Claude Code, /dev/tty is unavailable),
# so `tput cols` falls back to the terminfo default (80) regardless of the
# real pane width — useless for shortening decisions in wider terminals.
# Inside tmux, ask the server: it knows the real pane geometry. Fall back
# through stty/tput/120 only when not in tmux.
get_cols() {
    local c=${COLUMNS:-0}
    if [[ -z "$c" || "$c" == "0" ]] && [[ -n "$TMUX" && -n "$TMUX_PANE" ]]; then
        c=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null)
    fi
    if [[ -z "$c" || "$c" == "0" ]]; then
        c=$(stty size 2>/dev/null < /dev/tty | awk '{print $2}')
    fi
    if [[ -z "$c" || "$c" == "0" ]]; then
        c=$(tput cols 2>/dev/null)
    fi
    # Conservative final fallback: 80 is the universal terminal default.
    # EFFECTIVE_COLS will become 77 after the chrome reservation.
    [[ -z "$c" || "$c" == "0" ]] && c=80
    echo "$c"
}

# Visible width of a rendered string: strip ANSI SGR, count UTF-8 chars.
# Uses tr -d of UTF-8 continuation bytes + wc -c so the count matches
# column width regardless of the shell's current locale.
vislen() {
    printf '%s' "$1" \
        | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g' \
        | LC_ALL=C tr -d '\200-\277' \
        | wc -c | tr -d ' '
}

# Truncate $1 to $2 visible columns, preserving CSI escape sequences (which
# take 0 cells). Visible cells are counted byte-wise: any byte that isn't a
# UTF-8 continuation byte (0x80-0xBF) is one cell. Wide East-Asian glyphs
# would be undercounted but our content is single-cell only (ASCII, nerd-font
# PUA, the few specific symbols we use). Trailing escapes after the last
# emitted glyph are kept so terminal state still resets cleanly. No fork.
vis_truncate() {
    local s=$1 max=$2
    local LC_ALL=C  # operate on bytes
    local out="" w=0 i=0 n=${#s}
    local c cc j b last_lead_emitted=1
    while (( i < n )); do
        c=${s:i:1}
        if [[ "$c" == $'\033' ]]; then
            # CSI: ESC [ params/intermediates final-byte (0x40-0x7E).
            j=$((i + 1))
            [[ "${s:j:1}" == "[" ]] && ((j++))
            while (( j < n )); do
                cc=${s:j:1}
                printf -v b '%d' "'$cc"
                (( b >= 0x40 && b <= 0x7E )) && break
                ((j++))
            done
            out+="${s:i:j-i+1}"
            i=$((j + 1))
        else
            printf -v b '%d' "'$c"
            if (( b >= 0x80 && b < 0xC0 )); then
                (( last_lead_emitted )) && out+="$c"
            else
                if (( w < max )); then
                    out+="$c"
                    ((w++))
                    last_lead_emitted=1
                else
                    last_lead_emitted=0
                fi
            fi
            ((i++))
        fi
    done
    printf '%s' "$out"
}

# Emit $1 with each newline-separated line truncated to $2 columns.
# Joins lines back with the same newlines; no trailing newline added.
emit_truncated() {
    local s=$1 max=$2 line first=1
    while IFS= read -r line; do
        (( first )) || echo
        first=0
        vis_truncate "$line" "$max"
    done <<< "$s"
}

kilos() {
    local width=${2:-3}  # Default to 3 chars
    if [ -z "$1" ] || [ "$1" = "unset" ]; then
        if [ "$width" -eq 4 ]; then
            echo -n " -  "
        else
            echo -n " - "
        fi
        return
    fi
    if [ "$1" = "0" ]; then
        printf "%${width}d" 0
        return
    fi
    if [ "$1" -lt 1000 ]; then
        printf "%${width}d" "$1"
        return
    fi
    local k_digits=$((width - 1))  # Reserve 1 char for 'k'
    printf "%${k_digits}.0fk" "$(bc -l <<< "$1 / 1000")"
}

# shellcheck disable=SC2317
format_duration() {
    local ms=$1
    if [ "$ms" = "unset" ] || [ "$ms" = "null" ]; then
        return 1
    fi
    local total_seconds=$((ms / 1000))
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    if [ "$hours" -gt 0 ]; then
        if [ "$minutes" -lt 10 ]; then
            printf "%6s" "${hours}h0${minutes}m"
        else
            printf "%6s" "${hours}h${minutes}m"
        fi
    elif [ "$minutes" -gt 0 ]; then
        printf "%6s" "${minutes}m${seconds}s"
    else
        printf "%6s" "${seconds}s"
    fi
}

# Format 5h reset time → HH:MM (local time)
format_5h_reset() {
    local epoch=$1
    [[ -z "$epoch" || "$epoch" == "null" || "$epoch" == "0" ]] && return
    if [[ "$(uname -s)" == "Darwin" ]]; then
        date -r "$epoch" +%H:%M
    else
        date -d "@$epoch" +%H:%M
    fi
}

# Format 7d reset time → 3-letter weekday if not today, HH:MM if today (local time)
format_7d_reset() {
    local epoch=$1
    [[ -z "$epoch" || "$epoch" == "null" || "$epoch" == "0" ]] && return
    local today reset_date
    today=$(date +%Y-%m-%d)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        reset_date=$(date -r "$epoch" +%Y-%m-%d)
        if [[ "$reset_date" == "$today" ]]; then
            date -r "$epoch" +%H:%M
        else
            date -r "$epoch" +%a
        fi
    else
        reset_date=$(date -d "@$epoch" +%Y-%m-%d)
        if [[ "$reset_date" == "$today" ]]; then
            date -d "@$epoch" +%H:%M
        else
            date -d "@$epoch" +%a
        fi
    fi
}

# Format a duration in seconds as compact relative age: 15s / 15m / 3h / 2d
format_age() {
    local s=$1
    if (( s < 60 )); then echo "${s}s"
    elif (( s < 3600 )); then echo "$((s / 60))m"
    elif (( s < 86400 )); then echo "$((s / 3600))h"
    else echo "$((s / 86400))d"
    fi
}
```

- [x] **Step 2: Shellcheck the new file**

```bash
shellcheck claude/lib/format-utils.sh
```

Expected: no output (clean). The `SC2317` on `format_duration` is pre-suppressed by the inline directive.

- [x] **Step 3: Update `claude/test-statusline-helpers.sh`**

Replace the awk-extraction block at the top (lines 3–35 of the current test) with a direct source. The new file header and setup should be:

```bash
#!/usr/bin/env bash
# Tests for the pure-bash statusline helpers (vis_truncate, vislen).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# shellcheck source=claude/lib/format-utils.sh
source "$HERE/lib/format-utils.sh" || { echo "FATAL: format-utils.sh not found"; exit 2; }

# Sanity: confirm source worked
type vis_truncate >/dev/null 2>&1 || { echo "FATAL: vis_truncate not loaded"; exit 2; }
type vislen      >/dev/null 2>&1 || { echo "FATAL: vislen not loaded"; exit 2; }
type emit_truncated >/dev/null 2>&1 || { echo "FATAL: emit_truncated not loaded"; exit 2; }
```

The rest of the test (the `PASS=0; FAIL=0` block, `assert` function, and all test cases) stays unchanged.

- [x] **Step 4: Run tests to confirm they still pass**

```bash
bash claude/test-statusline-helpers.sh
```

Expected: `PASS  N tests` (same count as Task 1 baseline).

- [x] **Step 5: Commit**

```bash
git add claude/lib/format-utils.sh claude/test-statusline-helpers.sh
git commit -m "refactor(statusline): extract format helpers to claude/lib/format-utils.sh"
```

---

## Task 4: Create `claude/lib/sparkline.sh`

**Files:**
- Create: `claude/lib/sparkline.sh`

Globals consumed (must be set before this module is sourced or before its functions are called): `RESET`, `RESET_BG`, `RESET_FG`, `INVERSE`, `RESET_INVERSE`, `BOLD`, `EFFECTIVE_COLS`.
Functions consumed from other modules: `format_age` (format-utils.sh).

- [x] **Step 1: Write `claude/lib/sparkline.sh`**

```bash
#!/usr/bin/env bash
# Per-turn sparkline rendering for the statusline.
# Deps (source before this file): colors.sh, format-utils.sh
# Globals consumed: RESET RESET_BG RESET_FG INVERSE RESET_INVERSE BOLD EFFECTIVE_COLS

# Current SGR state for sparkline rendering (module-level, reset per sparkline).
# Lets spark_char skip redundant bg/fg emissions when the cell state is
# already what the terminal is in.
_SPARK_BG=""
_SPARK_FG=""

# Render one sparkline char for a token value.
# $1=value, $2=kind ("in" or "out")
# Log/2× ranges; fg = current range, bg = previous range (if any).
# Out bounds: 1k 2k 4k 8k 16k. In bounds: 5× out.
spark_char() {
    local value=$1
    local kind=$2
    local -a bounds fg_colors bg_colors

    if [[ "$kind" == "in" ]]; then
        bounds=(5000 10000 20000 40000 80000)
        fg_colors=($'\033[36m' $'\033[34m' $'\033[94m' $'\033[35m' $'\033[95m')
        bg_colors=($'\033[46m' $'\033[44m' $'\033[104m' $'\033[45m' $'\033[105m')
    else
        bounds=(1000 2000 4000 8000 16000)
        fg_colors=($'\033[32m' $'\033[33m' $'\033[93m' $'\033[31m' $'\033[91m')
        bg_colors=($'\033[42m' $'\033[43m' $'\033[103m' $'\033[41m' $'\033[101m')
    fi

    # Saturated: above top range max → inverse video on range-5 fg color.
    # With inverse: bg = saturation color, fg = terminal default bg.
    # Theme-adaptive glyph: "◆" shows in terminal bg on a loud color cell.
    # Inverse swaps the attribute registers, so invalidate cached state.
    if [ "$value" -gt "${bounds[4]}" ]; then
        echo -n "${INVERSE}${fg_colors[4]}◆${RESET_INVERSE}"
        _SPARK_BG=""
        _SPARK_FG=""
        return
    fi

    # Locate range
    local range=0 prev_max=0 i
    for i in 0 1 2 3 4; do
        if [ "$value" -le "${bounds[$i]}" ]; then
            range=$i
            break
        fi
        prev_max=${bounds[$i]}
    done

    local range_max=${bounds[$range]}
    local range_size=$((range_max - prev_max))
    local fill=$((value - prev_max))
    local idx=$(( (fill * 8 + range_size / 2) / range_size ))
    [ $idx -lt 0 ] && idx=0
    [ $idx -gt 8 ] && idx=8

    local blocks=(' ' '▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')

    local new_bg
    if [ "$range" -eq 0 ]; then
        new_bg="${RESET_BG}"
    else
        new_bg="${bg_colors[$((range - 1))]}"
    fi
    if [[ "$new_bg" != "$_SPARK_BG" ]]; then
        echo -n "$new_bg"
        _SPARK_BG="$new_bg"
    fi

    local new_fg="${fg_colors[$range]}"
    if [[ "$new_fg" != "$_SPARK_FG" ]]; then
        echo -n "$new_fg"
        _SPARK_FG="$new_fg"
    fi

    echo -n "${blocks[$idx]}"
}

# Format a `<turn_dur>│<wait>` separator for the sparkline.
# turn_dur empty → emit only `<sep><wait>` (leading boundary, no preceding U).
# wait is already a formatted string (e.g. "5m" or "14:30").
# gap_s is the elapsed seconds the separator spans, used to pick `│` vs ` `
# (space when > cache_ttl; cache has expired).
_spark_sep() {
    local turn_dur=$1 wait_str=$2 gap_s=$3 cache_ttl=$4
    local sep_char="│"
    (( gap_s > cache_ttl )) && sep_char=" "
    local turn_dur_str=""
    [[ -n "$turn_dur" ]] && turn_dur_str="$(format_age "$turn_dur")"
    printf '%s' "${turn_dur_str}${sep_char}${wait_str}"
}

# Format an epoch as local-time HH:MM.
# shellcheck disable=SC2317
_spark_clock() {
    local epoch=$1
    if [[ "$(uname -s)" == "Darwin" ]]; then
        date -r "$epoch" +%H:%M
    else
        date -d "@$epoch" +%H:%M
    fi
}

# Reset sparkline bg/fg to defaults if not already there.
_spark_reset_colors() {
    if [[ "$_SPARK_BG" != "$RESET_BG" ]]; then
        echo -n "${RESET_BG}"
        _SPARK_BG="${RESET_BG}"
    fi
    if [[ "$_SPARK_FG" != "$RESET_FG" ]]; then
        echo -n "${RESET_FG}"
        _SPARK_FG="${RESET_FG}"
    fi
}

# Per-turn input/output sparkline from session transcript.
# Turn = one API call (dedup by requestId across multi-block assistant entries).
# in  = input_tokens + cache_creation_input_tokens (cache_read excluded)
# out = output_tokens
# Structure:
#   - `<turn_dur>│<user_wait>` between user turns
#   - ` ` (gap) replaces `│` when user_wait >1h (cache expired)
#   - trailing `<turn_dur>│<wait_so_far>` when idle (awaiting user input)
display_turn_sparkline() {
    local transcript_path=$1
    local max_turns=${2:-30}
    local cache_ttl=3600
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return

    # Stream of ordered events with epoch timestamps:
    #   U <epoch>                                   - genuine user prompt (not tool_result)
    #   A <requestId> <epoch> <in> <out> <stop>     - assistant API call
    # <stop> is .message.stop_reason ("end_turn", "tool_use", etc.). Used to
    # decide whether the session is truly idle — only end_turn means the AI
    # has finished; tool_use means another API call is coming after the
    # tool_result arrives.
    local stream
    stream=$(tail -n 1500 "$transcript_path" 2>/dev/null | jq -r '
        select((.isSidechain // false) | not) |
        ((.timestamp // "") | if . == "" then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdate? // 0) end) as $ts |
        if .type == "user" then
            ((.message.content // "") | if type == "array" then (.[0].type // "") else "" end) as $ct |
            if $ct == "tool_result" then empty else "U \($ts)" end
        elif .type == "assistant" and .message.usage != null then
            ((.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)) as $i |
            (.message.usage.output_tokens // 0) as $o |
            (.message.stop_reason // "-") as $stop |
            if $i == 0 and $o == 0 then empty
            else "A \(.requestId // "-") \($ts) \($i) \($o) \($stop)" end
        else empty end
    ' 2>/dev/null)

    [[ -z "$stream" ]] && return

    # Dedupe A by requestId (bash-3 compatible: linear scan of seen list)
    local -a items=()
    local seen_req="|"
    local line
    while IFS= read -r line; do
        if [[ "$line" == A\ * ]]; then
            local req="${line#A }"; req="${req%% *}"
            [[ "$seen_req" == *"|$req|"* ]] && continue
            seen_req+="$req|"
        fi
        items+=("$line")
    done <<< "$stream"

    # Count A entries; trim to last $max_turns A plus their surrounding Us
    local a_count=0 i
    for ((i=0; i<${#items[@]}; i++)); do
        [[ "${items[$i]}" == A\ * ]] && ((a_count++))
    done

    # Pre-pass over the FULL dedupe'd stream to track:
    #   - the last turn's anchor (for trailing duration-so-far)
    #   - per-A turn anchors (for re-injecting the trimmed first turn's U)
    #   - whether the session is idle awaiting user input
    # The display trim below can drop a turn's U when the turn has more API
    # calls than fit in max_turns, or when the first displayed turn is the
    # tail end of a longer turn. Either way we need the pre-trim anchor so
    # both the first displayed turn's duration and the trailing running
    # duration reflect the real turn start.
    local trail_last_u_epoch=""
    local trail_last_api_epoch=""
    local trail_last_stop=""
    local _staging_u=""
    local _current_turn_u=""
    local -a a_turn_anchors=()
    for line in "${items[@]}"; do
        if [[ "$line" == U\ * ]]; then
            local u="${line#U }"
            [[ -z "$u" || "$u" == "0" ]] && continue
            [[ -z "$_staging_u" ]] && _staging_u=$u
        else
            local _r _ts _i _o _stop
            read -r _ _r _ts _i _o _stop <<< "$line"
            if [[ -n "$_staging_u" ]]; then
                _current_turn_u=$_staging_u
                trail_last_u_epoch=$_staging_u
                _staging_u=""
            fi
            a_turn_anchors+=("$_current_turn_u")
            trail_last_api_epoch=$_ts
            trail_last_stop=$_stop
        fi
    done

    # Skip rendering when the session is idle: the most recent assistant
    # API call ended with end_turn. Pending Us (slash commands, local
    # command echoes, or a just-submitted prompt) don't flip this — a
    # slash command like /plugin writes user entries to the transcript
    # without triggering an A, and treating those as "AI about to
    # respond" left the sparkline visible during idle. A genuine new
    # prompt briefly lands here too, but the next render (at the first
    # tool_use) re-enables the sparkline.
    if (( ${#a_turn_anchors[@]} == 0 )); then
        return
    fi
    if [[ "$trail_last_stop" == "end_turn" ]]; then
        return
    fi

    if (( a_count > max_turns )); then
        local skip=$((a_count - max_turns))
        local first_keep_a_idx=$skip
        local first_keep=0
        for ((i=0; i<${#items[@]}; i++)); do
            if [[ "${items[$i]}" == A\ * ]]; then
                if (( skip == 0 )); then first_keep=$i; break; fi
                ((skip--))
            fi
        done
        items=("${items[@]:$first_keep}")
        # Re-inject the first kept A's turn anchor so the first displayed
        # turn's duration is computed from its real start, not from the
        # first kept A's own timestamp.
        local _first_anchor="${a_turn_anchors[$first_keep_a_idx]}"
        if [[ -n "$_first_anchor" ]]; then
            items=("U $_first_anchor" "${items[@]}")
        fi
    fi

    # Build phase: turn items[] into parallel arrays indexed by A occurrence.
    #   a_lines[k]       = full "A <req> <ts> <in> <out> <stop>" line
    #   a_pending_sep[k] = rendered separator to emit before A_k's cells
    #                      (empty for the first A in the stream, or when A_k
    #                      is a continuation of the previous A's turn — no
    #                      new U between them)
    #   a_sep_vis[k]     = visible column width of a_pending_sep[k]
    # First-wins U logic is identical to the previous render loop — a user
    # turn may begin with preliminary Us (slash commands, command caveats)
    # before the real prompt, and we keep the earliest as the turn trigger.
    local -a a_lines=()
    local -a a_pending_sep=()
    local -a a_sep_vis=()
    local _build_last_api="" _build_last_u="" _build_staging=""
    for line in "${items[@]}"; do
        if [[ "$line" == U\ * ]]; then
            local u_epoch="${line#U }"
            [[ -z "$u_epoch" || "$u_epoch" == "0" ]] && continue
            [[ -z "$_build_staging" ]] && _build_staging=$u_epoch
        else
            local _r _ts _i _o _stop
            read -r _ _r _ts _i _o _stop <<< "$line"
            local sep_str="" sep_w=0
            if [[ -n "$_build_staging" ]]; then
                if [[ -n "$_build_last_api" ]]; then
                    local wait_s=$((_build_staging - _build_last_api))
                    (( wait_s < 0 )) && wait_s=0
                    local turn_dur=""
                    if [[ -n "$_build_last_u" ]]; then
                        turn_dur=$((_build_last_api - _build_last_u))
                        (( turn_dur < 0 )) && turn_dur=0
                    fi
                    sep_str="$(_spark_sep "$turn_dur" "$(format_age $wait_s)" "$wait_s" "$cache_ttl")"
                    # sep is ASCII digits/letters + the single-column box-drawing
                    # `│` (U+2502). Under a UTF-8 locale ${#} counts chars, which
                    # equals column width for these glyphs.
                    sep_w=${#sep_str}
                fi
                _build_last_u=$_build_staging
                _build_staging=""
            fi
            a_lines+=("$line")
            a_pending_sep+=("$sep_str")
            a_sep_vis+=("$sep_w")
            _build_last_api=$_ts
        fi
    done

    local a_unit_count=${#a_lines[@]}
    (( a_unit_count == 0 )) && return

    # Trailing duration-so-far. We've already returned early for the idle
    # (end_turn) case, so this is always `<dur_so_far>` = now − turn anchor.
    local now_epoch; now_epoch=$(date +%s)
    local trail_ref=${trail_last_u_epoch:-$trail_last_api_epoch}
    local trail_dur=$((now_epoch - trail_ref))
    (( trail_dur < 0 )) && trail_dur=0
    local trailing_str; trailing_str="$(format_age "$trail_dur")"
    local trailing_vis=${#trailing_str}

    # Width-based truncation: drop oldest A units from the left until the
    # line fits. The first displayed A's pending_sep is suppressed (it
    # describes a transition from a dropped turn), so its width doesn't
    # count against the budget.
    #   width(keep_from=k) = trailing + 2·(n − k) + Σ sep_vis[k+1 … n−1]
    # Iterate k downward from n−1: each step adds A_k's 2 cells plus A_{k+1}'s
    # separator (which was suppressed before, now becomes visible because
    # A_k has claimed the first-displayed slot).
    local cols=${EFFECTIVE_COLS:-77}
    local keep_from=$a_unit_count
    local used=$trailing_vis
    local k
    for ((k=a_unit_count-1; k>=0; k--)); do
        local add=2
        if (( k + 1 < a_unit_count )); then
            add=$((add + a_sep_vis[k+1]))
        fi
        if (( used + add > cols )); then
            break
        fi
        used=$((used + add))
        keep_from=$k
    done

    # Emit. Leading newline lives here (not in the caller) so skip-paths
    # above don't leave a blank line behind. Turn dim OFF for the whole
    # sparkline — ranges 2-4 and the saturated cell use bright SGR codes
    # (90-97 / 100-107) which force those cells un-dim regardless; mixing
    # dim + bright cells looks inconsistent.
    echo
    echo -n "${RESET}"
    _SPARK_BG=""
    _SPARK_FG=""

    for ((k=keep_from; k<a_unit_count; k++)); do
        if (( k > keep_from )) && [[ -n "${a_pending_sep[$k]}" ]]; then
            _spark_reset_colors
            echo -n "${a_pending_sep[$k]}"
        fi
        local _r _ts _i _o _stop
        read -r _ _r _ts _i _o _stop <<< "${a_lines[$k]}"
        spark_char "$_i" in
        spark_char "$_o" out
    done

    _spark_reset_colors
    echo -n "$trailing_str"
    echo -n "${RESET_BG}${RESET_FG}"
}
```

- [x] **Step 2: Shellcheck**

```bash
shellcheck -x claude/lib/sparkline.sh
```

Expected: no output (clean). The `SC2317` on `_spark_clock` is suppressed inline.

- [x] **Step 3: Commit**

```bash
git add claude/lib/sparkline.sh
git commit -m "refactor(statusline): extract sparkline to claude/lib/sparkline.sh"
```

---

## Task 5: Create `claude/lib/context-display.sh`

**Files:**
- Create: `claude/lib/context-display.sh`

Globals consumed: `BLUE`, `GREEN`, `YELLOW`, `RED`, `MAGENTA`, `RESET`.

- [x] **Step 1: Write `claude/lib/context-display.sh`**

```bash
#!/usr/bin/env bash
# Token and context-usage display functions for the statusline.
# Deps (source before this file): colors.sh, format-utils.sh
# Globals consumed: BLUE GREEN YELLOW RED MAGENTA RESET

# Get color for token count
# Color sequence (50k blocks): blue green yellow red magenta
get_token_color() {
    local tokens=$1
    # Handle empty, unset, or non-numeric values
    if [ -z "$tokens" ] || [ "$tokens" = "unset" ] || ! [[ "$tokens" =~ ^[0-9]+$ ]]; then
        return
    elif [ "$tokens" -lt 50000 ]; then
        echo -n "$BLUE"
    elif [ "$tokens" -lt 100000 ]; then
        echo -n "$GREEN"
    elif [ "$tokens" -lt 150000 ]; then
        echo -n "$YELLOW"
    elif [ "$tokens" -lt 200000 ]; then
        echo -n "$RED"
    else
        echo -n "$MAGENTA"
    fi
}

# Display vertical-growth token bar
# One char per 50k range, height shows fill within range (▁▂▃▄▅▆▇█)
# Colors: blue green yellow red magenta
display_token_bar() {
    local total=$1
    # Handle empty, unset, non-numeric, or zero values
    if [ -z "$total" ] || [ "$total" = "unset" ] || ! [[ "$total" =~ ^[0-9]+$ ]] || [ "$total" -eq 0 ]; then
        return
    fi

    local colors=("$BLUE" "$GREEN" "$YELLOW" "$RED" "$MAGENTA")
    local range_size=50000
    local num_ranges=${#colors[@]}
    local remaining=$total

    for ((i=0; i<num_ranges; i++)); do
        if [ "$remaining" -le 0 ]; then
            break
        elif [ "$remaining" -ge "$range_size" ]; then
            echo -n "${colors[$i]}█"
            remaining=$((remaining - range_size))
        else
            # Partial range — map to vertical block height
            local idx=$(((remaining * 8 + range_size / 2) / range_size))
            [[ $idx -lt 1 ]] && idx=1
            [[ $idx -gt 7 ]] && idx=7
            local color="${colors[$i]}"
            case $idx in
                1) echo -n "${color}▁" ;;
                2) echo -n "${color}▂" ;;
                3) echo -n "${color}▃" ;;
                4) echo -n "${color}▄" ;;
                5) echo -n "${color}▅" ;;
                6) echo -n "${color}▆" ;;
                7) echo -n "${color}▇" ;;
            esac
            remaining=0
        fi
    done

    echo -n "$RESET"
}

# Get context usage from transcript file
get_transcript_context() {
    local transcript_path=$1
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return

    # Find the most recent assistant message (not sidechain) with non-zero usage
    local transcript_tokens
    transcript_tokens=$(jq -c '
        select(.type == "assistant" and (.isSidechain | not)) |
        .message.usage |
        (.input_tokens // 0) +
        (.cache_creation_input_tokens // 0) +
        (.cache_read_input_tokens // 0) +
        (.output_tokens // 0)
    ' "$transcript_path" 2>/dev/null | grep -v '^0$' | tail -1)

    [[ -n "$transcript_tokens" && "$transcript_tokens" != "null" ]] && echo "$transcript_tokens"
}
```

- [x] **Step 2: Shellcheck**

```bash
shellcheck -x claude/lib/context-display.sh
```

Expected: no output (clean).

- [x] **Step 3: Commit**

```bash
git add claude/lib/context-display.sh
git commit -m "refactor(statusline): extract token display to claude/lib/context-display.sh"
```

---

## Task 6: Create `claude/lib/account-display.sh`

**Files:**
- Create: `claude/lib/account-display.sh`

Globals consumed: color constants (`GREEN`, `YELLOW`, `RED`, `MAGENTA`, `BOLD`, `RESET`), `$input` (raw statusbar JSON set by the orchestrator), `$MODE`, `$PROVIDER` (set by orchestrator).
Functions consumed: `kilos`, `format_5h_reset`, `format_7d_reset` (format-utils.sh); `validate_state`, `get_api_provider` (account-validation.sh).

- [x] **Step 1: Write `claude/lib/account-display.sh`**

```bash
#!/usr/bin/env bash
# Account display functions for the statusline.
# Deps (source before this file): colors.sh, format-utils.sh, account-validation.sh
# Globals consumed: GREEN YELLOW RED MAGENTA BOLD RESET
# Globals consumed (set by orchestrator): $input $MODE $PROVIDER

# Display plan limit utilization percentage
display_plan_limit_percent() {
    local utilization=$1
    local util_int; util_int=$(printf "%.0f" "$utilization")
    echo -n "${RESET}"
    if (( $(echo "$utilization < 80" | bc) )); then
        :
    elif (( $(echo "$utilization < 90" | bc) )); then
        echo -n "$YELLOW"
    else
        echo -n "$RED"
    fi
    printf "%2d%%" "$util_int"
}

# Display vertical progress bar
display_vertical_bar() {
    local utilization=$1

    # Determine color
    local color
    if (( $(echo "$utilization < 80" | bc) )); then
        color="$GREEN"
    elif (( $(echo "$utilization < 90" | bc) )); then
        color="$YELLOW"
    else
        color="$RED"
    fi

    # Map 0-100% to 8 vertical blocks with rounding: ▁ ▂ ▃ ▄ ▅ ▆ ▇ █
    local util_int; util_int=$(printf "%.0f" "$utilization")
    local idx=$(( (util_int * 8 + 50) / 100 ))
    [[ $idx -gt 8 ]] && idx=8

    case $idx in
        0) echo -n "${color} ${RESET}" ;;  # Empty space for 0%
        1) echo -n "${color}▁${RESET}" ;;
        2) echo -n "${color}▂${RESET}" ;;
        3) echo -n "${color}▃${RESET}" ;;
        4) echo -n "${color}▄${RESET}" ;;
        5) echo -n "${color}▅${RESET}" ;;
        6) echo -n "${color}▆${RESET}" ;;
        7) echo -n "${color}▇${RESET}" ;;
        8) echo -n "${color}█${RESET}" ;;
    esac
}

display_plan_usage() {
    local five_hour_util; five_hour_util=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' 2>/dev/null)
    local seven_day_util; seven_day_util=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0' 2>/dev/null)
    local five_hour_reset; five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // ""' 2>/dev/null)
    local seven_day_reset; seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // ""' 2>/dev/null)

    local five_hour_at_limit=false
    local seven_day_at_limit=false
    (( $(echo "$five_hour_util >= 100" | bc) )) && five_hour_at_limit=true
    (( $(echo "$seven_day_util >= 100" | bc) )) && seven_day_at_limit=true

    echo -n "${RESET}"
    if (( $(echo "${five_hour_util} != 0" | bc) )); then
        [[ "$five_hour_at_limit" == true ]] && echo -n "${BOLD}${RED}"

        echo -n "5h "
        display_plan_limit_percent "$five_hour_util"
        echo -n ' '
        display_vertical_bar "$five_hour_util"

        local reset_time; reset_time=$(format_5h_reset "$five_hour_reset")
        [[ -n "$reset_time" ]] && echo -n " $reset_time"

        [[ "$five_hour_at_limit" == true ]] && echo -n "${RESET}"
    fi

    if (( $(echo "${seven_day_util} != 0 && ${five_hour_util} != 0" | bc) )); then
        echo -n " / "
    fi

    if (( $(echo "${seven_day_util} != 0" | bc) )); then
        [[ "$seven_day_at_limit" == true ]] && echo -n "${BOLD}${RED}"

        echo -n "7d "
        display_plan_limit_percent "$seven_day_util"
        echo -n ' '
        display_vertical_bar "$seven_day_util"

        local reset_time; reset_time=$(format_7d_reset "$seven_day_reset")
        [[ -n "$reset_time" ]] && echo -n " $reset_time"

        [[ "$seven_day_at_limit" == true ]] && echo -n "${RESET}"
    fi
}

display_api_usage() {
    local stats_file=~/.claude/stats-cache.json
    [[ ! -f "$stats_file" ]] && return

    # Get today's date
    local today; today=$(date +%Y-%m-%d)

    # Get today's tokens by model class
    local today_stats
    today_stats=$(jq -r --arg date "$today" '
        (.dailyModelTokens[] | select(.date == $date) | .tokensByModel) // {} |
        {
            opus: (to_entries | map(select(.key | contains("opus"))) | map(.value) | add // 0),
            sonnet: (to_entries | map(select(.key | contains("sonnet"))) | map(.value) | add // 0),
            haiku: (to_entries | map(select(.key | contains("haiku"))) | map(.value) | add // 0)
        }
    ' "$stats_file" 2>/dev/null)

    # Get last 7 days tokens by model class
    local week_stats
    week_stats=$(jq -r '
        .dailyModelTokens[-7:] | map(.tokensByModel) | add |
        {
            opus: (to_entries | map(select(.key | contains("opus"))) | map(.value) | add // 0),
            sonnet: (to_entries | map(select(.key | contains("sonnet"))) | map(.value) | add // 0),
            haiku: (to_entries | map(select(.key | contains("haiku"))) | map(.value) | add // 0)
        }
    ' "$stats_file" 2>/dev/null)

    # Extract today values
    local today_opus; today_opus=$(echo "$today_stats" | jq -r '.opus // 0')
    local today_sonnet; today_sonnet=$(echo "$today_stats" | jq -r '.sonnet // 0')
    local today_haiku; today_haiku=$(echo "$today_stats" | jq -r '.haiku // 0')

    # Extract week values
    local week_opus; week_opus=$(echo "$week_stats" | jq -r '.opus // 0')
    local week_sonnet; week_sonnet=$(echo "$week_stats" | jq -r '.sonnet // 0')
    local week_haiku; week_haiku=$(echo "$week_stats" | jq -r '.haiku // 0')

    # Display today (always show, even if zero)
    local any_today=false
    if [[ "$today_opus" != "0" ]]; then
        echo -n "${RESET}${MAGENTA}$(kilos "$today_opus")${RESET}"
        any_today=true
    fi
    if [[ "$today_sonnet" != "0" ]]; then
        [[ "$any_today" == true ]] && echo -n "${RESET}/"
        echo -n "${RESET}${YELLOW}$(kilos "$today_sonnet")${RESET}"
        any_today=true
    fi
    if [[ "$today_haiku" != "0" ]]; then
        [[ "$any_today" == true ]] && echo -n "${RESET}/"
        echo -n "${RESET}${GREEN}$(kilos "$today_haiku")${RESET}"
        any_today=true
    fi
    [[ "$any_today" == true ]] && echo -n " today"

    # Display week
    local any_week=false
    if [[ "$week_opus" != "0" || "$week_sonnet" != "0" || "$week_haiku" != "0" ]]; then
        [[ "$any_today" == true ]] && echo -n "  "
        if [[ "$week_opus" != "0" ]]; then
            echo -n "${RESET}${MAGENTA}$(kilos "$week_opus")${RESET}"
            any_week=true
        fi
        if [[ "$week_sonnet" != "0" ]]; then
            [[ "$any_week" == true ]] && echo -n "${RESET}/"
            echo -n "${RESET}${YELLOW}$(kilos "$week_sonnet")${RESET}"
            any_week=true
        fi
        if [[ "$week_haiku" != "0" ]]; then
            [[ "$any_week" == true ]] && echo -n "${RESET}/"
            echo -n "${RESET}${GREEN}$(kilos "$week_haiku")${RESET}"
            any_week=true
        fi
        echo -n " 7d"
    fi
}

# Account status — assemble into a buffer, then truncate before emitting so
# wide content (especially OpenRouter's external statusline) can't blow the
# terminal width and trigger Claude Code dropping subsequent lines.
render_account() {
    if validate_state; then
        if [[ "$MODE" == "plan" ]]; then
            echo -n "${GREEN}Plan  "
            display_plan_usage
        else
            # API mode
            echo -n "${YELLOW}API${RESET}  "

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
        fi
    else
        echo -n "${RED}Auth state inconsistent - run 'claude-account status'${RESET}"
    fi
}
```

- [x] **Step 2: Shellcheck**

```bash
shellcheck -x claude/lib/account-display.sh
```

Expected: no output (clean).

- [x] **Step 3: Commit**

```bash
git add claude/lib/account-display.sh
git commit -m "refactor(statusline): extract account display to claude/lib/account-display.sh"
```

---

## Task 7: Rewrite the orchestrator

**Files:**
- Modify: `claude/statusline-command.sh`

The orchestrator keeps: the header block comment, stdin read + debug write, `getval` + all `getval` calls, the source calls (old account-validation source replaces with new ordered sources), `STATUSLINE_COLS`/`EFFECTIVE_COLS` setup, the `get_account_mode` wrapper, and all top-level display assembly code (MODEL/DIR/GIT/COST/CTX/line1/account/sparkline). Everything else (function definitions) is removed.

- [x] **Step 1: Replace `claude/statusline-command.sh` with the orchestrator-only version**

Write the new file with this exact content:

```bash
#!/usr/bin/env bash
# Claude Code statusline - displays model, directory, git, python env, and usage info
#
# DESIGN DECISIONS - Second Line Format:
#
# Token Organization:
#   📊 Session section: Shows cumulative totals (total_input_tokens / total_output_tokens)
#     - Format: input/output
#     - Color: GREEN for input, YELLOW for output
#
#   💬 Turn section: Shows current API call breakdown
#     - Format: cached/input/output
#     - cache_read_input_tokens: Retrieved from storage (90% cheaper, CYAN)
#     - input_tokens: Fresh input (GREEN)
#     - output_tokens: Assistant response (YELLOW)
#
#   ⏱️ Duration: total_duration_ms formatted adaptively (wall clock time)
#     - <1min: "23s   " (6 chars padded)
#     - <1hr:  "1m23s " (6 chars padded)
#     - ≥1hr:  "1h23m " (6 chars padded)
#
#   ✏️ Diff: Lines added/removed from total_lines_added/total_lines_removed
#     - Format: +123-45 (no space, color distinguishes)
#
# Why cache_creation_input_tokens is NOT shown:
#   - One-time cost for writing to cache, not part of context window
#   - Less actionable than cache reads for understanding context usage
#
# Why API duration is NOT shown:
#   - Users care about wall clock time (total_duration_ms)
#   - API-specific time is less useful for session tracking
#
# Color Coding (16-color ANSI, theme-neutral):
#   - GREEN: Input/inbound data (↓), additions (+), Sonnet model
#   - YELLOW: Output/outbound data (↑), Opus model (gold)
#   - CYAN: Cached data (→), timing/temporal, low context usage
#   - RED: Deletions/removals (-), Haiku model (capability warning)
#
# Symbols (nerdfont + unicode, dim-compatible):
#   - : Directory (nf-custom-folder_open)
#   - : Git branch (nf-dev-git_branch)
#   - : Python env (nf-dev-python)
#   - ⛁: Context window (matches /context command)
#   - ❶❷❸: Model tier (Opus/Sonnet/Haiku)
#   - ✔/✘: Git clean/dirty
#   - $: Cost (bold, no emoji)
#
# Layout Stability:
#   - Token counts: 4 chars (kilos() function handles padding)
#   - Duration: 6 chars left-padded
#   - Line stats: 4 digits right-aligned
#   - Sections hidden if data unavailable (conditional display)

# Read JSON input from stdin
input=$(cat)

# IMPORTANT: statusbar.json is for debugging ONLY
# - NOT a cache (not invalidated on session switch)
# - Do NOT use for token calculations
# - Always parse transcript for accurate, session-specific data
mkdir -p /tmp/claude
echo "$input" > /tmp/claude/statusbar.json

# Extract values using jq
getval () {
    local var query value
    var="$1"; query="$2"
    value=$(echo "$input" | jq -r "$query")
    eval "$var=\"$value\""
}

getval MODEL '.model.display_name // "Unknown"'
getval CURRENT_DIR '.workspace.current_dir // ""'
getval TRANSCRIPT_PATH '.transcript_path // ""'
getval TOTAL_IN '.context_window.total_input_tokens // "unset"'
getval TOTAL_OUT '.context_window.total_output_tokens // "unset"'
getval CONTEXT_SIZE '.context_window.context_window_size // "unset"'
# Primary context usage: sum current_usage fields from statusbar JSON
CONTEXT_TOKENS=$(echo "$input" | jq -r '
    .context_window.current_usage //null |
    if . == null then "unset"
    else ((.input_tokens // 0) + (.output_tokens // 0) +
          (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) | tostring
    end
')

getval COST '.cost.total_cost_usd // "unset"'
getval DURATION '.cost.total_duration_ms // "unset"'
getval LINES_ADDED '.cost.total_lines_added // "unset"'
getval LINES_REMOVED '.cost.total_lines_removed // "unset"'

# Source modules in dependency order
# shellcheck source=claude/lib/colors.sh
source "$HOME/code/home/claude/lib/colors.sh" || exit 1
# shellcheck source=claude/lib/format-utils.sh
source "$HOME/code/home/claude/lib/format-utils.sh" || exit 1
# shellcheck source=claude/lib/sparkline.sh
source "$HOME/code/home/claude/lib/sparkline.sh" || exit 1
# shellcheck source=claude/lib/context-display.sh
source "$HOME/code/home/claude/lib/context-display.sh" || exit 1
# shellcheck source=claude/lib/account-validation.sh
source "$HOME/code/home/claude/lib/account-validation.sh" || exit 1
# shellcheck source=claude/lib/account-display.sh
source "$HOME/code/home/claude/lib/account-display.sh" || exit 1

STATUSLINE_COLS=$(get_cols)
# Claude Code reserves ~3 columns of TUI chrome around the statusline.
# Anything we emit beyond `cols-3` triggers terminal wrap, and Claude Code
# then drops subsequent statusline rows. Budget all emission to this width.
EFFECTIVE_COLS=$((STATUSLINE_COLS > 3 ? STATUSLINE_COLS - 3 : STATUSLINE_COLS))

# Wrapper for statusline (historically uses get_account_mode)
get_account_mode() { get_mode; }

# ===============================================
# DISPLAY LOGIC BEGINS
# ===============================================

# Display model name with thinking indicator
# Negative circled digits: ❶=Opus, ❷=Sonnet, ❸=Haiku
# Colors: green=Sonnet (default/safe), yellow/gold=Opus (premium), red=Haiku (capability warning)
MODEL_INDICATOR=""
MODEL_COLOR=""
MODEL_TEXT=""
# shellcheck disable=SC2153
case "$MODEL" in
    "Haiku "*)
        MODEL_INDICATOR="${RED}❸"
        MODEL_COLOR="${RED}"
        MODEL_TEXT="Haiku" ;;
    "Sonnet "*)
        MODEL_INDICATOR="${GREEN}❷"
        MODEL_COLOR="${GREEN}"
        MODEL_TEXT="Sonnet" ;;
    "Opus "*)
        MODEL_INDICATOR="${YELLOW}❶"
        MODEL_COLOR="${YELLOW}"
        MODEL_TEXT="Opus" ;;
    *)
        MODEL_INDICATOR=""
        MODEL_COLOR="$RED"
        MODEL_TEXT="$MODEL" ;;
esac

# Two model presentations — full shows indicator + name; compact is indicator
# only. Unknown models have no indicator, so compact falls back to full.
MODEL_FULL="${MODEL_INDICATOR} ${MODEL_COLOR}${MODEL_TEXT}  "
if [[ -n "$MODEL_INDICATOR" ]]; then
    MODEL_COMPACT="${MODEL_INDICATOR}  "
else
    MODEL_COMPACT="$MODEL_FULL"
fi

# Format directory (show basename)
DIR_DISPLAY="${CURRENT_DIR##*/}"
if [ -z "$DIR_DISPLAY" ]; then
    DIR_DISPLAY="${CURRENT_DIR}"
fi

# Get git branch if in a git repo
BRANCH=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    if [ -z "$BRANCH" ]; then
        BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi
fi

# Python environment indicator (symbol only, no basename)
ICON_PYTHON=$''
PYENV_SEC=""
if [ -n "$VIRTUAL_ENV" ] || [ -n "$CONDA_DEFAULT_ENV" ]; then
    PYENV_SEC="${RESET}${GREEN}${ICON_PYTHON}${RESET} "
fi

# Display dir and git status (nerdfont symbols)
ICON_DIR=$''
ICON_GIT=$''
DIRGIT_SEC=""
if [ -n "$BRANCH" ]; then
    GIT_STATUS=$(git status --porcelain 2>/dev/null)
    if [ "$DIR_DISPLAY" = "$BRANCH" ]; then
        if [ -n "$GIT_STATUS" ]; then
            DIRGIT_SEC="${RESET}${CYAN}${ICON_DIR} ${YELLOW}${ICON_GIT}${BOLD} $BRANCH  "
        else
            DIRGIT_SEC="${RESET}${CYAN}${ICON_DIR} ${GREEN}${ICON_GIT} $BRANCH  "
        fi
    else
        DIRGIT_SEC="${RESET}${CYAN}${ICON_DIR} $DIR_DISPLAY  "
        if [ -n "$GIT_STATUS" ]; then
            DIRGIT_SEC+="${RESET}${YELLOW}${ICON_GIT}${BOLD} $BRANCH  "
        else
            DIRGIT_SEC+="${RESET}${GREEN}${ICON_GIT} $BRANCH  "
        fi
    fi
else
    DIRGIT_SEC="${RESET}${CYAN}${ICON_DIR} $DIR_DISPLAY  "
fi

# Cost section
if [ "$COST" = "unset" ]; then
    COST_SEC="${RESET}${BOLD}\$${RESET} -     "
else
    COST_SEC="${RESET}${BOLD}\$${RESET}$(printf "%2.2f" "$COST")  "
fi

# Context usage: prefer current_usage from statusbar, fallback to transcript
if [[ "$CONTEXT_TOKENS" == "unset" || "$CONTEXT_TOKENS" == "0" ]]; then
    CONTEXT_TOKENS=$(get_transcript_context "$TRANSCRIPT_PATH")
fi

context_color=$(get_token_color "$CONTEXT_TOKENS")
ICON_CONTEXT=$''
CTX_SEC="${RESET}${context_color}${ICON_CONTEXT} $(kilos "$CONTEXT_TOKENS" 3)${RESET} "
BAR_SEC="$(display_token_bar "$CONTEXT_TOKENS")"

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

MODE=$(get_account_mode)
PROVIDER=$(get_api_provider)

# Capture with trailing-newline guard (printf x; %x trick) so embedded
# trailing whitespace from external scripts isn't lost.
account_buf=$(render_account; printf x); account_buf=${account_buf%x}
echo
emit_truncated "$account_buf" "$EFFECTIVE_COLS"

# Per-turn in|out sparkline on its own line. Width-aware by construction
# (walks backward from the latest turn, stops at EFFECTIVE_COLS), and emits
# its own leading newline only when there's content to show.
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    display_turn_sparkline "$TRANSCRIPT_PATH"
fi

# Ensure script exits successfully
exit 0
```

- [x] **Step 2: Shellcheck the updated orchestrator**

```bash
shellcheck -x claude/statusline-command.sh
```

Expected: no output (clean).

- [x] **Step 3: Run tests**

```bash
bash claude/test-statusline-helpers.sh
```

Expected: same pass count as Task 1 baseline.

- [x] **Step 4: Smoke-test the full script with a synthetic JSON payload**

```bash
echo '{"model":{"display_name":"Sonnet 4"},"workspace":{"current_dir":"/tmp"},"transcript_path":"","context_window":{"current_usage":{"input_tokens":12000,"output_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"cost":{"total_cost_usd":0.05,"total_duration_ms":4500,"total_lines_added":10,"total_lines_removed":2},"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":""},"seven_day":{"used_percentage":0,"resets_at":""}}}' \
    | bash claude/statusline-command.sh
```

Expected: two lines of output (line 1 with model/dir/cost/context, line 2 with account info), exit 0. No errors to stderr.

- [x] **Step 5: Commit**

```bash
git add claude/statusline-command.sh
git commit -m "refactor(statusline): reduce orchestrator to assembly-only; source lib modules"
```

---

## Task 8: Final shellcheck across all files + cleanup

**Files:** (read-only verification)

- [x] **Step 1: Shellcheck all statusline files together**

```bash
shellcheck -x \
    claude/statusline-command.sh \
    claude/lib/colors.sh \
    claude/lib/format-utils.sh \
    claude/lib/sparkline.sh \
    claude/lib/context-display.sh \
    claude/lib/account-validation.sh \
    claude/lib/account-display.sh \
    claude/test-statusline-helpers.sh
```

Expected: no output (zero warnings).

- [x] **Step 2: Run tests one final time**

```bash
bash claude/test-statusline-helpers.sh
```

Expected: `PASS  N tests`.

- [x] **Step 3: Check file sizes are all under 4 ktok**

```bash
wc -l claude/lib/*.sh claude/statusline-command.sh
```

Expected: each file well under ~160 lines (proxy for 4 ktok). The orchestrator should be around 130 lines; the largest module (sparkline.sh) around 230 lines.

- [x] **Step 4: Run precommit**

```bash
just precommit
```

Note: if the claudeutils venv is still broken, shellcheck + bash tests will pass but the Python-based checks will report failure. That's a pre-existing issue unrelated to this change.

---

## Self-review

**Spec coverage:**

| Spec requirement | Task |
|-----------------|------|
| `colors.sh` — SGR constants | Task 2 |
| `format-utils.sh` — `vislen`, `vis_truncate`, `emit_truncated`, `get_cols`, `kilos`, `format_duration`, `format_age`, `format_5h_reset`, `format_7d_reset` | Task 3 |
| `sparkline.sh` — `_SPARK_*`, `spark_char`, `_spark_*`, `display_turn_sparkline` | Task 4 |
| `context-display.sh` — `get_token_color`, `display_token_bar`, `get_transcript_context` | Task 5 |
| `account-display.sh` — `display_plan_limit_percent`, `display_vertical_bar`, `display_plan_usage`, `display_api_usage`, `render_account` | Task 6 |
| Orchestrator: parse JSON, source modules, assemble + emit | Task 7 |
| Test: source `format-utils.sh` directly | Task 3 |
| Each file under 4 ktok | Task 8 verification |

**Placeholder scan:** None found. All code blocks contain complete, verbatim content.

**Type consistency:** All function names are consistent throughout. `get_account_mode` wrapper retained in orchestrator calls `get_mode` from account-validation.sh (unchanged).
