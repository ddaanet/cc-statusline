# Always-on sparkline — design

**Created**: 2026-05-26
**Status**: design approved, pending implementation plan

## Problem

The per-turn token sparkline (statusline line 3) is suppressed when the
session is idle — the most recent assistant API call ended with
`stop_reason == "end_turn"`, or a user prompt is staged but no assistant
response has started yet. This was deliberate (see
`claude/design-decisions.md` §5): the trailing running duration
(`now − turn_start`) keeps growing while you sit idle, which is more
misleading than informative.

The user wants an opt-in setting that keeps the sparkline visible at all
times, including when idle, with a non-misleading trailing value.

## Setting

A dedicated flag file: `~/.claude/sparkline-always-on`.

- **Presence = on.** Absence = off (current behavior).
- Matches the existing `~/.claude/account-mode` plain-file convention; no
  jq parse needed.
- No CLI subcommand. Toggle manually:
  - `touch ~/.claude/sparkline-always-on` — enable
  - `rm ~/.claude/sparkline-always-on` — disable
- Documented in `claude/README.md`.

## Behavior

### Threading the flag

Read the flag once in `statusline-command.sh`:

```sh
SPARK_ALWAYS_ON=0
[[ -f "$HOME/.claude/sparkline-always-on" ]] && SPARK_ALWAYS_ON=1
```

Pass it as a third argument to `display_turn_sparkline`:

```sh
display_turn_sparkline "$TRANSCRIPT_PATH" "" "$SPARK_ALWAYS_ON"
```

The lib function stays pure (no hardcoded path stat) so it remains
testable. Signature becomes
`display_turn_sparkline(transcript_path, max_turns=30, always_on=0)`.

### Idle definition

Inside `display_turn_sparkline`, after the pre-pass that computes
`trail_last_stop`, `trail_last_api_epoch`, `trail_last_u_epoch`, and
`_staging_u`:

```
idle = (trail_last_stop == "end_turn") || (_staging_u non-empty)
```

The three current early-return cases become:

| Case | Condition | always_on = 0 | always_on = 1 |
|------|-----------|---------------|---------------|
| no anchors | `a_turn_anchors` empty | return | **return** (nothing to draw) |
| idle (end_turn) | `trail_last_stop == end_turn` | return | render |
| pending U | `_staging_u` non-empty | return | render |

The no-anchors return fires regardless of the flag — there are no bars to
show on a brand-new session.

### Trailing element

The historical bars and inter-turn separators render identically in all
cases. Only the trailing element after the last turn's cells differs:

- **Not idle** (AI mid-turn, `stop_reason != end_turn`, no pending U):
  unchanged — running `format_age(now − trail_ref)`.
- **Idle + always_on**: final turn's *completed* duration,
  `format_age(trail_last_api_epoch − trail_last_u_epoch)` — a static
  value that does not grow while idle.
  - **Stale guard**: if the idle gap `now − trail_last_api_epoch >
    cache_ttl` (3600s), drop the trailing entirely (bars only). The cache
    has expired; the stale duration adds no value.

### Rendering examples

```
idle, fresh:   …  ▂▄█ 8s│3s ▃▅█ 12s     12s = completed final-turn work (static)
idle, >1h:     …  ▂▄█ 8s│3s ▃▅█          trailing dropped (cache expired)
running:       …  ▂▄█ 8s│3s ▃▅█ 47s     live now − turn start (unchanged)
flag absent:   (suppressed when idle — unchanged)
```

### Width-aware truncation

Unchanged. The backward walk already uses `trailing_vis` for its budget;
when the trailing is dropped (stale idle), `trailing_vis = 0` and the
existing accounting handles it with no special-casing.

## Files touched

- `claude/lib/sparkline.sh` — add `always_on` param; compute `idle`; gate
  the two idle returns on `!always_on`; branch trailing duration on
  `idle` with the stale guard.
- `claude/statusline-command.sh` — read flag, pass as 3rd arg.
- `claude/README.md` — document the flag and manual toggle.
- `claude/design-decisions.md` — note the always-on option under §5.

## Out of scope (YAGNI)

- No `claude-account` subcommand for the toggle.
- No dimming variant for the stale trailing — drop only.
- No change to the running (non-idle) trailing behavior.
