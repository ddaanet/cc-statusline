#!/usr/bin/env bash
# Line-1 identity group: model rank, reasoning effort, output style, fast mode,
# nothink.
# Pure — reads only the colour constants from colors.sh, writes only stdout.
# See statusline-design.md §4.17 for the glyph tables and the spacing rule.

# Echo the identity group at one of three presentation levels.
#   $1 level    full | mid | min
#   $2 name     .model.display_name
#   $3 effort   low|medium|high|xhigh|max, or "" when the payload omits the key
#   $4 fast     "true" | "false"   (.fast_mode)
#   $5 thinking "true" | "false"   (.thinking.enabled)
#   $6 style    .output_style.name, ALREADY LOWERCASED by the extractor — the
#               label is the name itself, and the caller's jq can downcase for
#               free where bash 3.2 has no ${var,,}
#
# Element order is fixed — model · effort · style · fast · nothink. Elements are
# joined by a single space at every level; the group closes with RESET_DIM + two
# spaces, the line-1 section separator.
render_model_sec() {
    # $6 is optional (`${6-}`, not `$6`) so `set -u` callers that predate the
    # style element keep working — an omitted style reads the same as `default`.
    local level=$1 name=$2 effort=$3 fast=$4 thinking=$5 style=${6-}
    local -a el=()

    # Model rank. Negative circled digits ❶❷❸❹ (U+2776-U+2779): Fable=❶,
    # Opus=❷, Sonnet=❸, Haiku=❹. Colours are capability signals, unchanged
    # from the pre-rank scheme: magenta=Fable, gold=Opus (premium),
    # green=Sonnet (default/safe), red=Haiku (capability warning).
    local mglyph mcolor mname
    case "$name" in
        "Fable "*)  mglyph="❶" mcolor="$MAGENTA" mname="Fable" ;;
        "Opus "*)   mglyph="❷" mcolor="$YELLOW"  mname="Opus" ;;
        "Sonnet "*) mglyph="❸" mcolor="$GREEN"   mname="Sonnet" ;;
        "Haiku "*)  mglyph="❹" mcolor="$RED"     mname="Haiku" ;;
        *)          mglyph=""  mcolor="$RED"     mname="$name" ;;
    esac
    if [[ -z "$mglyph" ]]; then
        # Unknown model: no rank glyph, so there is nothing to compact TO —
        # the full display name survives every level.
        el+=("${mcolor}${mname}")
    elif [[ "$level" == "full" ]]; then
        el+=("${mcolor}${mglyph} ${mname}")
    else
        el+=("${mcolor}${mglyph}")
    fi

    # Reasoning effort. Deliberately uncoloured (opens with RESET_DIM so the
    # model colour cannot leak in): the rank glyph already carries a colour
    # gradient, and a second one competes with it. An absent or unrecognised
    # level omits the element entirely — the payload only carries `effort` for
    # models that support it.
    local eglyph="" elabel=""
    case "$effort" in
        low)    eglyph="○" elabel="low" ;;
        medium) eglyph="◐" elabel="medium" ;;
        high)   eglyph="●" elabel="high" ;;
        xhigh)  eglyph="◉" elabel="xhigh" ;;
        max)    eglyph="◈" elabel="max" ;;
    esac
    if [[ -n "$eglyph" ]]; then
        if [[ "$level" == "full" ]]; then
            el+=("${RESET_DIM}${eglyph} ${elabel}")
        else
            el+=("${RESET_DIM}${eglyph}")
        fi
    fi

    # Output style, from .output_style.name. Same treatment as effort — it
    # answers the same kind of question (how is this session configured to
    # respond) and a second colour would compete with the rank gradient. The
    # three built-ins get a class glyph; any custom style falls back to the pen
    # and shows its own name, which is more use than the word "other". The
    # `default` style is the absence of a style and is omitted, so an element
    # here always means the session has been steered away from baseline.
    # The runes are written as byte escapes, not literals: three of them live in
    # the BMP private-use area, which editors and clipboards silently drop.
    local sglyph=""
    case "$style" in
        ""|default)  ;;
        explanatory) sglyph=$'\xef\x80\x82' ;;      # U+F002  nf-fa-magnifying_glass
        learning)    sglyph=$'\xef\x86\x9d' ;;      # U+F19D  nf-fa-graduation_cap
        proactive)   sglyph=$'\xef\x81\x90' ;;      # U+F050  nf-fa-forward_fast
        concise)     sglyph=$'\xef\x83\x84' ;;      # U+F0C4  nf-fa-scissors
        *)           sglyph=$'\xf3\xb0\xb4\x93' ;;  # U+F0D13 nf-md-fountain_pen_tip
    esac
    if [[ -n "$sglyph" ]]; then
        if [[ "$level" == "full" ]]; then
            el+=("${RESET_DIM}${sglyph} ${style}")
        else
            el+=("${RESET_DIM}${sglyph}")
        fi
    fi

    # Fast mode.
    if [[ "$fast" == "true" ]]; then
        if [[ "$level" == "full" ]]; then
            el+=("${MAGENTA}󱐋 Fast")
        else
            el+=("${MAGENTA}󱐋")
        fi
    fi

    # Thinking disabled. Keeps its label one level longer than the others —
    # it is the surprising state, and a bare glyph is easy to miss.
    if [[ "$thinking" == "false" ]]; then
        if [[ "$level" == "min" ]]; then
            el+=("${RED}󰥓")
        else
            el+=("${RED}󰥓 Nothink")
        fi
    fi

    local out="" i
    for (( i = 0; i < ${#el[@]}; i++ )); do
        if (( i > 0 )); then out+=" "; fi
        out+="${el[i]}"
    done
    printf '%s%s  ' "$out" "$RESET_DIM"
}

# Capture render_model_sec into the variable named by $1.
# Command substitution strips trailing whitespace and the group's trailing
# two-space separator is significant, so capture through a sentinel byte.
set_model_sec() {
    local __var=$1; shift
    local __v
    __v=$(render_model_sec "$@"; printf x)
    printf -v "$__var" '%s' "${__v%x}"
}
