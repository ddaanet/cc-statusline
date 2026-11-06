# Statusline second line: selectable sparkline vs. numeric turn stats

**Date**: 2026-06-25
**Related**: `plans/2026-04-20-sparkline.md`, `plans/2026-05-26-sparkline-always-on.md`, `claude/design-decisions.md` (§5)

## Problem

The statusline's second line currently has exactly one renderer: the per-API-call
sparkline (glyph triplets, cache/read/write, with turn boundaries). It is
educational and stays. But we also want a *numeric* second line giving per-user-turn
stats. Both are useful; the user wants to **choose** which renders, not replace one
with the other.

## Goal

A setting selects the second-line renderer:
- `sparkline` (default) — today's behaviour, unchanged.
- `stats` — a new numeric line, one group per user turn.

## Configuration

Single-value plain-text flag file, matching the existing `account-mode` /
`account-provider` idiom (NOT `account-config.json` — that is account-switcher
state and must not be conflated with statusline display).

- **File**: `~/.claude/statusline-line2`
- **Value**: `sparkline` or `stats`. Absent / empty / unrecognised → `sparkline`.
- `~/.claude/sparkline-always-on` is unchanged. It governs idle rendering of the
  sparkline and is simply inert when `stats` is selected.

Rationale: the need today is two statusline knobs (renderer choice + always-on).
A dedicated JSON config would be refactoring a working flag file to serve needs we
do not yet have — speculative, so rejected (YAGNI). If a third knob appears with
its own sub-options, revisit consolidation then.

## The `stats` line

### Unit: the user turn

A *user turn* = the user's message → the assistant going idle (`stop_reason ==
"end_turn"`), spanning N API calls (one per tool-use step). Turn segmentation
reuses the existing per-A anchor logic in `lib/sparkline.sh` (the last U before the
next A triggers a turn; empty user events / slash commands do not). Only
**completed** turns are rendered (see Idle / in-progress below).

### Fields per group

| field        | value                              | meaning |
|--------------|------------------------------------|---------|
| count        | `N` = API calls in the turn        | tool round-trips; makes `Σcr` legible (`Σcr ≈ N × context`) |
| cache-read   | `Σcr`                              | turn cost proxy — re-reads of the cached prefix, billed per call |
| input        | `Σcc − Σout + last_out − prev_last_out − R_turn` | effective external input: user message + tool results, with the model's own outputs and any re-cached (cold) tokens removed |
| output       | `Σout`                             | total generated this turn |
| duration     | work time (live while running)     | same definition as the sparkline's `turn_dur` |

Where, summed over the turn's calls *so far*: `Σcr` = Σ `cache_read_input_tokens`,
`Σcc` = Σ `cache_creation_input_tokens`, `Σout` = Σ `output_tokens`,
`last_out` = `output_tokens` of the **most recent** call, `prev_last_out` =
`output_tokens` of the **previous turn's final call** (0 for the first turn), and
`R_turn` = re-cached tokens from cold-cache events in this turn (see Cold-cache
events below; normally 0).

Three corrections are folded in:
- `−Σout + last_out` removes this turn's *already-cached* outputs (every output
  except the most recent — at any snapshot the most recent output is the one not yet
  written to cache). This makes the formula identical for a running turn and a
  finished one: at `end_turn` the most recent call *is* the final call, so
  `last_out == final_out`.
- `−prev_last_out` removes the **previous turn's final output**, which is cached on
  *this* turn's first call (it was the previous turn's uncached most-recent output)
  and would otherwise leak in. Without it the input field is dominated by the prior
  answer on short conversational turns. See the Appendix for the data confirming
  this leak.
- `−R_turn` removes **re-cached old context** from cold-cache events — those `cc`
  tokens are re-writing context the model already had, not new input.

The result is `user_message + Σtool_results`. It stays monotonic during a turn
(each call adds exactly its `cc`; `prev_last_out` and `R_turn` are constant per-turn
offsets); clamp at 0 defensively. The empirical basis for ignoring raw `input_tokens`
is in the Appendix.

### Format (monochrome first)

Group layout: optional cold-cache marker, then count prefix `×`, the three token
values slash-joined as `cache-read/input/output`, duration trailing. Groups
separated by ` · `. Newest turn on the right; oldest dropped on the left under width
pressure.

```
7× 364k/60k/12k 52s · ❄ 4× 90k/8k/5k 2m10 · 3❄ 6× 150k/9k/7k 4m
                      └ one cold event       └ three cold events
```

Reads: *7 calls, 364k cache-read, 60k input, 12k output, 52s.*

- Token values: `k`/`M` abbreviation, reusing the existing humanise helper in
  `lib/format-utils.sh`.
- Count: plain integer + `×`.
- Duration: the sparkline's `52s` / `1m18` formatter.
- Cold marker: `❄` if the turn had one cold-cache event, `N❄` for N>1, nothing for
  zero. The kind/cause of the cold event is **not** distinguished on the line.
- **No colour** in v1. Disambiguation is by `/` separators and field position.
  Colour is a deferred follow-up.

### Width truncation

Same strategy as the sparkline: probe columns (`tput cols` → `stty size < /dev/tty`
→ 120 fallback), pre-compute each group's rendered width, walk backward from the
newest accumulating width until the budget is exceeded, drop oldest groups from the
left. The first kept group's leading ` · ` separator is suppressed and excluded
from the budget.

### Cold-cache events

A cold-cache event is the model losing cached context it then has to re-write —
whatever the cause (TTL lapse, a prefix change like `/reload-plugins`, infra cache
miss). **Detection is purely structural — no elapsed-time or TTL reasoning** (see
the "cache lifetime is unstable" note below for why).

**Detection is per call, across the whole stream — not per turn boundary.** A
single turn can contain several events. For each adjacent call pair, a cold event
occurs when

```
cr_k < cr_{k-1} + cc_{k-1}
```

i.e. this call reads back **less** than the previous call had cached (read + just
written). Comparing against `cr_{k-1} + cc_{k-1}` (not just `cr_{k-1}`) is required
to catch a **re-expiration** where `cr` goes `0 → 0`: a fresh re-cache (`cc` large)
after the cache was already cold reads `cr=0` again, which `cr_k < cr_{k-1}` would
miss. Each event is attributed to the turn containing call `k`. Per turn:
- `cold_count` = number of such events → drives the `❄` / `N❄` marker.
- `drop_k = (cr_{k-1} + cc_{k-1}) − cr_k`; `R_turn = Σ drop_k` over the turn's cold
  events = total re-cached tokens → subtracted from `input` (the re-cache `cc` is
  not new input). Normally 0.

**Cold re-cache vs. context shrink (compaction / `/clear`).** Both drop `cr`, but a
cold event *re-does* the same context (re-cache ≈ what was lost) while compaction
*replaces* it with something smaller. Discriminate with freshly-processed tokens
`refresh_k = cc_k + in_k` (both, because new content can file under either — `in`
is usually ~2 but spiked to 20600 at cold start):

```
cold cache event :  drop_k > 0  AND  refresh_k ≥ drop_k     → mark ❄, add to R_turn
context shrink   :  drop_k > 0  AND  refresh_k < drop_k     → not cold, not marked
```

The line does **not** distinguish kinds of cold event (TTL vs prefix change): the
count is what matters, and magnitude cannot tell them apart (`R` scales with how
much context existed when the cache died, not with the cause).

**Cache lifetime is unstable — do not model it.** Observed in this design session's
own transcript: two full `cr→0` cold events on **2.2h and 3.6h** gaps (06-25), yet
an **80-hour** gap (06-29) left the cache fully intact (`cr` 174k→175k, `cc=86`) —
and a 12h overnight gap survived while a later 2.2h gap did not. No fixed TTL
explains this; cache persistence appears to have changed mid-conversation
(longer-TTL / persistence rollout, or routing). The `refresh ≥ drop` discriminator
and the `cr_k < cr_{k-1}+cc_{k-1}` detector were both validated against the real
06-25 events; the line-149 compaction did **not** drop `cr` at all. Detection must
stay structural so it survives further policy changes.

### Running turn & idle behaviour

The in-progress turn **is rendered** as the rightmost group, updating on every
statusline render — watching the numbers climb is a feature. All five fields use
the running aggregates above (`last_out` = most recent call's output), so they
update correctly without a special case:

- count, `Σcr`, `Σout`, `input` all increase per call (`input` by exactly the new
  call's `cc`); `duration` = `now − turn_anchor`, growing live.
- A turn appears once it has **≥1 completed call** (before the first call there are
  no numbers to show).
- When the session goes idle (last call was `end_turn`), the rightmost group is that
  completed turn with **static** numbers and its real completed `duration`
  (`last_api − anchor`, not a frozen `now − anchor`). Because the duration shown is
  the genuine completed time — not a misleading frozen clock — the stats line is
  **always rendered** when idle; no suppression, and `sparkline-always-on` does not
  apply.

### Edge cases

- **1-call turn** (a question answered with no tool use): `input = cc − out +
  last_out − prev_last_out = cc − prev_last_out` (single call → `out == last_out`).
  With the `−prev_last_out` correction this is just the user message, as intended.
- **Negative input**: clamp at 0 defensively (e.g. if the previous turn's output was
  not fully re-cached on this turn's first call).
- **First turn of a session**: polluted by SessionStart / UserPromptSubmit injected
  context (large cold-start `cc`). Rendered as-is; it is one historical group and
  not worth special-casing.

## Components

- `lib/turn-stats.sh` (new) — `display_turn_stats(transcript_path, [cols])`:
  segments turns, aggregates the five fields, formats and width-truncates. Mirrors
  `display_turn_sparkline`'s shape.
- Turn segmentation is currently private to `lib/sparkline.sh`. If extracting it
  into a shared helper is cheap, do so; otherwise duplicate the minimal anchor logic
  in `turn-stats.sh`. Decision deferred to the implementation plan.
- `statusline-command.sh` — at the second-line dispatch (currently ~L274-277),
  read `~/.claude/statusline-line2`; on `stats` call `display_turn_stats`, else the
  existing `display_turn_sparkline` path (with `always_on`). Always `exit 0`.

## Testing

Extend `test-statusline-helpers.sh` with fixtures of known per-turn `cr`/`cc`/`out`
sequences and assert:
- the five rendered fields, including the `Σcc − Σout + last_out − prev_last_out −
  R_turn` input formula and that it equals `user_message + Σtool_results` on a
  fixture with known values;
- the `prev_last_out` correction across a turn boundary (a short 1-call turn after a
  large-output turn yields a small input, not ≈ the previous output);
- the first-turn case (`prev_last_out = 0`);
- cold-cache detection via `cr_k < cr_{k-1}+cc_{k-1}`: a drop produces `❄`, multiple
  in one turn produce `N❄`, none → no marker; a mid-turn drop is detected (not just
  at turn boundaries); a **re-expiration** (`cr` `0→0` with large `cc`) is still
  detected; `R_turn` is subtracted from `input`;
- cold-vs-shrink discriminator: a fixture where `refresh = cc+in ≥ drop` is marked
  cold, and a compaction-style fixture where `refresh < drop` is **not** marked and
  not subtracted from `input`;
- width truncation drops oldest groups and suppresses the leading separator;
- output is monochrome (no SGR colour codes beyond the CLI's outer styling / resets);
- a running turn (no `end_turn`) renders live with `input` using `last_out`, and
  equals the finished value once `end_turn` arrives; duration is live while running,
  static (`last_api − anchor`) when idle.

## Appendix — why input is cache-derived, not raw `input_tokens`

Verified against a live transcript:

- Raw `input_tokens` collapses to **~2** on essentially every call after a cold
  start (occasional small bumps of tens of tokens; one-time cold-start bulk). It is
  not a usable per-turn signal.
- The freshly-processed content lands in `cache_creation_input_tokens` (`cc`),
  because Claude Code extends a cache breakpoint to cover newly-appended content; it
  is written to cache on the next call and read (`cr`) thereafter. Confirmed by
  arithmetic: a cold `cc=22059` + next `cc=24539` = following `cr=46598` exactly.
- Hypotheses tested and **refuted**: `in` is not driven by user-message-vs-tool-result
  (the largest mid-session `in` spike followed a tool_result; a 2.6k-token user
  message cached with `in=1`), and `in` is not hook `additionalContext` (two
  mid-session spikes sit in increments with no `additionalContext` anywhere near).
  The residual `in` jitter is internal breakpoint timing, bounded at ~130 tokens,
  and negligible per turn — so we ignore `in` entirely.
- Summing `cc` over the turn's calls so far telescopes to `prev_last_out +
  user_message + Σtool_results + Σ(this turn's outputs already cached)`. Two model-
  generated terms must come out:
  - At any snapshot the **most recent** output is the one not yet cached (written on
    the following call), so the already-cached outputs are `Σout − last_out`.
  - The **previous turn's final output** is cached on this turn's first call — it was
    the previous turn's uncached most-recent output. So `Σcc` carries a
    `prev_last_out` term that is not this turn's input.
  Hence `input = Σcc − Σout + last_out − prev_last_out = user_message + Σtool_results`.
- The `prev_last_out` leak is confirmed in the transcript — consecutive single-call
  turns: `out=1800 → next cc=1896` (Δ=96 user msg), `out=3235 → next cc=3258`
  (Δ=23), `out=1681 → next cc=1691` (Δ=10). Without the correction a short follow-up
  would display `input ≈ 1681` instead of ~10.

`cache-read` is deliberately `Σcr` (not final `cr`): `Σcr ≈ N × context` is a "how
much did the turn cost" proxy, and the `count` field lets the reader tell a deep
context from a many-call turn. This is the intended *mixed* view — cost-flavoured
`Σcr` and `Σout` alongside the logical `input`.
