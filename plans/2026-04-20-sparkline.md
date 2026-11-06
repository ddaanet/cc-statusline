# Per-turn token sparkline

**Date:** 2026-04-20
**Scope:** `claude/statusline-command.sh` — new element on line 2

## Goal

Compact per-turn input/output sparkline. One pair of chars per turn; fg encodes
current range (log / 2× doubling), partial vertical block encodes fill within
range, bg encodes the previously-filled range. Cache-read tokens excluded.

## Data

Source: current session transcript `.jsonl` at `$TRANSCRIPT_PATH`.

"Turn" = one assistant message (one API call). Filter:

- `.type == "assistant"`
- `.isSidechain` not true
- `.message.usage` present

Per turn:

- `in_tokens`  = `input_tokens + cache_creation_input_tokens`
  Captures new input processed (including cache misses).
  `cache_read_input_tokens` is excluded — cache reads cost ~10% of fresh input;
  user spec says "no cache stats".
- `out_tokens` = `output_tokens`

## Rendering

Each turn → `[in char][out char]`. Pairs within one user turn are not separated
(hue pattern cool-warm-cool-warm shows pair boundaries).

Block characters: ` ▁▂▃▄▅▆▇█` (9 levels: 0..8).

For value V in range R (1..5) with bounds M₀=0, M₁..M₅:

- If V ≤ M₁: R=1, fill in [M₀..M₁].
- Else R = smallest i s.t. V ≤ Mᵢ. Fill in [M_(R-1)..M_R].
- fill_idx = round(8 × (V − M_(R-1)) / (M_R − M_(R-1))), clamped to [0,8].
- If R = 1: fg = palette[0], bg reset.
- If R > 1: fg = palette[R-1], bg = palette[R-2].
- If V > M₅ (saturated): cell uses **inverse video** on the range-5 fg color
  with glyph `◆`. Inverse swaps fg/bg, so the cell paints bg = saturation
  colour, fg = terminal default background — theme-adaptive without needing
  to detect the theme.

### User turns and gaps

Between consecutive user turns that each triggered an assistant response,
emit `<turn_dur>│<user_wait>`:

- `turn_dur`  = last API call in that user turn − triggering-prompt
  timestamp (assistant work time).
- `user_wait` = next triggering prompt − last API call (think time).
- `│` → ` ` (space) when the spanned gap > 3600s — cache has expired
  (Claude Code uses 1h ephemeral cache, visible in
  `cache_creation.ephemeral_1h_input_tokens`).

A user turn often begins with preliminary U entries: local-command
caveats, slash commands (`/model`, `/plugin`), bash-input / bash-stdout
echoes, and so on. None of these trigger an assistant response on their
own; the real prompt arrives later in the same streak. They should all
count as part of the same turn rather than fragmenting it into empty
boundaries.

The implementation uses a first-wins staging slot: the first U after the
previous A is latched as the turn trigger, and subsequent Us in the
streak are ignored. That anchors `user_wait` to the user's first action
after the AI finished (real think-time) and `turn_dur` to the full turn
wall-clock (first U → last A). Without first-wins, the running
`<dur_so_far>` would start from whichever pre-prompt U happened last,
missing the earlier part of the turn.

### Pre-trim turn-anchor pass

A long tool-use session can emit more than `max_turns` API calls for a
single user turn. When that happens, the display-window trim drops every
U — including the current turn's triggering U — so the render loop's
`last_u_epoch` is empty and the running duration-so-far collapses to "now
− last_api_epoch" (seconds since the last tool call), not the real turn
duration.

To fix that, a pre-pass runs the same first-wins staging logic over the
**full** dedupe'd stream before trimming and captures
`trail_last_u_epoch`, `trail_last_api_epoch`, and `trail_last_stop`.
The trailing marker uses those pre-trim values, so the duration always
reflects the real turn start even when the triggering U is off-screen.
In-window separators still come from the render-time loop; only the
trailing anchor needs the full view.

The current user-turn's duration is always surfaced, either before its
separator (for completed turns, above) or at the line end (for the final
turn). Two shapes at the line end:

- Running (last A's `stop_reason != "end_turn"`): emit `<dur_so_far>` =
  now − triggering U. No trailing separator — the turn hasn't ended, so
  there's no wait / HH:MM to emit after it. Value stays fresh because
  statusline re-renders on tool events during a response.
- Pending user input (`stop_reason == "end_turn"`): emit
  `<turn_dur>│<HH:MM>` where turn_dur = last A − triggering U and HH:MM is
  the local-time clock reading of the last API call. HH:MM rather than a
  relative wait because the statusline doesn't auto-refresh while idle —
  a relative value would freeze at render time. Users compare HH:MM
  against their own clock.

If the trimmed window's first entry is an assistant turn (its triggering
prompt was outside the trimmed window), the first boundary omits
`turn_dur` and emits only `<sep><user_wait>`.

### Duration format

Compact single-unit duration (used for `turn_dur` and between-turn
`user_wait`; the trailing wait uses HH:MM instead):

- `< 60s`  → `Ns`
- `< 60m`  → `Nm`
- `< 24h`  → `Nh`
- `≥ 24h`  → `Nd`

Labels are placed inline at user-turn boundaries, not at the left edge, to
avoid visual confusion with the usage statistics preceding the sparkline.

## Ranges (log / 2× doubling)

| Range | out ≤ | in ≤ |
|-------|------:|-----:|
| R1    |  1000 |  5000 |
| R2    |  2000 | 10000 |
| R3    |  4000 | 20000 |
| R4    |  8000 | 40000 |
| R5    | 16000 | 80000 |

In boundaries = 5 × out boundaries (matches 5:1 per-token cost ratio of all
current Claude models).

## Palettes (16-color ANSI)

| Range | Reads (in)         | Writes (out)        |
|-------|--------------------|---------------------|
| R1    | cyan 36            | green 32            |
| R2    | blue 34            | yellow 33           |
| R3    | bright-blue 94     | bright-yellow 93    |
| R4    | magenta 35         | red 31              |
| R5    | bright-magenta 95  | bright-red 91       |

Bg codes: fg 30-series → bg 40-series (same low digit); fg 90-series → bg
100-series. So reads bg: 46, 44, 104, 45, 105. Writes bg: 42, 43, 103, 41, 101.

## Layout

- On its own line (line 3 of the statusline), below the account/rate-limits line.
- Width: last N assistant turns (deduped by `requestId`), cap N=30
  (≈60 chars for pairs + inline age labels and separators).
- Reset fg + bg at end so nothing leaks into subsequent output.

## Terminal compatibility

Claude Code wraps the statusline output in `\033[2m … \033[0m` so the whole
thing renders dim. But bright SGR codes (90–97 / 100–107), used by ranges
2–4 and the saturated cell, force their cell to full brightness and cannot
be re-dimmed on a per-cell basis. Mixing dim and non-dim cells in the same
sparkline looks inconsistent.

Fix: emit `${RESET}` (which expands to `\033[39m\033[22m\033[25m` —
`\033[22m` clears both bold and dim) once at the start of
`display_turn_sparkline`. Every cell then renders at full brightness for a
uniform appearance.

## Performance

`tail -n 1500 $TRANSCRIPT_PATH` piped into jq to bound work on long transcripts.
1500 covers ≥30 turns when interleaved with user prompts and tool_result
entries. `timestamp` is parsed in jq via `sub("\\.[0-9]+Z$"; "Z") | fromdate`
to strip the fractional-second suffix that jq's `fromdate` doesn't accept.

## Out of scope

- Sidechain / subagent turns.
- Non-current sessions.
- Explicit cost label (baked into the in=5×out scaling).
