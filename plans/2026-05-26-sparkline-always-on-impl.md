# Always-on Sparkline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in flag file (`~/.claude/sparkline-always-on`) that keeps the statusline sparkline visible when the session is idle, showing the final turn's static completed duration instead of a misleading growing clock.

**Architecture:** Extract trailing-duration logic into a pure, unit-testable helper `_spark_trailing` in `claude/lib/sparkline.sh`. Add an `always_on` parameter to `display_turn_sparkline` that gates the idle early-returns and selects the static vs. running trailing. `statusline-command.sh` reads the flag file and passes it through. No CLI command; toggle via `touch`/`rm`.

**Tech Stack:** Bash (3.x-compatible), jq, `just` recipes, shellcheck. Tests live in `claude/test-statusline-helpers.sh`, run by `just precommit`.

**Design spec:** `plans/2026-05-26-sparkline-always-on.md`

---

### Task 1: `_spark_trailing` helper + unit tests

Pure function computing the trailing duration string. No I/O, no `date` — `now` is passed in, so it's fully deterministic and testable.

**Files:**
- Modify: `claude/lib/sparkline.sh` (insert after `_spark_reset_colors`, ~line 135)
- Test: `claude/test-statusline-helpers.sh`

- [ ] **Step 1: Add the helper to `sparkline.sh`**

Insert immediately after the closing `}` of `_spark_reset_colors` (currently line 135), before the `# Per-turn token sparkline...` comment block:

```bash
# Trailing duration string shown after the last turn's cells.
#   idle=0 (AI mid-turn): live `now − turn_start` (grows as the turn runs).
#   idle=1 (always-on render of an idle session): the final turn's *completed*
#           work time `last_api − last_u` (static). Dropped (empty string)
#           once `now − last_api > cache_ttl` — the cache has expired and a
#           stale duration adds nothing.
# turn_start = last_u when a user prompt was captured, else last_api.
# Durations clamp to 0. Args: idle now last_u last_api cache_ttl
_spark_trailing() {
    local idle=$1 now=$2 last_u=$3 last_api=$4 cache_ttl=$5
    local ref=$last_u
    [[ -z "$ref" ]] && ref=$last_api
    local dur
    if (( idle )); then
        (( now - last_api > cache_ttl )) && return
        dur=$(( last_api - ref ))
    else
        dur=$(( now - ref ))
    fi
    (( dur < 0 )) && dur=0
    format_age "$dur"
}
```

- [ ] **Step 2: Add the test source + cases to `test-statusline-helpers.sh`**

After the existing `source "$HERE/lib/context-display.sh" || ...` line (line 13), add the sparkline source:

```bash
# shellcheck source=claude/lib/sparkline.sh
source "$HERE/lib/sparkline.sh" || { echo "FATAL: sparkline.sh not found"; exit 2; }
```

Then append a new test section at the end of the file, before the final `PASS`/`FAIL` summary block (the lines that print `PASS  N tests` / exit). Place these `assert` calls among the other sections:

```bash
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
```

- [ ] **Step 3: Run the tests, verify the new cases pass**

Run: `bash claude/test-statusline-helpers.sh`
Expected: all existing tests still `OK`, plus 5 new `OK` lines under `## _spark_trailing`, and `PASS N tests` with N increased by 5.

- [ ] **Step 4: Run shellcheck on the modified files**

Run: `shellcheck -x claude/lib/sparkline.sh claude/test-statusline-helpers.sh`
Expected: no output (clean).

- [ ] **Step 5: Commit**

```bash
git add claude/lib/sparkline.sh claude/test-statusline-helpers.sh
git commit -m "feat: add _spark_trailing helper for always-on sparkline"
```

---

### Task 2: Thread `always_on` into `display_turn_sparkline`

Add the parameter, compute the `idle` state once, gate the idle early-returns on the flag, and route the trailing through `_spark_trailing`.

**Files:**
- Modify: `claude/lib/sparkline.sh` (`display_turn_sparkline`)
- Test: `claude/test-statusline-helpers.sh`

- [ ] **Step 1: Add the `always_on` parameter**

In `display_turn_sparkline`, find:

```bash
    local transcript_path=$1
    local max_turns=${2:-30}
    local cache_ttl=3600
```

Replace with:

```bash
    local transcript_path=$1
    local max_turns=${2:-30}
    local always_on=${3:-0}
    local cache_ttl=3600
```

- [ ] **Step 2: Replace the idle early-returns with flag-gated logic**

Find this block (the comment paragraph plus the two idle returns, currently lines 234–251):

```bash
    # Skip rendering when the session is idle: the most recent assistant
    # API call ended with end_turn. Pending Us (slash commands, local
    # command echoes, or a just-submitted prompt) don't flip this — a
    # slash command like /plugin writes user entries to the transcript
    # without triggering an A, and treating those as "AI about to
    # respond" left the sparkline visible during idle. A genuine new
    # prompt briefly lands here too, but the next render (at the first
    # tool_use) re-enables the sparkline.
    if (( ${#a_turn_anchors[@]} == 0 )); then
        return
    fi
    if [[ "$trail_last_stop" == "end_turn" ]]; then
        return
    fi
    # Also suppress while user input is pending but AI hasn't started yet.
    if [[ -n "$_staging_u" ]]; then
        return
    fi
```

Replace with:

```bash
    # No turns captured → nothing to draw, regardless of the always-on flag.
    if (( ${#a_turn_anchors[@]} == 0 )); then
        return
    fi
    # Idle = the AI has finished (last call end_turn) or a prompt is staged
    # with no assistant response yet. Pending Us (slash commands, local
    # command echoes, a just-submitted prompt) count as idle: they write user
    # entries without triggering an API call. Normally idle is suppressed — a
    # growing trailing duration on a finished turn is misleading. The always-on
    # flag (~/.claude/sparkline-always-on, read by the caller) overrides that:
    # render the historical bars with a static final-turn duration instead.
    local idle=0
    [[ "$trail_last_stop" == "end_turn" ]] && idle=1
    [[ -n "$_staging_u" ]] && idle=1
    if (( idle )) && (( ! always_on )); then
        return
    fi
```

- [ ] **Step 3: Route the trailing through `_spark_trailing`**

Find this block (currently lines 324–331):

```bash
    # Trailing duration-so-far. We've already returned early for the idle
    # (end_turn) case, so this is always `<dur_so_far>` = now − turn anchor.
    local now_epoch; now_epoch=$(date +%s)
    local trail_ref=${trail_last_u_epoch:-$trail_last_api_epoch}
    local trail_dur=$((now_epoch - trail_ref))
    (( trail_dur < 0 )) && trail_dur=0
    local trailing_str; trailing_str="$(format_age "$trail_dur")"
    local trailing_vis=${#trailing_str}
```

Replace with:

```bash
    # Trailing duration. Running turns show the live `now − turn_start`; an
    # idle always-on render shows the final turn's static completed duration,
    # or nothing once the cache has expired. See _spark_trailing.
    local now_epoch; now_epoch=$(date +%s)
    local trailing_str
    trailing_str="$(_spark_trailing "$idle" "$now_epoch" "$trail_last_u_epoch" "$trail_last_api_epoch" "$cache_ttl")"
    local trailing_vis=${#trailing_str}
```

- [ ] **Step 4: Write the integration test (suppress vs. render flip)**

Append a new section to `claude/test-statusline-helpers.sh` (after the `## _spark_trailing` section). It builds an idle transcript fixture (last assistant call ends with `end_turn`) and checks the flag flips suppression. Assertions are time-robust: they check empty vs. non-empty, not the exact trailing value.

```bash
echo "## display_turn_sparkline always_on gating (idle fixture)"
EFFECTIVE_COLS=120
_spark_fix=$(mktemp "${TMPDIR:-/tmp}/spark-idle.XXXXXX")  # no .jsonl suffix: BSD/GNU mktemp require the template to end in X's
cat > "$_spark_fix" <<'JSONL'
{"type":"user","timestamp":"2026-05-26T10:00:00.000Z","message":{"content":"hello"}}
{"type":"assistant","timestamp":"2026-05-26T10:00:08.000Z","requestId":"r1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2000,"output_tokens":300,"cache_read_input_tokens":50000,"cache_creation_input_tokens":0}}}
JSONL
_spark_off=$(display_turn_sparkline "$_spark_fix" "" 0)
_spark_on=$(display_turn_sparkline "$_spark_fix" "" 1)
rm -f "$_spark_fix"
assert "idle, flag off → suppressed" "${_spark_off:+nonempty}" ""
assert "idle, flag on → rendered"    "${_spark_on:+nonempty}"  "nonempty"
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `bash claude/test-statusline-helpers.sh`
Expected: all `OK`, including the 2 new gating assertions; `PASS N tests` (N up by 2 from Task 1).

- [ ] **Step 6: Run shellcheck**

Run: `shellcheck -x claude/lib/sparkline.sh claude/test-statusline-helpers.sh`
Expected: no output (clean).

- [ ] **Step 7: Commit**

```bash
git add claude/lib/sparkline.sh claude/test-statusline-helpers.sh
git commit -m "feat: gate sparkline idle suppression on always_on flag"
```

---

### Task 3: Read the flag file in `statusline-command.sh`

Wire the flag file presence to the new third argument.

**Files:**
- Modify: `claude/statusline-command.sh:273-275`

- [ ] **Step 1: Pass the flag through**

Find:

```bash
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    display_turn_sparkline "$TRANSCRIPT_PATH"
fi
```

Replace with:

```bash
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    spark_always_on=0
    [[ -f "$HOME/.claude/sparkline-always-on" ]] && spark_always_on=1
    display_turn_sparkline "$TRANSCRIPT_PATH" "" "$spark_always_on"
fi
```

- [ ] **Step 2: Run shellcheck on the statusline script**

Run: `shellcheck -x claude/statusline-command.sh`
Expected: no output (clean).

- [ ] **Step 3: Manual smoke test (flag off then on)**

The statusline reads its JSON payload from stdin. Confirm the script runs cleanly both ways using the latest captured payload (`/tmp/claude/statusbar.json`, written on each render):

```bash
rm -f ~/.claude/sparkline-always-on
bash claude/statusline-command.sh < /tmp/claude/statusbar.json; echo "[exit $?]"
touch ~/.claude/sparkline-always-on
bash claude/statusline-command.sh < /tmp/claude/statusbar.json; echo "[exit $?]"
rm -f ~/.claude/sparkline-always-on
```

Expected: both invocations exit 0. If the captured session is idle, the second (flag on) shows an extra sparkline line that the first omits. (If `/tmp/claude/statusbar.json` is absent, skip this step — Task 2's fixture test already covers the gating.)

- [ ] **Step 4: Commit**

```bash
git add claude/statusline-command.sh
git commit -m "feat: read sparkline-always-on flag in statusline"
```

---

### Task 4: Document the flag

**Files:**
- Modify: `claude/README.md`
- Modify: `claude/design-decisions.md` (§5, sparkline subsection)

- [ ] **Step 1: Add a README section**

Add a subsection documenting the flag. Place it near the statusline/sparkline documentation (search README for "sparkline"; if no statusline section exists, add it under the most relevant heading):

```markdown
### Always-on sparkline

By default the per-turn token sparkline (statusline line 3) is hidden when the
session is idle. To keep it visible at all times:

```sh
touch ~/.claude/sparkline-always-on   # enable
rm   ~/.claude/sparkline-always-on    # disable (default)
```

When always-on and idle, the trailing value is the final turn's completed work
time (static), and is dropped once the prompt cache has expired (>1h idle).
```

- [ ] **Step 2: Note the option in `design-decisions.md`**

In the `#### Per-Turn Token Sparkline` subsection of §5, append a paragraph after the existing idle-suppression description:

```markdown
**Always-on option** (2026-05-26): The idle suppression is opt-out via the
flag file `~/.claude/sparkline-always-on` (presence = on; toggle with
`touch`/`rm`, no CLI command). When set, idle sessions still render the
historical bars; the trailing element becomes the final turn's *completed*
duration (`last_api − last_u`, static) rather than the growing `now − start`,
and is dropped entirely once the session has been idle longer than the cache
TTL (1h). Threaded as a third `always_on` arg to `display_turn_sparkline`
(read from the flag file in `statusline-command.sh`); the trailing decision
lives in the pure `_spark_trailing` helper. Spec:
`plans/2026-05-26-sparkline-always-on.md`.
```

- [ ] **Step 3: Verify line-limit check still passes**

Run: `./scripts/check_line_limits.sh; echo "[exit $?]"`
Expected: exit 0. (It only checks `agents/decisions/*.md`, so the docs edits are unaffected — this confirms nothing regressed.)

- [ ] **Step 4: Commit**

```bash
git add claude/README.md claude/design-decisions.md
git commit -m "docs: document always-on sparkline flag"
```

---

### Final verification

- [ ] **Run the full precommit suite**

Run: `just precommit`
Expected: `line-limits`, `shellcheck`, and `statusline tests` all report OK; `✓ Precommit OK`.
