# Statusline Second-Line `stats` Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a selectable second statusline line that renders per-user-turn numeric stats (`stats` mode) as an alternative to the existing per-API-call sparkline.

**Architecture:** A new pure-bash module `claude/lib/turn-stats.sh` exposes `display_turn_stats`, mirroring `display_turn_sparkline`'s shape: it parses the transcript JSONL into an ordered U/A event stream via `jq`, dedupes API calls by `requestId`, groups calls into user turns, aggregates five fields per turn, detects cold-cache events structurally, then formats and width-truncates a one-line string. Two shared formatting helpers (`humanize_tokens`, `format_turn_dur`) live in `claude/lib/format-utils.sh`. `statusline-command.sh` reads `~/.claude/statusline-line2` and dispatches to the stats or sparkline renderer.

**Tech Stack:** Bash (3.2-compatible idioms, matching `sparkline.sh`), `jq`, the existing `test-statusline-helpers.sh` harness.

## Global Constraints

- **Monochrome v1.** The `stats` line emits **no SGR colour codes** (beyond the CLI's outer styling). Disambiguation is by `/` separators and field position. Colour is a deferred follow-up.
- **Cold-cache detection is purely structural** — no elapsed-time or TTL reasoning anywhere. Detect via `cr_k < cr_{k-1} + cc_{k-1}` across the whole call stream; discriminate cold-vs-shrink via `refresh_k = cc_k + in_k ≥ drop_k`. See `claude/design-decisions.md` → "Prompt-Cache Behaviour (Empirical Findings)".
- **Config flag file:** `~/.claude/statusline-line2`, value `sparkline` (default) or `stats`. Absent / empty / unrecognised → `sparkline`. Plain-text, single value (matches the `account-mode` idiom; NOT `account-config.json`).
- **Always `exit 0`** in `statusline-command.sh`; a non-zero exit suppresses the whole statusline.
- Token humanisation: `k`/`M` abbreviation. Bash idioms must match `sparkline.sh` (linear-scan dedupe, `read -r` field splitting, no associative arrays).

---

## File Structure

- **`claude/lib/format-utils.sh`** (modify) — add two pure formatters: `humanize_tokens` (token count → `364k` / `1.5M`) and `format_turn_dur` (seconds → `52s` / `2m10` / `1h05`). This file is the no-dependency formatting layer, sourced before colour/render modules.
- **`claude/lib/turn-stats.sh`** (create) — the `stats` renderer: `display_turn_stats` plus two private helpers `_turn_input` (the input formula + clamp) and `_turn_marker` (cold count → `❄` / `N❄`).
- **`claude/statusline-command.sh`** (modify) — source `turn-stats.sh`; at the line-2 dispatch (~L270-277) read the flag file and call the chosen renderer.
- **`claude/test-statusline-helpers.sh`** (modify) — source `turn-stats.sh`; add fixture-driven tests for every new function.

Run all tests with: `bash claude/test-statusline-helpers.sh`

**Task map (4 tasks):** (1) the two shared formatters; (2) the `turn-stats.sh` pure helpers; (3) the full `display_turn_stats` renderer; (4) dispatch wiring. Tasks 1–3 each end on a green suite; Task 4 makes it live.

---

## Task 1: Shared formatters — `humanize_tokens` and `format_turn_dur`

Two small, independent pure functions in the same file. One gate.

**Files:**
- Modify: `claude/lib/format-utils.sh` (add `humanize_tokens` after `kilos`; `format_turn_dur` after `format_age`)
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Produces: `humanize_tokens <int> -> string`. `<1000` → integer verbatim; `<1_000_000` → rounded thousands `k` (`364k`); `≥1_000_000` → one-decimal millions `M`, trailing `.0` stripped (`1.5M`, `2M`). Empty / `unset` / non-numeric → `0`.
- Produces: `format_turn_dur <seconds> -> string`. `<60` → `Ns` (`52s`); `<3600` → `Mm` when seconds 0 (`4m`), else `MmSS` zero-padded (`2m10`, `1m18`); `≥3600` → `Hh` when minutes 0 (`1h`), else `HhMM` zero-padded (`1h05`). Negative → `0s`. (Deliberately finer than the sparkline's `format_age`: the stats line shows precise per-turn numbers, so duration keeps second/minute resolution to match the spec's examples.)

- [ ] **Step 1: Write the failing tests**

Add to `claude/test-statusline-helpers.sh` (before the final `if (( FAIL == 0 ))` block):

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash claude/test-statusline-helpers.sh 2>&1 | grep -E 'humanize_tokens|format_turn_dur'`
Expected: FAIL lines (`command not found` → empty `got`).

- [ ] **Step 3: Implement both formatters**

Add to `claude/lib/format-utils.sh` immediately after `kilos()`:

```bash
# Humanise a token count: 999 → "999", 364000 → "364k", 1500000 → "1.5M".
# k = rounded thousands (half-up); M = one decimal, trailing ".0" stripped.
# Empty / "unset" / non-numeric → "0".
humanize_tokens() {
    local n=$1
    if [[ -z "$n" || "$n" == "unset" || ! "$n" =~ ^[0-9]+$ ]]; then
        printf '0'
        return
    fi
    if (( n < 1000 )); then
        printf '%d' "$n"
    elif (( n < 1000000 )); then
        printf '%dk' "$(( (n + 500) / 1000 ))"
    else
        local m
        m=$(printf '%.1f' "$(bc -l <<< "$n / 1000000")")
        m=${m%.0}
        printf '%sM' "$m"
    fi
}
```

Add to `claude/lib/format-utils.sh` immediately after `format_age()`:

```bash
# Compact turn duration with sub-unit resolution: 52s / 2m10 / 4m / 1h05 / 1h.
# Seconds shown only when non-zero (<1h); minutes shown only when non-zero (≥1h).
# Negative clamps to 0s.
format_turn_dur() {
    local s=$1
    (( s < 0 )) && s=0
    if (( s < 60 )); then
        printf '%ds' "$s"
    elif (( s < 3600 )); then
        local m=$(( s / 60 )) sec=$(( s % 60 ))
        if (( sec == 0 )); then
            printf '%dm' "$m"
        else
            printf '%dm%02d' "$m" "$sec"
        fi
    else
        local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 ))
        if (( m == 0 )); then
            printf '%dh' "$h"
        else
            printf '%dh%02d' "$h" "$m"
        fi
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash claude/test-statusline-helpers.sh`
Expected: final line `PASS  N tests` (exit 0); the 16 new assertions all `OK`.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/format-utils.sh claude/test-statusline-helpers.sh
git commit -m "feat: add humanize_tokens and format_turn_dur formatters"
```

---

## Task 2: `turn-stats.sh` pure helpers — `_turn_input` and `_turn_marker`

Create the module with its two pure, independently-testable building blocks (the input formula and the cold marker). The renderer that consumes them is Task 3. Gating the formula here gives an early correctness check before it's buried in the orchestration.

**Files:**
- Create: `claude/lib/turn-stats.sh`
- Modify: `claude/test-statusline-helpers.sh` (add source line + tests)

**Interfaces:**
- Produces: `_turn_input <sum_cc> <sum_out> <last_out> <prev_last_out> <r_turn> -> int`. Computes `sum_cc − sum_out + last_out − prev_last_out − r_turn`, clamped at 0 (the turn's effective external input = `user_message + Σtool_results`).
- Produces: `_turn_marker <cold_count> -> string`. `0` (or less) → empty; `1` → `❄`; `N>1` → `N❄`.

- [ ] **Step 1: Create the module with both helpers**

Create `claude/lib/turn-stats.sh`:

```bash
#!/usr/bin/env bash
# Per-user-turn numeric stats line for the statusline (`stats` mode).
# Deps (source before this file): format-utils.sh (humanize_tokens,
# format_turn_dur, vislen). Globals consumed: EFFECTIVE_COLS.
# Counterpart to lib/sparkline.sh's display_turn_sparkline.

# Effective external input for a turn:
#   sum_cc − sum_out + last_out − prev_last_out − r_turn   (clamp at 0)
# Removes the model's already-cached outputs (all but the most recent), the
# previous turn's final output (cached on this turn's first call), and any
# re-cached cold-cache tokens. Result = user_message + Σtool_results.
_turn_input() {
    local sum_cc=$1 sum_out=$2 last_out=$3 prev_last_out=$4 r_turn=$5
    local input=$(( sum_cc - sum_out + last_out - prev_last_out - r_turn ))
    (( input < 0 )) && input=0
    printf '%d' "$input"
}

# Cold-cache marker for a turn: 0 → "", 1 → "❄", N → "N❄".
_turn_marker() {
    local cold=$1
    if (( cold <= 0 )); then
        printf ''
    elif (( cold == 1 )); then
        printf '❄'
    else
        printf '%d❄' "$cold"
    fi
}
```

- [ ] **Step 2: Wire the module into the test harness**

In `claude/test-statusline-helpers.sh`, add a source line after the `sparkline.sh` source (around line 15):

```bash
# shellcheck source=claude/lib/turn-stats.sh
source "$HERE/lib/turn-stats.sh" || { echo "FATAL: turn-stats.sh not found"; exit 2; }
```

(Do NOT add a `type display_turn_stats` sanity check yet — that function arrives in Task 3.)

- [ ] **Step 3: Write the failing tests**

Add to `claude/test-statusline-helpers.sh`:

```bash
echo "## _turn_input"
# full formula: 50000 − 12000 + 10000 − 0 − 0 = 48000
assert "full formula"        "$(_turn_input 50000 12000 10000 0 0)"     "48000"
# 1-call turn (out == last_out): cc − prev_last_out
assert "1-call minus prev"   "$(_turn_input 3258 900 900 3000 0)"       "258"
# first turn: prev_last_out 0
assert "first turn"          "$(_turn_input 60000 12000 12000 0 0)"     "60000"
# R_turn subtracted
assert "minus R_turn"        "$(_turn_input 140000 1300 800 0 120000)"  "19500"
# negative clamps to 0
assert "clamp negative"      "$(_turn_input 100 5000 0 0 0)"            "0"

echo "## _turn_marker"
assert "zero → empty"  "$(_turn_marker 0)"  ""
assert "one → snow"    "$(_turn_marker 1)"  "❄"
assert "three → 3snow" "$(_turn_marker 3)"  "3❄"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash claude/test-statusline-helpers.sh`
Expected: `PASS  N tests` (exit 0); the 8 new assertions `OK` (the module loaded cleanly).

- [ ] **Step 5: Commit**

```bash
git add claude/lib/turn-stats.sh claude/test-statusline-helpers.sh
git commit -m "feat: add turn-stats helpers _turn_input and _turn_marker"
```

---

## Task 3: `display_turn_stats` renderer

The full renderer in one cohesive function: stream parse → dedupe → turn grouping → aggregation → structural cold-cache detection → render → width truncation. Written complete (no staged placeholder inserts).

**Files:**
- Modify: `claude/lib/turn-stats.sh` (append `display_turn_stats`)
- Test: `claude/test-statusline-helpers.sh`

**Interfaces:**
- Consumes: `humanize_tokens`, `format_turn_dur`, `vislen` (format-utils.sh); `_turn_input`, `_turn_marker` (Task 2).
- Produces: `display_turn_stats <transcript_path> [cols] [now_override] -> stdout`. Emits a leading newline then one group per user turn, joined by ` · `, newest on the right. Each group: `[marker ]N× cr/input/out dur`. `cols` defaults to `${EFFECTIVE_COLS:-77}`. `now_override` (epoch seconds) is a test seam for the live duration of a running turn; production callers omit it. No output when the transcript is missing/empty or has no API calls.

- [ ] **Step 1: Add the `type` sanity check and write the failing tests**

In `claude/test-statusline-helpers.sh`, add after the existing `type` checks (around line 20):

```bash
type display_turn_stats >/dev/null 2>&1 || { echo "FATAL: display_turn_stats not loaded"; exit 2; }
```

Then add the tests (before the final summary block):

```bash
echo "## display_turn_stats — aggregation"
EFFECTIVE_COLS=200

# Single 1-call turn: input == cc (out == last_out, prev 0).
_ts_a=$(mktemp "${TMPDIR:-/tmp}/ts-a.XXXXXX")
cat > "$_ts_a" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"a1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":12000,"cache_read_input_tokens":364000,"cache_creation_input_tokens":60000}}}
JSONL
_ts_a_out=$(display_turn_stats "$_ts_a" 200 | tr -d '\n')
rm -f "$_ts_a"
assert "single turn group" "$_ts_a_out" "1× 364k/60k/12k 52s"

# Multi-call turn: count, Σcr, Σout, input over two calls (cr rises, no cold).
_ts_b=$(mktemp "${TMPDIR:-/tmp}/ts-b.XXXXXX")
cat > "$_ts_b" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:20.000Z","requestId":"b1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":2000,"cache_read_input_tokens":150000,"cache_creation_input_tokens":30000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"b2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":10000,"cache_read_input_tokens":190000,"cache_creation_input_tokens":20000}}}
JSONL
_ts_b_out=$(display_turn_stats "$_ts_b" 200 | tr -d '\n')
rm -f "$_ts_b"
# Σcr=340000, input=50000−12000+10000−0=48000, Σout=12000, dur=52s
assert "multi-call group" "$_ts_b_out" "2× 340k/48k/12k 52s"

# prev_last_out correction across a turn boundary: short follow-up after a turn.
_ts_c=$(mktemp "${TMPDIR:-/tmp}/ts-c.XXXXXX")
cat > "$_ts_c" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"c1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":3000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":5000}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:02:18.000Z","requestId":"c2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":900,"cache_read_input_tokens":60000,"cache_creation_input_tokens":3258}}}
JSONL
_ts_c_out=$(display_turn_stats "$_ts_c" 200 | tr -d '\n')
rm -f "$_ts_c"
# turn2 input = 3258−900+900−3000 = 258 (NOT 3258); dur = 78s = 1m18
case "$_ts_c_out" in
    *"1× 60k/258/900 1m18"*) _ts_c_ok=yes ;;
    *) _ts_c_ok=no ;;
esac
assert "prev_last_out correction" "$_ts_c_ok" "yes"

# Running turn: stop != end_turn → duration uses now_override.
_ts_e=$(mktemp "${TMPDIR:-/tmp}/ts-e.XXXXXX")
cat > "$_ts_e" <<'JSONL'
{"type":"user","timestamp":"2025-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2025-06-30T10:00:30.000Z","requestId":"e1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":5000,"cache_read_input_tokens":90000,"cache_creation_input_tokens":8000}}}
JSONL
# anchor epoch = 1751277600 (2025-06-30T10:00:00Z); now = anchor+90 → 1m30
_ts_e_out=$(display_turn_stats "$_ts_e" 200 1751277690 | tr -d '\n')
rm -f "$_ts_e"
assert "running uses now" "$_ts_e_out" "1× 90k/8k/5k 1m30"

# Idle: same shape but end_turn → static dur = last_api − anchor (now ignored).
_ts_i=$(mktemp "${TMPDIR:-/tmp}/ts-i.XXXXXX")
cat > "$_ts_i" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"i1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":5000,"cache_read_input_tokens":90000,"cache_creation_input_tokens":8000}}}
JSONL
_ts_i_out=$(display_turn_stats "$_ts_i" 200 9999999999 | tr -d '\n')
rm -f "$_ts_i"
assert "idle static dur" "$_ts_i_out" "1× 90k/8k/5k 30s"

# Monochrome: no ESC bytes in output.
_ts_m=$(mktemp "${TMPDIR:-/tmp}/ts-m.XXXXXX")
cat > "$_ts_m" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"m1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":12000,"cache_read_input_tokens":364000,"cache_creation_input_tokens":60000}}}
JSONL
_ts_m_raw=$(display_turn_stats "$_ts_m" 200)
rm -f "$_ts_m"
case "$_ts_m_raw" in
    *$'\033'*) _ts_m_esc=yes ;;
    *) _ts_m_esc=no ;;
esac
assert "monochrome (no SGR)" "$_ts_m_esc" "no"

echo "## display_turn_stats — cold-cache detection"
# Single cold event in a 2-call turn: cr drops 100000→0, refresh covers it.
_ts_g=$(mktemp "${TMPDIR:-/tmp}/ts-g.XXXXXX")
cat > "$_ts_g" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:20.000Z","requestId":"g1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":100000,"cache_creation_input_tokens":20000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"g2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":800,"cache_read_input_tokens":0,"cache_creation_input_tokens":120000}}}
JSONL
_ts_g_out=$(display_turn_stats "$_ts_g" 200 | tr -d '\n')
rm -f "$_ts_g"
# drop=(100000+20000)−0=120000; refresh=120002≥drop → cold.
# input=Σcc(140000)−Σout(1300)+last_out(800)−0−R(120000)=19500 → 20k
# (without R it would be 139500 → 140k). Marker "❄".
assert "single cold → ❄ + R subtracted" "$_ts_g_out" "❄ 2× 100k/20k/1k 52s"

# Two cold events in one turn, incl. a 0→0 re-expiration.
_ts_h=$(mktemp "${TMPDIR:-/tmp}/ts-h.XXXXXX")
cat > "$_ts_h" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"h1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:30.000Z","requestId":"h2","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":110000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"h3","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":120000}}}
JSONL
_ts_h_out=$(display_turn_stats "$_ts_h" 200 | tr -d '\n')
rm -f "$_ts_h"
# h2: drop=(100000+10000)−0=110000 → cold. h3 re-expiry:
# drop=(0+110000)−0=110000 → cold. cold_count=2 → "2❄".
case "$_ts_h_out" in
    "2❄ "*) _ts_h_ok=yes ;;
    *) _ts_h_ok=no ;;
esac
assert "two cold (incl re-expiry) → 2❄" "$_ts_h_ok" "yes"

# Context shrink (compaction): cr drops but refresh < drop → NOT cold.
_ts_j=$(mktemp "${TMPDIR:-/tmp}/ts-j.XXXXXX")
cat > "$_ts_j" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:20.000Z","requestId":"j1","message":{"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":200000,"cache_creation_input_tokens":5000}}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"j2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":80000,"cache_creation_input_tokens":1000}}}
JSONL
_ts_j_out=$(display_turn_stats "$_ts_j" 200 | tr -d '\n')
rm -f "$_ts_j"
# drop=(200000+5000)−80000=125000; refresh=1002 < drop → NOT cold.
case "$_ts_j_out" in
    *❄*) _ts_j_cold=yes ;;
    *) _ts_j_cold=no ;;
esac
assert "context shrink NOT marked" "$_ts_j_cold" "no"

echo "## display_turn_stats — width truncation"
# Three single-call turns with distinct cr values; tiny budget keeps newest.
_ts_w=$(mktemp "${TMPDIR:-/tmp}/ts-w.XXXXXX")
cat > "$_ts_w" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"w1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":111000,"cache_creation_input_tokens":1000}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:10.000Z","requestId":"w2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":222000,"cache_creation_input_tokens":1000}}}
{"type":"user","timestamp":"2026-06-30T10:02:00.000Z","message":{"content":"q3"}}
{"type":"assistant","timestamp":"2026-06-30T10:02:10.000Z","requestId":"w3","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":333000,"cache_creation_input_tokens":1000}}}
JSONL
# Each group "1× NNNk/1k/1k 10s" ≈ 19 cols; budget 25 keeps only the newest.
_ts_w_out=$(display_turn_stats "$_ts_w" 25 | tr -d '\n')
rm -f "$_ts_w"
case "$_ts_w_out" in *333k*) _ts_w_has_new=yes ;; *) _ts_w_has_new=no ;; esac
case "$_ts_w_out" in *111k*) _ts_w_has_old=yes ;; *) _ts_w_has_old=no ;; esac
case "$_ts_w_out" in " · "*) _ts_w_lead=yes ;; *) _ts_w_lead=no ;; esac
assert "truncation keeps newest"   "$_ts_w_has_new" "yes"
assert "truncation drops oldest"   "$_ts_w_has_old" "no"
assert "no leading separator"      "$_ts_w_lead"    "no"

# Wide budget keeps all + separator (truncation is conditional).
_ts_w2=$(mktemp "${TMPDIR:-/tmp}/ts-w2.XXXXXX")
cat > "$_ts_w2" <<'JSONL'
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"q1"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:10.000Z","requestId":"x1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":111000,"cache_creation_input_tokens":1000}}}
{"type":"user","timestamp":"2026-06-30T10:01:00.000Z","message":{"content":"q2"}}
{"type":"assistant","timestamp":"2026-06-30T10:01:10.000Z","requestId":"x2","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1000,"cache_read_input_tokens":222000,"cache_creation_input_tokens":1000}}}
JSONL
_ts_w2_out=$(display_turn_stats "$_ts_w2" 200 | tr -d '\n')
rm -f "$_ts_w2"
case "$_ts_w2_out" in *111k*222k*) _ts_w2_ok=yes ;; *) _ts_w2_ok=no ;; esac
assert "wide budget keeps all + separator" "$_ts_w2_ok" "yes"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash claude/test-statusline-helpers.sh 2>&1 | head -5`
Expected: `FATAL: display_turn_stats not loaded` (the sanity guard fires; the function does not exist yet).

- [ ] **Step 3: Implement `display_turn_stats`**

Append to `claude/lib/turn-stats.sh`:

```bash
# Per-user-turn numeric stats line. One group per turn:
#   [marker ]N× cr/input/out dur   joined by ' · ', newest on the right.
# Turn = the U that triggers the next A through the assistant going idle
# (end_turn), spanning N API calls. First-wins U: preliminary Us / slash
# commands collapse into one anchor.
# Args: transcript_path [cols] [now_override]
display_turn_stats() {
    local transcript_path=$1
    local cols=${2:-${EFFECTIVE_COLS:-77}}
    local now_override=${3:-}
    [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return

    # Ordered event stream (raw token counts, unlike the sparkline's
    # cost-normalised cells):
    #   U <epoch>
    #   A <requestId> <epoch> <cr> <cc> <out> <in> <stop>
    local stream
    stream=$(tail -n 1500 "$transcript_path" 2>/dev/null | jq -r '
        select((.isSidechain // false) | not) |
        ((.timestamp // "") | if . == "" then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdate? // 0) end) as $ts |
        if .type == "user" then
            ((.message.content // "") | if type == "array" then (.[0].type // "") else "" end) as $ct |
            if $ct == "tool_result" then empty else "U \($ts)" end
        elif .type == "assistant" and .message.usage != null then
            (.message.usage.cache_read_input_tokens // 0) as $cr |
            (.message.usage.cache_creation_input_tokens // 0) as $cc |
            (.message.usage.output_tokens // 0) as $out |
            (.message.usage.input_tokens // 0) as $in |
            (.message.stop_reason // "-") as $stop |
            if $cr == 0 and $cc == 0 and $out == 0 and $in == 0 then empty
            else "A \(.requestId // "-") \($ts) \($cr) \($cc) \($out) \($in) \($stop)" end
        else empty end
    ' 2>/dev/null)
    [[ -z "$stream" ]] && return

    # Dedupe A by requestId (bash-3 compatible linear scan).
    local -a items=()
    local seen_req="|" line
    while IFS= read -r line; do
        if [[ "$line" == A\ * ]]; then
            local req="${line#A }"; req="${req%% *}"
            [[ "$seen_req" == *"|$req|"* ]] && continue
            seen_req+="$req|"
        fi
        items+=("$line")
    done <<< "$stream"

    # Aggregate per turn. Parallel arrays indexed by turn occurrence.
    local -a t_n t_cr t_cc t_out t_lastout t_anchor t_lastapi t_cold t_r t_laststop
    local ti=-1 staging_u="" prev_cr="" prev_cc=""
    for line in "${items[@]}"; do
        if [[ "$line" == U\ * ]]; then
            local u="${line#U }"
            [[ -z "$u" || "$u" == "0" ]] && continue
            [[ -z "$staging_u" ]] && staging_u=$u
        else
            local _r _ts _cr _cc _out _in _stop
            read -r _ _r _ts _cr _cc _out _in _stop <<< "$line"
            if [[ -n "$staging_u" ]]; then
                ti=$(( ti + 1 ))
                t_anchor[ti]=$staging_u
                t_n[ti]=0; t_cr[ti]=0; t_cc[ti]=0; t_out[ti]=0
                t_cold[ti]=0; t_r[ti]=0
                staging_u=""
            elif (( ti < 0 )); then
                ti=$(( ti + 1 ))
                t_anchor[ti]=$_ts
                t_n[ti]=0; t_cr[ti]=0; t_cc[ti]=0; t_out[ti]=0
                t_cold[ti]=0; t_r[ti]=0
            fi
            # Cold-cache detection across the whole stream (global adjacency).
            # A cold event: this call reads back less than the previous call
            # had cached (read + just-written), AND the freshly-processed
            # tokens cover the drop (refresh ≥ drop) — distinguishing a cold
            # re-cache from a context shrink (compaction/clear). Comparing
            # against cr+cc (not cr alone) catches a 0→0 re-expiration.
            if [[ -n "$prev_cr" ]]; then
                local cap=$(( prev_cr + prev_cc ))
                local drop=$(( cap - _cr ))
                if (( drop > 0 )); then
                    local refresh=$(( _cc + _in ))
                    if (( refresh >= drop )); then
                        t_cold[ti]=$(( t_cold[ti] + 1 ))
                        t_r[ti]=$(( t_r[ti] + drop ))
                    fi
                fi
            fi
            prev_cr=$_cr; prev_cc=$_cc
            t_n[ti]=$(( t_n[ti] + 1 ))
            t_cr[ti]=$(( t_cr[ti] + _cr ))
            t_cc[ti]=$(( t_cc[ti] + _cc ))
            t_out[ti]=$(( t_out[ti] + _out ))
            t_lastout[ti]=$_out
            t_lastapi[ti]=$_ts
            t_laststop[ti]=$_stop
        fi
    done
    (( ti < 0 )) && return
    local ngroups=$(( ti + 1 ))

    local now=$now_override
    [[ -z "$now" ]] && now=$(date +%s)

    # Build group strings, oldest → newest.
    local -a groups=()
    local g
    for ((g=0; g<ngroups; g++)); do
        local prev_last_out=0
        (( g > 0 )) && prev_last_out=${t_lastout[$((g-1))]}
        local input cr_h input_h out_h marker dur dur_str
        input=$(_turn_input "${t_cc[$g]}" "${t_out[$g]}" "${t_lastout[$g]}" "$prev_last_out" "${t_r[$g]}")
        cr_h=$(humanize_tokens "${t_cr[$g]}")
        input_h=$(humanize_tokens "$input")
        out_h=$(humanize_tokens "${t_out[$g]}")
        marker=$(_turn_marker "${t_cold[$g]}")
        # Duration: static completed time, except a live last turn still running.
        dur=$(( ${t_lastapi[$g]} - ${t_anchor[$g]} ))
        if (( g == ngroups-1 )) && [[ "${t_laststop[$g]}" != "end_turn" ]]; then
            dur=$(( now - ${t_anchor[$g]} ))
        fi
        (( dur < 0 )) && dur=0
        dur_str=$(format_turn_dur "$dur")
        groups[g]="${marker:+$marker }${t_n[$g]}× ${cr_h}/${input_h}/${out_h} ${dur_str}"
    done

    # Width truncation: drop oldest groups from the left until the line fits.
    # Walk backward from the newest, accumulating each group's width plus one
    # ' · ' separator (3 cols) for every group that has a kept neighbour to its
    # right. The first kept group's leading separator is never emitted, so it
    # is excluded from the budget. Always keep at least the newest group.
    local sep_w=3
    local -a gw=()
    local g2
    for ((g2=0; g2<ngroups; g2++)); do
        gw[g2]=$(vislen "${groups[$g2]}")
    done
    local keep_from=$ngroups used=0 k2
    for ((k2=ngroups-1; k2>=0; k2--)); do
        local add=${gw[$k2]}
        (( k2+1 < ngroups )) && add=$(( add + sep_w ))
        (( used + add > cols )) && break
        used=$(( used + add ))
        keep_from=$k2
    done
    (( keep_from >= ngroups )) && keep_from=$(( ngroups - 1 ))

    # Emit: leading newline (so skip-paths leave no blank line), groups joined
    # by ' · ', monochrome — no SGR codes.
    local out="" k
    for ((k=keep_from; k<ngroups; k++)); do
        (( k > keep_from )) && out+=" · "
        out+="${groups[$k]}"
    done
    echo
    printf '%s' "$out"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash claude/test-statusline-helpers.sh`
Expected: `PASS  N tests` (exit 0); all aggregation, cold-detection, and truncation assertions `OK`.

- [ ] **Step 5: Commit**

```bash
git add claude/lib/turn-stats.sh claude/test-statusline-helpers.sh
git commit -m "feat: implement display_turn_stats renderer"
```

---

## Task 4: Wire dispatch into `statusline-command.sh`

**Files:**
- Modify: `claude/statusline-command.sh` (source line ~99; dispatch block ~270-278)

**Interfaces:**
- Consumes: `display_turn_stats`, `display_turn_sparkline`, `~/.claude/statusline-line2`, `~/.claude/sparkline-always-on`, `TRANSCRIPT_PATH`, `EFFECTIVE_COLS`.

- [ ] **Step 1: Source the new module**

In `claude/statusline-command.sh`, after the `sparkline.sh` source line (line 99), add:

```bash
# shellcheck source=claude/lib/turn-stats.sh
source "$HOME/code/home/claude/lib/turn-stats.sh" || exit 1
```

- [ ] **Step 2: Replace the second-line dispatch block**

Replace the existing block (lines ~270-278):

```bash
# Per-turn in|out sparkline on its own line. Width-aware by construction
# (walks backward from the latest turn, stops at EFFECTIVE_COLS), and emits
# its own leading newline only when there's content to show.
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    # ~/.claude/sparkline-always-on: keep the sparkline visible when idle
    spark_always_on=0
    [[ -f "$HOME/.claude/sparkline-always-on" ]] && spark_always_on=1
    display_turn_sparkline "$TRANSCRIPT_PATH" "" "$spark_always_on"
fi
```

with:

```bash
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
```

- [ ] **Step 3: Smoke-test the `stats` path end-to-end**

Run:

```bash
bash -c '
set -e
fix=$(mktemp "${TMPDIR:-/tmp}/sl-stats.XXXXXX")
cat > "$fix" <<JSONL
{"type":"user","timestamp":"2026-06-30T10:00:00.000Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-06-30T10:00:52.000Z","requestId":"s1","message":{"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":12000,"cache_read_input_tokens":364000,"cache_creation_input_tokens":60000}}}
JSONL
source "$HOME/code/home/claude/lib/colors.sh"
source "$HOME/code/home/claude/lib/format-utils.sh"
source "$HOME/code/home/claude/lib/turn-stats.sh"
EFFECTIVE_COLS=120
display_turn_stats "$fix" 120
echo
rm -f "$fix"
'
```

Expected: a line `1× 364k/60k/12k 52s`.

- [ ] **Step 4: Verify syntax and the unchanged default path**

Run: `bash -n claude/statusline-command.sh && echo "syntax OK"`
Expected: `syntax OK`. (With no `~/.claude/statusline-line2` file, `line2_mode` stays `sparkline` and the existing sparkline branch runs exactly as before. The trailing `exit 0` is untouched.)

- [ ] **Step 5: Run the full suite once more**

Run: `bash claude/test-statusline-helpers.sh`
Expected: `PASS  N tests` (exit 0).

- [ ] **Step 6: Commit**

```bash
git add claude/statusline-command.sh
git commit -m "feat: dispatch statusline line 2 via ~/.claude/statusline-line2"
```

---

## Self-Review

**Spec coverage:**
- Config flag file `~/.claude/statusline-line2`, default sparkline → Task 4 (+ Global Constraints).
- Five fields (count, Σcr, input, Σout, duration) → Task 3 aggregation + render.
- Input formula `Σcc − Σout + last_out − prev_last_out − R_turn`, clamp 0 → Task 2 (`_turn_input`), R from Task 3 cold detection.
- prev_last_out correction across turn boundary → Task 3 (test `_ts_c`).
- 1-call / first-turn edge cases → Task 2 (`_turn_input` tests) + Task 3 (`_ts_a`).
- Cold detection `cr_k < cr_{k-1}+cc_{k-1}`, re-expiration, cold-vs-shrink discriminator, `R_turn` → Task 3 (tests `_ts_g/_ts_h/_ts_j`).
- `❄` / `N❄` marker → Task 2 (`_turn_marker`), wired in Task 3.
- Format (group layout, ` · ` join, newest right), k/M humanise, duration formatter → Tasks 1, 3.
- Width truncation (drop oldest, suppress leading separator) → Task 3 (tests `_ts_w/_ts_w2`).
- Running turn live / idle static duration, always-rendered when idle → Task 3 (tests `_ts_e/_ts_i`; no idle-suppression path exists in `display_turn_stats`).
- Monochrome (no SGR) → Task 3 (test `_ts_m`).
- Always `exit 0` → unchanged; the dispatch block precedes the existing trailing `exit 0`.

**Placeholder scan:** No `TBD`/`add appropriate…` placeholders; every code step shows complete code; every test step shows the assertion. No staged placeholder-insert handoffs (the renderer is written whole in Task 3).

**Type/name consistency:** `humanize_tokens`, `format_turn_dur`, `_turn_input`, `_turn_marker`, `display_turn_stats` are spelled identically across definitions (Tasks 1-3), call sites (Task 3), and dispatch (Task 4). `_turn_input`'s 5-arg order (`sum_cc sum_out last_out prev_last_out r_turn`) matches its Task 3 call. The `type display_turn_stats` sanity guard is added in Task 3, when the function first exists (no throwaway stub).

**Deferred / deviations flagged:** (1) `format_turn_dur` uses second resolution (matching the spec's `2m10`/`1m18` examples) rather than the sparkline's coarser `format_age`. (2) No M-capable humaniser pre-existed, so `humanize_tokens` is new rather than reused. (3) Turn segmentation is duplicated (minimal) in `turn-stats.sh`, not extracted from `sparkline.sh` — extraction would be more invasive than the duplication it saves, since the sparkline groups per-API-call, not per-turn.
