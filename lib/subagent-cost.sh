#!/usr/bin/env bash
# Subagent cost aggregation for the statusline.
# Deps: jq, awk. Source after format-utils.sh.

# Echo "IN OUT" base prices ($/M tokens) for a transcript model string.
# Static table — litellm lacks opus-4-8; cache multipliers are uniform across
# models so only base in/out prices vary. Update when model pricing changes.
# Sources: Anthropic pricing (platform.claude.com/docs/en/about-claude/pricing).
model_price() {
    case "$1" in
        *opus-4-8*|*opus-4-7*) printf '5 25'  ;;   # Opus 4.7/4.8 tier
        *opus*)                printf '15 75' ;;   # Opus 4.5 and earlier
        *sonnet*)              printf '3 15'  ;;
        *haiku*)               printf '0.8 4' ;;
        *)                     printf '3 15'  ;;   # conservative default
    esac
}

# Echo "MODEL IN OUT CR C5 C1" summed over deduped assistant entries.
# Dedup by message.id (streaming writes the same message repeatedly with
# cumulative usage — keep the max-output entry per id). Split cache-creation
# into 5m/1h TTL buckets for correct multipliers.
_subagent_tokens() {
    jq -s -r '
      [ .[] | select(.type=="assistant" and .message.id != null)
        | {id: .message.id, m: .message.model, u: .message.usage} ]
      | (map(.m) | last) as $model
      | (group_by(.id) | map(max_by(.u.output_tokens)) | map(.u)) as $us
      | ($us | reduce .[] as $u ({i:0,o:0,cr:0,c5:0,c1:0};
          { i:  (.i  + ($u.input_tokens // 0)),
            o:  (.o  + ($u.output_tokens // 0)),
            cr: (.cr + ($u.cache_read_input_tokens // 0)),
            c5: (.c5 + (($u.cache_creation.ephemeral_5m_input_tokens) // 0)),
            c1: (.c1 + (($u.cache_creation.ephemeral_1h_input_tokens) // 0)) })) as $t
      | "\($model // "unknown") \($t.i) \($t.o) \($t.cr) \($t.c5) \($t.c1)"
    ' "$1" 2>/dev/null
}

# Echo the USD cost of one subagent transcript (%.6f). Missing/empty → 0.
# cost = (in + cr*0.1 + c5*1.25 + c1*2.0) * Pin + out * Pout, per million.
subagent_cost() {
    local f=$1 line model i o cr c5 c1 pin pout
    [[ -z "$f" || ! -s "$f" ]] && { printf '0'; return; }
    line=$(_subagent_tokens "$f")
    [[ -z "$line" ]] && { printf '0'; return; }
    read -r model i o cr c5 c1 <<< "$line"
    read -r pin pout <<< "$(model_price "$model")"
    awk -v i="$i" -v o="$o" -v cr="$cr" -v c5="$c5" -v c1="$c1" \
        -v pin="$pin" -v pout="$pout" \
        'BEGIN { printf "%.6f",
                 (i*pin + cr*pin*0.1 + c5*pin*1.25 + c1*pin*2.0 + o*pout) / 1000000 }'
}

# Cost of one subagent file, memoised by path+size+mtime. A completed file is
# static, so its cost is cached permanently; a growing (running) file re-parses
# only when its signature changes.
_cached_subagent_cost() {
    local f=$1 key hit c
    local cache=/tmp/claude/subagent-cost-cache
    key="$f:$(_stat_sig "$f")"
    if [[ -f "$cache" ]]; then
        hit=$(awk -F'\t' -v k="$key" '$1==k{v=$2} END{if(v!="")print v}' "$cache" 2>/dev/null)
        if [[ -n "$hit" ]]; then printf '%s' "$hit"; return; fi
    fi
    c=$(subagent_cost "$f")
    mkdir -p /tmp/claude
    printf '%s\t%s\n' "$key" "$c" >> "$cache"
    printf '%s' "$c"
}

# Sum subagent cost for a session. $1 = main transcript path
# (<dir>/<session>.jsonl → subagents at <dir>/<session>/subagents/).
session_subagent_cost() {
    local transcript=$1 base subdir total f
    [[ -z "$transcript" || ! -f "$transcript" ]] && { printf '0'; return; }
    base="${transcript%.jsonl}"
    subdir="$base/subagents"
    [[ -d "$subdir" ]] || { printf '0'; return; }
    total=0
    for f in "$subdir"/agent-*.jsonl; do
        [[ -e "$f" ]] || continue
        total=$(awk -v a="$total" -v b="$(_cached_subagent_cost "$f")" \
                'BEGIN { printf "%.6f", a + b }')
    done
    printf '%s' "$total"
}
