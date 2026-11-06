#!/usr/bin/env bash
# Per-turn sparkline rendering for the statusline.
# Deps (source before this file): colors.sh, format-utils.sh
# Globals consumed: RESET RESET_BG RESET_FG INVERSE RESET_INVERSE BOLD EFFECTIVE_COLS
# _TX_MAX_LINES

# Current SGR state for sparkline rendering (module-level, reset per sparkline).
# Lets spark_char skip redundant bg/fg emissions.
_SPARK_BG=""
_SPARK_FG=""

# Render one sparkline char for a token value.
# $1=value, $2=kind ("cache", "in", or "out") — retained for caller clarity but
#   no longer styled differently; all cells share one palette. Kind is conveyed
#   by position within a turn (cache · in · out); turns are split by a separator.
# Values are cost-normalised before calling: cache=cache_read/10,
# in=input_tokens+cache_creation×2, out=output_tokens×5. All three therefore share
# the same bounds (1k/5k/25k/125k, uniform ×5 log scale).
# Colour progression: blue→green→yellow→red, one hue per range; >125k → ◆ inverse.
spark_char() {
    local value=$1

    local -a bounds=(1000 5000 25000 125000)
    local -a fg_colors=($'\033[34m' $'\033[32m' $'\033[33m' $'\033[31m')
    local -a bg_colors=($'\033[44m' $'\033[42m' $'\033[43m' $'\033[41m')

    # Saturated: above top range max → inverse video on range-5 fg color.
    # Inverse swaps attribute registers; invalidate cached bg/fg so next cell
    # re-emits. Intensity state is unaffected by RESET_INVERSE.
    if [ "$value" -gt "${bounds[3]}" ]; then
        echo -n "${INVERSE}${fg_colors[4]}◆${RESET_INVERSE}"
        _SPARK_BG=""
        _SPARK_FG=""
        return
    fi

    # Locate range
    local range=0 prev_max=0 i
    for i in 0 1 2 3; do
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

# Trailing duration string shown after the last turn's cells.
#   idle=0 (AI mid-turn): live `now − turn_start` (grows as the turn runs).
#   idle=1 (always-on render of an idle session): the final turn's *completed*
#           work time `last_api − last_u` (static). Dropped (empty string)
#           once `now − last_api > cache_ttl` — the cache has expired and a
#           stale duration adds nothing.
# turn_start = last_u when a user prompt was captured, else last_api.
# Durations clamp to 0. Args: idle now last_u last_api cache_ttl
_spark_trailing() {
    local idle=$1 now=$2 last_u=$3 last_api=$4 cache_ttl=$5
    local ref=$last_u
    [[ -z "$ref" ]] && ref=$last_api
    local dur
    if (( idle )); then
        (( now - last_api > cache_ttl )) && return
        dur=$(( last_api - ref ))
    else
        dur=$(( now - ref ))
    fi
    (( dur < 0 )) && dur=0
    format_age "$dur"
}

# Raw event stream for the last $_TX_MAX_LINES transcript lines (cached via
# _tx_cached; the window and the cache body bound are in transcript-cache.sh).
# $1 = transcript path.
_spark_stream_jq() {
    tail -n "$_TX_MAX_LINES" "$1" | jq -r '
        select((.isSidechain // false) | not) |
        ((.timestamp // "") | if . == "" then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdate? // 0) end) as $ts |
        if .type == "user" then
            # isMeta:true users are injected skill/slash-command content (often
            # with sourceToolUseID), not real turns — they would force spurious
            # turn-boundary separators. tool_result users are tool responses.
            # promptSource=="system" users are harness-injected notifications
            # (e.g. <task-notification> subagent completions), not user turns.
            if (.isMeta // false) or (.promptSource == "system") then empty
            else
                ((.message.content // "") | if type == "array" then (.[0].type // "") else "" end) as $ct |
                if $ct == "tool_result" then empty else "U \($ts)" end
            end
        elif .type == "assistant" and .message.usage != null then
            ((.message.usage.cache_read_input_tokens // 0) / 10 | floor) as $c |
            ((.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0) * 2) as $i |
            ((.message.usage.output_tokens // 0) * 5) as $o |
            (.message.stop_reason // "-") as $stop |
            if $c == 0 and $i == 0 and $o == 0 then empty
            else "A \(.requestId // "-") \($ts) \($c) \($i) \($o) \($stop)" end
        else empty end
    '
}

# Per-turn token sparkline from session transcript.
# Turn = one API call (dedup by requestId across multi-block assistant entries).
# cache = cache_read_input_tokens / 10                  (cheap reads at 0.1× cost)
# in    = input_tokens + cache_creation_input_tokens × 2 (fresh input; steady-state
#         caching bills new content as cache creation, not input_tokens. Cache writes are
#         weighted 2× as Claude Code uses 1h-TTL caching, billed at 2× base input.)
# out   = output_tokens × 5                              (writes scaled to same cost units)
# All three cells share one blue→green→yellow→red palette (no dim/bright); the
# kinds are read by position. Bounds: 1k/5k/25k/125k (uniform ×5 log); >125k → ◆.
# Structure:
#   - three cells per turn (API call): cache · read · write
#   - turns split by a separator: `·` between continuation calls (no user prompt),
#     `<turn_dur>│<user_wait>` at user-turn boundaries
#   - ` ` (gap) replaces `│` when user_wait > cache_ttl (cache expired)
#   - trailing `<dur_so_far>` while AI is running; static completed duration
#     when always-on + idle; suppressed when idle and always_on=0 (default)
display_turn_sparkline() {
    local transcript_path=$1
    local max_turns=${2:-30}
    local always_on=${3:-0}
    local cache_ttl=3600
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return

    # Stream of ordered events with epoch timestamps:
    #   U <epoch>                                        - genuine user prompt (not tool_result)
    #   A <requestId> <epoch> <cr/10> <in> <out×5> <stop> - assistant API call
    # <stop> is .message.stop_reason ("end_turn", "tool_use", etc.). Used to
    # decide whether the session is truly idle — only end_turn means the AI
    # has finished; tool_use means another API call is coming after the
    # tool_result arrives.
    local stream
    stream=$(_tx_cached spark "$transcript_path" _spark_stream_jq)

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
            local _r _ts _c _i _o _stop
            read -r _ _r _ts _c _i _o _stop <<< "$line"
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

    # No turns captured → nothing to draw, regardless of the always-on flag.
    if (( ${#a_turn_anchors[@]} == 0 )); then
        return
    fi
    # Idle = the AI has finished (last call end_turn) or a prompt is staged
    # with no assistant response yet. Pending Us (slash commands, local
    # command echoes, a just-submitted prompt) count as idle: they write user
    # entries without triggering an API call. Normally idle is suppressed — a
    # growing trailing duration on a finished turn is misleading. The always-on
    # flag (~/.claude/sparkline-always-on, read by the caller) overrides that:
    # render the historical bars with a static final-turn duration instead.
    local idle=0
    [[ "$trail_last_stop" == "end_turn" ]] && idle=1
    [[ -n "$_staging_u" ]] && idle=1
    if (( idle )) && (( ! always_on )); then
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
    #   a_lines[k]       = full "A <req> <ts> <cache> <in> <out> <stop>" line
    #   a_pending_sep[k] = rendered separator to emit before A_k's cells:
    #                      `<turn_dur>│<wait>` at a user-turn boundary, `·` for a
    #                      continuation call within the same turn, empty only for
    #                      the very first A in the stream.
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
            local _r _ts _c _i _o _stop
            read -r _ _r _ts _c _i _o _stop <<< "$line"
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
            elif [[ -n "$_build_last_api" ]]; then
                # Continuation call (no new user prompt): plain default-style
                # centred-dot separator so the cell triplets stay legible
                # without colour. `·` (U+00B7) is single-column under UTF-8.
                sep_str="·"
                sep_w=1
            fi
            a_lines+=("$line")
            a_pending_sep+=("$sep_str")
            a_sep_vis+=("$sep_w")
            _build_last_api=$_ts
        fi
    done

    local a_unit_count=${#a_lines[@]}
    (( a_unit_count == 0 )) && return

    # Trailing duration. Running turns show the live `now − turn_start`; an
    # idle always-on render shows the final turn's static completed duration,
    # or nothing once the cache has expired. See _spark_trailing.
    local now_epoch; now_epoch=$(date +%s)
    local trailing_str
    trailing_str="$(_spark_trailing "$idle" "$now_epoch" "$trail_last_u_epoch" "$trail_last_api_epoch" "$cache_ttl")"
    local trailing_vis=${#trailing_str}

    # Width-based truncation: drop oldest A units from the left until the
    # line fits. The first displayed A's pending_sep is suppressed (it
    # describes a transition from a dropped turn), so its width doesn't
    # count against the budget.
    #   width(keep_from=k) = trailing + 3·(n − k) + Σ sep_vis[k+1 … n−1]
    # Iterate k downward from n−1: each step adds A_k's 3 cells plus A_{k+1}'s
    # separator (which was suppressed before, now becomes visible because
    # A_k has claimed the first-displayed slot).
    local cols=${EFFECTIVE_COLS:-77}
    local keep_from=$a_unit_count
    local used=$trailing_vis
    local k
    for ((k=a_unit_count-1; k>=0; k--)); do
        local add=3
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
    # above don't leave a blank line behind. The leading RESET clears the CLI's
    # outer dim so every cell renders at full, uniform intensity.
    echo
    echo -n "${RESET}"
    _SPARK_BG=""
    _SPARK_FG=""

    for ((k=keep_from; k<a_unit_count; k++)); do
        if (( k > keep_from )) && [[ -n "${a_pending_sep[$k]}" ]]; then
            _spark_reset_colors
            echo -n "${a_pending_sep[$k]}"
        fi
        local _r _ts _c _i _o _stop
        read -r _ _r _ts _c _i _o _stop <<< "${a_lines[$k]}"
        spark_char "$_c" cache
        spark_char "$_i" in
        spark_char "$_o" out
    done

    _spark_reset_colors
    echo -n "$trailing_str"
    echo -n "${RESET_BG}${RESET_FG}"
}
