#!/usr/bin/env bash
# Pure line-1 layout engine for the statusline. No jq, no I/O beyond stdout.
# Depends on vislen (format-utils.sh). Reads L1_* globals in layout_line1.

# Echo the richest plan variant whose visible width fits $1 columns.
# $1=budget  $2=full $3=no_plan_label $4=no_period_labels $5=no_bars
# Variants are ordered richest→leanest; returns the first that fits.
# Empty variants are skipped; echoes "" when none fit (→ caller omits plan).
pick_plan_variant() {
    local budget=$1 v
    for v in "$2" "$3" "$4" "$5"; do
        [[ -z "$v" ]] && continue
        if (( $(vislen "$v") <= budget )); then
            printf '%s' "$v"
            return 0
        fi
    done
    printf ''
}

# Join non-empty rows with a single newline (no trailing newline).
_emit_rows() {
    local first=1 r
    for r in "$@"; do
        [[ -z "$r" ]] && continue
        (( first )) || printf '\n'
        first=0
        printf '%s' "$r"
    done
}

# Decide the multi-row line-1 layout from the L1_* globals.
# Ladder (row 1 must fit L1_R1; continuation rows must fit L1_RC):
#   L0  full identity + ctx(+bar) [+ full plan inline]
#   A   plan wraps to its own row; full identity + ctx(+bar) on row 1
#       → elide bar middle → mid identity → compact identity → drop bar
#   B   [model pyenv dir] / [branch + ctx(no bar)] / [plan]   full → mid → compact
#   C   [model pyenv dir] / [branch] / [ctx(no bar)] / [plan] full → mid → compact
# The identity group's three widths — full (labels), mid (glyphs, nothink still
# labelled), compact (glyphs only) — are spent BEFORE the context bar is
# dropped, but AFTER its middle is elided: the labels restate what their glyphs
# already say, whereas the bar is the only place the context figure gets a
# magnitude at a glance — and eliding costs neither, since the hidden ranges are
# a flat run the head and tail already summarise.
# The context group (cost+ctx+[bar]+timer) never drops beyond its bar.
# The final structured row is emitted unconditionally; emit_line1 truncates.
layout_line1() {
    local r1=$L1_R1 rc=$L1_RC row1 rowb2

    # L0: everything on one row (full plan inline only — plan wraps before it degrades)
    if [[ -n "$L1_PLAN_INLINE" ]]; then
        row1="${L1_IDFULL}${L1_CGBAR}${L1_PLAN_INLINE}"
    else
        row1="${L1_IDFULL}${L1_CGBAR}"
    fi
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1"; return; fi

    # Tier A: plan (if any) drops to L1_PLANROW below; full identity + ctx(bar)
    row1="${L1_IDFULL}${L1_CGBAR}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # elide the bar's middle before spending anything else: the ranges it hides
    # are a flat magenta smear, and the head and tail still carry what the bar
    # is for. Below 400k this is the same string as L1_CGBAR (inert rung).
    row1="${L1_IDFULL}${L1_CGELIDED}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # drop the identity labels (rank/effort/fast become glyphs; nothink keeps
    # its label — it is the surprising state)
    row1="${L1_IDFULLM}${L1_CGELIDED}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # drop the nothink label too — identity is glyphs only
    row1="${L1_IDFULLC}${L1_CGELIDED}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # drop the context bar
    row1="${L1_IDFULLC}${L1_CGNOBAR}"
    if (( $(vislen "$row1") <= r1 )); then _emit_rows "$row1" "$L1_PLANROW"; return; fi

    # Tier B: [model pyenv dir] / [branch + ctx(no bar)]
    rowb2="${L1_BRANCH}${L1_CGNOBAR}"
    if (( $(vislen "$rowb2") <= rc )); then
        if (( $(vislen "$L1_IDHEAD") <= r1 )); then
            _emit_rows "$L1_IDHEAD" "$rowb2" "$L1_PLANROW"; return
        fi
        if (( $(vislen "$L1_IDHEADM") <= r1 )); then
            _emit_rows "$L1_IDHEADM" "$rowb2" "$L1_PLANROW"; return
        fi
        if (( $(vislen "$L1_IDHEADC") <= r1 )); then
            _emit_rows "$L1_IDHEADC" "$rowb2" "$L1_PLANROW"; return
        fi
    fi

    # Tier C: [model pyenv dir] / [branch] / [ctx(no bar)]
    if (( $(vislen "$L1_IDHEAD") <= r1 )); then
        _emit_rows "$L1_IDHEAD" "$L1_BRANCH" "$L1_CGNOBAR" "$L1_PLANROW"; return
    fi
    if (( $(vislen "$L1_IDHEADM") <= r1 )); then
        _emit_rows "$L1_IDHEADM" "$L1_BRANCH" "$L1_CGNOBAR" "$L1_PLANROW"; return
    fi
    _emit_rows "$L1_IDHEADC" "$L1_BRANCH" "$L1_CGNOBAR" "$L1_PLANROW"
}

# Emit the chosen rows, truncating row 1 to L1_R1 and continuation rows to
# L1_RC. No trailing newline (matches the orchestrator's single-line contract).
emit_line1() {
    local rows first=1 r
    rows=$(layout_line1)
    while IFS= read -r r; do
        if (( first )); then
            vis_truncate "$r" "$L1_R1"; first=0
        else
            printf '\n'
            vis_truncate "$r" "$L1_RC"
        fi
    done <<< "$rows"
}
