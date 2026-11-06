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
_sl_start_ms=$(date +%s%3N 2>/dev/null); [[ "$_sl_start_ms" =~ ^[0-9]+$ ]] || _sl_start_ms=0

# Every payload field the script uses, in ONE jq fork (statusline-design.md
# §4.18). Fields are joined by U+001F: unlike tab/space it is not IFS
# whitespace, so empty fields survive `read` instead of collapsing and shifting
# the rest. Free-text fields (model, dir, style) may contain anything but a
# newline or U+001F, and nothing is eval'd.
#
# Booleans use `== true` / `!= false`, NOT `//`: jq's alternative operator
# treats `false` as falsy, so `.thinking.enabled // true` yields true exactly
# when thinking is DISABLED (§4.17). The output style is downcased here, not in
# model-display.sh: bash 3.2 has no ${var,,} and this fork already runs.
# CONTEXT_TOKENS is the sum of current_usage's fields, or "unset" when the field
# is null (early in a session) so the caller falls back to the transcript.
# shellcheck disable=SC2034  # FIVE_*/SEVEN_* are consumed by render_plan_right
IFS=$'\x1f' read -r MODEL CURRENT_DIR TRANSCRIPT_PATH CONTEXT_TOKENS COST \
    EFFORT FAST_MODE THINKING FIVE_RAW FIVE_RESET SEVEN_RAW SEVEN_RESET OUTPUT_STYLE \
    <<< "$(echo "$input" | jq -r '
    [ (.model.display_name // "Unknown"),
      (.workspace.current_dir // ""),
      (.transcript_path // ""),
      (.context_window.current_usage // null |
          if . == null then "unset"
          else ((.input_tokens // 0) + (.output_tokens // 0) +
                (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
          end),
      (.cost.total_cost_usd // "unset"),
      (.effort.level // ""),
      (.fast_mode == true),
      (.thinking.enabled != false),
      (.rate_limits.five_hour.used_percentage // "absent"),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // "absent"),
      (.rate_limits.seven_day.resets_at // ""),
      (.output_style.name // "" | ascii_downcase)
    ] | map(tostring) | join("\u001f")' 2>/dev/null)"

# Resolve the script's real directory. Claude Code reaches this script through
# a symlink (~/.claude/statusline-command.sh), and bash 3.2 / macOS has no
# `readlink -f`, so walk the link chain by hand.
_src=${BASH_SOURCE[0]}
while [ -L "$_src" ]; do
    _dir=$(cd "$(dirname "$_src")" && pwd -P)
    _src=$(readlink "$_src")
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR=$(cd "$(dirname "$_src")" && pwd -P)
unset _src _dir

# Account-validation library (get_mode, get_api_provider, validate_state) lives
# outside this repo, next to the claude-account switcher. Resolution order:
#   1. $CC_STATUSLINE_ACCOUNT_LIB
#   2. first line of ~/.claude/statusline-account-lib
#   3. $HOME/code/cc-switch/lib/account-validation.sh
# When the file is absent the account badge is skipped: mode defaults to "plan"
# and the state is treated as consistent.
if [[ -z "${CC_STATUSLINE_ACCOUNT_LIB:-}" && -r "$HOME/.claude/statusline-account-lib" ]]; then
    IFS= read -r CC_STATUSLINE_ACCOUNT_LIB < "$HOME/.claude/statusline-account-lib" || true
fi
: "${CC_STATUSLINE_ACCOUNT_LIB:=$HOME/code/cc-switch/lib/account-validation.sh}"

# Source modules in dependency order
# shellcheck source=lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh" || exit 1
# shellcheck source=lib/model-display.sh
source "$SCRIPT_DIR/lib/model-display.sh" || exit 1
# shellcheck source=lib/format-utils.sh
source "$SCRIPT_DIR/lib/format-utils.sh" || exit 1
# shellcheck source=lib/transcript-cache.sh
source "$SCRIPT_DIR/lib/transcript-cache.sh" || exit 1
# shellcheck source=lib/sparkline.sh
source "$SCRIPT_DIR/lib/sparkline.sh" || exit 1
# shellcheck source=lib/turn-stats.sh
source "$SCRIPT_DIR/lib/turn-stats.sh" || exit 1
# shellcheck source=lib/context-display.sh
source "$SCRIPT_DIR/lib/context-display.sh" || exit 1
if [[ -r "$CC_STATUSLINE_ACCOUNT_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$CC_STATUSLINE_ACCOUNT_LIB" || exit 1
else
    get_mode() { echo plan; }
    get_api_provider() { echo anthropic; }
    validate_state() { return 0; }
fi
# shellcheck source=lib/account-display.sh
source "$SCRIPT_DIR/lib/account-display.sh" || exit 1
# shellcheck source=lib/line1-layout.sh
source "$SCRIPT_DIR/lib/line1-layout.sh" || exit 1
# shellcheck source=lib/subagent-cost.sh
source "$SCRIPT_DIR/lib/subagent-cost.sh" || exit 1

# Wrapper for statusline (historically uses get_account_mode)
get_account_mode() { get_mode; }

MODE=$(get_account_mode)
PROVIDER=$(get_api_provider)

STATUSLINE_COLS=$(get_cols)
# Claude Code reserves ~3 columns of TUI chrome around the statusline.
# Anything we emit beyond `cols-3` triggers terminal wrap, and Claude Code
# then drops subsequent statusline rows. Claude Code also draws a ~4-column
# right-edge indicator block (system notifications, the `/rc` marker, mode
# labels) on the FIRST row only — but EVERY row must reserve that space: if any
# row fills the full width, the block gets pushed out after the whole status
# block instead of sitting at the right edge of row 1. Both reservations are
# folded in here, so every line — line 1, its wrapped continuation rows, line 2,
# and the sparkline/stats line — inherits the same budget.
#
# The indicator block's width is NOT observable: it is not in the statusline
# JSON payload and not in the environment. Claude Code builds it as an
# unshrinkable (`flexShrink:0`) chain of ` · `-joined labels — `/rc` or
# `/rc active`, then `focus` (focus mode), then `memory paused` — inside a
# `flexWrap:"wrap"` row. So it either fits beside row 1 or wraps whole onto its
# own row below the status block; it never truncates. The default 4 covers the
# common `/rc` (3 + 1 column gap). Widen it via `~/.claude/statusline-chrome-cols`
# when running with extra labels permanently on (`/rc · focus` needs 12,
# `/rc active · focus · memory paused` needs 35) — at the cost of those columns
# on every row. Leaving it at 4 is also fine: the only consequence is the
# indicator block taking its own row.
CHROME_COLS=$(cat "$HOME/.claude/statusline-chrome-cols" 2>/dev/null)
[[ "$CHROME_COLS" =~ ^[0-9]+$ ]] || CHROME_COLS=4
EFFECTIVE_COLS=$((STATUSLINE_COLS > 3 ? STATUSLINE_COLS - 3 : STATUSLINE_COLS))
EFFECTIVE_COLS=$((EFFECTIVE_COLS > CHROME_COLS ? EFFECTIVE_COLS - CHROME_COLS : EFFECTIVE_COLS))

# ===============================================
# DISPLAY LOGIC BEGINS
# ===============================================

# Identity group — model rank, reasoning effort, output style, fast mode,
# nothink — in three presentations the line-1 ladder elides through: full
# (glyph + label each), mid (glyphs, nothink still labelled), min (glyphs only).
# shellcheck disable=SC2153
set_model_sec MODEL_FULL    full "$MODEL" "$EFFORT" "$FAST_MODE" "$THINKING" "$OUTPUT_STYLE"
set_model_sec MODEL_MID     mid  "$MODEL" "$EFFORT" "$FAST_MODE" "$THINKING" "$OUTPUT_STYLE"
set_model_sec MODEL_COMPACT min  "$MODEL" "$EFFORT" "$FAST_MODE" "$THINKING" "$OUTPUT_STYLE"

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
    PYENV_SEC="${RESET_DIM}${GREEN}${ICON_PYTHON}${RESET_DIM} "
fi

# Directory section (nerd-font folder). Always shown.
ICON_DIR=$''
DIR_SEC="${RESET_DIM}${CYAN}${ICON_DIR} $DIR_DISPLAY${RESET_DIM}  "

# Branch section (nerd-font git branch). Green when clean, bold-yellow when dirty.
ICON_GIT=$''
BRANCH_SEC=""
if [ -n "$BRANCH" ]; then
    GIT_STATUS=$(git status --porcelain 2>/dev/null)
    if [ -n "$GIT_STATUS" ]; then
        BRANCH_SEC="${RESET_DIM}${YELLOW}${ICON_GIT}${BOLD} $BRANCH${RESET_DIM}  "
    else
        BRANCH_SEC="${RESET_DIM}${GREEN}${ICON_GIT} $BRANCH${RESET_DIM}  "
    fi
fi

# Fold in the cost of this session's subagents (payload cost is main-thread
# only). Kept before COST_SEC so the displayed $ reflects the aggregate.
if [[ "$COST" != "unset" ]]; then
    _sub_cost=$(session_subagent_cost "$TRANSCRIPT_PATH")
    COST=$(awk -v a="$COST" -v b="$_sub_cost" 'BEGIN { printf "%.8f", a + b }')
fi

# Cost section
if [ "$COST" = "unset" ]; then
    COST_SEC="${RESET_DIM}${BOLD}\$${RESET_DIM} -     "
else
    COST_SEC="${RESET_DIM}${BOLD}\$${RESET_DIM}$(printf "%2.2f" "$COST")  "
fi

# Context usage: prefer current_usage from statusbar, fallback to transcript
if [[ "$CONTEXT_TOKENS" == "unset" || "$CONTEXT_TOKENS" == "0" ]]; then
    CONTEXT_TOKENS=$(get_transcript_context "$TRANSCRIPT_PATH")
fi

context_color=$(get_token_color "$CONTEXT_TOKENS")
ICON_CONTEXT=$''
CTX_SEC="${RESET_DIM}${context_color}${ICON_CONTEXT} $(kilos "$CONTEXT_TOKENS" 3)${RESET_DIM}"
# The space belongs to the bar, not to the value: when the bar is absent —
# dropped by the ladder, or empty because context is 0/unparseable — the
# separator goes with it, leaving the timer's own 2-space section gap.
BAR_SEC="$(display_token_bar "$CONTEXT_TOKENS")"
[[ -n "$BAR_SEC" ]] && BAR_SEC=" ${BAR_SEC}"
# Middle-elided bar for the narrow rung of the ladder (§4.12). Identical to
# BAR_SEC below 400k, where eliding would cost a column instead of saving any.
BAR_ELIDED_SEC="$(display_token_bar "$CONTEXT_TOKENS" elide)"
[[ -n "$BAR_ELIDED_SEC" ]] && BAR_ELIDED_SEC=" ${BAR_ELIDED_SEC}"

# Cache-expiry timer as its own section (never dropped; glued after context).
CACHE_EXPIRY=$(format_cache_expiry "$TRANSCRIPT_PATH")
TIMER_SEC=$(render_timer "$CACHE_EXPIRY")

# Context group travels as a unit: cost → context value → [bar] → timer.
CG_BAR="${COST_SEC}${CTX_SEC}${BAR_SEC}${TIMER_SEC}"
CG_ELIDED="${COST_SEC}${CTX_SEC}${BAR_ELIDED_SEC}${TIMER_SEC}"
CG_NOBAR="${COST_SEC}${CTX_SEC}${TIMER_SEC}"

# ── Line 1: tiered wrap layout ────────────────────────────────────────────
# Every row shares one budget: EFFECTIVE_COLS already reserves the right-edge
# chrome (system notifications / the /rc marker). The marker only overlays
# row 1, but every row reserves the space so it stays at row 1's right edge.
L1_R1=$EFFECTIVE_COLS
L1_RC=$EFFECTIVE_COLS

# Identity atoms (never dropped): model + pyenv + dir + branch. Three model
# presentations → three widths per atom; the ladder picks among them.
L1_IDFULL="${MODEL_FULL}${PYENV_SEC}${DIR_SEC}${BRANCH_SEC}"
# shellcheck disable=SC2034  # consumed by layout_line1 in lib/line1-layout.sh
L1_IDFULLM="${MODEL_MID}${PYENV_SEC}${DIR_SEC}${BRANCH_SEC}"
L1_IDFULLC="${MODEL_COMPACT}${PYENV_SEC}${DIR_SEC}${BRANCH_SEC}"
L1_IDHEAD="${MODEL_FULL}${PYENV_SEC}${DIR_SEC}"
# shellcheck disable=SC2034  # consumed by layout_line1 in lib/line1-layout.sh
L1_IDHEADM="${MODEL_MID}${PYENV_SEC}${DIR_SEC}"
L1_IDHEADC="${MODEL_COMPACT}${PYENV_SEC}${DIR_SEC}"
L1_BRANCH="$BRANCH_SEC"
L1_CGBAR="$CG_BAR"
# shellcheck disable=SC2034  # consumed by layout_line1 in lib/line1-layout.sh
L1_CGELIDED="$CG_ELIDED"
L1_CGNOBAR="$CG_NOBAR"

# Plan variants (plan-mode only). L1_PLAN_INLINE is the full plan for L0;
# L1_PLANROW is the richest style that fits a continuation row (or "" → omit).
L1_PLAN_INLINE=""
L1_PLANROW=""
if [[ "$MODE" == "plan" ]]; then
    _plan_full=$(render_plan_right full)
    if [[ -n "$_plan_full" ]]; then
        L1_PLAN_INLINE="  ${_plan_full}"
        L1_PLANROW=$(pick_plan_variant "$L1_RC" \
            "$_plan_full" \
            "$(render_plan_right no_plan_label)" \
            "$(render_plan_right no_period_labels)" \
            "$(render_plan_right no_bars)")
    fi
fi

emit_line1

# API mode: emit account line 2 (Plan mode: plan status is already on line 1)
if [[ "$MODE" != "plan" ]]; then
    account_buf=$(render_account; printf x); account_buf=${account_buf%x}
    echo
    emit_truncated "$account_buf" "$EFFECTIVE_COLS"
fi

# Selectable second line. ~/.claude/statusline-line2 = "stats" → per-turn
# numeric stats; anything else (default) → the per-API-call sparkline. Both
# renderers are width-aware by construction and emit their own leading
# newline only when there's content to show.
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    line2_mode=sparkline
    if [[ -f "$HOME/.claude/statusline-line2" ]]; then
        line2_mode=$(<"$HOME/.claude/statusline-line2")
        line2_mode=${line2_mode//[[:space:]]/}
    fi
    if [[ "$line2_mode" == "stats" ]]; then
        display_turn_stats "$TRANSCRIPT_PATH" "$EFFECTIVE_COLS"
    else
        # ~/.claude/sparkline-always-on: keep the sparkline visible when idle
        spark_always_on=0
        [[ -f "$HOME/.claude/sparkline-always-on" ]] && spark_always_on=1
        display_turn_sparkline "$TRANSCRIPT_PATH" "" "$spark_always_on"
    fi
fi

# Ensure script exits successfully
_sl_end_ms=$(date +%s%3N 2>/dev/null); [[ "$_sl_end_ms" =~ ^[0-9]+$ ]] || _sl_end_ms=0
if (( _sl_start_ms > 0 && _sl_end_ms > 0 )); then
    printf '%s %dms\n' "$(date -Iseconds)" "$(( _sl_end_ms - _sl_start_ms ))" \
        >> /tmp/claude/statusline-timing.log
fi

exit 0
