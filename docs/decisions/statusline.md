# Statusline

Quick-reference summary. `statusline-design.md` is the authority: rationale,
rejected alternatives and history live there (section numbers below).

## When modifying statusline display

**Statusline script must always exit 0 (non-zero suppresses output). Close
segments with `RESET_DIM` or `RESET_FG`, not `RESET`, to preserve Claude CLI's
dim state** (§4.11). Only `lib/sparkline.sh` uses `RESET`, deliberately.

Display format:
- Line 1: identity group, dir, branch, cost, context value and growth bar,
  cache-expiry timer (§4.1, §4.17). Cost is the payload's `total_cost_usd`
  as-is, main-thread only: nothing is estimated (§5). It reflows onto extra rows rather than
  dropping sections.
- Plan mode: limits on line 1, e.g. `Plan 5h 40%/80% ▃ 23:41 / Fable 30%/50% ▂ Tue / 7d 20%/50% ▂ Tue`
  (§4.2); the Fable window comes from the mod (§4.20).
- API mode: an extra line `API  <switchback time | token usage>`, or
  `Auth state inconsistent` when the account library reports a mismatch.
- Optional last line: per-call sparkline (default), per-turn stats, or `off`
  (§4.3–4.8), from `~/.claude/statusline-line2`.
- Agent panel (`subagent-statusline.sh`): one row per subagent, e.g.
  `▶ 4m12  general-purpose  ❷ Opus ● high  ⛁ 117k ██▃` — status, agent
  type, model/effort, context gauge. The bar drops first under width pressure,
  then labels. No cost; intensity never changed (§4.19).

Indicators:
- Model rank `❶ Fable` / `❷ Opus` / `❸ Sonnet` / `❹ Haiku`, then effort
  (`○ ◐ ● ◉ ◈`), output style, `Fast`, and `Nothink` when thinking is
  disabled — all from the payload (§4.17)
- Plan window: `A%/B%` = used / elapsed, one pace colour over both and the bar:
  red above 94, else green under pace, else yellow; bold red at ≥100. A payload
  99 is shown as 100 (§4.15)
- Context value coloured by the gradient below, with a growth bar (§4.12)

## How to calculate context usage

**Primary: sum `context_window.current_usage` fields from the payload.
Fallback: parse the transcript when `current_usage` is null (early session).**

Fields: input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens.

History: the payload's `context_window` total_input/output_tokens are
cumulative session totals (GitHub #13783), not actual context usage — do NOT
use those.

## When displaying token counts

**Colour gradient by 50k ranges. Token bar: one vertical-growth char per range
(▁▂▃▄▅▆▇█), unbounded past 200k, middle elided above 400k.**

| Range | Colour |
|-------|--------|
| 0–50k | Blue |
| 50–100k | Green |
| 100–150k | Yellow |
| 150–200k | Red |
| 200k+ | Bright magenta (bar blocks alternate Bright magenta / Magenta, 200–250k bright) |

Bright magenta is the only bright colour allowed (NFR7): plain magenta after red
lacks contrast. Colour
coding (16-colour ANSI, theme-neutral): GREEN = input/additions, YELLOW =
output, CYAN = cached/timing, RED = deletions.

## How to read plan usage data

**Source: `rate_limits` in the statusline payload. No external API call.**

Fields: `rate_limits.{five_hour,seven_day}.used_percentage` (int) and `.resets_at` (Unix epoch).
The Fable window is not in the payload: the mod writes `fable-<session_id>` in
the state dir from the `anthropic-ratelimit-unified-7d_oi-*` response headers
(statusline-design.md §4.20).

Reset time display:
- 5h: `HH:MM` (always)
- 7d: `Ddd` (3-letter weekday) if not today; `HH:MM` if today
