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

# The UTF-8 continuation bytes 0x80-0xBF, spelled out for vis_truncate. They are
# matched as a bracket set of single bytes, not by value: bash 3.2's printf %d
# on "'<byte>" returns a negative number for a byte above 0x7F, which classed every
# continuation byte as a cell. The set has no range, so no collation either.
_VT_CONT=$'\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277'

# Truncate $1 to $2 visible columns, preserving CSI escape sequences (which
# take 0 cells). Visible cells are counted byte-wise: any byte that isn't a
# UTF-8 continuation byte (0x80-0xBF) is one cell. Wide East-Asian glyphs
# would be undercounted but our content is single-cell only (ASCII, nerd-font
# PUA, the few specific symbols we use). Trailing escapes after the last
# emitted glyph are kept so terminal state still resets cleanly. No fork.
# When content is actually cut, the last visible cell is replaced by U+2026 (…)
# emitted in the SGR state that was active at that cell position.
vis_truncate() {
    local s=$1 max=$2
    local LC_ALL=C  # operate on bytes
    local out="" w=0 i=0 n=${#s}
    local c cc j b last_lead_emitted=1
    # Ellipsis support: buffer SGR until next cell so we can snapshot the
    # pre-cell state; collect escapes after truncation for terminal-state reset.
    local pending_sgr="" last_cell_pre="" last_cell_sgr=""
    local truncated=0 tail_out=""
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
            if (( truncated )); then
                tail_out+="${s:i:j-i+1}"
            else
                pending_sgr+="${s:i:j-i+1}"
            fi
            i=$((j + 1))
        else
            if [[ "$c" == [$_VT_CONT] ]]; then
                # UTF-8 continuation byte: emit only when not truncated and lead was emitted
                (( ! truncated && last_lead_emitted )) && out+="$c"
            else
                if (( ! truncated && w < max )); then
                    # Snapshot state before this cell (for ellipsis replacement)
                    last_cell_pre="$out"
                    last_cell_sgr="$pending_sgr"
                    out+="${pending_sgr}${c}"
                    pending_sgr=""
                    ((w++))
                    last_lead_emitted=1
                elif (( ! truncated )); then
                    # First cell over budget: mark truncation, move pending to tail
                    truncated=1
                    tail_out+="$pending_sgr"
                    pending_sgr=""
                    last_lead_emitted=0
                else
                    last_lead_emitted=0
                fi
            fi
            ((i++))
        fi
    done
    # Flush any trailing pending SGR (input ends with escape after last cell)
    if (( truncated )); then
        tail_out+="$pending_sgr"
    else
        out+="$pending_sgr"
    fi
    if (( truncated && max > 0 )); then
        # Replace last visible cell with U+2026 in the cell's SGR state
        printf '%s' "${last_cell_pre}${last_cell_sgr}"$'\xe2\x80\xa6'"${tail_out}"
    elif (( truncated )); then
        # max=0: no room for ellipsis; emit only terminal-state escapes
        printf '%s' "${tail_out}"
    else
        printf '%s' "$out"
    fi
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

# Humanise a token count: 999 → "999", 364000 → "364k", 1500000 → "1.5M".
# k = rounded thousands (half-up); M = one decimal, trailing ".0" stripped.
# Empty / "unset" / non-numeric → "0".
humanize_tokens() {
    local n=$1
    if [[ -z "$n" || "$n" == "unset" || ! "$n" =~ ^[0-9]+$ ]]; then
        printf '0'
        return
    fi
    if (( n < 1000 )); then
        printf '%d' "$n"
    elif (( n < 1000000 )); then
        printf '%dk' "$(( (n + 500) / 1000 ))"
    else
        local m
        m=$(LC_NUMERIC=C printf '%.1f' "$(bc -l <<< "$n / 1000000")")
        m=${m%.0}
        printf '%sM' "$m"
    fi
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

# Compact turn duration with sub-unit resolution: 52s / 2m10 / 4m / 1h05 / 1h.
# Seconds shown only when non-zero (<1h); minutes shown only when non-zero (≥1h).
# Negative clamps to 0s.
format_turn_dur() {
    local s=$1
    (( s < 0 )) && s=0
    if (( s < 60 )); then
        printf '%ds' "$s"
    elif (( s < 3600 )); then
        local m=$(( s / 60 )) sec=$(( s % 60 ))
        if (( sec == 0 )); then
            printf '%dm' "$m"
        else
            printf '%dm%02d' "$m" "$sec"
        fi
    else
        local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 ))
        if (( m == 0 )); then
            printf '%dh' "$h"
        else
            printf '%dh%02d' "$h" "$m"
        fi
    fi
}

# Window-elapsed percent: how far through the rate-limit window we are.
# $1=resets_at_epoch $2=window_secs $3=now_epoch (optional override for tests)
# Outputs an integer 0-100, or nothing when resets_at is missing/null/0, or
# when window_secs is <= 0 (degenerate input; avoids division by zero).
window_elapsed_pct() {
    local resets_at=$1 window_secs=$2
    local now=${3:-$(date +%s)}
    [[ -z "$resets_at" || "$resets_at" == "null" || "$resets_at" == "0" ]] && return
    (( window_secs <= 0 )) && return
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

# Portable "size:mtime" signature (GNU stat, then BSD/macOS stat).
_stat_sig() {
    local sz mt
    sz=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
    mt=$(stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null)
    printf '%s:%s' "${sz:-0}" "${mt:-0}"
}

# Byte size of a file (GNU stat, then BSD/macOS stat); 0 when unknown, so the
# result is always safe in arithmetic.
_file_size() {
    local sz
    sz=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
    [[ "$sz" =~ ^[0123456789]{1,18}$ ]] || sz=0
    printf '%s' "$((10#$sz))"
}

# _cc_private_dir <dir>
# Succeeds only if <dir> is an absolute path to a directory owned by the current
# user and is not itself a symlink, creating it 0700 (umask 077) when absent.
# A trailing slash is refused: `-L dir/` tests the link's target, not the link.
# Other local users can create neither such a dir nor anything inside it once
# it is 0700, so files under it are safe to write and to read back. `-L` is
# tested first: `-d` and `-O` follow a symlink, and `mkdir -p` succeeds silently
# on a symlink to a dir. Callers that get a failure compute uncached.
_cc_private_dir() {
    [[ "$1" == /* && "$1" != */ ]] || return 1
    [[ -e "$1" || -L "$1" ]] || (umask 077; mkdir -p -- "$1") 2>/dev/null
    [[ ! -L "$1" && -d "$1" && -O "$1" ]]
}

# cc_state_dir_init
# Sets CC_STATE_DIR, once per render, to the private per-user state dir holding
# the payload dump, the timing log and both caches (statusline-design.md §4.18):
# $CC_STATUSLINE_STATE_DIR, else $XDG_RUNTIME_DIR/cc-statusline, else
# $HOME/.cache/cc-statusline (macOS has no XDG_RUNTIME_DIR). Set to empty when
# that dir is unusable; every consumer then skips its write or computes
# uncached. Always returns 0.
# shellcheck disable=SC2034  # CC_STATE_DIR is read by the other libs
cc_state_dir_init() {
    local base d
    CC_STATE_DIR=
    d=${CC_STATUSLINE_STATE_DIR:-}
    if [[ -z "$d" ]]; then
        base=${XDG_RUNTIME_DIR:-}
        [[ -n "$base" ]] || { [[ -n "${HOME:-}" ]] && base=$HOME/.cache; }
        [[ -n "$base" ]] && d=$base/cc-statusline
    fi
    while [[ "$d" == */ ]]; do d=${d%/}; done
    if _cc_private_dir "$d"; then CC_STATE_DIR=$d; fi
    return 0
}

# _cc_write_file <path> <content>
# Replace <path> with <content> + newline through a temp file and `mv`: rename
# replaces a planted symlink instead of writing through it, and a concurrent
# render never reads half a file. Failures are silent.
_cc_write_file() {
    local tmp
    tmp=$(mktemp "${1%/*}/.tmp.XXXXXX" 2>/dev/null) || return 0
    if printf '%s\n' "$2" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$1" 2>/dev/null; fi
    rm -f "$tmp" 2>/dev/null
    return 0
}
