#!/usr/bin/env bash
# Subagent row rendering for subagent-statusline.sh (statusline-design.md §4.19).
# Deps (source before this file): colors.sh, format-utils.sh, model-display.sh,
# context-display.sh, transcript-cache.sh.
# Everything here is pure except sa_agent_calls, which reads the agent's
# transcript through _tx_cached.

# Context icon, the same nerd-font glyph line 1 uses (U+F1C0 nf-fa-database).
_SA_ICON_CTX=$'\xef\x87\x80'

# Sparkline palette: one fg-on-bg pair per 50k band (16-colour ANSI), the last
# band (300k+) solid bright magenta. Band 0 sets an explicit black background so
# a cell's height reads the same on any terminal background.
_SA_BAND_BG=($'\033[40m' $'\033[44m' $'\033[42m' $'\033[43m' $'\033[41m' $'\033[45m' $'\033[105m')
_SA_BAND_FG=($'\033[34m' $'\033[32m' $'\033[33m' $'\033[31m' $'\033[35m' $'\033[95m' $'\033[95m')
_SA_STEPS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# Map a model id from the subagent payload to the display name render_model_sec
# expects: claude-opus-5-5 → "Opus 5.5", claude-sonnet-4-5-20250929 →
# "Sonnet 4.5", claude-3-5-sonnet-20241022 → "Sonnet 3.5". A `[1m]`-style
# suffix, a provider prefix up to `claude-` and a trailing date are dropped. An
# id of any other shape is kept unchanged, which render_model_sec shows as an
# unranked model.
#
# The renderer runs on every tick for every visible agent, so each helper below
# has a `_v` form that assigns the variable named by its first argument instead
# of printing (no `$( )` fork); the printing form wraps it. Locals carry a
# per-function prefix so they cannot shadow the caller's target variable.
_sa_model_name_v() {
    local _mn_s=${2%%\[*} _mn_f _mn_maj _mn_min=""
    if [[ "$_mn_s" != *claude-* ]]; then printf -v "$1" '%s' "$2"; return 0; fi
    _mn_s=${_mn_s##*claude-}
    [[ "$_mn_s" =~ ^(.*)-[0123456789]{8}$ ]] && _mn_s=${BASH_REMATCH[1]}
    if [[ "$_mn_s" =~ ^(opus|sonnet|haiku|fable)-([0123456789]+)(-([0123456789]+))?$ ]]; then
        _mn_f=${BASH_REMATCH[1]} _mn_maj=${BASH_REMATCH[2]} _mn_min=${BASH_REMATCH[4]}
    elif [[ "$_mn_s" =~ ^([0123456789]+)(-([0123456789]+))?-(opus|sonnet|haiku|fable)$ ]]; then
        _mn_f=${BASH_REMATCH[4]} _mn_maj=${BASH_REMATCH[1]} _mn_min=${BASH_REMATCH[3]}
    else
        printf -v "$1" '%s' "$2"; return 0
    fi
    case $_mn_f in
        opus) _mn_f=Opus ;; sonnet) _mn_f=Sonnet ;; haiku) _mn_f=Haiku ;; fable) _mn_f=Fable ;;
    esac
    printf -v "$1" '%s %s%s' "$_mn_f" "$_mn_maj" "${_mn_min:+.$_mn_min}"
}
sa_model_name() { local n; _sa_model_name_v n "$1"; printf '%s' "$n"; }

# One sparkline cell for a per-call context size, into _SA_CELL_BG / _SA_CELL_FG
# / _SA_CELL_GLYPH. Band = value / 50000 picks the colour pair; the height is
# the position inside the band in 8 steps of 6250. 300k and up is a solid
# bright-magenta block. A value that is not a plain integer leaves all three
# empty.
_sa_cell() {
    _SA_CELL_BG="" _SA_CELL_FG="" _SA_CELL_GLYPH=""
    [[ "$1" =~ ^[0123456789]{1,18}$ ]] || return 0
    local v=$((10#$1)) band idx
    band=$(( v / 50000 ))
    if (( band >= 6 )); then
        band=6 idx=7
    else
        idx=$(( (v % 50000) / 6250 ))
        (( idx > 7 )) && idx=7
    fi
    _SA_CELL_BG=${_SA_BAND_BG[band]} _SA_CELL_FG=${_SA_BAND_FG[band]} _SA_CELL_GLYPH=${_SA_STEPS[idx]}
}

# A run of cells, one per value, oldest first. Background and foreground are
# emitted only when they change, and both are reset after the run so nothing
# leaks into the rest of the row.
_sa_spark_v() {
    local _sp_var=$1 _sp_v _sp_bg="" _sp_fg="" _sp_out=""; shift
    for _sp_v in "$@"; do
        _sa_cell "$_sp_v"
        [[ -n "$_SA_CELL_GLYPH" ]] || continue
        [[ "$_SA_CELL_BG" == "$_sp_bg" ]] || { _sp_out+=$_SA_CELL_BG; _sp_bg=$_SA_CELL_BG; }
        [[ "$_SA_CELL_FG" == "$_sp_fg" ]] || { _sp_out+=$_SA_CELL_FG; _sp_fg=$_SA_CELL_FG; }
        _sp_out+=$_SA_CELL_GLYPH
    done
    [[ -n "$_sp_out" ]] && _sp_out+=$RESET_BG$RESET_FG
    printf -v "$_sp_var" '%s' "$_sp_out"
}
sa_sparkline() { local r; _sa_spark_v r "$@"; printf '%s' "$r"; }

# Status glyph, coloured per status, plus the elapsed time of a running agent.
#   $2 status   running | completed | failed | killed | anything else
#   $3 elapsed  seconds since startTime, or "" (shown only when running)
_sa_status_v() {
    local _st_c _st_g
    case "$2" in
        running)   _st_c=$CYAN   _st_g="▶" ;;
        completed) _st_c=$GREEN  _st_g="✔" ;;
        failed)    _st_c=$RED    _st_g="✘" ;;
        killed)    _st_c=$YELLOW _st_g="■" ;;
        *)         printf -v "$1" '?'; return 0 ;;
    esac
    if [[ "$2" == running && "$3" =~ ^[0123456789]{1,18}$ ]]; then
        _st_g+=" $(format_turn_dur "$((10#$3))")"
    fi
    printf -v "$1" '%s%s%s' "$_st_c" "$_st_g" "$RESET_FG"
}
sa_status_sec() { local r; _sa_status_v r "$1" "$2"; printf '%s' "$r"; }

# Agent label: "name (agentType)", or whichever of the two is present.
_sa_label_v() {
    if [[ -n "$2" && -n "$3" ]]; then printf -v "$1" '%s (%s)' "$2" "$3"
    else printf -v "$1" '%s' "$2$3"
    fi
}
sa_label() { local r; _sa_label_v r "$1" "$2"; printf '%s' "$r"; }

# Identity element at one render_model_sec level, without the group's trailing
# two-space separator. With no model, render_model_sec still opens with its
# unranked colour and an empty name; strip those so the effort stands alone,
# and leave nothing when nothing is left.
_sa_model_sec_v() {
    local _ms_s
    _ms_s=$(render_model_sec "$2" "$3" "$4" false true "")
    _ms_s=${_ms_s%  }
    if [[ -z "$3" ]]; then
        _ms_s=${_ms_s#"$RED"}; _ms_s=${_ms_s# }
        [[ "$_ms_s" == "$RESET_DIM" ]] && _ms_s=""
    fi
    printf -v "$1" '%s' "$_ms_s"
}

# Join the non-empty arguments with the two-space section gap.
_sa_join_v() {
    local _j_var=$1 _j_p _j_out=""; shift
    for _j_p in "$@"; do
        [[ -n "$_j_p" ]] || continue
        _j_out+=${_j_out:+  }$_j_p
    done
    printf -v "$_j_var" '%s' "$_j_out"
}

# Assemble one agent row that fits <cols> visible columns.
#   sa_row <cols> <status_sec> <label> <model_id> <effort> <tokens> [cells…]
# Elements, in order: status, label, model + effort, context value + growth
# bar, sparkline (cells oldest first). Under width pressure the sparkline loses
# cells oldest first until it is gone, then the bar is elided and dropped, then
# the model and effort labels shrink to glyphs, then the agent label is cut and
# dropped; vis_truncate is the last resort. The prefix is measured once and the
# bar and cells are one column each, so the bar and the cells are fitted by
# arithmetic.
_sa_row_v() {
    local _r_var=$1 _r_cols=$2 _r_st=$3 _r_label=$4 _r_model=$5 _r_effort=$6 _r_tok=$7; shift 7
    local _r_name _r_mfull _r_mmin _r_ctx="" _r_bar="" _r_bare _r_nb=0 _r_nbe _r_w0 _r_w1 _r_wl
    local _r_k _r_room _r_pre _r_row _r_spark
    [[ "$_r_cols" =~ ^[0123456789]{1,5}$ ]] || _r_cols=80
    _r_cols=$((10#$_r_cols))
    _sa_model_name_v _r_name "$_r_model"
    _sa_model_sec_v _r_mfull full "$_r_name" "$_r_effort"
    if [[ "$_r_tok" =~ ^[0123456789]{1,18}$ ]]; then
        _r_tok=$((10#$_r_tok))
        _r_ctx="$(get_token_color "$_r_tok")${_SA_ICON_CTX} $(kilos "$_r_tok" 3)${RESET_FG}"
        token_bar_width _r_nb "$_r_tok"
        (( _r_nb > 0 )) && _r_bar=$(display_token_bar "$_r_tok")
    fi

    _sa_join_v _r_pre "$_r_st" "$_r_label" "$_r_mfull" "$_r_ctx"
    vislen_v _r_w0 "$_r_pre"
    if (( _r_nb == 0 || _r_w0 + 1 + _r_nb <= _r_cols )); then
        _r_row=$_r_pre${_r_bar:+ $_r_bar}
        _r_room=$(( _r_cols - _r_w0 - (_r_nb ? _r_nb + 1 : 0) - 2 ))
        _r_k=$#; (( _r_k > _r_room )) && _r_k=$_r_room
        if (( _r_k > 0 )); then
            _sa_spark_v _r_spark "${@:$(( $# - _r_k + 1 ))}"
            printf -v "$_r_var" '%s  %s' "$_r_row" "$_r_spark"; return 0
        fi
        if (( _r_w0 + (_r_nb ? _r_nb + 1 : 0) <= _r_cols )); then
            printf -v "$_r_var" '%s' "$_r_row"; return 0
        fi
    fi
    token_bar_width _r_nbe "$_r_tok" elide
    if (( _r_nbe < _r_nb && _r_w0 + 1 + _r_nbe <= _r_cols )); then
        _r_bare=$(display_token_bar "$_r_tok" elide)
        printf -v "$_r_var" '%s %s' "$_r_pre" "$_r_bare"; return 0
    fi
    if (( _r_w0 <= _r_cols )); then printf -v "$_r_var" '%s' "$_r_pre"; return 0; fi
    _sa_model_sec_v _r_mmin min "$_r_name" "$_r_effort"
    _sa_join_v _r_row "$_r_st" "$_r_label" "$_r_mmin" "$_r_ctx"
    vislen_v _r_w1 "$_r_row"
    if (( _r_w1 > _r_cols )) && [[ -n "$_r_label" ]]; then
        vislen_v _r_wl "$_r_label"
        if (( _r_cols - (_r_w1 - _r_wl) >= 2 )); then
            _sa_join_v _r_row "$_r_st" "$(vis_truncate "$_r_label" $(( _r_cols - (_r_w1 - _r_wl) )))" \
                "$_r_mmin" "$_r_ctx"
        else
            _sa_join_v _r_row "$_r_st" "$_r_mmin" "$_r_ctx"
        fi
    fi
    printf -v "$_r_var" '%s' "$(vis_truncate "$_r_row" "$_r_cols")"
}
sa_row() { local r; _sa_row_v r "$@"; printf '%s' "$r"; }

# Per-call context sizes of the agent's last _TX_SUBCALLS_MAX API calls, oldest
# first, one integer per line. Streaming writes one message several times under
# one message.id, so entries are deduplicated by id (largest total kept, in
# first-seen order). Size = input + cache read + cache creation + output: the
# context the call ran with plus what it added. A call that ran a server-side
# tool (the advisor) logs top-level usage summed over its `iterations`, which
# overstates its context, so the last `message` iteration is read when there is
# one. Lines are parsed one by one (`fromjson?`), so a torn last line does not
# void the rest. Bounded to the transcript's last _SA_TAIL_LINES lines: a call
# writes about six, so the window holds 16 calls with room to spare.
# $1 = agent transcript.
_SA_TAIL_LINES=240
_sa_calls_jq() {
    tail -n "$_SA_TAIL_LINES" "$1" | jq -R -n -r --argjson max "$_TX_SUBCALLS_MAX" '
        [ inputs | fromjson? | select(type == "object" and .type == "assistant") | .message
          | select(type == "object" and (.id | type) == "string" and (.usage | type) == "object")
          | { id,
              v: (.usage
                  | ([.iterations // empty | arrays | .[] | objects | select(.type == "message")]
                     | last) as $it
                  | ($it // .)
                  | [.input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, .output_tokens]
                  | map(numbers) | add // 0 | floor) } ]
        | reduce .[] as $e ({o: [], v: {}};
            (if .v | has($e.id) then . else .o += [$e.id] end)
            | .v[$e.id] = ([.v[$e.id] // 0, $e.v] | max))
        | .v as $v | .o[-$max:][] | $v[.] | if . < 0 then 0 else . end' 2>/dev/null
}

# sa_agent_calls <session transcript> <task id>
# The agent's transcript sits at <session>/subagents/agent-<id>.jsonl beside the
# session's own .jsonl. An id that is not a plain word, or a missing or empty
# file, yields nothing.
sa_agent_calls() {
    local tp=$1 id=$2 f
    [[ -n "$tp" && "$id" =~ ^[[:alnum:]_-]{1,128}$ ]] || return 0
    f="${tp%.jsonl}/subagents/agent-$id.jsonl"
    [[ -f "$f" && -s "$f" ]] || return 0
    _tx_cached subcalls "$f" _sa_calls_jq
}
