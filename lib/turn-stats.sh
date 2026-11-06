#!/usr/bin/env bash
# Per-user-turn numeric stats line for the statusline (`stats` mode).
# Deps (source before this file): colors.sh (BOLD, CYAN, BLUE, GREEN, YELLOW,
# RESET_DIM), format-utils.sh (humanize_tokens, format_turn_dur, vislen).
# Globals consumed: EFFECTIVE_COLS, _TX_MAX_LINES.
# Counterpart to lib/sparkline.sh's display_turn_sparkline.

# Effective external input for a turn:
#   sum_cc − sum_out + last_out − prev_last_out   (clamp at 0)
# Removes the model's already-cached outputs (all but the most recent) and the
# previous turn's final output (cached on this turn's first call). Result =
# user_message + Σtool_results. On a cold turn the cache-creation spike inflates
# this figure (input visibly jumps); the ❄ marker distinguishes that re-cache
# from a genuinely large user input.
_turn_input() {
    local sum_cc=$1 sum_out=$2 last_out=$3 prev_last_out=$4
    local input=$(( sum_cc - sum_out + last_out - prev_last_out ))
    (( input < 0 )) && input=0
    printf '%d' "$input"
}

# Cold-cache marker for a turn: 0 → "", 1 → "❄", N → "N❄".
_turn_marker() {
    local cold=$1
    if (( cold <= 0 )); then
        printf ''
    elif (( cold == 1 )); then
        printf '❄'
    else
        printf '%d❄' "$cold"
    fi
}

# Raw event stream for the last $_TX_MAX_LINES transcript lines (cached via
# _tx_cached; the window and the cache body bound are in transcript-cache.sh).
# $1 = transcript path.
_stats_stream_jq() {
    tail -n "$_TX_MAX_LINES" "$1" | jq -r '
        select((.isSidechain // false) | not) |
        ((.timestamp // "") | if . == "" then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdate? // 0) end) as $ts |
        if .type == "user" then
            # isMeta:true users are injected skill/slash-command content (often
            # with sourceToolUseID), not real turns — they would split one turn
            # into many. tool_result users are tool responses, likewise not turns.
            # promptSource=="system" users are harness-injected notifications
            # (e.g. <task-notification> subagent completions), not user turns.
            if (.isMeta // false) or (.promptSource == "system") then empty
            else
                ((.message.content // "") | if type == "array" then (.[0].type // "") else "" end) as $ct |
                if $ct == "tool_result" then empty else "U \($ts)" end
            end
        elif .type == "assistant" and .message.usage != null then
            (.message.usage.cache_read_input_tokens // 0) as $cr |
            (.message.usage.cache_creation_input_tokens // 0) as $cc |
            (.message.usage.output_tokens // 0) as $out |
            (.message.usage.input_tokens // 0) as $in |
            (.message.stop_reason // "-") as $stop |
            if $cr == 0 and $cc == 0 and $out == 0 and $in == 0 then empty
            else "A \(.requestId // "-") \($ts) \($cr) \($cc) \($out) \($in) \($stop)" end
        else empty end
    '
}

# Per-user-turn numeric stats line. One group per turn:
#   [marker ]N× cr/input/out dur   joined by ' · ', newest on the right.
# Turn = the U that triggers the next A through the assistant going idle
# (end_turn), spanning N API calls. First-wins U: preliminary Us / slash
# commands collapse into one anchor.
# Args: transcript_path [cols] [now_override]
display_turn_stats() {
    local transcript_path=$1
    local cols=${2:-${EFFECTIVE_COLS:-77}}
    local now_override=${3:-}
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return

    # Ordered event stream (raw token counts, unlike the sparkline's
    # cost-normalised cells):
    #   U <epoch>
    #   A <requestId> <epoch> <cr> <cc> <out> <in> <stop>
    local stream
    stream=$(_tx_cached stats "$transcript_path" _stats_stream_jq)
    [[ -z "$stream" ]] && return

    # Dedupe A by requestId (bash-3 compatible linear scan).
    local -a items=()
    local seen_req="|" line
    while IFS= read -r line; do
        if [[ "$line" == A\ * ]]; then
            local req="${line#A }"; req="${req%% *}"
            [[ "$seen_req" == *"|$req|"* ]] && continue
            seen_req+="$req|"
        fi
        items+=("$line")
    done <<< "$stream"

    # Aggregate per turn. Parallel arrays indexed by turn occurrence.
    local -a t_n t_cr t_cc t_out t_lastout t_anchor t_lastapi t_cold t_laststop
    local ti=-1 staging_u="" prev_cr="" prev_cc=""
    for line in "${items[@]}"; do
        if [[ "$line" == U\ * ]]; then
            local u="${line#U }"
            [[ -z "$u" || "$u" == "0" ]] && continue
            [[ -z "$staging_u" ]] && staging_u=$u
        else
            local _r _ts _cr _cc _out _in _stop
            read -r _ _r _ts _cr _cc _out _in _stop <<< "$line"
            if [[ -n "$staging_u" ]]; then
                ti=$(( ti + 1 ))
                t_anchor[ti]=$staging_u
                t_n[ti]=0; t_cr[ti]=0; t_cc[ti]=0; t_out[ti]=0
                t_cold[ti]=0
                staging_u=""
            elif (( ti < 0 )); then
                ti=$(( ti + 1 ))
                t_anchor[ti]=$_ts
                t_n[ti]=0; t_cr[ti]=0; t_cc[ti]=0; t_out[ti]=0
                t_cold[ti]=0
            fi
            # Cold-cache detection across the whole stream (global adjacency).
            # A cold event: this call reads back less than the previous call
            # had cached (read + just-written), AND the freshly-processed
            # tokens cover the drop (refresh ≥ drop) — distinguishing a cold
            # re-cache from a context shrink (compaction/clear). Comparing
            # against cr+cc (not cr alone) catches a 0→0 re-expiration.
            # The drop must also exceed half the cache (2·drop > cap): a real
            # TTL expiry wipes the whole prefix (cr → ~0), whereas a new user
            # turn dips cr a few % below cap as breakpoints shift — that normal
            # boundary churn trivially satisfies refresh ≥ drop and must not mark.
            # refresh ≥ drop is the discriminator ONLY for partial drops (cr>0):
            # it rejects a compaction/clear, where the context shrinks and only a
            # small summary is re-cached. But when the whole prefix expires the
            # re-cache covers only the *current* context, so if that context also
            # shrank, cc < drop even though the cache genuinely went cold. A full
            # collapse (cr==0, nothing read back) is therefore unconditionally
            # cold — refresh ≥ drop must not gate it.
            if [[ -n "$prev_cr" ]]; then
                local cap=$(( prev_cr + prev_cc ))
                local drop=$(( cap - _cr ))
                if (( drop > 0 )); then
                    local refresh=$(( _cc + _in ))
                    if (( (refresh >= drop || _cr == 0) && 2 * drop > cap )); then
                        t_cold[ti]=$(( t_cold[ti] + 1 ))
                    fi
                fi
            fi
            prev_cr=$_cr; prev_cc=$_cc
            t_n[ti]=$(( t_n[ti] + 1 ))
            t_cr[ti]=$(( t_cr[ti] + _cr ))
            t_cc[ti]=$(( t_cc[ti] + _cc ))
            t_out[ti]=$(( t_out[ti] + _out ))
            t_lastout[ti]=$_out
            t_lastapi[ti]=$_ts
            t_laststop[ti]=$_stop
        fi
    done
    (( ti < 0 )) && return
    local ngroups=$(( ti + 1 ))

    local now=$now_override
    [[ -z "$now" ]] && now=$(date +%s)

    # Build group strings, oldest → newest.
    local -a groups=()
    local g
    for ((g=0; g<ngroups; g++)); do
        local prev_last_out=0
        (( g > 0 )) && prev_last_out=${t_lastout[$((g-1))]}
        local input cr_h input_h out_h marker dur dur_str
        input=$(_turn_input "${t_cc[$g]}" "${t_out[$g]}" "${t_lastout[$g]}" "$prev_last_out")
        cr_h=$(humanize_tokens "${t_cr[$g]}")
        input_h=$(humanize_tokens "$input")
        out_h=$(humanize_tokens "${t_out[$g]}")
        marker=$(_turn_marker "${t_cold[$g]}")
        # Duration: static completed time, except a live last turn still running.
        dur=$(( ${t_lastapi[$g]} - ${t_anchor[$g]} ))
        if (( g == ngroups-1 )) && [[ "${t_laststop[$g]}" != "end_turn" ]]; then
            dur=$(( now - ${t_anchor[$g]} ))
        fi
        (( dur < 0 )) && dur=0
        dur_str=$(format_turn_dur "$dur")
        # Colour: marker bold-cyan, call count bold, cr blue, input green,
        # out yellow, duration default. vislen strips SGR, so the width
        # truncation budget below is unaffected.
        local marker_c=""
        [[ -n "$marker" ]] && marker_c="${BOLD}${CYAN}${marker}${RESET_DIM} "
        groups[g]="${marker_c}${BOLD}${t_n[$g]}×${RESET_DIM} ${BLUE}${cr_h}${RESET_DIM}/${GREEN}${input_h}${RESET_DIM}/${YELLOW}${out_h}${RESET_DIM} ${dur_str}"
    done

    # Inter-turn separators carry the user think-time gap: the idle span between
    # one turn's last API call and the next turn's anchor (clamped ≥0), rendered
    # ' ·<wait>· ' with the same compact age format the sparkline uses. sep_str[i]
    # joins group i to group i+1. No trailing separator: the running turn's live
    # duration already reflects the current wait.
    local -a sep_str=() sep_w=()
    local s
    for ((s=0; s<ngroups-1; s++)); do
        local wait=$(( ${t_anchor[$((s+1))]} - ${t_lastapi[$s]} ))
        (( wait < 0 )) && wait=0
        sep_str[s]=" ·$(format_age "$wait")· "
        sep_w[s]=$(vislen "${sep_str[$s]}")
    done

    # Width truncation: drop oldest groups from the left until the line fits.
    # Walk backward from the newest, accumulating each group's width plus the
    # separator to its right (sep_w[k2]) for every group that has a kept
    # neighbour. The first kept group's leading separator is never emitted, so
    # it is excluded from the budget. Always keep at least the newest group.
    local -a gw=()
    local g2
    for ((g2=0; g2<ngroups; g2++)); do
        gw[g2]=$(vislen "${groups[$g2]}")
    done
    local keep_from=$ngroups used=0 k2
    for ((k2=ngroups-1; k2>=0; k2--)); do
        local add=${gw[$k2]}
        (( k2+1 < ngroups )) && add=$(( add + ${sep_w[$k2]} ))
        (( used + add > cols )) && break
        used=$(( used + add ))
        keep_from=$k2
    done
    (( keep_from >= ngroups )) && keep_from=$(( ngroups - 1 ))

    # Emit: leading newline (so skip-paths leave no blank line), groups joined
    # by their inter-turn separators. A leading RESET_DIM clears any SGR the CLI
    # left active (back to its ambient dim) so the first segment's colour is not
    # contaminated; every segment self-resets the same way.
    local out="" k
    for ((k=keep_from; k<ngroups; k++)); do
        (( k > keep_from )) && out+="${sep_str[$((k-1))]}"
        out+="${groups[$k]}"
    done
    echo
    printf '%s' "${RESET_DIM}${out}"
}
