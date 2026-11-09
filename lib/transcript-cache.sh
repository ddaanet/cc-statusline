#!/usr/bin/env bash
# Memoise transcript-derived `jq` output across renders. Source after
# format-utils.sh (needs _stat_sig, _cc_private_dir).
#
# The statusline re-runs on every redraw, and most redraws (refresh timer,
# perm-mode or vim toggle) see an unchanged transcript. Only the raw producer
# output is cached; anything that depends on "now" (running-turn duration, idle
# check, expiry) stays in the callers.
#
# The cache lives in $TX_CACHE_DIR, else $CC_STATE_DIR/tx-cache (the private
# per-user state dir, see cc_state_dir_init in format-utils.sh). Either is used
# only if _cc_private_dir accepts it (owned by the user, not a symlink); else
# every call runs its producer uncached.

# The dir is private, but a hit is still not trusted (defence in depth: the
# dir's own mode is the user's to loosen): callers feed these bodies to `date
# -d` and bash arithmetic, where a planted value such as `a[$(cmd)]` would
# execute. Each kind below accepts only the exact line shapes its producer
# emits; a body that fails is a miss and is regenerated. A kind with no
# validator is never accepted (always a miss), so a new kind must add a
# `_tx_valid_<kind>` before it can be cached.
#
# Integers have no leading zero (arithmetic reads `08` as an invalid octal base)
# and at most 18 digits (they must fit a signed 64-bit integer). `0` is valid:
# producers emit it for a missing timestamp and for zero counts. Digits are
# spelled out rather than `[0-9]` so the bash `=~` below is locale-independent.
_TX_UINT='(0|[123456789][0123456789]{0,17})'
# Fixed-width fields with zeros allowed: this goes to `date`, not to arithmetic.
_TX_ISO_TS='[0123456789]{4}-[0123456789]{2}-[0123456789]{2}T[0123456789]{2}:[0123456789]{2}:[0123456789]{2}(\.[0123456789]+)?Z'
# <req> and <stop> must hold no whitespace at all: consumers split with
# default-IFS `read`, so a tab inside one would shift a planted value into an
# arithmetic field.
_TX_WORD='[^[:space:]]+'

# The stream producers read the last _TX_MAX_LINES transcript lines and emit at
# most one line per input line, so no legitimate spark/stats body is longer. A
# planted body within the grammar but far longer would cost the consumers'
# superlinear scan on every render (0.7 s at 1500 lines, 5.8 s at 6000).
# _TX_MAX_BYTES bounds every kind, including one giant field; real lines are
# 75-105 bytes.
_TX_MAX_LINES=1500
_TX_MAX_BYTES=$(( _TX_MAX_LINES * 256 ))

# last: line 1 ISO timestamp or empty, line 2 token total or empty, nothing else.
_tx_valid_last() {
    local ts tok
    [[ "${1%$'\n'}" != *$'\n'*$'\n'* ]] || return 1
    { IFS= read -r ts; IFS= read -r tok; } <<< "$1"
    [[ "$ts" =~ ^($_TX_ISO_TS)?$ && "$tok" =~ ^($_TX_UINT)?$ ]]
}

# _tx_lines_match <alternation> <body>
# Succeeds only on positive evidence: every line of <body> matches
# ^(<alternation>)$ (the bad-line count printed is the string `0`) and the line
# count is at most _TX_MAX_LINES. There is no pipeline, so the sourcing shell's
# `pipefail` cannot change the verdict, and a grep that cannot run, a bad regex
# or an unwritable here-string temp file prints no `0` and rejects. The case
# pattern needs a line after the `0`, and a count that grep did not print leaves
# a bare `0` (substitution strips the trailing newline), so `n` is always a
# number when `[ -le ]` runs.
_tx_lines_match() {
    local out n
    out=$({
        LC_ALL=C grep -cvE "^($1)$" <<< "${2%$'\n'}"
        LC_ALL=C grep -c '' <<< "${2%$'\n'}"
    } 2>/dev/null)
    case "$out" in
        0$'\n'*) n=${out#0$'\n'} ;;
        *) return 1 ;;
    esac
    [ "$n" -le "$_TX_MAX_LINES" ]
}

# spark: "U <epoch>" and "A <req> <epoch> <cr> <in> <out> <stop>" lines.
_tx_valid_spark() {
    _tx_lines_match "U $_TX_UINT|A $_TX_WORD $_TX_UINT $_TX_UINT $_TX_UINT $_TX_UINT $_TX_WORD" "$1"
}

# stats: "U <epoch>" and "A <req> <epoch> <cr> <cc> <out> <in> <stop>" lines.
_tx_valid_stats() {
    _tx_lines_match "U $_TX_UINT|A $_TX_WORD $_TX_UINT $_TX_UINT $_TX_UINT $_TX_UINT $_TX_UINT $_TX_WORD" "$1"
}

# subcalls: one per-call context size per line, at most _TX_SUBCALLS_MAX lines
# (the subagent sparkline's cell count; _sa_calls_jq emits no more).
_TX_SUBCALLS_MAX=16
_tx_valid_subcalls() {
    local nl=$'\n'
    [[ "${1%"$nl"}$nl" =~ ^($_TX_UINT$nl){1,$_TX_SUBCALLS_MAX}$ ]]
}

# _tx_body_ok <kind> <body>
# An unknown kind or an oversized body is rejected. An empty body is valid for
# every kind that has a validator, so a transcript with no turns keeps hitting.
_tx_body_ok() {
    declare -F "_tx_valid_$1" >/dev/null || return 1
    (( ${#2} <= _TX_MAX_BYTES )) || return 1
    [[ -z "$2" ]] || "_tx_valid_$1" "$2"
}

# _tx_cached <kind> <transcript> <producer-fn> [args…]
# Echoes the producer's output for <transcript>. Cache file layout: line 1 is
# the "size:mtime" signature, the remainder is the body. One file per
# transcript path and kind, overwritten in place (no unbounded growth). The
# write goes through a temp file + mv so concurrent renders never read a
# half-written body.
_tx_cached() {
    local kind=$1 tx=$2; shift 2
    local key=${tx//\//_} sig cache first body tmp
    local dir=${TX_CACHE_DIR:-${CC_STATE_DIR:+$CC_STATE_DIR/tx-cache}}
    # Same rule for the default and an override: no private dir, no caching.
    _cc_private_dir "$dir" || { "$@" "$tx"; return; }
    cache="$dir/$key.$kind"
    sig=$(_stat_sig "$tx")
    if [[ -f "$cache" ]]; then
        # -n 64: a real signature is under 40 characters, and a planted file with
        # no newline must not be slurped into `first`. A longer line reads as a
        # truncated signature, which cannot match, so it is a miss.
        { IFS= read -r -n 64 first; body=$(head -c $(( _TX_MAX_BYTES + 1 )); printf x); } < "$cache"
        body=${body%x}
        if [[ "$first" == "$sig" ]] && _tx_body_ok "$kind" "$body"; then
            printf '%s' "$body"
            return
        fi
    fi
    body=$("$@" "$tx"; printf x)
    tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) && {
        { printf '%s\n' "$sig"; printf '%s' "${body%x}"; } > "$tmp" && mv -f "$tmp" "$cache" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    }
    printf '%s' "${body%x}"
}
