#!/usr/bin/env bash
# Claude Code subagentStatusLine: one row per visible subagent in the agent
# panel (statusline-design.md §4.19). Reads one JSON object per refresh tick on
# stdin (base hook fields, `columns`, `tasks[]`) and writes one JSON line per
# task, {"id": …, "content": …}. Any parse failure prints nothing, which keeps
# every default row. Always exits 0.

input=$(cat)

# Resolve the script's real directory through the ~/.claude symlink, the same
# manual walk as statusline-command.sh (bash 3.2 / macOS has no `readlink -f`).
_src=${BASH_SOURCE[0]}
while [ -L "$_src" ]; do
    _dir=$(cd "$(dirname "$_src")" && pwd -P)
    _src=$(readlink "$_src")
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR=$(cd "$(dirname "$_src")" && pwd -P)
unset _src _dir

# A missing module prints nothing rather than failing: default rows stay.
# shellcheck source=lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh" || exit 0
# shellcheck source=lib/format-utils.sh
source "$SCRIPT_DIR/lib/format-utils.sh" || exit 0
# shellcheck source=lib/model-display.sh
source "$SCRIPT_DIR/lib/model-display.sh" || exit 0
# shellcheck source=lib/context-display.sh
source "$SCRIPT_DIR/lib/context-display.sh" || exit 0
# shellcheck source=lib/subagent-display.sh
source "$SCRIPT_DIR/lib/subagent-display.sh" || exit 0

# The agent panel's ambient intensity is not documented, so a row never changes
# intensity: the shared modules close segments with RESET_DIM, which here resets
# the foreground only (§4.19).
RESET_DIM=$RESET_FG

cc_state_dir_init
# Debugging only, never a data source.
[[ -n "$CC_STATE_DIR" ]] && _cc_write_file "$CC_STATE_DIR/subagent-payload.json" "$input"

# Every field in ONE jq fork (§4.18): a header line (columns),
# then one line per task, fields joined by U+001F. Control characters in the
# free-text fields become spaces, so no field can hold the delimiter or a
# newline. A payload that is not an object fails the fork and prints nothing.
# shellcheck disable=SC2016  # jq program, not shell
parsed=$(printf '%s' "$input" | jq -r '
    def s: if . == null then "" else tostring | gsub("[\u0000-\u001f\u007f]"; " ") end;
    if type != "object" then error("not an object") else . end
    | (.columns | s),
      (.tasks | if type == "array" then .[] else empty end | select(type == "object")
       | [.id, .name, .agentType, .status, .startTime, .model, .effort, .tokenCount]
       | map(s) | join("\u001f"))' 2>/dev/null) || exit 0
[[ -n "$parsed" ]] || exit 0

cols="" now="" first=1 st="" label="" row=""
out=()
while IFS=$'\x1f' read -r id name atype status start model effort tok; do
    if (( first )); then
        first=0 cols=$id
        [[ "$cols" =~ ^[123456789][0123456789]{0,4}$ ]] || cols=80
        continue
    fi
    [[ -n "$id" ]] || continue
    elapsed=""
    if [[ "$status" == running && "$start" =~ ^[0123456789]{1,18}$ ]]; then
        [[ -n "$now" ]] || now=$(date +%s)
        if [[ "$now" =~ ^[0123456789]{1,18}$ ]]; then
            elapsed=$(( now - 10#$start / 1000 ))
            (( elapsed < 0 )) && elapsed=0
        fi
    fi
    _sa_status_v st "$status" "$elapsed"
    _sa_label_v label "$name" "$atype"
    _sa_row_v row "$cols" "$st" "$label" "$model" "$effort" "$tok"
    out+=("$id" "$row")
done <<< "$parsed"

if (( ${#out[@]} > 0 )); then
    # shellcheck disable=SC2016  # jq program, not shell
    jq -n -c '$ARGS.positional as $a | range(0; $a | length; 2) | {id: $a[.], content: $a[. + 1]}' \
        --args "${out[@]}" 2>/dev/null
fi
exit 0
