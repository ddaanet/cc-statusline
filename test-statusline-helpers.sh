#!/usr/bin/env bash
# Tests for the pure-bash statusline helpers (vis_truncate, vislen).
# shellcheck disable=SC2329  # stubs and producers are called indirectly (by name, via overrides)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX") || { echo "FATAL: cannot create scratch dir"; exit 2; }
trap 'rm -rf "$TEST_TMP"' EXIT

# Every state write — in-process calls and the rendered script alike — lands in
# a test-owned dir: never the real $HOME, $XDG_RUNTIME_DIR or /tmp.
unset XDG_RUNTIME_DIR
_st_dir="$TEST_TMP/state"
export CC_STATUSLINE_STATE_DIR="$_st_dir"

# Account-validation lib: same resolution as statusline-command.sh
# (env var, pointer file, default); fallbacks when absent.
if [[ -z "${CC_STATUSLINE_ACCOUNT_LIB:-}" && -r "$HOME/.claude/statusline-account-lib" ]]; then
    IFS= read -r CC_STATUSLINE_ACCOUNT_LIB < "$HOME/.claude/statusline-account-lib" || true
fi
: "${CC_STATUSLINE_ACCOUNT_LIB:=$HOME/code/cc-switch/lib/account-validation.sh}"
export CC_STATUSLINE_ACCOUNT_LIB

# shellcheck source=lib/format-utils.sh
source "$HERE/lib/format-utils.sh" || { echo "FATAL: format-utils.sh not found"; exit 2; }
# shellcheck source=lib/colors.sh
source "$HERE/lib/colors.sh" || { echo "FATAL: colors.sh not found"; exit 2; }
# shellcheck source=lib/transcript-cache.sh
source "$HERE/lib/transcript-cache.sh" || { echo "FATAL: transcript-cache.sh not found"; exit 2; }
# shellcheck source=lib/model-display.sh
source "$HERE/lib/model-display.sh" || { echo "FATAL: model-display.sh not found"; exit 2; }
# shellcheck source=lib/context-display.sh
source "$HERE/lib/context-display.sh" || { echo "FATAL: context-display.sh not found"; exit 2; }
# shellcheck source=lib/sparkline.sh
source "$HERE/lib/sparkline.sh" || { echo "FATAL: sparkline.sh not found"; exit 2; }
# shellcheck source=lib/turn-stats.sh
source "$HERE/lib/turn-stats.sh" || { echo "FATAL: turn-stats.sh not found"; exit 2; }
# shellcheck disable=SC2317  # fallbacks are invoked indirectly by account-display.sh
if [[ -r "$CC_STATUSLINE_ACCOUNT_LIB" ]]; then
    echo "account lib: $CC_STATUSLINE_ACCOUNT_LIB"
    # shellcheck source=/dev/null
    source "$CC_STATUSLINE_ACCOUNT_LIB" || { echo "FATAL: cannot source $CC_STATUSLINE_ACCOUNT_LIB"; exit 2; }
else
    echo "account lib absent ($CC_STATUSLINE_ACCOUNT_LIB): using no-op fallbacks"
    get_mode() { echo plan; }
    get_api_provider() { echo anthropic; }
    validate_state() { return 0; }
fi
# shellcheck source=lib/account-display.sh
source "$HERE/lib/account-display.sh" || { echo "FATAL: account-display.sh not found"; exit 2; }
# shellcheck source=lib/line1-layout.sh
source "$HERE/lib/line1-layout.sh" || { echo "FATAL: line1-layout.sh not found"; exit 2; }
# shellcheck source=lib/subagent-display.sh
source "$HERE/lib/subagent-display.sh" || { echo "FATAL: subagent-display.sh not found"; exit 2; }

# Sanity: confirm source worked
type vis_truncate >/dev/null 2>&1 || { echo "FATAL: vis_truncate not loaded"; exit 2; }
type vislen      >/dev/null 2>&1 || { echo "FATAL: vislen not loaded"; exit 2; }
type emit_truncated >/dev/null 2>&1 || { echo "FATAL: emit_truncated not loaded"; exit 2; }
type display_turn_stats >/dev/null 2>&1 || { echo "FATAL: display_turn_stats not loaded"; exit 2; }
type pick_plan_variant >/dev/null 2>&1 || { echo "FATAL: pick_plan_variant not loaded"; exit 2; }
type layout_line1 >/dev/null 2>&1 || { echo "FATAL: layout_line1 not loaded"; exit 2; }
type render_timer >/dev/null 2>&1 || { echo "FATAL: render_timer not loaded"; exit 2; }
type render_model_sec >/dev/null 2>&1 || { echo "FATAL: render_model_sec not loaded"; exit 2; }
type set_model_sec >/dev/null 2>&1 || { echo "FATAL: set_model_sec not loaded"; exit 2; }
type sa_row >/dev/null 2>&1 || { echo "FATAL: sa_row not loaded"; exit 2; }

cc_state_dir_init

PASS=0; FAIL=0
assert() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        printf '  OK   %s\n' "$desc"
        ((PASS++))
    else
        printf '  FAIL %s\n    got:  %q\n    want: %q\n' "$desc" "$got" "$want"
        ((FAIL++))
    fi
}

RED=$'\033[31m'
RESET=$'\033[39m'
BOLD=$'\033[1m'

ELLIPSIS=$'\xe2\x80\xa6'  # U+2026, 3-byte UTF-8

echo "## Plain ASCII"
assert "cut at 5 — last cell replaced by ellipsis" "$(vis_truncate "abcdefgh" 5)"  "abcd${ELLIPSIS}"
assert "under limit — no ellipsis"                 "$(vis_truncate "abc" 10)"       "abc"
assert "exactly at limit — no ellipsis"            "$(vis_truncate "abcde" 5)"      "abcde"
assert "max=0 — empty"                             "$(vis_truncate "abcdef" 0)"    ""
assert "empty input"                               "$(vis_truncate "" 5)"          ""
assert "max=1 with longer input — ellipsis only"   "$(vis_truncate "abc" 1)"       "${ELLIPSIS}"

echo "## SGR pass-through (escapes are 0-cell)"
assert "leading SGR + cut: ellipsis in active color" \
    "$(vis_truncate "${RED}abcdef${RESET}" 3)" \
    "${RED}ab${ELLIPSIS}${RESET}"
assert "mid-string SGR: ellipsis in color active at cut point" \
    "$(vis_truncate "ab${RED}cdef${RESET}" 3)" \
    "ab${RED}${ELLIPSIS}${RESET}"
assert "max=0 still emits reset escapes" \
    "$(vis_truncate $'\033[31mabc\033[0m' 0)" \
    $'\033[31m\033[0m'
assert "no truncation with SGR — no change" \
    "$(vis_truncate "${RED}abc${RESET}" 10)" \
    "${RED}abc${RESET}"

echo "## Multi-byte UTF-8 (1-cell glyphs)"
assert "❶ counted as 1 cell — last cell replaced"  "$(vis_truncate "❶abc" 2)"       "❶${ELLIPSIS}"
assert "❶ at boundary — replaced by ellipsis"      "$(vis_truncate "abc❶def" 4)"    "abc${ELLIPSIS}"
assert "❶ over budget — preceding cell replaced"   "$(vis_truncate "abc❶def" 3)"    "ab${ELLIPSIS}"
assert "4-byte glyph at max=1 — ellipsis only"     "$(vis_truncate "𝐀b" 1)"         "${ELLIPSIS}"
assert "4-byte glyph over budget — prior replaced" "$(vis_truncate "ab𝐀cd" 2)"      "a${ELLIPSIS}"

echo "## vis_truncate does not depend on printf's value for a high byte"
# bash 3.2 (macOS /bin/bash) returns a negative number from printf %d "'<byte>"
# for a byte above 0x7F. Emulate it: every continuation byte then looks like a
# cell if classification goes through that value.
# shellcheck disable=SC2317  # invoked indirectly via vis_truncate
_vt_signed_printf() {
    # shellcheck disable=SC2059  # forwards the caller's format
    builtin printf "$@" || return
    if [[ "$1" == -v && "$3" == %d ]]; then
        local _vt_v=${!2}
        (( _vt_v >= 128 && _vt_v < 256 )) && builtin printf -v "$2" %d $(( _vt_v - 256 ))
    fi
    return 0
}
# shellcheck disable=SC2317  # invoked indirectly via vis_truncate
_vt_r=$( printf() { _vt_signed_printf "$@"; }; vis_truncate "❶abc" 2 )
assert "signed printf: ❶ still one cell"             "$_vt_r" "❶${ELLIPSIS}"
# shellcheck disable=SC2317  # invoked indirectly via vis_truncate
_vt_r=$( printf() { _vt_signed_printf "$@"; }; vis_truncate "ab𝐀cd" 2 )
assert "signed printf: 4-byte glyph over budget"     "$_vt_r" "a${ELLIPSIS}"
# shellcheck disable=SC2030,SC2031  # the subshell isolates LC_ALL
_vt_r=$( LC_ALL=C.UTF-8; vis_truncate "❶abc" 2 )
assert "result is the same under a UTF-8 LC_ALL"      "$_vt_r" "❶${ELLIPSIS}"

echo "## Adversarial CSI"
assert "consecutive SGR codes — ellipsis in last SGR state" \
    "$(vis_truncate $'\033[31m\033[1m\033[7mAB\033[0m' 1)" \
    $'\033[31m\033[1m\033[7m'"${ELLIPSIS}"$'\033[0m'
assert "multi-param SGR (semicolons) — ellipsis" \
    "$(vis_truncate $'\033[1;31;4mAB' 1)" \
    $'\033[1;31;4m'"${ELLIPSIS}"

echo "## ASCII corner cases"
assert "single quote"   "$(vis_truncate "ab'cd" 4)"  "ab'${ELLIPSIS}"
assert "backslash"      "$(vis_truncate 'ab\cd' 4)"  "ab\\${ELLIPSIS}"
# shellcheck disable=SC2016  # single quotes are intentional: testing literal $
assert "dollar sign"    "$(vis_truncate 'ab$cd' 4)"  'ab$'"${ELLIPSIS}"

echo "## vislen invariant: vislen(vis_truncate(s,n)) == min(vislen(s), n)"
LINE="${RED}❶${RESET} Opus  ${BOLD}home${RESET}"
LINE_VIS=$(vislen "$LINE")
for n in 0 1 5 12 20; do
    out=$(vis_truncate "$LINE" "$n")
    got=$(vislen "$out")
    want=$(( n < LINE_VIS ? n : LINE_VIS ))
    if (( got == want )); then
        printf '  OK   n=%d → vislen=%d\n' "$n" "$got"; ((PASS++))
    else
        printf '  FAIL n=%d got=%d want=%d\n' "$n" "$got" "$want"; ((FAIL++))
    fi
done

echo "## emit_truncated"
# Multi-line input: each line truncated independently, joined by newlines.
ml=$(emit_truncated $'aaaaa\nbbbbbbbb\nccc' 3; printf x); ml=${ml%x}
assert "multi-line" "$ml" $'aa'"${ELLIPSIS}"$'\nbb'"${ELLIPSIS}"$'\nccc'

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
assert "window_secs=0 → empty"   "$(window_elapsed_pct $_we_now 0 $_we_now)" ""

echo "## plan_pace_color"
# $RED/$GREEN/$YELLOW resolve from constants already in scope: the test file
# redefines RED to $'\033[31m' (identical to colors.sh); GREEN/YELLOW come from
# the sourced colors.sh.
assert "A>94 → red (beats pace)" "$(plan_pace_color 95 99)" "$RED"
assert "under pace → green"      "$(plan_pace_color 40 50)" "$GREEN"
assert "over pace → yellow"      "$(plan_pace_color 60 50)" "$YELLOW"
assert "tie A==B → yellow"       "$(plan_pace_color 50 50)" "$YELLOW"
assert "A>94 wins over under"    "$(plan_pace_color 95 96)" "$RED"

echo "## _render_plan_window"
# Trivial reset formatter: ignores its arg, returns a fixed string, so
# assertions don't depend on real reset-time formatting.
# shellcheck disable=SC2317  # invoked indirectly via `$reset_fn` in _render_plan_window
_rpw_reset_fn() { echo "12:34"; }

# At-limit branch (A>=100): bold+pace-color spans label, A%/B%, bar, AND the
# reset time — closed by RESET_DIM only at the very end (reviewer-confirmed
# example: A=100, B=50). reset_epoch is now+9000 against an 18000s window, so
# window_elapsed_pct (called internally with no now-override) reads B=50%.
# No glyph: bold+red alone signals at-limit.
_rpw_reset_epoch=$(( $(date +%s) + 9000 ))
_rpw_at_limit=$(_render_plan_window "5h" 100 "$_rpw_reset_epoch" 18000 1 1 _rpw_reset_fn)
_rpw_at_limit_want="${RESET_DIM}${BOLD}${RED}5h ${RED}100%/50% ${RED}█${RESET_DIM}${BOLD}${RED} 12:34${RESET_DIM}"
assert "at-limit: bold+red spans label/pct/bar/reset" "$_rpw_at_limit" "$_rpw_at_limit_want"

# 99 → 100 promotion: the server pins the header at 0.99 while overage absorbs
# the excess, so a saturated window arrives as 99. Renders identically to a
# real 100.
_rpw_capped=$(_render_plan_window "7d" 99 "$_rpw_reset_epoch" 18000 1 1 _rpw_reset_fn)
_rpw_capped_want="${RESET_DIM}${BOLD}${RED}7d ${RED}100%/50% ${RED}█${RESET_DIM}${BOLD}${RED} 12:34${RESET_DIM}"
assert "capped 99 → 100" "$_rpw_capped" "$_rpw_capped_want"

# 98 stays 98: the promotion is exactly one step wide, not a >=99 threshold.
_rpw_98=$(_render_plan_window "7d" 98 "$_rpw_reset_epoch" 18000 1 1 _rpw_reset_fn)
_rpw_98_want="${RESET_DIM}7d ${RED}98%/50% ${RED}█${RESET_DIM} 12:34${RESET_DIM}"
# The want string above also pins NFR5: exactly one RESET_DIM between bar and
# reset time — display_vertical_bar closes the pace colour, the reset time no
# longer re-closes it.
assert "98 not promoted, not at-limit, single colour close" "$_rpw_98" "$_rpw_98_want"

# Missing-resets_at fallback (window_elapsed_pct returns empty): just A%, no
# /B%, no bar even though show_bars=1; red when A>94.
_rpw_fallback_hi=$(_render_plan_window "5h" 95 "" 18000 1 1 _rpw_reset_fn)
_rpw_fallback_hi_want="${RESET_DIM}5h ${RED}95%${RESET_DIM} 12:34${RESET_DIM}"
assert "missing resets_at, A>94 → red, no bar/B%" "$_rpw_fallback_hi" "$_rpw_fallback_hi_want"

# Same fallback, A<=94 → dim (RESET_DIM), not colored. Uses "null" (the other
# window_elapsed_pct empty-trigger) for variety.
_rpw_fallback_lo=$(_render_plan_window "5h" 80 "null" 18000 1 1 _rpw_reset_fn)
_rpw_fallback_lo_want="${RESET_DIM}5h ${RESET_DIM}80%${RESET_DIM} 12:34${RESET_DIM}"
assert "missing resets_at, A<=94 → dim, no bar/B%" "$_rpw_fallback_lo" "$_rpw_fallback_lo_want"

echo "## format_cache_expiry"
assert "empty path → empty"      "$(format_cache_expiry "")"              ""
assert "missing file → empty"    "$(format_cache_expiry "/no/such/file")" ""

# Fresh transcript: assistant entry 59s ago → cache expires in ~4m, output is HH:MM
_ce_now=$(date +%s)
_ce_ts=$(date -d "@$(( _ce_now - 59 ))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         date -r "$(( _ce_now - 59 ))" -u +%Y-%m-%dT%H:%M:%SZ)
_ce_tf=$(mktemp "$TEST_TMP/tmp.XXXXXX")
printf '{"type":"assistant","timestamp":"%s","isSidechain":false,"message":{"usage":{"input_tokens":10,"output_tokens":5}}}\n' \
    "$_ce_ts" > "$_ce_tf"
_ce_result=$(format_cache_expiry "$_ce_tf")
rm -f "$_ce_tf"
if [[ "$_ce_result" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    echo "  OK   fresh cache returns HH:MM: $_ce_result"; (( PASS++ ))
else
    echo "  FAIL fresh cache: expected HH:MM, got '$_ce_result'"; (( FAIL++ ))
fi

# Darwin branch under Linux: stub uname and a BSD-style `date -j -f` that, like
# the real one, rejects text after the format and reads the string in $TZ. Run in
# a non-UTC zone so a local-time parse of the UTC timestamp would land hours off.
# Both a plain and a fractional-seconds timestamp (what transcripts carry) must work.
# The stub computes with GNU date, so it is skipped where only BSD date exists.
_ce_gnu_date=$(command -v date)
# shellcheck disable=SC2317  # invoked indirectly via format_cache_expiry
_ce_bsd_date() {
    if [[ "$1" == -j ]]; then
        [[ "$4" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
        "$_ce_gnu_date" -d "$4" +%s
    elif [[ "$1" == -r ]]; then
        "$_ce_gnu_date" -d "@$2" "$3"
    else
        "$_ce_gnu_date" "$@"
    fi
}
if "$_ce_gnu_date" --version >/dev/null 2>&1; then
    for _ce_frac in "" ".123"; do
        _ce_tsf="${_ce_ts%Z}${_ce_frac}Z"
        _ce_tf4=$(mktemp "$TEST_TMP/tmp.XXXXXX")
        printf '{"type":"assistant","timestamp":"%s","isSidechain":false,"message":{"usage":{"input_tokens":10,"output_tokens":5}}}\n' \
            "$_ce_tsf" > "$_ce_tf4"
        _ce_darwin=$( uname() { echo Darwin; }; date() { _ce_bsd_date "$@"; }
                      TZ=Pacific/Kiritimati format_cache_expiry "$_ce_tf4" )
        rm -f "$_ce_tf4"
        if [[ "$_ce_darwin" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
            echo "  OK   Darwin parse, ts '$_ce_tsf': $_ce_darwin"; (( PASS++ ))
        else
            echo "  FAIL Darwin parse, ts '$_ce_tsf': expected HH:MM, got '$_ce_darwin'"; (( FAIL++ ))
        fi
    done
else
    echo "  SKIP Darwin parse stub: needs GNU date (the real BSD date ran in the test above)"
fi

# Stale transcript: assistant entry 3660s ago (61 min) → cache expired → empty
_ce_ts2=$(date -d "@$(( _ce_now - 3660 ))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
          date -r "$(( _ce_now - 3660 ))" -u +%Y-%m-%dT%H:%M:%SZ)
_ce_tf2=$(mktemp "$TEST_TMP/tmp.XXXXXX")
printf '{"type":"assistant","timestamp":"%s","isSidechain":false,"message":{"usage":{"input_tokens":10,"output_tokens":5}}}\n' \
    "$_ce_ts2" > "$_ce_tf2"
assert "expired cache → empty" "$(format_cache_expiry "$_ce_tf2")" ""
rm -f "$_ce_tf2"

# Transcript with only sidechain assistant entries → empty (filtered out)
_ce_tf3=$(mktemp "$TEST_TMP/tmp.XXXXXX")
printf '{"type":"assistant","timestamp":"%s","isSidechain":true,"message":{"usage":{"input_tokens":10,"output_tokens":5}}}\n' \
    "$_ce_ts" > "$_ce_tf3"
assert "sidechain only → empty" "$(format_cache_expiry "$_ce_tf3")" ""
rm -f "$_ce_tf3"

echo "## render_timer"
assert "empty → nothing"     "$(render_timer "")"      ""
_rt_hg=$'\xef\x89\x92'  # nf-fa-hourglass_half U+F252
assert "value → icon + HH:MM" "$(render_timer "16:20")" "  ${CYAN}${_rt_hg} 16:20${RESET_DIM}"

echo "## _spark_trailing"
# idle=0: running turn → now − turn_start (live)
assert "running, with U start"   "$(_spark_trailing 0 985 940 980 3600)" "45s"
assert "running, no U → from API" "$(_spark_trailing 0 1000 "" 980 3600)" "20s"
# idle=1, within cache TTL → final turn's completed duration (static)
assert "idle fresh → completed dur" "$(_spark_trailing 1 1000 940 980 3600)" "40s"
# idle=1, beyond cache TTL → dropped
assert "idle stale → empty"         "$(_spark_trailing 1 10000 940 980 3600)" ""
# negative clamp
assert "idle negative → 0s"         "$(_spark_trailing 1 1000 990 980 3600)" "0s"
# idle=1, no U → ref falls back to last_api → dur 0
assert "idle, no U → 0s"            "$(_spark_trailing 1 1000 "" 980 3600)" "0s"

echo "## display_turn_sparkline always_on gating (idle fixture)"
EFFECTIVE_COLS=120
_spark_fix=$(mktemp "$TEST_TMP/spark-idle.XXXXXX")  # omit .jsonl suffix; mktemp template must end in X's
cat > "$_spark_fix" <<'JSONL'
{"type":"user","timestamp":"2026-05-26T10:00:00.000Z","message":{"content":"hello"}}
{"type":"assistant","timestamp":"2026-05-26T10:00:08.000Z","requestId":"r1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2000,"output_tokens":300,"cache_read_input_tokens":50000,"cache_creation_input_tokens":0}}}
JSONL
_spark_off=$(display_turn_sparkline "$_spark_fix" "" 0)
_spark_on=$(display_turn_sparkline "$_spark_fix" "" 1)
rm -f "$_spark_fix"
assert "idle, flag off → suppressed" "${_spark_off:+nonempty}" ""
assert "idle, flag on → rendered"    "${_spark_on:+nonempty}"  "nonempty"

echo "## display_turn_sparkline read cell counts cache_creation_input_tokens"
# Steady-state caching: fresh input lands in cache_creation_input_tokens while
# input_tokens drops to ~2. cache_read=0 and output=0 make the cache (1st) and
# write (3rd) cells blank, so a filled block can only come from the read (2nd)
# cell — proving it counts cache_creation_input_tokens (weighted ×2).
EFFECTIVE_COLS=120
_spark_cc=$(mktemp "$TEST_TMP/spark-cc.XXXXXX")
cat > "$_spark_cc" <<'JSONL'
{"type":"user","timestamp":"2026-05-26T10:00:00.000Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-05-26T10:00:08.000Z","requestId":"r1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":22688}}}
JSONL
_spark_cc_out=$(display_turn_sparkline "$_spark_cc" "" 1)
rm -f "$_spark_cc"
case "$_spark_cc_out" in
    *▁*|*▂*|*▃*|*▄*|*▅*|*▆*|*▇*|*█*) _spark_cc_block=yes ;;
    *) _spark_cc_block=no ;;
esac
assert "read cell reflects cache_creation" "$_spark_cc_block" "yes"

echo "## display_turn_sparkline continuation calls split by '·'"
# Two API calls in one user turn (first stop_reason=tool_use, no user prompt
# between) must be separated by a plain '·' so the cell triplets stay legible.
EFFECTIVE_COLS=120
_spark_co=$(mktemp "$TEST_TMP/spark-cont.XXXXXX")
cat > "$_spark_co" <<'JSONL'
{"type":"user","timestamp":"2026-05-27T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-05-27T10:00:05.000Z","requestId":"a1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":300,"cache_read_input_tokens":40000,"cache_creation_input_tokens":8000}}}
{"type":"assistant","timestamp":"2026-05-27T10:00:09.000Z","requestId":"a2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":900,"cache_read_input_tokens":42000,"cache_creation_input_tokens":1500}}}
JSONL
# strip SGR, then keep only the glyph row; expect a '·' between the triplets
_spark_co_plain=$(display_turn_sparkline "$_spark_co" 10 1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_spark_co"
case "$_spark_co_plain" in
    *·*) _spark_co_sep=yes ;;
    *) _spark_co_sep=no ;;
esac
assert "continuation '·' separator present" "$_spark_co_sep" "yes"

echo "## display_turn_sparkline isMeta U does not split a turn"
# An isMeta:true user (skill/slash-command injection) between two calls of one
# turn must NOT force a turn-boundary separator — the calls stay one turn, so a
# '·' continuation appears (with the bug, each call became its own turn and no
# '·' would be emitted).
EFFECTIVE_COLS=120
_spark_meta=$(mktemp "$TEST_TMP/spark-meta.XXXXXX")
cat > "$_spark_meta" <<'JSONL'
{"type":"user","timestamp":"2026-05-27T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-05-27T10:00:05.000Z","requestId":"m1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":300,"cache_read_input_tokens":40000,"cache_creation_input_tokens":8000}}}
{"type":"user","isMeta":true,"sourceToolUseID":"toolu_abc","timestamp":"2026-05-27T10:00:07.000Z","message":{"content":[{"type":"text","text":"skill body injected"}]}}
{"type":"assistant","timestamp":"2026-05-27T10:00:09.000Z","requestId":"m2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":900,"cache_read_input_tokens":42000,"cache_creation_input_tokens":1500}}}
JSONL
_spark_meta_plain=$(display_turn_sparkline "$_spark_meta" 10 1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_spark_meta"
case "$_spark_meta_plain" in
    *·*) _spark_meta_sep=yes ;;
    *) _spark_meta_sep=no ;;
esac
assert "isMeta U does not split sparkline turn" "$_spark_meta_sep" "yes"

echo "## task-notification (subagent completion) is not a turn"
# A <task-notification> user message is a background subagent-completion
# notification injected by the harness (promptSource=system,
# origin.kind=task-notification), not a genuine user turn. It must not start
# or split a turn. Placed between two calls of one turn: with the bug it forced
# a turn boundary (two 1-call turns, no continuation '·'); fixed, the calls
# stay one turn and a '·' continuation appears.
EFFECTIVE_COLS=120
_spark_tn=$(mktemp "$TEST_TMP/spark-tn.XXXXXX")
cat > "$_spark_tn" <<'JSONL'
{"type":"user","timestamp":"2026-05-27T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-05-27T10:00:05.000Z","requestId":"n1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":300,"cache_read_input_tokens":40000,"cache_creation_input_tokens":8000}}}
{"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"timestamp":"2026-05-27T10:00:07.000Z","message":{"content":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>"}}
{"type":"assistant","timestamp":"2026-05-27T10:00:09.000Z","requestId":"n2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":900,"cache_read_input_tokens":42000,"cache_creation_input_tokens":1500}}}
JSONL
_spark_tn_plain=$(display_turn_sparkline "$_spark_tn" 10 1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
case "$_spark_tn_plain" in
    *·*) _spark_tn_sep=yes ;;
    *) _spark_tn_sep=no ;;
esac
assert "task-notification does not split sparkline turn" "$_spark_tn_sep" "yes"

# Same fixture through the stats line: one 2-call turn (single "×" group), not
# two 1-call turns. Count "×" occurrences after stripping SGR.
_stats_tn_plain=$(display_turn_stats "$_spark_tn" 200 | sed 's/\x1b\[[0-9;]*m//g')
rm -f "$_spark_tn"
_stats_tn_groups=$(printf '%s' "$_stats_tn_plain" | grep -o '×' | wc -l | tr -d ' ')
assert "task-notification does not split stats turn" "$_stats_tn_groups" "1"

echo "## humanize_tokens"
assert "sub-k verbatim"      "$(humanize_tokens 999)"      "999"
assert "exact k rounding"    "$(humanize_tokens 364000)"   "364k"
assert "k rounds half-up"    "$(humanize_tokens 1500)"     "2k"
assert "60k"                 "$(humanize_tokens 60000)"    "60k"
assert "zero"                "$(humanize_tokens 0)"        "0"
assert "millions one-dec"    "$(humanize_tokens 1500000)"  "1.5M"
assert "millions strip .0"   "$(humanize_tokens 2000000)"  "2M"
assert "empty → 0"           "$(humanize_tokens "")"       "0"
assert "non-numeric → 0"     "$(humanize_tokens "unset")"  "0"

echo "## format_turn_dur"
assert "seconds"             "$(format_turn_dur 52)"    "52s"
assert "minutes+seconds"     "$(format_turn_dur 130)"   "2m10"
assert "minutes+seconds pad" "$(format_turn_dur 78)"    "1m18"
assert "whole minutes"       "$(format_turn_dur 240)"   "4m"
assert "whole hour"          "$(format_turn_dur 3600)"  "1h"
assert "hours+minutes pad"   "$(format_turn_dur 3900)"  "1h05"
assert "negative → 0s"       "$(format_turn_dur -5)"    "0s"

echo "## _turn_input"
# full formula: 50000 − 12000 + 10000 − 0 = 48000
assert "full formula"        "$(_turn_input 50000 12000 10000 0)"     "48000"
# 1-call turn (out == last_out): cc − prev_last_out
assert "1-call minus prev"   "$(_turn_input 3258 900 900 3000)"       "258"
# first turn: prev_last_out 0
assert "first turn"          "$(_turn_input 60000 12000 12000 0)"     "60000"
# negative clamps to 0
assert "clamp negative"      "$(_turn_input 100 5000 0 0)"            "0"

echo "## _turn_marker"
assert "zero → empty"  "$(_turn_marker 0)"  ""
assert "one → snow"    "$(_turn_marker 1)"  "❄"
assert "three → 3snow" "$(_turn_marker 3)"  "3❄"

echo "## display_turn_stats — aggregation"
EFFECTIVE_COLS=200

# Single 1-call turn: input == cc (out == last_out, prev 0).
_ts_a=$(mktemp "$TEST_TMP/ts-a.XXXXXX")
cat > "$_ts_a" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"a1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":12000,"cache_read_input_tokens":364000,"cache_creation_input_tokens":60000}}}
JSONL
_ts_a_out=$(display_turn_stats "$_ts_a" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_a"
assert "single turn group" "$_ts_a_out" "1× 364k/60k/12k 52s"

# Multi-call turn: count, Σcr, Σout, input over two calls (cr rises, no cold).
_ts_b=$(mktemp "$TEST_TMP/ts-b.XXXXXX")
cat > "$_ts_b" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:20.000Z","requestId":"b1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":2000,"cache_read_input_tokens":150000,"cache_creation_input_tokens":30000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"b2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":10000,"cache_read_input_tokens":190000,"cache_creation_input_tokens":20000}}}
JSONL
_ts_b_out=$(display_turn_stats "$_ts_b" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_b"
# Σcr=340000, input=50000−12000+10000−0=48000, Σout=12000, dur=52s
assert "multi-call group" "$_ts_b_out" "2× 340k/48k/12k 52s"

# prev_last_out correction across a turn boundary: short follow-up after a turn.
_ts_c=$(mktemp "$TEST_TMP/ts-c.XXXXXX")
cat > "$_ts_c" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"c1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":3000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":5000}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:02:18.000Z","requestId":"c2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":900,"cache_read_input_tokens":60000,"cache_creation_input_tokens":3258}}}
JSONL
_ts_c_out=$(display_turn_stats "$_ts_c" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_c"
# turn2 input = 3258−900+900−3000 = 258 (NOT 3258); dur = 78s = 1m18
case "$_ts_c_out" in
    *"1× 60k/258/900 1m18"*) _ts_c_ok=yes ;;
    *) _ts_c_ok=no ;;
esac
assert "prev_last_out correction" "$_ts_c_ok" "yes"

# Running turn: stop != end_turn → duration uses now_override.
_ts_e=$(mktemp "$TEST_TMP/ts-e.XXXXXX")
cat > "$_ts_e" <<'JSONL'
{"type":"user","timestamp":"2025-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2025-06-30T10:00:30.000Z","requestId":"e1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":5000,"cache_read_input_tokens":90000,"cache_creation_input_tokens":8000}}}
JSONL
# anchor epoch = 1751277600 (2025-06-30T10:00:00Z); now = anchor+90 → 1m30
_ts_e_out=$(display_turn_stats "$_ts_e" 200 1751277690 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_e"
assert "running uses now" "$_ts_e_out" "1× 90k/8k/5k 1m30"

# Idle: same shape but end_turn → static dur = last_api − anchor (now ignored).
_ts_i=$(mktemp "$TEST_TMP/ts-i.XXXXXX")
cat > "$_ts_i" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"i1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":5000,"cache_read_input_tokens":90000,"cache_creation_input_tokens":8000}}}
JSONL
_ts_i_out=$(display_turn_stats "$_ts_i" 200 9999999999 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_i"
assert "idle static dur" "$_ts_i_out" "1× 90k/8k/5k 30s"

# Colourised: count bold, cr blue, input green, out yellow (marker checked
# on the cold fixture below). vislen-stripped text assertions above prove the
# numbers are intact; these prove the SGR wraps the right segment.
_ts_m=$(mktemp "$TEST_TMP/ts-m.XXXXXX")
cat > "$_ts_m" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"m1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":12000,"cache_read_input_tokens":364000,"cache_creation_input_tokens":60000}}}
JSONL
_ts_m_raw=$(display_turn_stats "$_ts_m" 200)
rm -f "$_ts_m"
case "$_ts_m_raw" in *"${BOLD}1×"*)    _ts_m_cnt=yes ;; *) _ts_m_cnt=no ;; esac
case "$_ts_m_raw" in *"${BLUE}364k"*)  _ts_m_cr=yes  ;; *) _ts_m_cr=no  ;; esac
case "$_ts_m_raw" in *"${GREEN}60k"*)  _ts_m_in=yes  ;; *) _ts_m_in=no  ;; esac
case "$_ts_m_raw" in *"${YELLOW}12k"*) _ts_m_out=yes ;; *) _ts_m_out=no ;; esac
assert "count is bold"    "$_ts_m_cnt" "yes"
assert "cr is blue"       "$_ts_m_cr"  "yes"
assert "input is green"   "$_ts_m_in"  "yes"
assert "output is yellow" "$_ts_m_out" "yes"

echo "## display_turn_stats — cold-cache detection"
# Single cold event in a 2-call turn: cr drops 100000→0, refresh covers it.
_ts_g=$(mktemp "$TEST_TMP/ts-g.XXXXXX")
cat > "$_ts_g" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:20.000Z","requestId":"g1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":100000,"cache_creation_input_tokens":20000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"g2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":800,"cache_read_input_tokens":0,"cache_creation_input_tokens":120000}}}
JSONL
_ts_g_raw=$(display_turn_stats "$_ts_g" 200)
_ts_g_out=$(printf '%s' "$_ts_g_raw" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_g"
# drop=(100000+20000)−0=120000; refresh=120002≥drop → cold (❄ marker).
# input=Σcc(140000)−Σout(1300)+last_out(800)−0=139500 → 140k: the cache-creation
# spike surfaces directly in input, flagged as a re-cache by the ❄ marker.
assert "single cold → ❄, spike in input" "$_ts_g_out" "❄ 2× 100k/140k/1k 52s"
case "$_ts_g_raw" in *"${BOLD}${CYAN}❄"*) _ts_g_mk=yes ;; *) _ts_g_mk=no ;; esac
assert "marker is bold-cyan" "$_ts_g_mk" "yes"

# Two cold events in one turn, incl. a 0→0 re-expiration.
_ts_h=$(mktemp "$TEST_TMP/ts-h.XXXXXX")
cat > "$_ts_h" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"h1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"h2","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":110000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"h3","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":120000}}}
JSONL
_ts_h_out=$(display_turn_stats "$_ts_h" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_h"
# h2: drop=(100000+10000)−0=110000 → cold. h3 re-expiry:
# drop=(0+110000)−0=110000 → cold. cold_count=2 → "2❄".
case "$_ts_h_out" in
    "2❄ "*) _ts_h_ok=yes ;;
    *) _ts_h_ok=no ;;
esac
assert "two cold (incl re-expiry) → 2❄" "$_ts_h_ok" "yes"

# Context shrink (compaction): cr drops but refresh < drop → NOT cold.
_ts_j=$(mktemp "$TEST_TMP/ts-j.XXXXXX")
cat > "$_ts_j" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:20.000Z","requestId":"j1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":200000,"cache_creation_input_tokens":5000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"j2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":80000,"cache_creation_input_tokens":1000}}}
JSONL
_ts_j_out=$(display_turn_stats "$_ts_j" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_j"
# drop=(200000+5000)−80000=125000; refresh=1002 < drop → NOT cold.
case "$_ts_j_out" in
    *❄*) _ts_j_cold=yes ;;
    *) _ts_j_cold=no ;;
esac
assert "context shrink NOT marked" "$_ts_j_cold" "no"

# Turn-boundary cache churn: cr dips slightly below cap (cr+cc) when a new
# user turn appends a message; refresh(cc+in) trivially covers the small drop.
# This is normal, NOT a cold-cache expiry — must not be marked.
_ts_k=$(mktemp "$TEST_TMP/ts-k.XXXXXX")
cat > "$_ts_k" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"k1","message":{"stop_reason":"end_turn","usage":{"input_tokens":131,"output_tokens":553,"cache_read_input_tokens":77631,"cache_creation_input_tokens":467}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:10.000Z","requestId":"k2","message":{"stop_reason":"end_turn","usage":{"input_tokens":81,"output_tokens":130,"cache_read_input_tokens":75342,"cache_creation_input_tokens":3409}}}
JSONL
_ts_k_out=$(display_turn_stats "$_ts_k" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_k"
# k2: cap=78098, drop=2756, refresh=3490≥drop — but drop is only 3.5% of cap,
# so NOT a cold expiry (real expiry drops cr by ~100%).
case "$_ts_k_out" in
    *❄*) _ts_k_cold=yes ;;
    *) _ts_k_cold=no ;;
esac
assert "boundary churn NOT marked cold" "$_ts_k_cold" "no"

# Cold expiry that coincides with a context shrink: cr collapses to 0 (whole
# prefix expired) but the re-cached context is SMALLER than what was lost, so
# refresh(cc+in) < drop. A full collapse (cr==0) is unconditionally cold — the
# refresh>=drop refinement only governs partial drops (cr>0). Regression for a
# real 11h-idle expiry (session 4999475a) that went unmarked.
_ts_l=$(mktemp "$TEST_TMP/ts-l.XXXXXX")
cat > "$_ts_l" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"l1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0}}}
{"type":"user","timestamp":"2026-06-30T21:00:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T21:00:30.000Z","requestId":"l2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":800,"cache_read_input_tokens":0,"cache_creation_input_tokens":150000}}}
JSONL
_ts_l_out=$(display_turn_stats "$_ts_l" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_l"
# l2: cap=200000, drop=200000, 2*drop>cap; refresh=150002 < drop, but cr==0
# (whole prefix gone) → cold. Marker "❄" on the 2nd (newest) turn.
case "$_ts_l_out" in
    *❄*) _ts_l_cold=yes ;;
    *) _ts_l_cold=no ;;
esac
assert "full collapse (cr=0) marked cold despite shrink" "$_ts_l_cold" "yes"

echo "## display_turn_stats — turn segmentation"
# An isMeta:true user entry (skill activation / slash-command injection, often
# carrying sourceToolUseID) is NOT a user turn — it must not split one real
# turn into multiple groups.
_ts_s=$(mktemp "$TEST_TMP/ts-s.XXXXXX")
cat > "$_ts_s" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"s1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}}
{"type":"user","isMeta":true,"sourceToolUseID":"toolu_abc","timestamp":"2026-06-30T10:00:20.000Z","message":{"content":[{"type":"text","text":"skill body injected"}]}}
{"type":"assistant","timestamp":"2026-06-30T10:00:40.000Z","requestId":"s2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":200,"cache_read_input_tokens":110000,"cache_creation_input_tokens":5000}}}
JSONL
_ts_s_out=$(display_turn_stats "$_ts_s" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_s"
# Both calls belong to one turn: "2×", Σcr=210k, no second group / separator.
# input=Σcc(15000)−Σout(300)+last_out(200)−0−0=14900→15k, dur=40s.
assert "isMeta U does not split turn" "$_ts_s_out" "2× 210k/15k/300 40s"

echo "## display_turn_stats — width truncation"
# Three single-call turns with distinct cr values; tiny budget keeps newest.
_ts_w=$(mktemp "$TEST_TMP/ts-w.XXXXXX")
cat > "$_ts_w" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"w1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":111000,"cache_creation_input_tokens":1000}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:10.000Z","requestId":"w2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":222000,"cache_creation_input_tokens":1000}}}
{"type":"user","timestamp":"2026-06-30T10:02:00.000Z","message":{"content":"q3"}}
{"type":"assistant","timestamp":"2026-06-30T10:02:10.000Z","requestId":"w3","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":333000,"cache_creation_input_tokens":1000}}}
JSONL
# Each group "1× NNNk/1k/1k 10s" ≈ 19 cols; budget 25 keeps only the newest.
_ts_w_out=$(display_turn_stats "$_ts_w" 25 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_w"
case "$_ts_w_out" in *333k*) _ts_w_has_new=yes ;; *) _ts_w_has_new=no ;; esac
case "$_ts_w_out" in *111k*) _ts_w_has_old=yes ;; *) _ts_w_has_old=no ;; esac
case "$_ts_w_out" in " ·"*) _ts_w_lead=yes ;; *) _ts_w_lead=no ;; esac
assert "truncation keeps newest"   "$_ts_w_has_new" "yes"
assert "truncation drops oldest"   "$_ts_w_has_old" "no"
assert "no leading separator"      "$_ts_w_lead"    "no"

# Wide budget keeps all + separator (truncation is conditional).
_ts_w2=$(mktemp "$TEST_TMP/ts-w2.XXXXXX")
cat > "$_ts_w2" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"x1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":111000,"cache_creation_input_tokens":1000}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:10.000Z","requestId":"x2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":222000,"cache_creation_input_tokens":1000}}}
JSONL
_ts_w2_out=$(display_turn_stats "$_ts_w2" 200 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
rm -f "$_ts_w2"
case "$_ts_w2_out" in *111k*222k*) _ts_w2_ok=yes ;; *) _ts_w2_ok=no ;; esac
assert "wide budget keeps all + separator" "$_ts_w2_ok" "yes"
# Separator carries the user think-time gap: x1 lastapi 10:00:10 → x2 anchor
# 10:01:00 = 50s, rendered ' ·50s· ' between the two turn groups.
case "$_ts_w2_out" in *"·50s·"*) _ts_w2_sep=yes ;; *) _ts_w2_sep=no ;; esac
assert "separator carries user wait" "$_ts_w2_sep" "yes"

echo "## render_model_sec"
# Codepoints are pinned as byte escapes so a mangled glyph fails loudly here
# rather than silently rendering as a replacement char in the statusline.
_R1=$'\xe2\x9d\xb6'  # ❶ U+2776  Fable
_R2=$'\xe2\x9d\xb7'  # ❷ U+2777  Opus
_R3=$'\xe2\x9d\xb8'  # ❸ U+2778  Sonnet
_R4=$'\xe2\x9d\xb9'  # ❹ U+2779  Haiku
_ELO=$'\xe2\x97\x8b'      # ○ U+25CB  low
_EME=$'\xe2\x97\x90'      # ◐ U+25D0  medium
_EHI=$'\xe2\x97\x8f'      # ● U+25CF  high
_EXH=$'\xe2\x97\x89'      # ◉ U+25C9  xhigh
_EMX=$'\xe2\x97\x88'      # ◈ U+25C8  max
_FAST=$'\xf3\xb1\x90\x8b' # 󱐋 U+F140B nf-md-lightning_bolt
_NOTH=$'\xf3\xb0\xa5\x93' # 󰥓 U+F0953 nf-md-sleep
_SEXP=$'\xef\x80\x82'     #  U+F002  nf-fa-magnifying_glass  explanatory
_SLRN=$'\xef\x86\x9d'     #  U+F19D  nf-fa-graduation_cap    learning
_SPRO=$'\xef\x81\x90'     #  U+F050  nf-fa-forward_fast      proactive
_SCON=$'\xef\x83\x84'     #  U+F0C4  nf-fa-scissors          concise
_SOTH=$'\xf3\xb0\xb4\x93' # 󰴓 U+F0D13 nf-md-fountain_pen_tip  anything else

# set_model_sec, not $(render_model_sec ...): the group's trailing two-space
# section separator is significant and command substitution would eat it.
set_model_sec _ms full "Opus 5" high false true
# shellcheck disable=SC2154  # set_model_sec assigns _ms indirectly, via printf -v
assert "full: rank glyph + name, effort labelled" "$_ms" \
    "${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high${RESET_DIM}  "
set_model_sec _ms mid "Opus 5" high false true
assert "mid: glyphs only, single-space joins" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI}${RESET_DIM}  "
set_model_sec _ms min "Opus 5" high false true
assert "min == mid when nothink is off" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI}${RESET_DIM}  "

set_model_sec _ms full "Fable 5" "" false true
assert "Fable is rank 1, magenta" "$_ms" "${MAGENTA}${_R1} Fable${RESET_DIM}  "
set_model_sec _ms full "Sonnet 5" "" false true
assert "Sonnet is rank 3, green"  "$_ms" "${GREEN}${_R3} Sonnet${RESET_DIM}  "
set_model_sec _ms full "Haiku 4.5" "" false true
assert "Haiku is rank 4, red"     "$_ms" "${RED}${_R4} Haiku${RESET_DIM}  "

# No rank glyph → nothing to compact to; the display name survives to min.
set_model_sec _ms min "gpt-something" "" false true
assert "unknown model keeps its name at min" "$_ms" "${RED}gpt-something${RESET_DIM}  "

# `effort` is absent from the payload for models without effort support.
set_model_sec _ms full "Opus 5" "" false true
assert "absent effort omits the element" "$_ms" "${YELLOW}${_R2} Opus${RESET_DIM}  "
set_model_sec _ms full "Opus 5" "turbo" false true
assert "unrecognised effort omits the element" "$_ms" "${YELLOW}${_R2} Opus${RESET_DIM}  "

for _e in "low:$_ELO:low" "medium:$_EME:medium" "high:$_EHI:high" \
          "xhigh:$_EXH:xhigh" "max:$_EMX:max"; do
    IFS=: read -r _lvl _g _lbl <<< "$_e"
    set_model_sec _ms full "Opus 5" "$_lvl" false true
    assert "effort $_lvl → glyph + label" "$_ms" \
        "${YELLOW}${_R2} Opus ${RESET_DIM}${_g} ${_lbl}${RESET_DIM}  "
done

set_model_sec _ms full "Opus 5" high true true
assert "fast mode, magenta, after effort" "$_ms" \
    "${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high ${MAGENTA}${_FAST} Fast${RESET_DIM}  "

set_model_sec _ms full "Opus 5" high false false
assert "nothink, red, last" "$_ms" \
    "${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high ${RED}${_NOTH} Nothink${RESET_DIM}  "

# Output style: rune + the (already lowercased) name, uncoloured like effort,
# sitting between effort and fast mode.
for _s in "explanatory:$_SEXP" "learning:$_SLRN" "proactive:$_SPRO" \
          "concise:$_SCON" "mystyle:$_SOTH" "yolo mode:$_SOTH"; do
    IFS=: read -r _sn _sg <<< "$_s"
    set_model_sec _ms full "Opus 5" high false true "$_sn"
    assert "style $_sn → rune + name" "$_ms" \
        "${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high ${RESET_DIM}${_sg} ${_sn}${RESET_DIM}  "
done

# `default` is the absence of a style, and an absent key reads as "".
set_model_sec _ms full "Opus 5" high false true "default"
assert "default style omits the element" "$_ms" \
    "${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high${RESET_DIM}  "
set_model_sec _ms full "Opus 5" high false true ""
assert "absent style omits the element" "$_ms" \
    "${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high${RESET_DIM}  "

set_model_sec _ms full "Opus 5" high true false "learning"
assert "style sits between effort and fast" "$_ms" \
"${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high ${RESET_DIM}${_SLRN} learning ${MAGENTA}${_FAST} Fast ${RED}${_NOTH} Nothink${RESET_DIM}  "

# Style elides exactly like effort: bare rune at mid and min.
set_model_sec _ms mid "Opus 5" high false true "learning"
assert "mid drops the style name" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI} ${RESET_DIM}${_SLRN}${RESET_DIM}  "
set_model_sec _ms min "Opus 5" high false true "learning"
assert "min drops the style name" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI} ${RESET_DIM}${_SLRN}${RESET_DIM}  "

# Nothink keeps its label one level longer than the rest; the join before it is
# a single space like every other, so mid is glyphs + one trailing word.
set_model_sec _ms mid "Opus 5" high true false
assert "mid keeps only the nothink label" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI} ${MAGENTA}${_FAST} ${RED}${_NOTH} Nothink${RESET_DIM}  "
set_model_sec _ms mid "Opus 5" high true false "proactive"
assert "mid with a style is five glyphs + nothink" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI} ${RESET_DIM}${_SPRO} ${MAGENTA}${_FAST} ${RED}${_NOTH} Nothink${RESET_DIM}  "
set_model_sec _ms min "Opus 5" high true false
assert "min is four bare glyphs" "$_ms" \
    "${YELLOW}${_R2} ${RESET_DIM}${_EHI} ${MAGENTA}${_FAST} ${RED}${_NOTH}${RESET_DIM}  "

set_model_sec _ms full "Opus 5" high true false
assert "full: every element labelled" "$_ms" \
"${YELLOW}${_R2} Opus ${RESET_DIM}${_EHI} high ${MAGENTA}${_FAST} Fast ${RED}${_NOTH} Nothink${RESET_DIM}  "

# Widths the elision ladder relies on: each level must be strictly narrower.
set_model_sec _ms full "Opus 5" high true false; _wfull=$(vislen "$_ms")
set_model_sec _ms mid  "Opus 5" high true false; _wmid=$(vislen "$_ms")
set_model_sec _ms min  "Opus 5" high true false; _wmin=$(vislen "$_ms")
assert "full > mid > min" "$(( _wfull > _wmid && _wmid > _wmin ))" "1"
set_model_sec _ms full "Opus 5" high true false explanatory; _wsfull=$(vislen "$_ms")
set_model_sec _ms mid  "Opus 5" high true false explanatory; _wsmid=$(vislen "$_ms")
set_model_sec _ms min  "Opus 5" high true false explanatory; _wsmin=$(vislen "$_ms")
assert "with style: full > mid > min" "$(( _wsfull > _wsmid && _wsmid > _wsmin ))" "1"
# A style costs 2 columns once elided (rune + join), 14 at full (" ⟨rune⟩ explanatory").
assert "style costs 2 columns at mid" "$(( _wsmid - _wmid ))" "2"

echo "## display_token_bar"
_BLK=$'\xe2\x96\x88'  # █ U+2588  full range
_B2=$'\xe2\x96\x82'   # ▂ U+2582
_B3=$'\xe2\x96\x83'   # ▃ U+2583
_B7=$'\xe2\x96\x87'   # ▇ U+2587

assert "zero → nothing"          "$(display_token_bar 0)"      ""
assert "unset → nothing"         "$(display_token_bar unset)"  ""
assert "non-numeric → nothing"   "$(display_token_bar abc)"    ""
assert "empty → nothing"         "$(display_token_bar '')"     ""
assert "partial first range"     "$(display_token_bar 42000)"  "${BLUE}${_B7}${RESET_DIM}"

# 200–250k is BRMAGENTA (plain magenta beside red lacks contrast); from there
# the ranges alternate MAGENTA/BRMAGENTA.
assert "250k → four full + brmagenta full" "$(display_token_bar 250000)" \
    "${BLUE}${_BLK}${GREEN}${_BLK}${YELLOW}${_BLK}${RED}${_BLK}${BRMAGENTA}${_BLK}${RESET_DIM}"
assert "260k → 250-300k range is magenta" "$(display_token_bar 260000)" \
    "${BLUE}${_BLK}${GREEN}${_BLK}${YELLOW}${_BLK}${RED}${_BLK}${BRMAGENTA}${_BLK}${MAGENTA}${_B2}${RESET_DIM}"
assert "320k → alternates back to brmagenta" "$(display_token_bar 320000)" \
    "${BLUE}${_BLK}${GREEN}${_BLK}${YELLOW}${_BLK}${RED}${_BLK}${BRMAGENTA}${_BLK}${MAGENTA}${_BLK}${BRMAGENTA}${_B3}${RESET_DIM}"

# A 1M window is 20 blocks and the alternation is still running at the far end
# (range 19 is odd → magenta). The old five-colour table capped the bar at 5.
_tb=$(display_token_bar 1000000)
assert "1M → 20 blocks"            "$(vislen "$_tb")" "20"
assert "1M ends on a magenta block" \
    "$([[ "$_tb" == *"${MAGENTA}${_BLK}${RESET_DIM}" ]] && echo 1 || echo 0)" "1"

echo "## get_token_color"
assert "199999 → red"       "$(get_token_color 199999)" "$RED"
assert "200000 → brmagenta" "$(get_token_color 200000)" "$BRMAGENTA"
assert "1M → brmagenta"     "$(get_token_color 1000000)" "$BRMAGENTA"
# Runaway guard: absurd totals stop at 32 blocks instead of looping forever.
assert "cap at 32 blocks" "$(vislen "$(display_token_bar 99000000)")" "32"

echo "## display_token_bar — elided"
_ELL=$'\xe2\x8b\xaf'  # ⋯ U+22EF  midline ellipsis (not the … vis_truncate writes)

# 5 head + ⋯ + 2 tail = 8 columns, so elision only pays from 9 blocks (>400k).
# At or below that the two forms must be the very same string, which is what
# makes the ladder's elided rung inert on ordinary sessions.
assert "no-op well below threshold" \
    "$(display_token_bar 320000 elide)" "$(display_token_bar 320000)"
assert "no-op at exactly 8 blocks"  \
    "$(display_token_bar 400000 elide)" "$(display_token_bar 400000)"
assert "9 blocks → elides, saving one column" \
    "$(vislen "$(display_token_bar 450000 elide)")" "8"
assert "9 blocks unelided is still 9" \
    "$(vislen "$(display_token_bar 450000)")" "9"

# 1M: head ramp, one ⋯, then ranges 18 (brmagenta) and 19 (magenta) — the tail
# keeps its true parity so the alternation stays readable through the elision.
assert "1M elided → head ⋯ last two" "$(display_token_bar 1000000 elide)" \
    "${BLUE}${_BLK}${GREEN}${_BLK}${YELLOW}${_BLK}${RED}${_BLK}${BRMAGENTA}${_BLK}${BRMAGENTA}${_ELL}${BRMAGENTA}${_BLK}${MAGENTA}${_BLK}${RESET_DIM}"
assert "1M elided → 8 columns" "$(vislen "$(display_token_bar 1000000 elide)")" "8"
# Opposite tail parity, and a partial final block: the live fill survives.
assert "1.02M elided → magenta full then brmagenta partial" \
    "$(display_token_bar 1020000 elide)" \
    "${BLUE}${_BLK}${GREEN}${_BLK}${YELLOW}${_BLK}${RED}${_BLK}${BRMAGENTA}${_BLK}${BRMAGENTA}${_ELL}${MAGENTA}${_BLK}${BRMAGENTA}${_B3}${RESET_DIM}"
# Width is flat past the threshold — that is the point of the rung.
assert "1.6M elided → still 8 columns" "$(vislen "$(display_token_bar 1600000 elide)")" "8"
# Unknown mode strings are not elision (and one-arg calls must keep working).
assert "unrecognised mode renders whole" \
    "$(display_token_bar 1000000 nope)" "$(display_token_bar 1000000)"

echo "## pick_plan_variant"
assert "picks full when it fits"    "$(pick_plan_variant 20 "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" "FULLPLAN"
assert "degrades to first fitting"  "$(pick_plan_variant 7  "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" "NOLABEL"
assert "picks nobars when tiny"     "$(pick_plan_variant 6  "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" "NOBARS"
assert "none fit → empty (omit)"    "$(pick_plan_variant 3  "FULLPLAN" "NOLABEL" "PERIODS" "NOBARS")" ""
assert "all empty → empty"          "$(pick_plan_variant 40 "" "" "" "")"                              ""

echo "## layout_line1 — tier selection"
# Widths: IDFULL 7, IDMID 6, IDF 4 / IDHEAD 7, IDHM 5, IDH 4 / BR 3,
# CGBAR 6, CGEL 5, CGN 4, PLAN 5, PLANROW 8. All distinct so each rung is
# reachable. In production CGEL == CGBAR below 400k; here they differ so the
# elision rung can be tested in isolation.
_L1_reset() {
    L1_IDFULL="IDFULL " L1_IDFULLM="IDMID " L1_IDFULLC="IDF "
    L1_IDHEAD="IDHEAD " L1_IDHEADM="IDHM " L1_IDHEADC="IDH "
    L1_BRANCH="BR " L1_CGBAR="CGBAR " L1_CGELIDED="CGEL " L1_CGNOBAR="CGN "
    L1_PLAN_INLINE="PLAN " L1_PLANROW="PLANROW "
}

# L0: everything fits one row.
_L1_reset; L1_R1=100 L1_RC=100
assert "L0 single row" "$(layout_line1)" "IDFULL CGBAR PLAN "

# Tier A: L0 (with inline plan) overflows, but identity+ctx(bar) fits → plan wraps.
_L1_reset; L1_R1=13 L1_RC=100
assert "A wraps plan" "$(layout_line1)" $'IDFULL CGBAR \nPLANROW '

# Elide the bar's middle first: full+ctx(bar)=13 overflows R1=12, and
# full+ctx(elided)=12 fits. This rung is spent before the identity labels —
# the hidden ranges are a flat run, so it costs less than any label does.
_L1_reset; L1_R1=12 L1_RC=100
assert "A-1 elides bar middle" "$(layout_line1)" $'IDFULL CGEL \nPLANROW '

# Mid identity: full+ctx(elided)=12 overflows R1=11, mid+ctx(elided)=11 fits.
# The identity labels still go BEFORE the bar is dropped — that ordering is the
# point of this rung, and it is what the pre-identity-group ladder got backwards.
_L1_reset; L1_R1=11 L1_RC=100
assert "A-2 mid identity" "$(layout_line1)" $'IDMID CGEL \nPLANROW '

# Compact identity: mid+ctx(elided)=11 overflows R1=10, compact+ctx(elided)=9 fits.
_L1_reset; L1_R1=10 L1_RC=100
assert "A-3 compact identity" "$(layout_line1)" $'IDF CGEL \nPLANROW '

# Only now the bar: compact+ctx(elided)=9 overflows R1=8, compact+ctx(nobar)=8 fits.
_L1_reset; L1_R1=8 L1_RC=100
assert "A-4 drops bar" "$(layout_line1)" $'IDF CGN \nPLANROW '

# Tier B: even compact identity+ctx overflows R1=7; IDHEAD=7 fits, branch+ctx fits RC.
_L1_reset; L1_R1=7 L1_RC=100
assert "B splits identity" "$(layout_line1)" $'IDHEAD \nBR CGN \nPLANROW '

# Tier B mid head: IDHEAD=7 overflows R1=6, IDHM=5 fits.
_L1_reset; L1_R1=6 L1_RC=100
assert "B mid head" "$(layout_line1)" $'IDHM \nBR CGN \nPLANROW '

# Tier B compact head: IDHM=5 overflows R1=4, IDH=4 fits.
_L1_reset; L1_R1=4 L1_RC=100
assert "B compact head" "$(layout_line1)" $'IDH \nBR CGN \nPLANROW '

# Tier C: branch+ctx (7) overflows RC=6, but branch (3) and ctx (4) each fit alone.
_L1_reset; L1_R1=7 L1_RC=6
assert "C splits branch/ctx" "$(layout_line1)" $'IDHEAD \nBR \nCGN \nPLANROW '

# Tier C mid head: same RC squeeze, IDHEAD=7 overflows R1=6.
_L1_reset; L1_R1=6 L1_RC=6
assert "C mid head" "$(layout_line1)" $'IDHM \nBR \nCGN \nPLANROW '

# Tier C compact head is unconditional — emitted even when it overflows R1
# (emit_line1 hard-truncates it).
_L1_reset; L1_R1=3 L1_RC=6
assert "C compact head unconditional" "$(layout_line1)" $'IDH \nBR \nCGN \nPLANROW '

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

echo "## _tx_cached"
_tc_dir="$TEST_TMP/txc"; TX_CACHE_DIR="$_tc_dir"
_tc_tx="$TEST_TMP/tx-a.jsonl"; _tc_cnt="$TEST_TMP/tx-count"
printf 'one\n' > "$_tc_tx"; : > "$_tc_cnt"
# shellcheck disable=SC2317  # invoked indirectly via _tx_cached
_tc_prod() { echo x >> "$_tc_cnt"; printf 'body:%s\n' "$(wc -c < "$1" | tr -d ' ')"; }
_tc_runs() { wc -l < "$_tc_cnt" | tr -d ' '; }
# A kind is cacheable only if it has a validator (an unknown kind always
# misses); these ad-hoc test kinds accept any body.
# shellcheck disable=SC2317  # invoked indirectly via _tx_body_ok
_tx_valid_k() { return 0; }
# shellcheck disable=SC2317
_tx_valid_other() { return 0; }
# shellcheck disable=SC2317
_tx_valid_e() { return 0; }
assert "miss runs producer"        "$(_tx_cached k "$_tc_tx" _tc_prod)" "body:4"
assert "miss ran it once"          "$(_tc_runs)" "1"
assert "hit returns same body"     "$(_tx_cached k "$_tc_tx" _tc_prod)" "body:4"
assert "hit skips producer"        "$(_tc_runs)" "1"
printf 'longer\n' >> "$_tc_tx"
assert "size change re-runs"       "$(_tx_cached k "$_tc_tx" _tc_prod)" "body:11"
assert "re-ran exactly once more"  "$(_tc_runs)" "2"
assert "kinds are independent"     "$(_tx_cached other "$_tc_tx" _tc_prod)" "body:11"
assert "other kind ran producer"   "$(_tc_runs)" "3"
_tc_empty="$TEST_TMP/tx-empty.jsonl"; : > "$_tc_empty"
assert "empty producer output hits" "$(_tx_cached e "$_tc_empty" printf '')" ""
_tc_tx2="$TEST_TMP/sub/tx-a.jsonl"; mkdir -p "$TEST_TMP/sub"; printf 'zz\n' > "$_tc_tx2"
assert "same basename, other dir"  "$(_tx_cached k "$_tc_tx2" _tc_prod)" "body:3"
assert "no tmp files left behind"  "$(find "$_tc_dir" -name '.tmp.*' | wc -l | tr -d ' ')" "0"
: > "$_tc_cnt"
_tx_cached nov "$_tc_tx" _tc_prod >/dev/null; _tx_cached nov "$_tc_tx" _tc_prod >/dev/null
assert "kind without a validator never hits" "$(_tc_runs)" "2"
# A planted cache file with one huge line and no newline must not be slurped
# into the signature variable: unbounded, the 64 MB read costs seconds per render.
: > "$_tc_cnt"
head -c 64000000 /dev/zero | tr '\0' x > "$_tc_dir/${_tc_tx//\//_}.k"
_tc_t0=$SECONDS
_tc_big=$(_tx_cached k "$_tc_tx" _tc_prod)
_tc_dt=$(( SECONDS - _tc_t0 ))
assert "oversized signature line: miss, producer ran" "$_tc_big|$(_tc_runs)" "body:11|1"
assert "oversized signature line: read is bounded"    "$(( _tc_dt < 2 ))" "1"
assert "oversized signature line: overwritten, next render hits" \
    "$(_tx_cached k "$_tc_tx" _tc_prod)|$(_tc_runs)" "body:11|1"
# An override is held to the same rule as the default dir: a symlink (here to a
# dir the user owns, so only the link check can refuse it) is neither read nor
# written, and the producer output is still returned.
_tc_victim="$TEST_TMP/txc-victim"; mkdir -p "$_tc_victim"
ln -s "$_tc_victim" "$TEST_TMP/txc-link"; TX_CACHE_DIR="$TEST_TMP/txc-link"
: > "$_tc_cnt"
assert "symlinked TX_CACHE_DIR: producer output returned" "$(_tx_cached k "$_tc_tx" _tc_prod)" "body:11"
assert "symlinked TX_CACHE_DIR: nothing written through it" "$(find "$_tc_victim" -mindepth 1 | wc -l | tr -d ' ')" "0"
{ printf '%s\n' "$(_stat_sig "$_tc_tx")"; printf 'planted\n'; } > "$_tc_victim/${_tc_tx//\//_}.k"
assert "symlinked TX_CACHE_DIR: not read through either" "$(_tx_cached k "$_tc_tx" _tc_prod)" "body:11"
rm -f "$_tc_victim"/*
TX_CACHE_DIR="$TEST_TMP/txc-link/"
_tx_cached k "$_tc_tx" _tc_prod >/dev/null
assert "symlinked TX_CACHE_DIR with trailing slash: nothing written through it" "$(find "$_tc_victim" -mindepth 1 | wc -l | tr -d ' ')" "0"
# The default sits in the private state dir.
unset TX_CACHE_DIR
rm -rf "$_st_dir/tx-cache"
_tx_cached k "$_tc_tx" _tc_prod >/dev/null
assert "default tx cache lives in the state dir" "$(find "$_st_dir/tx-cache" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "## get_transcript_context / format_cache_expiry share one pass"
TX_CACHE_DIR="$TEST_TMP/txc2"
_tl="$TEST_TMP/last.jsonl"
{
  printf '{"type":"assistant","timestamp":"2026-01-01T10:00:00.000Z","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}\n'
  printf '{"type":"assistant","isSidechain":true,"timestamp":"2026-01-01T11:00:00.000Z","message":{"usage":{"input_tokens":900}}}\n'
  printf '{"type":"assistant","timestamp":"2026-01-01T12:00:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0}}}\n'
  printf '{"type":"user","timestamp":"2026-01-01T13:00:00.000Z","message":{"content":"hi"}}\n'
} > "$_tl"
assert "context = last non-zero non-sidechain total" "$(get_transcript_context "$_tl")" "10"
assert "no usage anywhere → empty" "$(get_transcript_context "$_tc_empty")" ""
_tl_ts=$(_tx_cached last "$_tl" _tx_last_jq | sed -n 1p)
assert "last ts = last non-sidechain (even zero usage)" "$_tl_ts" "2026-01-01T12:00:00.000Z"
# Window holds only noise → falls back to the whole file.
_tw="$TEST_TMP/window.jsonl"
{ printf '{"type":"assistant","timestamp":"2026-01-02T00:00:00.000Z","message":{"usage":{"output_tokens":7}}}\n'
  for _i in $(seq 1 1600); do printf '{"type":"user","message":{"content":"x"}}\n'; done; } > "$_tw"
assert "full-file fallback when tail window empty" "$(get_transcript_context "$_tw")" "7"
# A call that ran the advisor logs top-level usage summed over its iterations:
# the context is the last `message` iteration (2+155+154816+2518), not the sum.
_ti="$TEST_TMP/iter.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-01-03T00:00:00.000Z","message":{"usage":{"input_tokens":4,"cache_read_input_tokens":299452,"cache_creation_input_tokens":12698,"output_tokens":342,"iterations":[{"type":"message","input_tokens":2,"output_tokens":187,"cache_read_input_tokens":144636,"cache_creation_input_tokens":10180},{"type":"advisor_message","input_tokens":146951,"output_tokens":14732},{"type":"message","input_tokens":2,"output_tokens":155,"cache_read_input_tokens":154816,"cache_creation_input_tokens":2518}]}}}' > "$_ti"
assert "advisor call: last message iteration, not the summed usage" "$(get_transcript_context "$_ti")" "157491"
_te="$TEST_TMP/iter-empty.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-01-03T00:00:00.000Z","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":4,"iterations":[]}}}' > "$_te"
assert "empty iterations: top-level usage" "$(get_transcript_context "$_te")" "10"
unset TX_CACHE_DIR

echo "## planted cache bodies are rejected, never evaluated"
# Only spark/stats fields reach an evaluating sink (bash arithmetic), so the
# `_hx_mark` check guards those kinds. `last` has no evaluating sink: its fields
# are guarded by output comparison (a bypass shows as a different render) or by
# a direct validator check.
TX_CACHE_DIR="$TEST_TMP/txc-hostile"
_hx="$TEST_TMP/hostile.jsonl"
{
  printf '{"type":"user","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":"hi"}}\n'
  printf '{"type":"assistant","requestId":"r1","timestamp":"2026-01-01T10:00:05.000Z","message":{"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3000,"cache_creation_input_tokens":4000}}}\n'
} > "$_hx"
_hx_mark="$TEST_TMP/hostile-ran"
# Plant <body> as a signature-valid cache entry of <kind> for $_hx.
_hx_plant() {
    mkdir -p "$TX_CACHE_DIR"
    { printf '%s\n' "$(_stat_sig "$_hx")"; printf '%s' "$2"; } > "$TX_CACHE_DIR/${_hx//\//_}.$1"
}
_hx_ran() { [[ -e "$_hx_mark" ]] && echo executed || echo clean; }
# Counting producer for this section: prints nothing, appends a line per run.
_hx_cnt="$TEST_TMP/hostile-count"; : > "$_hx_cnt"
# shellcheck disable=SC2317  # invoked via $( )
_hx_runs() { wc -l < "$_hx_cnt" | tr -d ' '; }
# shellcheck disable=SC2317  # invoked indirectly via _tx_cached
_hx_nil() { echo x >> "$_hx_cnt"; }
# shellcheck disable=SC2317
_hx_ok() { _tx_body_ok "$@" && echo ok || echo bad; }
# <n> valid stats "A" lines, each about 96 bytes (40-char <req>, 7-digit counts).
# shellcheck disable=SC2317
_hx_lines() {
    local i
    for ((i = 0; i < $1; i++)); do
        printf 'A r%039d 1767261605 1000000 2000000 3000000 4000000 end_turn\n' "$i"
    done
}
# shellcheck disable=SC2016  # literal $( ) is the payload
# No whitespace (the consumers split lines with `read -r`; ${IFS} expands during
# arithmetic) and a subscript base that exists (this file runs under `set -u`,
# which aborts on an unset `a[…]` before the substitution would run).
_hx_sub='PASS[$(touch${IFS}'"$_hx_mark"')]'

rm -rf "$TX_CACHE_DIR"
_hx_ctx=$(get_transcript_context "$_hx")
_hx_spark=$(display_turn_sparkline "$_hx" 30 1); _hx_stats=$(display_turn_stats "$_hx" 80 1767261610)
assert "fixture: baseline context" "$_hx_ctx" "7003"
assert "fixture: baseline spark non-empty" "$([[ -n "$_hx_spark" ]] && echo yes)" "yes"
assert "fixture: baseline stats non-empty" "$([[ -n "$_hx_stats" ]] && echo yes)" "yes"

rm -rf "$TX_CACHE_DIR"
assert "last: non-ISO timestamp rejected" "$(_hx_ok last $'tomorrow\n7003\n')" "bad"
_hx_plant last $'2026-01-01T10:00:05.000Z\n'"$_hx_sub"$'\n'
assert "last: non-numeric token total rejected" "$(get_transcript_context "$_hx")" "$_hx_ctx"
assert "last: extra line rejected" "$(_tx_body_ok last $'2026-01-01T10:00:05.000Z\n7003\nextra\n' && echo ok || echo bad)" "bad"
assert "last: well-formed body accepted" "$(_tx_body_ok last $'2026-01-01T10:00:05.000Z\n7003\n' && echo ok || echo bad)" "ok"
assert "last: line after a blank line rejected" "$(_tx_body_ok last $'2026-01-01T10:00:05.000Z\n7003\n\nextra\n' && echo ok || echo bad)" "bad"
assert "last: CR-terminated token rejected" "$(_tx_body_ok last $'2026-01-01T10:00:05.000Z\n7003\r\n' && echo ok || echo bad)" "bad"
assert "last: leading-zero token rejected (octal)" "$(_hx_ok last $'2026-01-01T10:00:05.000Z\n08\n')" "bad"
assert "last: 19-digit token rejected (overflow)" "$(_hx_ok last $'2026-01-01T10:00:05.000Z\n1000000000000000000\n')" "bad"
assert "last: zero token accepted" "$(_hx_ok last $'2026-01-01T10:00:05.000Z\n0\n')" "ok"
assert "last: 18-digit token accepted" "$(_hx_ok last $'2026-01-01T10:00:05.000Z\n999999999999999999\n')" "ok"

# Integers: no leading zeros (`08` is an invalid octal base in arithmetic) and at
# most 18 digits (a signed 64-bit integer). Zero stays valid (missing timestamp,
# zero counts).
assert "spark: leading-zero <c> rejected" "$(_hx_ok spark $'U 1767261600\nA r1 1767261605 08 300 0 tool_use\n')" "bad"
assert "spark: leading-zero U epoch rejected" "$(_hx_ok spark $'U 0123\nA r1 1767261605 1 2 3 tool_use\n')" "bad"
assert "stats: leading-zero <cr> rejected" "$(_hx_ok stats $'U 1767261600\nA r1 1767261605 08 0 0 0 end_turn\n')" "bad"
assert "stats: leading-zero U epoch rejected" "$(_hx_ok stats $'U 0123\nA r1 1767261605 1 2 3 4 end_turn\n')" "bad"
assert "spark: 19-digit <o> rejected (overflow)" "$(_hx_ok spark $'U 1767261600\nA r1 1767261605 1 2 1000000000000000000 tool_use\n')" "bad"
assert "spark: zero fields accepted" "$(_hx_ok spark $'U 0\nA r1 0 0 0 0 tool_use\n')" "ok"
assert "spark: 18-digit <o> accepted" "$(_hx_ok spark $'U 1767261600\nA r1 1767261605 1 2 999999999999999999 tool_use\n')" "ok"
rm -rf "$TX_CACHE_DIR"
_hx_plant spark $'U 1767261600\nA r1 1767261605 08 300 0 tool_use\n'
_hx_out=$(display_turn_sparkline "$_hx" 30 1 2>"$TEST_TMP/hostile-err")
assert "spark: leading-zero body is a miss, not rendered" "$_hx_out" "$_hx_spark"
assert "spark: leading-zero body raises no arithmetic error" "$(cat "$TEST_TMP/hostile-err")" ""

# Every numeric position rejects the payload on its own, and the ones whose sink
# evaluates it (spark <ts> <c> <i> <o>) render the baseline and run nothing.
rm -rf "$TX_CACHE_DIR"; rm -f "$_hx_mark"
assert "spark: planted U epoch rejected" "$(_hx_ok spark "U $_hx_sub"$'\nA r1 1767261605 1 2 3 tool_use\n')" "bad"
_hx_names=(ts c i o)
for _hx_p in 0 1 2 3; do
    _hx_f=(1767261605 300 5 7); _hx_f[_hx_p]=$_hx_sub
    _hx_b=$(printf 'U 1767261600\nA r1 %s %s %s %s tool_use\n' "${_hx_f[0]}" "${_hx_f[1]}" "${_hx_f[2]}" "${_hx_f[3]}")$'\n'
    assert "spark: planted <${_hx_names[_hx_p]}> rejected" "$(_hx_ok spark "$_hx_b")" "bad"
    _hx_plant spark "$_hx_b"
    assert "spark: planted <${_hx_names[_hx_p]}> renders the baseline" "$(display_turn_sparkline "$_hx" 30 1)" "$_hx_spark"
done
# A tab inside <req> is one field to the validator but two to `read -r`, which
# would shift the payload into <epoch>.
_hx_plant spark "A r1"$'\t'"$_hx_sub 1 300 0 10 end_turn"$'\n'
assert "spark: tab-smuggled field rejected" "$(display_turn_sparkline "$_hx" 30 1)" "$_hx_spark"
assert "spark: nothing executed" "$(_hx_ran)" "clean"

rm -rf "$TX_CACHE_DIR"; rm -f "$_hx_mark"
assert "stats: planted U epoch rejected" "$(_hx_ok stats "U $_hx_sub"$'\nA r1 1767261605 1 2 3 4 end_turn\n')" "bad"
_hx_plant stats "U $_hx_sub"$'\nA r1 1767261605 1 2 3 4 end_turn\n'
assert "stats: planted U epoch renders the baseline" "$(display_turn_stats "$_hx" 80 1767261610)" "$_hx_stats"
_hx_names=(ts cr cc out in)
for _hx_p in 0 1 2 3 4; do
    _hx_f=(1767261605 1 2 3 4); _hx_f[_hx_p]=$_hx_sub
    _hx_b=$(printf 'U 1767261600\nA r1 %s %s %s %s %s end_turn\n' "${_hx_f[0]}" "${_hx_f[1]}" "${_hx_f[2]}" "${_hx_f[3]}" "${_hx_f[4]}")$'\n'
    assert "stats: planted <${_hx_names[_hx_p]}> rejected" "$(_hx_ok stats "$_hx_b")" "bad"
    _hx_plant stats "$_hx_b"
    assert "stats: planted <${_hx_names[_hx_p]}> renders the baseline" "$(display_turn_stats "$_hx" 80 1767261610)" "$_hx_stats"
done
_hx_plant stats "U 1767261600"$'\n'"A r1"$'\t'"$_hx_sub 1 1 1 1 1 end_turn"$'\n'
assert "stats: tab-smuggled field rejected" "$(display_turn_stats "$_hx" 80 1767261610)" "$_hx_stats"
assert "stats: nothing executed" "$(_hx_ran)" "clean"

# The validator must accept only on positive evidence: a payload on line 1 of a
# body longer than a pipe buffer is the case a `pipefail` pipeline into
# `grep -q` waved through (SIGPIPE turned the verdict into acceptance).
rm -rf "$TX_CACHE_DIR"; rm -f "$_hx_mark"
_hx_pad=$(_hx_lines 1400)
_hx_plant stats "U 1767261600"$'\n'"A r1 1767261605 $_hx_sub 0 0 0 end_turn"$'\n'"$_hx_pad"$'\n'
assert "stats: padded planted body rejected under pipefail" "$(display_turn_stats "$_hx" 80 1767261610)" "$_hx_stats"
assert "stats: padded planted body ran nothing" "$(_hx_ran)" "clean"
# shellcheck disable=SC2123  # deliberate: no grep on PATH
assert "validator rejects when grep cannot run" "$(PATH=/nonexistent/dir; _hx_ok stats $'U 1\nA r1 5 1 2 3 4 end_turn\n')" "bad"

# Bounds: the producers emit at most one line per input line of a 1500-line
# window, so no legitimate body is longer; a planted one would otherwise cost
# the consumers' superlinear scan on every render.
_hx_b1500="U 1767261600"$'\n'"$(_hx_lines 1499)"$'\n'
_hx_b1501="U 1767261600"$'\n'"$(_hx_lines 1500)"$'\n'
assert "stats: exactly 1500 lines accepted" "$(_hx_ok stats "$_hx_b1500")" "ok"
assert "stats: 1501 lines rejected" "$(_hx_ok stats "$_hx_b1501")" "bad"
printf -v _hx_big '%0400000d' 0
assert "spark: 400000-character <req> rejected" "$(_hx_ok spark $'U 1767261600\nA '"$_hx_big"$' 1767261605 1 2 3 tool_use\nA r2 1767261606 1 2 3 tool_use\n')" "bad"
rm -rf "$TX_CACHE_DIR"
_hx_plant stats "$_hx_b1501"
assert "stats: planted 1501-line body renders the baseline" "$(display_turn_stats "$_hx" 80 1767261610)" "$_hx_stats"
printf -v _hx_big '%0500000d' 0
_hx_plant stats $'U 1767261600\nA '"$_hx_big"$' 1767261605 1 2 3 4 end_turn\n'
assert "stats: planted 500000-byte body renders the baseline" "$(display_turn_stats "$_hx" 80 1767261610)" "$_hx_stats"

# An empty stream is a valid body for every kind, so a transcript with no turns
# keeps hitting instead of re-running jq on every render.
rm -rf "$TX_CACHE_DIR"; : > "$_hx_cnt"
_tx_cached spark "$_hx" _hx_nil >/dev/null; _tx_cached spark "$_hx" _hx_nil >/dev/null
assert "empty spark stream is a cache hit" "$(_hx_runs)" "1"
rm -rf "$TX_CACHE_DIR"; : > "$_hx_cnt"
_tx_cached stats "$_hx" _hx_nil >/dev/null; _tx_cached stats "$_hx" _hx_nil >/dev/null
assert "empty stats stream is a cache hit" "$(_hx_runs)" "1"

# Real producer output must validate, or every render silently re-runs jq.
rm -rf "$TX_CACHE_DIR"; : > "$_hx_cnt"
get_transcript_context "$_hx" >/dev/null
display_turn_sparkline "$_hx" 30 1 >/dev/null; display_turn_stats "$_hx" 80 1767261610 >/dev/null
for _hx_k in last spark stats; do _tx_cached "$_hx_k" "$_hx" _hx_nil >/dev/null; done
assert "real producer bodies are cache hits" "$(_hx_runs)" "0"
rm -rf "$TX_CACHE_DIR"; : > "$_hx_cnt"
# shellcheck disable=SC2317  # invoked indirectly via _tx_cached
_hx_prod() { echo x >> "$_hx_cnt"; printf 'U 1\nA r1 5 1 2 3 4 end_turn\n'; }
_tx_cached stats "$_hx" _hx_prod >/dev/null; _tx_cached stats "$_hx" _hx_prod >/dev/null
assert "valid stats body is a cache hit" "$(_hx_runs)" "1"
unset TX_CACHE_DIR

echo "## statusline-command.sh payload parsing (one jq fork, no eval)"
_sp_home="$TEST_TMP/sphome"; mkdir -p "$_sp_home/.claude"
echo api > "$_sp_home/.claude/account-mode"
_sp_run() { # $1=payload json
    printf '%s' "$1" | HOME="$_sp_home" COLUMNS=200 MODE_FILE="$_sp_home/.claude/account-mode" \
        TX_CACHE_DIR="$TEST_TMP/txc3" bash "$HERE/statusline-command.sh" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
}
# shellcheck disable=SC2016  # literal $( ) is the point of this fixture
_sp_out=$(_sp_run '{"model":{"display_name":"Evil\"; touch '"$TEST_TMP"'/pwned; $(touch '"$TEST_TMP"'/pwned2) |x"},"thinking":{"enabled":false},"output_style":{"name":"Concise"}}')
# shellcheck disable=SC2016
assert "hostile model name rendered literally" "$([[ "$_sp_out" == *'Evil"; touch '*'$(touch '*') |x'* ]] && echo yes)" "yes"
assert "no eval: nothing executed" "$([[ -e "$TEST_TMP/pwned" || -e "$TEST_TMP/pwned2" ]] && echo executed || echo clean)" "clean"
_sp_out1=$(_sp_run '{"model":{"display_name":"Opus 4.8"},"thinking":{"enabled":false},"output_style":{"name":"Concise"}}')
assert "thinking=false → Nothink shown" "$([[ "$_sp_out1" == *Nothink* ]] && echo yes)" "yes"
assert "absent effort + style still parsed" "$([[ "$_sp_out1" == *'Opus '*concise* ]] && echo yes)" "yes"
_sp_out2=$(_sp_run '{"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"fast_mode":true,"cost":{"total_cost_usd":1.5}}')
# shellcheck disable=SC2016  # literal $ in the cost
assert "effort/fast/cost fields land in the right slots" \
    "$([[ "$_sp_out2" == *'Opus ● high'* && "$_sp_out2" == *Fast* && "$_sp_out2" == *'$1.50'* && "$_sp_out2" != *Nothink* ]] && echo yes)" "yes"
echo plan > "$_sp_home/.claude/account-mode"
_sp_out3=$(_sp_run '{"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":null},"seven_day":{"used_percentage":50}}}')
assert "plan limits: 0% window present, 7d present" "$([[ "$_sp_out3" == *'5h '*'0%'* && "$_sp_out3" == *'7d '*'50%'* ]] && echo yes)" "yes"
_sp_out4=$(_sp_run '{"model":{"display_name":"Opus 4.8"}}')
assert "plan limits absent → no Plan section" "$([[ "$_sp_out4" == *Plan* ]] && echo shown || echo hidden)" "hidden"
assert "empty payload exits 0" "$(printf '' | HOME="$_sp_home" bash "$HERE/statusline-command.sh" >/dev/null 2>&1; echo $?)" "0"

echo "## statusline-line2 selects the last line"
_l2_tx="$TEST_TMP/l2.jsonl"
cat > "$_l2_tx" <<'JSONL'
{"type":"user","timestamp":"2026-05-26T10:00:00.000Z","message":{"content":"hello"}}
{"type":"assistant","timestamp":"2026-05-26T10:00:08.000Z","requestId":"r1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2000,"output_tokens":300,"cache_read_input_tokens":50000,"cache_creation_input_tokens":0}}}
JSONL
_l2_payload=$(jq -cn --arg tp "$_l2_tx" '{model: {display_name: "Opus 4.8"}, transcript_path: $tp}')
_l2_lines() { # $1=statusline-line2 content ("" = no file) → line count
    rm -f "$_sp_home/.claude/statusline-line2"
    [[ -n "$1" ]] && printf '%s\n' "$1" > "$_sp_home/.claude/statusline-line2"
    _sp_run "$_l2_payload" | wc -l | tr -d ' '
}
touch "$_sp_home/.claude/sparkline-always-on"
_l2_default=$(_l2_lines '')
_l2_off=$(_l2_lines off)
assert "off drops the sparkline line (default and sparkline keep it)" "$(_l2_lines sparkline)|$(( _l2_default - _l2_off ))" "$_l2_default|1"
assert "surrounding whitespace is ignored" "$(_l2_lines ' off ')" "$_l2_off"
rm -f "$_sp_home/.claude/statusline-line2" "$_sp_home/.claude/sparkline-always-on"

echo "## private state directory"
_st_payload='{"model":{"display_name":"Opus 4.8"}}'
_st_run() { # $1=state dir → "<exit status>|<output or none>|<stderr: clean or noisy>"
    local out rc err="$TEST_TMP/st-err"
    out=$(printf '%s' "$_st_payload" | HOME="$_sp_home" COLUMNS=200 \
        MODE_FILE="$_sp_home/.claude/account-mode" CC_STATUSLINE_STATE_DIR="$1" bash "$HERE/statusline-command.sh" 2>"$err")
    rc=$?
    printf '%s|%s|%s' "$rc" "$([[ "$out" == *Opus* ]] && echo output || echo none)" \
        "$([[ -s "$err" ]] && echo noisy || echo clean)"
}
_st_good="$TEST_TMP/st-good"
assert "good dir: render exits 0 with output" "$(_st_run "$_st_good")" "0|output|clean"
assert "good dir: payload dumped there" "$(cat "$_st_good/statusbar.json" 2>/dev/null)" "$_st_payload"
# shellcheck disable=SC2012  # only the mode column is read; stat -c/-f diverge
assert "good dir: created 0700" "$(ls -ld "$_st_good" 2>/dev/null | cut -c1-10)" "drwx------"

# The timing log needs GNU `date +%s%3N`; where it is unavailable no log is kept.
if [[ "$(date +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
    for _st_i in $(seq 1 8000); do printf '2026-01-01T00:00:00+00:00 %dms\n' "$_st_i"; done > "$_st_good/statusline-timing.log"
    _st_run "$_st_good" >/dev/null
    assert "oversized timing log is started over" "$(wc -l < "$_st_good/statusline-timing.log" | tr -d ' ')" "1"
fi

# A symlinked state dir is refused even when it points at a dir the user owns.
_st_victim="$TEST_TMP/st-victim"; mkdir -p "$_st_victim"
ln -s "$_st_victim" "$TEST_TMP/st-link"
assert "symlinked dir: render exits 0 with output" "$(_st_run "$TEST_TMP/st-link")" "0|output|clean"
assert "symlinked dir: nothing written through it" "$(find "$_st_victim" -mindepth 1 | wc -l | tr -d ' ')" "0"
printf 'keep' > "$TEST_TMP/st-file"
assert "regular file as dir: render exits 0 with output" "$(_st_run "$TEST_TMP/st-file")" "0|output|clean"

# Symlinks planted inside a verified dir are replaced or skipped, never followed.
_st_plant="$TEST_TMP/st-plant"; mkdir -m 700 "$_st_plant"
printf 'ORIG' > "$TEST_TMP/st-dump-victim"; printf 'ORIG' > "$TEST_TMP/st-log-victim"
ln -s "$TEST_TMP/st-dump-victim" "$_st_plant/statusbar.json"
ln -s "$TEST_TMP/st-log-victim" "$_st_plant/statusline-timing.log"
assert "planted links: render exits 0 with output" "$(_st_run "$_st_plant")" "0|output|clean"
assert "planted dump link: target untouched" "$(cat "$TEST_TMP/st-dump-victim")" "ORIG"
assert "planted dump link: replaced by the dump" \
    "$([[ -f "$_st_plant/statusbar.json" && ! -L "$_st_plant/statusbar.json" ]] && cat "$_st_plant/statusbar.json")" "$_st_payload"
assert "planted log link: target untouched" "$(cat "$TEST_TMP/st-log-victim")" "ORIG"

echo "## cc_state_dir_init resolution"
assert "XDG_RUNTIME_DIR used when no override" \
    "$(unset CC_STATUSLINE_STATE_DIR; XDG_RUNTIME_DIR="$TEST_TMP/xdg" cc_state_dir_init; echo "${CC_STATE_DIR:-}")" "$TEST_TMP/xdg/cc-statusline"
assert "\$HOME/.cache fallback without XDG_RUNTIME_DIR" \
    "$(unset CC_STATUSLINE_STATE_DIR; HOME="$TEST_TMP/rh" cc_state_dir_init; echo "${CC_STATE_DIR:-}")" "$TEST_TMP/rh/.cache/cc-statusline"
assert "relative override refused" \
    "$(cd "$TEST_TMP" && CC_STATUSLINE_STATE_DIR=rel cc_state_dir_init; echo "${CC_STATE_DIR:-none}"; [[ -e rel ]] && echo created)" "none"
assert "symlinked override refused" \
    "$(CC_STATUSLINE_STATE_DIR="$TEST_TMP/st-link" cc_state_dir_init; echo "${CC_STATE_DIR:-none}")" "none"
assert "symlinked override with trailing slashes refused" \
    "$(CC_STATUSLINE_STATE_DIR="$TEST_TMP/st-link//" cc_state_dir_init; echo "${CC_STATE_DIR:-none}")" "none"
assert "trailing slash on a good override is dropped" \
    "$(CC_STATUSLINE_STATE_DIR="$_st_good/" cc_state_dir_init; echo "${CC_STATE_DIR:-none}")" "$_st_good"

echo "## kilos: integer path matches printf %.0f of n/1000"
_kl=ok
for _kl_v in 1000 1499 1500 2500 3500 9999 59714 116499 116500 117500 202467 999499 999500 1000000 1234567; do
    _kl_want=$(printf '%2.0fk' "$(bc -l <<< "$_kl_v / 1000")")
    [[ "$(kilos "$_kl_v" 3)" == "$_kl_want" ]] || _kl="$_kl_v: $(kilos "$_kl_v" 3) ≠ $_kl_want"
done
assert "same text as the bc path, ties to even" "$_kl" "ok"
assert "below 1000 unchanged" "$(kilos 999 3)|$(kilos 0 3)|$(kilos '' 3)" "999|  0| - "

echo "## _stat_sig"
printf 'abcde' > "$TEST_TMP/sig-file"
assert "size:mtime of a file" "$(_stat_sig "$TEST_TMP/sig-file")" "5:$(stat -c %Y "$TEST_TMP/sig-file" 2>/dev/null || stat -f %m "$TEST_TMP/sig-file")"
assert "missing file → 0:0" "$(_stat_sig "$TEST_TMP/no-such-file")" "0:0"

echo "## vislen_v counts what vislen counts"
_vlv=ok _vlv_n=
for _vlv_s in "" "abc" "${RED}ab${RESET}c" $'\033[38;5;12m❶\033[0m x' "𝐀b…" $'\033[49m\033[39m' "a${BOLD}m${RESET}m" "⛁ 117k ██▃"; do
    vislen_v _vlv_n "$_vlv_s"
    [[ "$_vlv_n" == "$(vislen "$_vlv_s")" ]] || _vlv="$(printf '%q' "$_vlv_s") → $_vlv_n"
done
assert "same width on plain, SGR-laden and multibyte strings" "$_vlv" "ok"

echo "## token_bar_width matches display_token_bar"
_tbw=ok _tbw_w=
for _tbw_v in 0 1 49999 50000 50001 116800 400000 400001 1000000 1600000 5000000 '' x; do
    for _tbw_m in '' elide; do
        token_bar_width _tbw_w "$_tbw_v" $_tbw_m
        [[ "$_tbw_w" == "$(vislen "$(display_token_bar "$_tbw_v" $_tbw_m)")" ]] || _tbw="$_tbw_v $_tbw_m"
    done
done
assert "width equals the rendered bar's" "$_tbw" "ok"

echo "## subagent row: model id → display name"
assert "opus id"                 "$(sa_model_name claude-opus-5-5)"            "Opus 5.5"
assert "fable id"                "$(sa_model_name claude-fable-5-1)"           "Fable 5.1"
assert "date-suffixed sonnet id" "$(sa_model_name claude-sonnet-4-5-20250929)" "Sonnet 4.5"
assert "haiku id"                "$(sa_model_name claude-haiku-4-5-20251001)"  "Haiku 4.5"
assert "context-window suffix"   "$(sa_model_name 'claude-opus-4-8[1m]')"      "Opus 4.8"
assert "major-only id"           "$(sa_model_name claude-opus-5)"              "Opus 5"
assert "old version-first id"    "$(sa_model_name claude-3-5-sonnet-20241022)" "Sonnet 3.5"
assert "unknown shape passes through" "$(sa_model_name gpt-something)"         "gpt-something"
assert "empty → empty"           "$(sa_model_name '')"                         ""

echo "## subagent row: status"
assert "running: cyan play + elapsed" "$(sa_status_sec running 252)" "${CYAN}▶ 4m12${RESET_FG}"
assert "completed: green check"       "$(sa_status_sec completed '')" "${GREEN}✔${RESET_FG}"
assert "failed: red cross"            "$(sa_status_sec failed '')"    "${RED}✘${RESET_FG}"
assert "killed: yellow square"        "$(sa_status_sec killed '')"    "${YELLOW}■${RESET_FG}"
assert "unknown status: plain ?"      "$(sa_status_sec paused '')"    "?"
assert "running without elapsed"      "$(sa_status_sec running '')"   "${CYAN}▶${RESET_FG}"

echo "## subagent row: label"
assert "type only"     "$(sa_label '' general-purpose)"   "general-purpose"
assert "name and type" "$(sa_label scout Explore)"        "scout (Explore)"
assert "name only"     "$(sa_label scout '')"             "scout"
assert "neither"       "$(sa_label '' '')"                ""

echo "## subagent row: assembly and width"
_sa_strip() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }
_sa_ic=$'\xef\x87\x80'
_sa_st=$(sa_status_sec running 252)
_sa_r() { sa_row "$1" "$_sa_st" general-purpose claude-opus-5-5 high 116800; }
_sa_pre="▶ 4m12  general-purpose  ❷ Opus ● high  $_sa_ic 117k"
assert "wide: every element"                 "$(_sa_strip "$(_sa_r 200)")" "$_sa_pre ██▃"
assert "50 cols: the bar just fits"          "$(_sa_strip "$(_sa_r 50)")" "$_sa_pre ██▃"
assert "49 cols: the bar goes first"         "$(_sa_strip "$(_sa_r 49)")" "$_sa_pre"
assert "45 cols: then the model/effort labels" "$(_sa_strip "$(_sa_r 45)")" "▶ 4m12  general-purpose  ❷ ●  $_sa_ic 117k"
assert "30 cols: then the agent label is cut" "$(_sa_strip "$(_sa_r 30)")" "▶ 4m12  general-…  ❷ ●  $_sa_ic 117k"
assert "20 cols: agent label dropped"         "$(_sa_strip "$(_sa_r 20)")" "▶ 4m12  ❷ ●  $_sa_ic 117k"
_sa_fit=ok
for _sa_cols in 1 5 10 15 20 24 30 40 45 49 50 51 60 80; do
    _sa_wd=$(vislen "$(_sa_r "$_sa_cols")")
    (( _sa_wd <= _sa_cols )) || _sa_fit="$_sa_cols cols → $_sa_wd"
done
assert "never wider than columns" "$_sa_fit" "ok"
assert "1M context: bar elided before it is dropped" \
    "$(_sa_strip "$(sa_row 57 "$_sa_st" general-purpose claude-opus-5-5 high 1000000)")" \
    "▶ 4m12  general-purpose  ❷ Opus ● high  $_sa_ic 1000k █████⋯██"
assert "no model, effort or tokens" "$(_sa_strip "$(sa_row 80 "$_sa_st" general-purpose '' '' '')")" "▶ 4m12  general-purpose"
assert "numeric effort budget is omitted" \
    "$(_sa_strip "$(sa_row 80 "$_sa_st" '' claude-sonnet-5-5 16000 5000)")" "▶ 4m12  ❸ Sonnet  $_sa_ic  5k ▁"
assert "gauge uses the line-1 value colour" \
    "$([[ "$(sa_row 80 "$_sa_st" x '' '' 116800)" == *"${YELLOW}${_sa_ic} 117k"* ]] && echo yes)" "yes"

echo "## subagent-statusline.sh end to end"
_sa_now_ms=$(( $(date +%s) * 1000 ))
# Sanitized from a real capture (subagent-payload.json): session id and paths
# replaced, a named failed task and an effort added to cover those fields.
_sa_payload=$(jq -c --argjson st $(( _sa_now_ms - 125000 )) '.tasks[0].startTime = $st' <<'JSON'
{"session_id":"00000000-0000-0000-0000-000000000000","transcript_path":"/work/sess.jsonl","cwd":"/work/repo","prompt_id":"11111111-1111-1111-1111-111111111111","columns":95,"tasks":[
 {"id":"a1b2","type":"local_agent","agentType":"general-purpose","status":"running","description":"Remove cost estimate, build agent rows","label":"Editing CLAUDE.md","startTime":0,"model":"claude-opus-5-5","contextWindowSize":1000000,"tokenCount":116800,"tokenSamples":[94248,99361,110659,116800],"cwd":"/work/repo"},
 {"id":"c3d4","type":"local_agent","agentType":"general-purpose","status":"completed","description":"Survey","label":"Survey","startTime":1794003820486,"model":"claude-sonnet-5-5","contextWindowSize":1000000,"tokenCount":59714,"tokenSamples":[59714],"cwd":"/work/repo"},
 {"id":"e5f6","name":"scout","type":"local_agent","agentType":"Explore","status":"failed","description":"Look around","label":"Look around","startTime":1794003820486,"effort":"high","tokenCount":0,"tokenSamples":[],"cwd":"/work/repo"}]}
JSON
)
_sa_state="$TEST_TMP/sa-state"
_sa_run() { # $1=stdin → stdout; stderr discarded, exit status appended as "rc=N"
    local out rc
    out=$(printf '%s' "$1" | HOME="$_sp_home" CC_STATUSLINE_STATE_DIR="$_sa_state" \
        bash "$HERE/subagent-statusline.sh" 2>/dev/null)
    rc=$?
    printf '%s\nrc=%d' "$out" "$rc"
}
_sa_out=$(_sa_run "$_sa_payload")
assert "one JSON line per task, ids echoed in order, exit 0" \
    "$(printf '%s\n' "$_sa_out" | sed '$d' | jq -r .id 2>&1 | paste -sd, -)|${_sa_out##*$'\n'}" "a1b2,c3d4,e5f6|rc=0"
_sa_rows=$(printf '%s\n' "$_sa_out" | sed '$d' | jq -r .content 2>/dev/null)
_sa_r1=$(_sa_strip "$(sed -n 1p <<< "$_sa_rows")")
assert "running row: status, type, model, gauge" \
    "$([[ "$_sa_r1" =~ ^▶\ 2m0[456]\ \ general-purpose\ \ ❷\ Opus\ \ $_sa_ic\ 117k\ ██▃$ ]] && echo yes || printf '%q' "$_sa_r1")" "yes"
assert "completed row" \
    "$(_sa_strip "$(sed -n 2p <<< "$_sa_rows")")" "✔  general-purpose  ❸ Sonnet  $_sa_ic 60k █▂"
assert "failed row: name, effort, zero gauge" \
    "$(_sa_strip "$(sed -n 3p <<< "$_sa_rows")")" "✘  scout (Explore)  ● high  $_sa_ic   0"
_sa_wide=ok
while IFS= read -r _sa_line; do
    (( $(vislen "$_sa_line") <= 95 )) || _sa_wide=$(vislen "$_sa_line")
done <<< "$_sa_rows"
assert "rows fit the payload's columns" "$_sa_wide" "ok"
assert "rows never change intensity (panel dim state unknown)" \
    "$([[ "$_sa_rows" == *$'\033[2m'* || "$_sa_rows" == *$'\033[22m'* || "$_sa_rows" == *$'\033[0m'* ]] && echo touched || echo clean)" "clean"
assert "payload dumped to the state dir" "$(cat "$_sa_state/subagent-payload.json" 2>/dev/null)" "$_sa_payload"
_sa_narrow=$(_sa_run "$(jq -c '.columns = 30' <<< "$_sa_payload")")
_sa_nw=ok
while IFS= read -r _sa_line; do
    (( $(vislen "$_sa_line") <= 30 )) || _sa_nw=$(vislen "$_sa_line")
done <<< "$(printf '%s\n' "$_sa_narrow" | sed '$d' | jq -r .content 2>/dev/null)"
assert "30 columns: rows still fit" "$_sa_nw" "ok"
assert "garbage stdin: no output, exit 0" "$(_sa_run 'not json {')" $'\nrc=0'
assert "empty stdin: no output, exit 0"   "$(_sa_run '')" $'\nrc=0'
assert "no tasks: no output, exit 0"      "$(_sa_run '{"tasks":[]}')" $'\nrc=0'
assert "tasks not an array: no output, exit 0" "$(_sa_run '{"tasks":"x"}')" $'\nrc=0'

echo
if (( FAIL == 0 )); then
    printf 'PASS  %d tests\n' "$PASS"
    exit 0
else
    printf 'FAIL  %d failed, %d passed\n' "$FAIL" "$PASS"
    exit 1
fi
