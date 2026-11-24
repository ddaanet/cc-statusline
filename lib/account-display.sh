#!/usr/bin/env bash
# Account display functions for the statusline.
# Deps (source before this file): colors.sh, format-utils.sh, account-validation.sh (from ../cc-switch)
# Globals consumed: GREEN YELLOW RED MAGENTA BOLD RESET_DIM
# Globals consumed (set by orchestrator): $input $MODE $PROVIDER

# shellcheck disable=SC2154  # input, MODE, PROVIDER are globals set by orchestrator

# Display vertical progress bar in a caller-supplied color.
# $1=utilization (0-100) $2=color escape
display_vertical_bar() {
    local utilization=$1 color=$2
    local util_int; util_int=$(printf "%.0f" "$utilization")
    local idx=$(( (util_int * 8 + 50) / 100 ))
    [[ $idx -gt 8 ]] && idx=8
    [[ $idx -lt 0 ]] && idx=0
    case $idx in
        0) echo -n "${color} ${RESET_DIM}" ;;  # Empty space for 0%
        1) echo -n "${color}▁${RESET_DIM}" ;;
        2) echo -n "${color}▂${RESET_DIM}" ;;
        3) echo -n "${color}▃${RESET_DIM}" ;;
        4) echo -n "${color}▄${RESET_DIM}" ;;
        5) echo -n "${color}▅${RESET_DIM}" ;;
        6) echo -n "${color}▆${RESET_DIM}" ;;
        7) echo -n "${color}▇${RESET_DIM}" ;;
        8) echo -n "${color}█${RESET_DIM}" ;;
    esac
}

# Display API token usage from stats-cache.json
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
        echo -n "${RESET_DIM}${MAGENTA}$(humanize_tokens "$today_opus")${RESET_DIM}"
        any_today=true
    fi
    if [[ "$today_sonnet" != "0" ]]; then
        [[ "$any_today" == true ]] && echo -n "${RESET_DIM}/"
        echo -n "${RESET_DIM}${YELLOW}$(humanize_tokens "$today_sonnet")${RESET_DIM}"
        any_today=true
    fi
    if [[ "$today_haiku" != "0" ]]; then
        [[ "$any_today" == true ]] && echo -n "${RESET_DIM}/"
        echo -n "${RESET_DIM}${GREEN}$(humanize_tokens "$today_haiku")${RESET_DIM}"
        any_today=true
    fi
    [[ "$any_today" == true ]] && echo -n " today"

    # Display week
    local any_week=false
    if [[ "$week_opus" != "0" || "$week_sonnet" != "0" || "$week_haiku" != "0" ]]; then
        [[ "$any_today" == true ]] && echo -n "  "
        if [[ "$week_opus" != "0" ]]; then
            echo -n "${RESET_DIM}${MAGENTA}$(humanize_tokens "$week_opus")${RESET_DIM}"
            any_week=true
        fi
        if [[ "$week_sonnet" != "0" ]]; then
            [[ "$any_week" == true ]] && echo -n "${RESET_DIM}/"
            echo -n "${RESET_DIM}${YELLOW}$(humanize_tokens "$week_sonnet")${RESET_DIM}"
            any_week=true
        fi
        if [[ "$week_haiku" != "0" ]]; then
            [[ "$any_week" == true ]] && echo -n "${RESET_DIM}/"
            echo -n "${RESET_DIM}${GREEN}$(humanize_tokens "$week_haiku")${RESET_DIM}"
            any_week=true
        fi
        echo -n " 7d"
    fi
}

# Top-level account status renderer
render_account() {
    if validate_state; then
        # API mode (plan-mode status is rendered on line 1 by render_plan_right)
        echo -n "${YELLOW}API${RESET_DIM}  "

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
    else
        echo -n "${RED}Auth state inconsistent - run 'claude-account status'${RESET_DIM}"
    fi
}

# Render one rate-limit window: "<label> A%/B% C <reset>" with pace color.
# $1=label $2=used_raw $3=reset_epoch $4=window_secs
# $5=show_periods (0/1) $6=show_bars (0/1) $7=reset_formatter_fn name
_render_plan_window() {
    local label=$1 used_raw=$2 reset_epoch=$3 window_secs=$4
    local show_periods=$5 show_bars=$6 reset_fn=$7

    local a; a=$(printf '%.0f' "$used_raw")

    # The server pins the unified `-utilization` header at 0.99 while overage
    # credits absorb the excess, so a saturated window reaches the payload as
    # 99, never 100 (see statusline-design.md §4.15). Promote 99 → 100; a
    # literal 100 is flagged the same way — bold + red is enough, no glyph.
    if (( a == 99 )); then
        a=100
    fi

    local b; b=$(window_elapsed_pct "$reset_epoch" "$window_secs")
    local at_limit=0; (( a >= 100 )) && at_limit=1

    local color
    if [[ -n "$b" ]]; then
        color=$(plan_pace_color "$a" "$b")
    elif (( a > 94 )); then
        color=$RED
    else
        color=$RESET_DIM
    fi

    echo -n "${RESET_DIM}"
    (( at_limit )) && echo -n "${BOLD}${color}"
    (( show_periods )) && echo -n "${label} "

    # A%/B% in pace color
    printf '%s%2d%%' "$color" "$a"
    [[ -n "$b" ]] && printf '/%d%%' "$b"

    # Tracks whether the pace colour is still open, so the reset time doesn't
    # re-close what display_vertical_bar already closed (NFR5).
    local color_open=1

    if (( show_bars )) && [[ -n "$b" ]]; then
        echo -n ' '
        display_vertical_bar "$a" "$color"   # closes with RESET_DIM itself
        if (( at_limit )); then
            echo -n "${BOLD}${color}"        # reopen: bold+red spans the reset time
        else
            color_open=0
        fi
    fi

    local reset_str; reset_str=$($reset_fn "$reset_epoch")
    if [[ -n "$reset_str" ]]; then
        (( ! at_limit && color_open )) && echo -n "${RESET_DIM}"
        echo -n " $reset_str"
    fi

    echo -n "${RESET_DIM}"
}

# Render the cache-expiry timer as its own section (mode-independent).
# $1 = pre-formatted HH:MM string (empty → nothing). Prepends a 2-space gap
# and the nf-fa-hourglass_half glyph (U+F252).
render_timer() {
    local cache_expiry=$1
    [[ -z "$cache_expiry" ]] && return
    local _hg=$'\xef\x89\x92'
    echo -n "  ${CYAN}${_hg} ${cache_expiry}${RESET_DIM}"
}

# Read the Fable weekly window the cc-statusline mod writes (hooks/fable.ts,
# statusline-design.md §4.20) into FABLE_RAW / FABLE_RESET.
#   $1 = state dir ("" → absent)   $2 = session id   $3 = now, epoch seconds
# The mod writes one file per session, fable-<session id>, so a figure never
# crosses an account switch. It holds one "<percent> <reset_epoch>" line.
# Anything else, a missing file, or a reset already past leaves
# FABLE_RAW="absent", FABLE_RESET="".
read_fable_limit() {
    FABLE_RAW=absent FABLE_RESET=""
    local _fl_p="" _fl_r="" _fl_f
    [[ -n "$1" && "$2" =~ ^[A-Za-z0-9-]{1,64}$ ]] || return 0
    _fl_f="$1/fable-$2"
    [[ -f "$_fl_f" && ! -L "$_fl_f" ]] || return 0
    IFS=' ' read -r _fl_p _fl_r _ < "$_fl_f" 2>/dev/null || [[ -n "$_fl_r" ]] || return 0
    [[ "$_fl_p" =~ ^[0123456789]{1,3}$ && "$_fl_r" =~ ^[0123456789]{1,12}$ ]] || return 0
    [[ "$3" =~ ^[0123456789]{1,12}$ ]] || return 0
    (( 10#$_fl_r > 10#$3 )) || return 0
    FABLE_RAW=$((10#$_fl_p)) FABLE_RESET=$((10#$_fl_r))
    return 0
}

# Render plan rate-limit status for the right side of line 1.
# $1=style: "full" | "no_plan_label" | "no_period_labels" | "no_bars"
# Reads globals: FIVE_RAW, FIVE_RESET, FABLE_RAW, FABLE_RESET, SEVEN_RAW,
# SEVEN_RESET, color constants. Windows render in that order, joined by " / ".
# Emits nothing when no window is present.
render_plan_right() {
    local style=${1:-full}

    # FIVE_RAW/FIVE_RESET/SEVEN_RAW/SEVEN_RESET come from the payload's single
    # jq fork in statusline-command.sh ("absent" when the window has no
    # used_percentage). This runs up to four times per render, one per style.
    # shellcheck disable=SC2153  # globals set by statusline-command.sh
    local five_raw=$FIVE_RAW five_reset=$FIVE_RESET
    # shellcheck disable=SC2153
    local seven_raw=$SEVEN_RAW seven_reset=$SEVEN_RESET
    # FABLE_* come from read_fable_limit; unset reads as absent.
    local fable_raw=${FABLE_RAW:-absent} fable_reset=${FABLE_RESET-}

    # Nothing to show when no window's data is present.
    [[ "$five_raw" == "absent" && "$fable_raw" == "absent" && "$seven_raw" == "absent" ]] && return

    local show_periods=1 show_bars=1 show_plan_label=0
    [[ "$style" == "no_period_labels" || "$style" == "no_bars" ]] && show_periods=0
    [[ "$style" == "no_bars" ]] && show_bars=0
    [[ "$style" == "full" ]] && show_plan_label=1

    echo -n "${RESET_DIM}"
    (( show_plan_label )) && echo -n "${GREEN}Plan ${RESET_DIM}"

    local rendered=0
    if [[ "$five_raw" != "absent" ]]; then
        _render_plan_window "5h" "$five_raw" "$five_reset" 18000 \
            "$show_periods" "$show_bars" format_5h_reset
        rendered=1
    fi

    if [[ "$fable_raw" != "absent" ]]; then
        (( rendered )) && echo -n " / "
        _render_plan_window "Fable" "$fable_raw" "$fable_reset" 604800 \
            "$show_periods" "$show_bars" format_7d_reset
        rendered=1
    fi

    if [[ "$seven_raw" != "absent" ]]; then
        (( rendered )) && echo -n " / "
        _render_plan_window "7d" "$seven_raw" "$seven_reset" 604800 \
            "$show_periods" "$show_bars" format_7d_reset
    fi
}
