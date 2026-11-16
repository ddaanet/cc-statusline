#!/usr/bin/env bash
# Token and context-usage display functions for the statusline.
# Deps (source before this file): colors.sh, format-utils.sh
# Globals consumed: BLUE GREEN YELLOW RED MAGENTA BRMAGENTA RESET_DIM

# Get color for token count
# Color sequence (50k blocks): blue green yellow red brmagenta.
# Stops at brmagenta above 200k on purpose: the growth bar's alternation past
# 250k exists to make its blocks countable, and a single value has no blocks.
# Bright, not plain magenta: plain magenta follows red with too little contrast.
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
        echo -n "$BRMAGENTA"
    fi
}

# Colour of the $2'th 50k range of the growth bar, assigned into var named $1.
# 0–200k keeps the historic blue/green/yellow/red ramp; from 200k on the ranges
# alternate BRMAGENTA / MAGENTA so a long bar's blocks remain countable
# (a 1M window is 20 blocks; one flat magenta run reads as a single smear).
# The range after red is BRMAGENTA: plain magenta beside red lacks contrast.
# printf -v, not an echo + $(…): this runs once per block on every render.
_token_bar_color() {
    local _c
    case $2 in
        0) _c=$BLUE ;;
        1) _c=$GREEN ;;
        2) _c=$YELLOW ;;
        3) _c=$RED ;;
        *) if (( $2 % 2 )); then _c=$MAGENTA; else _c=$BRMAGENTA; fi ;;
    esac
    printf -v "$1" '%s' "$_c"
}

# Visible width of display_token_bar's output for the same arguments, into the
# variable named $1: one column per 50k range (capped at 32), 0 for an
# empty/invalid/zero total, and the flat 8 of the elided form from 9 blocks up.
# Lets a caller fit the bar arithmetically instead of measuring it.
token_bar_width() {
    local _tbw_n=0
    if [[ "$2" =~ ^[0123456789]{1,18}$ ]]; then
        _tbw_n=$(( (10#$2 + 49999) / 50000 ))
        (( _tbw_n > 32 )) && _tbw_n=32
        [[ "${3-}" == elide ]] && (( _tbw_n > 8 )) && _tbw_n=8
    fi
    printf -v "$1" '%d' "$_tbw_n"
}

# Display vertical-growth token bar
# One char per 50k range, height shows fill within range (▁▂▃▄▅▆▇█)
# Colors: blue green yellow red, then brmagenta/magenta alternating
# $2="elide": drop the middle ranges — the 0–250k head, a BRMAGENTA ⋯, then the
# last two blocks (§4.12). Only kicks in once that is actually narrower than the
# whole bar; below the threshold the two forms are byte-identical.
display_token_bar() {
    local total=$1 mode=${2-}
    # Handle empty, unset, non-numeric, or zero values
    if [ -z "$total" ] || [ "$total" = "unset" ] || ! [[ "$total" =~ ^[0-9]+$ ]] || [ "$total" -eq 0 ]; then
        return
    fi

    local range_size=50000
    # Block count. No fixed range count — the ramp continues for as long as
    # there are tokens left. Bounded anyway (32 blocks = 1.6M) so a bogus
    # payload value cannot spin here; row truncation handles the width.
    local n=$(((total + range_size - 1) / range_size))
    [[ $n -gt 32 ]] && n=32

    # The elided form is 5 head + ⋯ + 2 tail = 8 columns, so it saves nothing
    # below 9 blocks (>400k) — render whole there rather than pay a column to
    # hide one range.
    local elide=0
    [[ "$mode" == "elide" && $n -gt 8 ]] && elide=1

    local i fill idx range_color
    for ((i=0; i<n; i++)); do
        # Elided span: one ⋯ in place of ranges 5 … n-3.
        if [[ $elide -eq 1 && $i -ge 5 && $i -lt $((n - 2)) ]]; then
            [[ $i -eq 5 ]] && echo -n "${BRMAGENTA}⋯"
            continue
        fi
        _token_bar_color range_color "$i"
        fill=$((total - i * range_size))
        if [ "$fill" -ge "$range_size" ]; then
            echo -n "${range_color}█"
            continue
        fi
        # Partial range — map to vertical block height
        idx=$(((fill * 8 + range_size / 2) / range_size))
        [[ $idx -lt 1 ]] && idx=1
        [[ $idx -gt 7 ]] && idx=7
        case $idx in
            1) echo -n "${range_color}▁" ;;
            2) echo -n "${range_color}▂" ;;
            3) echo -n "${range_color}▃" ;;
            4) echo -n "${range_color}▄" ;;
            5) echo -n "${range_color}▅" ;;
            6) echo -n "${range_color}▆" ;;
            7) echo -n "${range_color}▇" ;;
        esac
    done

    echo -n "$RESET_DIM"
}

# One pass over the transcript for both fields the line-1 fallbacks need
# (cached via _tx_cached, see transcript-cache.sh). Emits two lines:
#   1. timestamp of the last non-sidechain assistant entry ("" if none)
#   2. total tokens of the last such entry with non-zero usage ("" if none).
#      A call that ran the advisor logs top-level usage summed over its
#      `iterations`; its last `message` iteration is read instead (§4.12).
# Scans the last 1500 lines and only falls back to the whole file when that
# window holds neither, so a transcript tail of sidechain/tool noise still
# resolves. $1 = transcript path.
_tx_last_jq() {
    # shellcheck disable=SC2016  # jq program, not shell
    local prog='
        reduce (inputs | select(.type == "assistant" and (.isSidechain // false | not))) as $e
            ({ts: "", tok: ""};
             ($e.timestamp // "") as $t |
             (($e.message.usage // {})
              | ([.iterations // empty | arrays | .[] | objects | select(.type == "message")] | last) as $it
              | ($it // .)
              | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) +
                (.cache_read_input_tokens // 0) + (.output_tokens // 0)) as $n |
             (if $t != "" then .ts = $t else . end) |
             (if $n != 0 then .tok = ($n | tostring) else . end))
        | .ts, .tok'
    local out
    out=$(tail -n 1500 "$1" | jq -r -n "$prog" 2>/dev/null)
    if [[ -z "${out//$'\n'/}" ]]; then
        out=$(jq -r -n "$prog" < "$1" 2>/dev/null)
    fi
    printf '%s\n' "$out"
}

# Get context usage from transcript file
get_transcript_context() {
    local transcript_path=$1
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return

    # Most recent assistant message (not sidechain) with non-zero usage
    local last tok
    last=$(_tx_cached last "$transcript_path" _tx_last_jq)
    { IFS= read -r _; IFS= read -r tok; } <<< "$last"
    [[ -n "$tok" && "$tok" != "null" ]] && echo "$tok"
}

# Expiry time of the most recent prompt cache entry.
# $1=transcript_path. Outputs HH:MM (local) or nothing if expired or unavailable.
# Cache TTL = 3600s (1 hour) from last assistant API call.
format_cache_expiry() {
    local transcript_path=$1
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return
    local _os; _os=$(uname -s)
    local last last_ts tok
    last=$(_tx_cached last "$transcript_path" _tx_last_jq)
    { IFS= read -r last_ts; IFS= read -r tok; } <<< "$last"
    [[ -z "$last_ts" ]] && return
    local last_epoch
    if [[ "$_os" == "Darwin" ]]; then
        # BSD date rejects trailing text after the format and reads the string as
        # local time, so drop the fraction and the Z and pin the zone to UTC.
        local bsd_ts=${last_ts%Z}
        last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${bsd_ts%%.*}" +%s 2>/dev/null)
    else
        last_epoch=$(date -d "${last_ts}" +%s 2>/dev/null)
    fi
    [[ -z "$last_epoch" ]] && return
    local expiry=$(( last_epoch + 3600 ))
    local now; now=$(date +%s)
    (( now >= expiry )) && return
    if [[ "$_os" == "Darwin" ]]; then
        date -r "$expiry" +%H:%M
    else
        date -d "@$expiry" +%H:%M
    fi
}
