# Statusline — Design Document

**Status**: living document. Update the relevant section *and* the changelog
whenever behaviour changes; do not flatten decisions into summaries — the
rationale is the point.

**Scope**: `statusline-command.sh` and `lib/*.sh` in this repository — everything
Claude Code renders below the prompt. Account switching itself is in
[`account-switcher-design.md`](account-switcher-design.md); the statusline only
*reads* the mode it publishes.

---

## 1. Functional Requirements

**FR1 — Line 1 status block.** One row (reflowed onto more rows when narrow)
carrying, in order: model indicator, pyenv, directory, git branch, cost,
context, plan/account section, cache-expiry timer.

**FR2 — Account badge.** 🎫 Plan / 💳 API immediately confirms which account is
active (mode read from `~/.claude/account-mode`).

**FR3 — Plan-mode limits.** Each rate-limit window renders `A%/B% C`:
A = `used_percentage` (99 promoted to 100, §4.15), B = window-elapsed percent,
C = a vertical bar. A window renders whenever its `used_percentage` field is
present/non-null (`0%/B% ▁` at zero); the section hides only when *neither*
window has the field.

**FR4 — API-mode usage.** Token counts instead of limits:
`💳 API 240k today | 1.2M week`, sourced from `stats-cache.json`. Cost
estimation is deliberately not shown (§4.13).

**FR5 — Identity group.** The head of line 1 answers "what am I talking to right
now": model rank glyph + name, reasoning effort, output style, fast mode, and a
nothink indicator when thinking is disabled — e.g.
`❷ Opus ● high  learning 󱐋 Fast 󰥓 Nothink`.
Every element is read from the statusline payload; nothing is inferred from
settings files. Elements are omitted when they do not apply, and the whole group
elides to glyphs as the terminal narrows (§4.17).

**FR6 — Context usage.** `🧠 42k`, coloured and optionally accompanied by a
growth bar, reflecting *current* context occupancy (not cumulative session
totals).

**FR7 — Cost.** Session cost including subagents.

**FR8 — Selectable second line.** `~/.claude/statusline-line2` selects
`sparkline` (default) or `stats`.

**FR9 — Sparkline mode.** Three cells per API call — cache, read, write —
across the session's call stream, with turn separators carrying turn duration
and user think time.

**FR10 — Stats mode.** One numeric group per *user turn*: call count,
Σcache-read, effective input, Σoutput, duration, with cold-cache markers and
inter-turn wait separators.

**FR11 — Width awareness.** Everything fits the terminal: line 1 reflows, line 2
truncates from the left (oldest first).

**FR12 — Idle behaviour.** When the session is idle the sparkline is suppressed
by default; opt out with the flag file `~/.claude/sparkline-always-on`.

---

## 2. Non-Functional Requirements

**NFR1 — Never break the statusline.** `statusline-command.sh` must always exit
0; a non-zero exit makes the Claude CLI suppress statusline output entirely.
(Historic bug: `get_thinking_state()` returned 1 when settings were missing or
thinking was disabled, and that propagated to the script exit. The function was
deleted in `63e54a8` — thinking state now comes from the payload, §4.17 — but
the failure mode it illustrates applies to any helper whose last command is a
test.)

**NFR2 — Cheap on every render.** The script runs on every redraw. Prefer
payload fields over file parsing; cache derived work (subagent cost and the
transcript-derived streams are cached by file size + mtime, §4.18). The payload
is read in a single `jq` fork, and a render over an unchanged transcript forks
`jq` once.

**NFR3 — Defensive arithmetic.** Every numeric input is validated before bash
arithmetic — bash integer ops fail silently on empty strings, and empty
transcript values are normal when a file is missing or parsing fails. Pattern:
`[ -z "$var" ] || [ "$var" = "unset" ] || ! [[ "$var" =~ ^[0-9]+$ ]]`. Indices
into glyph tables are clamped.

**NFR4 — Colour discipline.** The CLI renders the statusline dim; colour
handling must not leak state across segments (§4.11).

**NFR5 — Compact wire output.** SGR background/foreground codes are deduped via
module-level state tracking.

**NFR6 — Testable pure helpers.** Display logic lives in pure functions
(`_spark_trailing`, `_turn_input`, `_turn_marker`, `layout_line1`,
`window_elapsed_pct`, …) covered by `test-statusline-helpers.sh`; regressions
get a fixture there.

**NFR7 — Theme-neutral colours.** 16-colour ANSI base colours only, no bright
variants: GREEN = input/additions, YELLOW = output, CYAN = cached/timing,
RED = deletions. One deliberate exception: `BRMAGENTA` alternates with `MAGENTA`
in the context growth bar past 250k, and colours that bar's elision `⋯` (§4.12).
It carries no meaning of its own — it only makes block boundaries countable — so
a theme where the two are indistinguishable degrades to the pre-2026-07-30 flat
magenta run without losing information. The `⋯` survives such a theme too: it is
distinguishable from the blocks around it by shape, not by colour.

---

## 3. Architecture

### 3.1 Components

| File | Responsibility |
|------|----------------|
| `statusline-command.sh` | Entry point; reads payload, probes width, dispatches line 1/line 2, always `exit 0` |
| `lib/line1-layout.sh` | Pure layout engine: `layout_line1` / `emit_line1` |
| `lib/model-display.sh` | Pure identity group: `render_model_sec` / `set_model_sec` |
| `lib/account-display.sh` | Account badge, plan/API section, timer |
| `lib/context-display.sh` | Context value, colour gradient, growth bar |
| `lib/sparkline.sh` | Per-API-call sparkline (line 2, `sparkline` mode) |
| `lib/turn-stats.sh` | Per-user-turn stats (line 2, `stats` mode) |
| `lib/transcript-cache.sh` | `_tx_cached`: size+mtime memoisation of transcript `jq` output (§4.18) |
| `lib/subagent-cost.sh` | Subagent cost from subagent transcripts |
| `lib/format-utils.sh` | `humanize_tokens`, `format_turn_dur`, `format_age`, `window_elapsed_pct`, `plan_pace_color`; state dir `cc_state_dir_init` / `_cc_private_dir` / `_cc_write_file` (§4.18) |
| `lib/colors.sh` | SGR constants: `RESET`, `RESET_FG`, `RESET_DIM`, `BOLD` |
| *external* `account-validation.sh` | `get_mode` / `get_api_provider` / `validate_state`, shared with the `claude-account` switcher and kept in that repo. Located via `$CC_STATUSLINE_ACCOUNT_LIB`, else the first line of `~/.claude/statusline-account-lib`, else `$HOME/code/cc-switch/lib/account-validation.sh`. Absent → no-op fallbacks (mode `plan`, provider `anthropic`, state consistent) and the account badge is skipped |

The entry point resolves its own directory through the `~/.claude/statusline-command.sh` symlink (a `while [ -L ]` walk, no `readlink -f`, for bash 3.2) and sources `lib/` relative to it.

### 3.2 Data sources

| Source | Used for |
|--------|----------|
| Statusline JSON payload (also dumped to `statusbar.json` in the private state dir for debugging, §4.18) | model, dir, cost, `context_window.current_usage`, `rate_limits`, `effort.level`, `output_style.name`, `fast_mode`, `thinking.enabled` |
| Session transcript `.jsonl` | sparkline / stats streams, context fallback, cache-expiry timestamp — all via the state dir's `tx-cache/` (§4.18) |
| `<session>/subagents/agent-*.jsonl` | subagent cost |
| `stats-cache.json` | API-mode daily/weekly token counts |
| `~/.claude/account-mode` | account badge |
| Flag files: `statusline-line2`, `sparkline-always-on`, `statusline-chrome-cols` | mode/behaviour switches |

### 3.3 Terminal width

Claude Code does **not** pass the terminal column width to the statusline
script — not in the JSON payload, not in the environment. Width is probed:
`tput cols` → `stty size < /dev/tty` → fallback 120. The right-edge chrome
reservation (§4.10) is subtracted to form `EFFECTIVE_COLS`, which bounds *every*
emitted row.

---

## 4. Design Decisions

### 4.1 Line 1 reflows rather than drops (2026-07-12)

Line 1 wraps onto extra rows instead of discarding sections. `layout_line1`
picks the widest of an ordered ladder of layouts whose every row fits the
budget:

- **Tier A** — plan section wraps to its own row; then the context bar's middle
  elides (§4.12); then the identity group elides full → mid → compact (§4.17);
  then the context bar drops entirely.
- **Tier B** — split `[model pyenv dir]` / `[branch + context]`, the head itself
  stepping full → mid → compact.
- **Tier C** — branch and context each get their own row, same three heads.

Never dropped: identity group (it only *elides*), pyenv, dir, branch, cost,
context *value*, timer. Only the context *bar* (droppable) and the plan section
(wraps via `pick_plan_variant`, then omitted if even `no_bars` won't fit) give
way.

**Identity labels are spent before the context bar** (2026-07-29, reversing the
original order). The labels restate what their glyphs already say — `❷` is
`Opus`, `●` is `High` — so dropping them costs recognition speed at worst. The
🧠 bar is the only place the context figure gets a magnitude at a glance, and
the number beside it does not substitute for it.

**But the bar's middle is elided before either** (2026-07-30). That ordering
refines the rule above rather than reversing it: the labels are spent before the
bar is *dropped*, because dropping is what costs the magnitude. Eliding costs
neither — the hidden ranges are a flat magenta/bright-magenta run that the
retained head and tail already summarise — so it is the cheapest thing on the
ladder and goes first. Below 400k the elided string is identical to the full bar
(§4.12), which makes the rung inert on ordinary sessions rather than a silent
change to how they render.

Cost moved **before** context. The cache-expiry timer was extracted out of
`render_plan_right` into `render_timer` so it renders in any mode and stays
glued after context.

**Rationale**: on a narrow terminal the dropped sections were exactly the ones
being watched; a second row costs nothing but vertical space.

### 4.2 Plan display: `A%/B% C` per window (2026-07-02)

A = `used_percentage`, B = window-elapsed percent (`window_elapsed_pct`),
C = the bar. One pace colour spans A%/B% and the bar (`plan_pace_color`): red if
A > 94 (saturation wins), else green if A < B (under pace), else yellow (A ≥ B;
ties yellow). Bold red is retained when A ≥ 100.

Truncation order within the plan-mode ladder: `Plan` label → `5h`/`7d` labels →
bars → identity labels → context bar → cost. The context 🧠 bar is deliberately
*not* in the first batch.

Reset-time rendering: 5h always `HH:MM`; 7d `Ddd` (e.g. `Fri`) if not today,
`HH:MM` if today. `rate_limits` comes from the payload — no OAuth call, no
network on render.

**Rationale**: B conveys pace directly (burn = A/B) without a separate metric.

### 4.3 Per-turn sparkline — cell semantics (2026-04-20)

Three cells per API call:

| Cell | Value |
|------|-------|
| cache | `cache_read_input_tokens / 10` |
| read | `input_tokens + cache_creation_input_tokens × 2` |
| write | `output_tokens × 5` |

Cache writes are weighted ×2 because Claude Code uses 1h-TTL caching, billed at
2× base input. In steady-state caching the freshly-processed prompt is counted
as `cache_creation_input_tokens`, not `input_tokens` (which collapses to ~2), so
omitting `cc` left the read cell almost always blank.

Uniform ×5 log scale, bounds 1k/5k/25k/125k shared across all three kinds (after
cost normalisation); `◆` with inverse video marks saturation above 125k.

Full spec: `plans/2026-04-20-sparkline.md`.

### 4.4 Sparkline encoding: position, not intensity (2026-05-27)

All three cells share one blue→green→yellow→red palette (hue = magnitude). Dim
(cache) and bright (write) intensities were dropped: faint (SGR 2) dims only the
foreground, but the block glyphs sit on a coloured background, so the dim cache
cell was visually indistinguishable from the normal read cell. Kind is read by
*position* within a turn (cache · read · write). Triplets stay legible via a
plain default-style centred-dot `·` separator between continuation API calls.

The CLI's outer dim is cleared at the sparkline start so every cell renders at
full, uniform intensity.

### 4.5 Turn boundaries and idle handling

- Between user turns the separator is `<turn_dur>│<user_wait>` — turn work time
  before the separator, think time after. `│` becomes a space when the gap
  exceeds 1h (cache expired).
- Empty user events (slash commands with no following assistant call) produce no
  separator — only the last U before the next A counts as the turn trigger.
- While a turn is running (`stop_reason != "end_turn"`), line-end emits
  `<dur_so_far>` alone: no separator, because the turn has not ended.
- When the session is idle (last assistant call ended with
  `stop_reason=end_turn`) the sparkline is suppressed entirely — a frozen
  `<turn_dur>│<HH:MM>` trailing on an idle statusline was more misleading than
  informative. The idle check looks *only* at the last assistant `stop_reason`,
  never at pending user entries: slash commands and command stdout write user
  events without triggering an API call, so a pending U does not imply "AI about
  to respond".
- A pre-trim pass captures per-A turn anchors over the full stream. The last
  turn's anchor feeds the trailing running duration; the first *displayed*
  turn's anchor is re-injected as a synthetic U after trimming so its duration
  shows correctly even when the triggering U fell outside the display window
  (long tool-use sessions, or a first visible turn that is the tail of a longer
  one).

### 4.6 Turn trigger excludes system-injected prompts (2026-07-06)

The U filter shared by `lib/sparkline.sh` and `lib/turn-stats.sh` drops
`isMeta:true` (skill/slash-command injections), `tool_result` users, and — since
2026-07-06 — users with `promptSource == "system"`: harness-injected prompts such
as `<task-notification>` background subagent-completion notices.

Those arrive as `type:user`, `isMeta:null`, plain-string content, so they passed
the old filter and segmented the line on every subagent completion: a background
task finishing mid-idle spawned a spurious turn whose epoch anchored a bogus
multi-hour duration on the following turn.

`origin.kind == "task-notification"` is the narrower signal;
`promptSource == "system"` is used because it is the correct semantic level (not
user-initiated) and covers any future system notification kind. Regression test
(fixture with a `<task-notification>` U between two calls of one turn) asserts it
splits neither the sparkline nor the stats line.

### 4.7 Always-on sparkline (2026-05-26)

Idle suppression is opt-out via the flag file `~/.claude/sparkline-always-on`
(presence = on; toggle with `touch`/`rm`, no CLI command). When set, idle
sessions still render historical bars; the trailing element becomes the final
turn's *completed* duration (`last_api − last_u`, static) rather than the growing
`now − last_u`, and is dropped once the session has been idle longer than the
cache TTL (1h). Threaded as a third `always_on` argument to
`display_turn_sparkline`; the trailing decision lives in the pure
`_spark_trailing` helper. Spec: `plans/2026-05-26-sparkline-always-on.md`.

### 4.8 Line 2 `stats` mode (2026-06-29, shipped 2026-06-30)

One numeric group per *user turn* rather than per API call: turn count,
Σcache-read, effective input, Σoutput, duration, with `❄`/`N❄` cold-cache
markers; the running turn renders live. Colourised: marker bold-cyan, call count
bold, cache-read blue, input green, output yellow, duration default. `vislen`
strips SGR so width truncation is unaffected; a leading `RESET` clears inherited
SGR and every segment self-resets.

Groups are joined by ` ·<wait>· `, carrying user think time — the idle span from
one turn's last API call to the next turn's anchor
(`t_anchor[i+1] − t_lastapi[i]`, clamped ≥ 0), rendered with the same compact
`format_age` (`52s`/`8m`/`3h`/`2d`) the sparkline uses. There is no trailing
separator: the running turn's live duration already reflects the current wait.

Example: `❄ 2× 100k/140k/1k 52s ·8m· 1× 60k/258/900 1m18`

**Input formula** (simplified 2026-07-18):
`input = Σcc − Σout + last_out − prev_last_out`. A cold turn's cache-creation
spike now inflates `input` visibly, and the `❄` marker distinguishes that
re-cache from a genuinely large user message.

**Rationale**: per-user-turn numbers were wanted *alongside* the educational
per-call sparkline, not instead of it.

Full spec and signed-off formula derivation:
`plans/2026-06-25-statusline-line2-stats.md`; implementation plan
`plans/2026-06-30-statusline-line2-stats-impl.md`. Enable with
`echo stats > ~/.claude/statusline-line2`.

### 4.9 Cold-cache detection is structural, never time-based

With `cap = cr + cc` from the previous call, `drop = cap − cr`, and
`refresh = cc + in`, a turn is cold when:

```
(refresh ≥ drop || cr == 0) && 2·drop > cap
```

`refresh ≥ drop` rejects a compaction/clear (context shrinks, only a small
summary is re-cached, `cc ≪ drop`). But it also rejected *genuine* expiries
whenever the context happened to shrink at the same time: on a full expiry the
re-cache covers only the *current* context, so if that context is smaller than
what was lost, `cc < drop` even though the cache truly went cold. Observed in
session `4999475a` — two turns with `cr=0` after 11h and 3h idle gaps went
unmarked. Fix (2026-07-18): a full collapse (`cr == 0`, nothing read back) is
*unconditionally* cold; `refresh ≥ drop` now only gates partial drops (`cr > 0`).

Compaction stays correctly unmarked: real `/compact` boundaries in that same
session kept `cr` at the surviving system-prompt floor (`cr = 26152`, not 0), so
they still fall under the `refresh ≥ drop` branch. Regression test `ts-l` in
`test-statusline-helpers.sh`.

**Empirical basis — prompt-cache persistence has no reliable fixed TTL.**
Observed within one Claude Code session (this repo's transcript, model
`claude-opus-4-8`, 2026-06-24 21:06 → 2026-06-29 18:43 UTC):

| Gap | Duration | Result | `cache_read` | re-cache `cc` |
|-----|----------|--------|--------------|---------------|
| 06-24 21:45 → 06-25 09:47 | 12.0h | survived | 70,874 → 73,937 | 269 |
| 06-25 10:35 → 12:45 | 2.2h | cold miss | 133,254 → 0 | 139,704 |
| 06-25 12:54 → 16:28 | 3.6h | cold miss | 144,199 → 0 | 155,315 |
| 06-25 16:28 → 06-26 09:49 | 17.4h | cold miss (re-expiry) | 0 → 0 | 162,066 |
| 06-26 09:56 → 06-29 18:09 | 80.2h | survived intact | 174,272 → 175,210 | 86 |

A 2.2h gap expired the cache but an 80h gap three days later did not; a 12h
overnight gap survived while a later 2.2h gap did not. No fixed TTL explains
this. **Implication: detect cold-cache events structurally — `cache_read`
dropping below the previous call's `cache_read + cache_creation` — never by
elapsed time.** (The sparkline's 1h-TTL assumption for the always-on trailing
element predates this finding and should be revisited.)

Related: `input_tokens` collapses to ~2 in steady state. Freshly-processed
prompt content is billed as `cache_creation`, not `input_tokens`, because Claude
Code puts a cache breakpoint over new content. The meaningful "new tokens this
turn" signal is `cache_creation` (verified: a cold `cc=22059` then next
`cc=24539` summed to the following `cr=46598` exactly).

### 4.10 Right-edge chrome reservation is a deliberate guess (2026-07-20)

The right-edge chrome is not always `/rc`. Decompiled from the 2.1.215 bundle it
is an unshrinkable (`flexShrink:0`, `marginLeft:"auto"`) chain of ` · `-joined
labels rendered right-aligned: `hipaa` → cloud → IDE → `Debug` → the bridge
marker (`/rc` or `/rc active`) → PR → mode labels (`focus`, `memory paused`) →
notifications (stacked in a column above, so they add height, not width).
Observed combinations: `/rc`, `/rc · focus`, `focus`.

*Why `/rc` drops first*: it is gated on raw terminal width — `bridge && cols >=
60 && …` — an absolute threshold independent of what the statusline emits. The
other labels have no such gate.

*Why the rest wraps below*: the container is
`<Box width={cols} flexWrap="wrap" paddingLeft={2} paddingRight={focus?1:2}
columnGap={1}>{statusline}{indicators}</Box>`. Both children are atomic; the
indicator block never truncates, so it either fits beside row 1 or wraps whole
onto its own row after the entire status block.

**Decision**: the block's width is unobservable — not in the payload, not in the
environment, and focus mode is a runtime toggle persisted nowhere. The
reservation is therefore a static guess, defaulting to 4 (`/rc` + the 1-column
gap) and overridable via `~/.claude/statusline-chrome-cols` (`lib`-free read in
`statusline-command.sh`; non-numeric → 4). Reference widths: `/rc · focus` = 12,
`/rc active · focus · memory paused` = 35.

The reservation applies to **every** row — each line-1 row, line 2, and the
sparkline/stats line — folded into `EFFECTIVE_COLS` (2026-07-14; previously
row-1-only). If any row filled the full width, the marker would be pushed out
after the whole status block instead of sitting at row 1's right edge.

**Rationale for not reserving worst case**: over-reservation costs those columns
on *every* row, permanently, for labels usually absent; under-reservation costs
one extra row only while the extra labels show. The failure mode is cosmetic
either way, so the cheap default wins and the user widens it if they live in
focus mode.

### 4.11 Colour and intensity handling

**Use `RESET_DIM`/`RESET_FG`, not `RESET`.** The Claude CLI sets the whole
statusline dim. `RESET` (`\033[0m`) clears all attributes including that dim
state; `RESET_FG` (`\033[39m`) resets only the foreground. Example:
`🧠 ${GREEN}42k${RESET_FG}`.

**Bug found and fixed (2026-07-01)**: the rule was only ever followed in
`lib/sparkline.sh`. Every other file (`lib/account-display.sh`,
`lib/turn-stats.sh`, `lib/context-display.sh`, `statusline-command.sh`) closed
coloured/bold segments with `${RESET}`. `RESET_BOLD` (`\033[22m`, "normal
intensity") clears bold *and* dim — they share one intensity slot — so every
such segment, and everything after it on the line, permanently lost the CLI's
outer dim. Fix: `RESET_DIM` (`RESET` + `\033[2m`) added to `lib/colors.sh` and
those four files switched to it. `sparkline.sh` keeps plain `RESET`: it
deliberately strips dim so cells render at full uniform intensity (§4.4).

**Follow-up regression**: after that fix, bold segments following a `RESET_DIM`
(stats-mode turn count, `❄` marker, git branch name, `$` cost sign) rendered dim
instead of bold. The CLI's renderer apparently does not treat bold (`\033[1m`) /
faint (`\033[2m`) as one tri-state intensity the way real terminals do — a bare
`\033[1m` right after `\033[2m` still showed dim. Fix: `BOLD` now emits
`\033[22m\033[1m`, explicitly clearing intensity before setting bold.

### 4.12 Context usage from `current_usage` (2026-01-19)

Sum the four fields of `context_window.current_usage`:
`input_tokens + output_tokens + cache_creation_input_tokens +
cache_read_input_tokens`. This matches `/context` output. The field can be
`null` early in a session (documented behaviour) — fall back to transcript
parsing then. Display: `🧠 42k` (single value, no parentheses).

Do **not** use `context_window.total_input_tokens` / `total_output_tokens`:
those accumulate across the session (GitHub #13783, still open) and do not
reflect actual context occupancy.

Colour gradient and growth bar (one vertical-growth char per 50k range,
`▁▂▃▄▅▆▇█`):

| Range | Colour |
|-------|--------|
| 0–50k | Blue |
| 50–100k | Green |
| 100–150k | Yellow |
| 150–200k | Red |
| 200–250k | Magenta |
| 250–300k | Bright magenta |
| 300k+ | alternating Magenta / Bright magenta, one per 50k |

**Rationale**: a payload field already in memory is faster and more reliable
than parsing the transcript on every render, and handles the zero-token edge
case properly (the field is null, not zero).

**Bar ranges are unbounded past 200k** (2026-07-30). The old implementation held
a five-entry colour array and iterated `num_ranges` times, so the bar physically
stopped at five blocks: a 1M-context session showed the same `█████` from 250k
to 1M — precisely the range where magnitude matters most. The ramp now continues
for as long as there are tokens left (hard-stopped at 32 blocks = 1.6M so a
bogus payload value cannot spin the loop; row truncation handles the width).

Alternating the colour past 250k is what makes that bar readable: 20 identical
magenta blocks read as one smear, whereas an alternating run can be counted in
pairs. The alternation is the *only* job of the second colour — the number beside
the bar remains authoritative, and the value's own colour (`get_token_color`)
deliberately stops at magenta for everything ≥ 200k, because a single glyph has
no boundaries to count.

**Under width pressure the bar elides its middle** (2026-07-30). Unbounded
growth costs columns exactly where they are scarcest, so `display_token_bar`
takes an `elide` mode that keeps the 0–250k head as five full blocks, emits one
`⋯` (U+22EF, `BRMAGENTA`) for every hidden range, then the last two blocks in
their true parity colours and heights:

```
1.0M   █████⋯██     ranges 0–4, ⋯ for 5–17, then 18 (magenta) and 19 (brmagenta)
1.02M  █████⋯█▃     tail keeps the live partial fill
```

The tail is two blocks, not one, so the magenta alternation stays legible
through the elision — a lone tail block has no neighbour to alternate against.
U+22EF rather than U+2026: `vis_truncate` writes `…` when a row is genuinely
cut, and the two must not be confused. Width is a flat 8 columns at any size.

Elision applies only from **9 blocks (> 400k)**, where 8 columns is actually a
saving; below that the elided and full forms are byte-identical, so the ladder's
elided rung (§4.1) is inert and no session under 400k changes how it renders.

**The bar owns the space before it** (2026-07-30). `CTX_SEC` used to end with a
trailing space and `BAR_SEC` was appended bare, so the space survived both ways
the bar can vanish — dropped by the layout ladder (§4.1), or empty because
context is 0/unparseable. That left `🧠 260k` + 3 spaces before the timer's own
2-space section gap, or a trailing space at end of row. The space is now
prepended to a non-empty `BAR_SEC` instead, which fixes both paths at once and
keeps the section gap at exactly the canonical two columns.

### 4.13 Cost includes subagents (2026-07-12)

The payload's `total_cost_usd` is main-thread only. `lib/subagent-cost.sh`
computes per-subagent cost from `<session>/subagents/agent-*.jsonl` token usage ×
per-model base price (cache read ×0.1, 5m write ×1.25, 1h write ×2.0), deduped
by `message.id`, cached by file size + mtime in the private state dir (§4.18).

Validated by reproducing a session's main-thread `total_cost_usd` from its
transcript (Opus 4.8 = $5/$25). `claude-model-info.py` misprices Opus 4.8 as
4.5's $15/$75, so a **static table in `subagent-cost.sh` is the source of
truth**.

Spec: `plans/2026-07-12-statusline-wrap-design.md`; plan:
`plans/2026-07-12-statusline-wrap-plan.md`.

### 4.14 Line-2 truncation walks backward from newest

The sparkline pre-computes per-A separator widths, then walks backward from the
latest A accumulating width until the budget is exceeded, dropping the oldest A
units from the left. The first kept A's separator is suppressed (it would
reference a dropped turn) and is excluded from the width budget.

### 4.15 A saturated window arrives as 99, not 100 (2026-07-29)

A full weekly quota rendered as `99%`. The payload is faithful — the *server*
never sends 100 while overage credits are absorbing the excess.

**Chain** (decompiled from the 2.1.220 bundle): the response header
`anthropic-ratelimit-unified-{5h,7d}-utilization` is read verbatim as a 0–1
fraction (`SLu()`: `{utilization: Number(o), resets_at: …}`), and the statusline
payload is built as `used_percentage: utilization * 100`. No rounding is applied
client-side; the value in the payload *is* the header.

**Measured 2026-07-29 08:12 UTC**, same account, both sources fresh:

| Source | 7d value | Other fields |
|--------|----------|--------------|
| `anthropic-ratelimit-unified-7d-utilization` header | `0.99` | `7d-status: allowed_warning`, `overage-in-use: true`, `representative-claim: seven_day` |
| `GET /api/oauth/usage` → `seven_day.utilization` | `100.0` | `severity: critical`, `is_active: true`, `extra_usage` 4726/10000 credits |

Not staleness: `5h-reset` advanced between calls, so the headers were live. The
header is *pinned* below 1.0 — it drives client-side blocking, and blocking
would be wrong while extra usage covers the overflow (the bundle carries a
separate `7d_oi` = `seven_day_overage_included` claim for exactly this). The
headers are coarse elsewhere too: `overage-utilization: 0.0` while the API
reported 47.26%.

Claude Code's own `/usage` screen shares the artifact — it renders
`${Math.floor(utilization)}% used`.

**Decision**: promote `a == 99` to `100` in `_render_plan_window`. The
approximation is deliberate and one step wide — 98 is left alone, so this is a
*promotion*, not a `>= 99` threshold. It costs the ability to distinguish a
genuine 99% from a saturated window, which is precisely the distinction the
payload cannot express anyway.

A literal `100` from the payload would mean the cap is gone, but that no
longer gets a distinct glyph (2026-08-10: dropped nf-fa-warning U+F071 — bold
+ red already marks at-limit, and a second at-limit cue read as noise). 99 and
a genuine 100 now render identically. The `## _render_plan_window` block in
`test-statusline-helpers.sh` pins both: 98 unchanged, 99 → 100 rendering the
same as a literal 100.

**Not fixable from the payload.** None of the discriminating signals —
`overage-in-use`, `7d-status`, `representative-claim` — reach the statusline;
the payload carries only `used_percentage` + `resets_at` for two windows. Full
precision requires the OAuth endpoint (§5).

Cross-reference: `account-switcher-design.md` §4.4 treats ≥ 99% as "at limit"
for switch decisions. Same empirical ceiling, different mechanism — the switcher
queries the OAuth API directly and can afford the network call.

### 4.16 One colour close between bar and reset time (2026-07-29)

`display_vertical_bar` closes with `RESET_DIM`, and the reset-time branch closed
the pace colour again — two `RESET_DIM` runs (8 SGR codes) whenever a
not-at-limit window rendered both a bar and a reset time. Idempotent, so the
display was correct, but it cut against NFR5.

The second close is load-bearing on the paths where the bar does *not* run
(`show_bars=0`, or `b` empty), so it cannot simply be deleted. A `color_open`
flag now records whether the bar already closed the colour. The at-limit path is
unaffected: it deliberately reopens `BOLD+color` after the bar so bold red spans
the reset time.

### 4.17 Identity group: rank, effort, style, fast mode, nothink (2026-07-29, style added 2026-07-31)

`lib/model-display.sh` renders one group at the head of line 1, in a fixed
element order — **model · effort · style · fast · nothink**.

**Model rank.** Negative circled digits, ordered by capability, so the glyph
alone reads as a tier:

| `display_name` prefix | Glyph | Colour |
|---|---|---|
| `Fable ` | `❶` U+2776 | MAGENTA |
| `Opus ` | `❷` U+2777 | YELLOW |
| `Sonnet ` | `❸` U+2778 | GREEN |
| `Haiku ` | `❹` U+2779 | RED |
| _anything else_ | — | RED |

Colours are unchanged from the pre-rank scheme (gold = premium, green =
default/safe, red = capability warning); only the digit shifted when Fable took
rank 1. An unrecognised model gets no glyph, so there is nothing to compact
*to* — its full display name survives every elision level.

**Effort**, from `.effort.level`:

| Level | Glyph | Label |
|---|---|---|
| `low` | `○` U+25CB | low |
| `medium` | `◐` U+25D0 | medium |
| `high` | `●` U+25CF | high |
| `xhigh` | `◉` U+25C9 | xhigh |
| `max` | `◈` U+25C8 | max |
| absent / unrecognised | — | element omitted |

Rendered **uncoloured** — it opens with `RESET_DIM` so the model colour cannot
leak in. Grading it by colour was rejected (§5). Labels are lowercase
(2026-07-31): they are payload enum values, not proper nouns, and title case
made them read as headings competing with the model name beside them.

**Output style**, from `.output_style.name` — same uncoloured treatment as
effort, and the same question (how is this session configured to respond):

| `.output_style.name` | Rune | Label |
|---|---|---|
| `Explanatory` | `` U+F002 nf-fa-magnifying_glass | explanatory |
| `Learning` | `` U+F19D nf-fa-graduation_cap | learning |
| `Proactive` | `` U+F050 nf-fa-forward_fast | proactive |
| `Concise` | `` U+F0C4 nf-fa-scissors | concise |
| _any other name_ | `󰴓` U+F0D13 nf-md-fountain_pen_tip | the name itself |
| `default` / absent | — | element omitted |

`default` is the *absence* of a style, so it is omitted: an element here always
means the session has been steered off baseline. A custom style shows its own
name under the pen rune rather than a literal "other" — the rune already says
"unclassified", and the name is the part that carries information.

The label is the style name **lowercased**, which the `jq` extraction does
(`ascii_downcase`) rather than `model-display.sh`: bash 3.2 has no `${var,,}`,
the module is fork-free by design, and that `jq` fork already runs. So the
module receives a normalised token and matches lowercase arms — mirroring
`effort`, which is a lowercase payload enum already.

**Fast mode** `󱐋 Fast` (U+F140B, nf-md-lightning_bolt) in MAGENTA when
`.fast_mode == true`. **Nothink** `󰥓 Nothink` (U+F0953, nf-md-sleep) in RED when
`.thinking.enabled == false`.

**Three presentation levels**, which the line-1 ladder (§4.1) elides through:

| Level | model | effort | style | fast | nothink |
|---|---|---|---|---|---|
| `full` | glyph + name | glyph + label | rune + name | glyph + label | glyph + label |
| `mid` | glyph | glyph | rune | glyph | glyph + label |
| `min` | glyph | glyph | rune | glyph | glyph |

Nothink keeps its label one level longer than the rest: it is the *surprising*
state, and a bare glyph among other bare glyphs is easy to miss.

**Spacing rule.** Elements are joined by a **single** space at every level; the
group closes with `RESET_DIM` + two spaces, the established line-1 section
separator. So:

```
full  ❷ Opus ● high  learning 󱐋 Fast 󰥓 Nothink␣␣
mid   ❷ ●  󱐋 󰥓 Nothink␣␣
min   ❷ ●  󱐋 󰥓␣␣
```

The group reads as one unit rather than five sections, which is the point — it
answers a single question. The two-space separator is reserved for the boundary
*between* line-1 sections, so widening the intra-group joins to two at `full`
(considered, then dropped) would have made the identity group look like five
peers of dir and branch.

**Payload facts** (verified against a live payload and the 2.1.220 bundle):

- `.effort.level` is **conditionally present** — built as
  `…OI(y) && {effort:{level:yj(y,p)}}`, so the key is absent entirely for models
  without effort support (`claude-3-*`, `opus-4-0`, `opus-4-1`, `sonnet-4-5`).
  Absence must omit the element, not default it.
- The valid levels are exactly `EL = ["low","medium","high","xhigh","max"]`.
  `ultracode` is an *alias* mapping to `xhigh`; there is no `ultra` level.
- `.fast_mode` and `.thinking.enabled` are always present.
- `.output_style.name` is always present too, built as `output_style:{name:_}`.
  The built-in names are exactly `default`, `Explanatory`, `Learning`,
  `Proactive` (bundle table `mfe`, keyed by `GB="default"` plus the three) and,
  since 2026-08-25, `Concise` (observed via `/config`, not re-decompiled);
  anything else is a user style from `~/.claude/output-styles/`, whose name is
  arbitrary text.

**jq `//` is wrong for these booleans.** jq's alternative operator treats `false`
as falsy, so `.thinking.enabled // true` yields `true` exactly when thinking is
*disabled* — inverting the indicator. The extraction uses
`(.fast_mode == true)` / `(.thinking.enabled != false)`, which are correct and
also absorb a missing key. All four fields come out of one `jq` fork (NFR2),
`|`-joined rather than `@tsv`: tab is IFS whitespace, so a leading empty field
(the common absent-`effort` case) would silently shift the read. The style name
is joined **last**, because it is the one field whose value is arbitrary user
text: `read -r` puts every surplus field into the final variable, so a `|` in a
style name corrupts only itself instead of shifting the other three.

**Capture through a sentinel.** The group's trailing two spaces are significant
and `$(…)` strips trailing whitespace, hence `set_model_sec <var> …` — it
appends an `x`, strips it, and assigns via `printf -v`. `render_model_sec`
itself stays a pure echo function so the tests can assert it byte-for-byte.

**Width.** All glyphs are single-cell as `vislen` counts them (SGR stripped,
UTF-8 continuation bytes dropped). The PUA glyphs match the existing `  `
icons; `○◐●◉◈` are ambiguous-width like `❶`. Deliberately no emoji — `vislen`
would undercount those. `test-statusline-helpers.sh` pins every codepoint as a
byte escape so a mangled glyph fails there rather than in the terminal.
`model-display.sh` follows the same convention for the output-style runes
(2026-07-31); the older icons in `statusline-command.sh` (`` U+E5FE, `` U+E702,
`` U+E73C, `` U+F1C0) are plain `$'…'` literals and are equally fine — the
private-use area is not special here, and either form is acceptable in new code.

Confirmed in the live terminal (iTerm2, 2026-07-29 for the original nine,
2026-07-31 for the four style runes, the latter by cycling `/config` through
every built-in style): every glyph advances exactly one column and the layout
holds. The style runes are ambiguous-width like most of the others, which is
what `vislen` already assumes. `◐` and `◉` do *ink* into the cell of the glyph to their
right — the filled half and the inner disc sit close to the right edge of the
em box — but this is cosmetic overlap, not a width error, and the single-space
join already separates them adequately. **Do not pad around them.** Widening
the join for these two levels alone would make the group's spacing depend on
the effort value, which is exactly the instability the fixed single-space rule
above exists to prevent.

### 4.18 One payload fork, cached transcript streams (2026-10-08)

A plan-mode render forked `jq` about 28 times: ten `getval` calls, one for
context tokens, one for the identity group, and four per `render_plan_right`
call — which runs once per plan variant, up to four times. Up to four more
passes read the transcript: the cache-expiry timestamp and the context fallback
each scanned the whole file, and the sparkline/stats stream read its last 1500
lines. Nothing was cached, so a redraw with an unchanged transcript (refresh
timer, perm-mode or vim toggle) redid all of it.

**Payload.** One `jq` emits every used field, joined by U+001F, and
`IFS=$'\x1f' read -r` splits it. U+001F is not IFS *whitespace*, so empty fields
survive and nothing shifts — the same reason §4.17 rejected `@tsv`. Unlike the
`|` join, a delimiter that cannot appear in the free-text fields (model, dir,
style) means the style no longer has to be last to be safe; it stays last by
habit. The §4.17 boolean forms (`== true`, `!= false`) are unchanged.
`getval` is gone, and with it its `eval "$var=\"$value\""`: a `"` or `$(…)` in a
model name or path used to break the assignment or run. Rate-limit fields are
read once into `FIVE_RAW`/`FIVE_RESET`/`SEVEN_RAW`/`SEVEN_RESET` and
`render_plan_right` reads those globals. Six fields that were extracted but never
used (`total_input_tokens`, `total_output_tokens`, `context_window_size`,
`total_duration_ms`, `total_lines_added`, `total_lines_removed`) were dropped.

**Transcript.** `_tx_cached <kind> <transcript> <producer…>` stores the
producer's raw output in `<state dir>/tx-cache/<path with / → _>.<kind>`; line 1
is the `size:mtime` signature, the rest is the body. A signature match skips the
producer. Writes go through a temp file and `mv`, so concurrent renders never
see a half-written body. One file per transcript and kind, overwritten in place.
Keying on the full path, not the basename, keeps two sessions with the same file
name apart.

Kinds: `spark` and `stats` cache the existing stream programs unchanged, and
`last` is one pass producing both the last non-sidechain assistant timestamp and
the last non-zero token total, replacing the two separate scans in
`format_cache_expiry` and `get_transcript_context`. `last` reads the last 1500
lines and falls back to the whole file only if that window holds neither value,
so a transcript tail of sidechain or user noise still resolves.

**State lives in a private per-user directory.** The payload dump
(`statusbar.json`), the timing log (`statusline-timing.log`), the subagent cost
cache (`subagent-cost-cache`, §4.13) and the transcript cache (`tx-cache/`) all
live in one state dir, resolved once per render by `cc_state_dir_init` in
`lib/format-utils.sh`: `$CC_STATUSLINE_STATE_DIR`, else
`$XDG_RUNTIME_DIR/cc-statusline`, else `$HOME/.cache/cc-statusline` (macOS has
no `XDG_RUNTIME_DIR`), with trailing slashes dropped (a `TX_CACHE_DIR` override
ending in `/` is refused instead, since `-L dir/` tests the target). `_cc_private_dir` creates
it 0700 under `umask 077` and accepts it only if the path is absolute and the
dir is not a symlink, is a directory, and is owned by the current user (`-O`);
`-L` is tested first because `-d`, `-O` and `mkdir -p` all follow a link. When
it is refused — a symlink (even to a dir the user owns), a regular file, a dir
owned by someone else, a relative path, or a path that cannot be created —
`CC_STATE_DIR` is empty: the dump and the timing log are skipped, subagent and
transcript work is computed uncached, and the render is otherwise unchanged and
exits 0.

The shared, world-writable `/tmp/claude` this replaces let another local user
pre-create the directory and plant symlinks: the dump and the timing log were
written through them, clobbering or appending to any file the user owns and
leaking the payload, and subagent-cost hits were read back unvalidated into the
displayed cost. Those are worse than the cosmetic residual a shared transcript
cache leaves, and once a private dir exists the transcript cache uses it too.
Inside it, writes still do not trust what they find. The dump is replaced
through a temp file and `mv` (a planted symlink is replaced, not followed, and a
concurrent render never reads half a file); the timing log and the subagent
cache are not written through a symlink. Both append-only files are dropped and
started over past 262144 bytes, since the state dir, unlike `/tmp`, may survive
a reboot. A subagent-cost hit must match the exact shape `subagent_cost` prints
— `%.6f` with no leading zero, or the bare `0` of its early returns — or it is a
miss and is recomputed; a path holding a tab or newline is never cached, since
the record is one tab-split line. `TX_CACHE_DIR` overrides the transcript cache
location (the test suite uses it), and `_tx_cached` holds an override to the
same `_cc_private_dir` check on every call before it reads or writes; the check
is builtins only unless the dir has to be created. Only the last path component
is checked: an override inside a directory another user owns could still be
swapped after the check, so the override is the user's own responsibility.

**A hit is validated before use.** The dir is private, but validation stays as
defence in depth (the dir's mode is the user's to loosen, and an override may
point anywhere), because the consumers pass cached fields to `date -d` and bash
arithmetic (`$(( ))` evaluates `a[$(cmd)]`). `_tx_cached` therefore accepts a hit
only if `_tx_body_ok` passes, and anything else is a miss that is regenerated
and overwritten. The rules, all in `lib/transcript-cache.sh`:

- *Shapes.* Each kind accepts only the line shapes its producer emits.
  `_tx_valid_last` takes an ISO timestamp or empty, then an integer or empty,
  and no further line. `_tx_valid_spark` and `_tx_valid_stats` take any number
  of `U <epoch>` and `A …` lines, up to the line cap below.
  `<req>` and `<stop>` hold no whitespace at all, because consumers split `A`
  lines with default-IFS `read -r` and a tab inside `<req>` would shift a planted
  value into `<epoch>`.
- *Integers.* No leading zero and at most 18 digits. `$(( ))` reads `08` as an
  invalid octal base, so the statusline would print `value too great for base`
  and lose line 2. 18 digits always fit a signed 64-bit integer; a value past
  2^63−1 makes `[ -gt ]` print `integer expression expected` on every render
  and `$(( ))` wrap silently. `0` is valid, since producers emit it for a
  missing timestamp and for zero counts. Digits are spelled out as
  `[0123456789]` rather than `[0-9]`, so the bash `=~` in `_tx_valid_last` does
  not depend on the locale. The ISO timestamp keeps fixed-width fields with
  zeros allowed, because it goes to `date`, not to arithmetic.
- *Positive evidence.* Spark and stats bodies go through one helper,
  `_tx_lines_match`, which runs `grep -cvE` in the C locale and then counts
  lines, both on a here-string with no pipeline. It accepts only when the
  bad-line count printed is `0` and the line count printed after it is within
  the cap (a count that grep did not print leaves a bare `0`, which rejects).
  A `grep` that cannot run, a bad regex or an unwritable temp file prints no
  `0` and rejects, and the sourcing shell's `pipefail` cannot change the verdict.
  A negated pipeline such as `! printf … | grep -q` accepts on any pipeline
  failure: on a body longer than a pipe buffer with the payload on line 1,
  `grep -q` exits early, `printf` dies of SIGPIPE, `pipefail` fails the
  pipeline and `!` turns that into acceptance; a missing `grep` is accepted the
  same way. The helper therefore neither pipes nor negates a status.
- *Caps.* A spark or stats body over `_TX_MAX_LINES` (1500) lines is a miss.
  The stream producers read the last `_TX_MAX_LINES` transcript lines and emit
  at most one line per input line, so no legitimate body is longer, and the
  window and the bound share one constant so they cannot drift apart. Without
  the cap a well-formed planted body costs the consumers' superlinear
  `seen_req` and per-line `read` scan on every render: measured 0.7 s at 1500
  lines, 5.8 s at 6000, over four minutes at 10000. Any body over
  `_TX_MAX_BYTES` (`_TX_MAX_LINES` × 256 = 384000) is a miss, which bounds a
  single giant field that the line count does not. `_tx_cached` reads the body
  of a hit with `head -c $(( _TX_MAX_BYTES + 1 ))`, so a huge planted body is
  never slurped.
  The check counts characters, so a multibyte-heavy oversized file can come back
  truncated and still pass; that is accepted, because cost is already bounded
  by the read and the line cap.
- *Empty and unknown.* An empty body is valid for every kind that has a
  validator, so a transcript with no turns keeps hitting. A kind with no
  `_tx_valid_<kind>` is never accepted (always a miss): a new kind must add its
  validator before it can be cached, and forgetting one costs a `jq` fork per
  render rather than letting unvalidated content reach `$(( ))`.

Validation sits in one place rather than in each consumer. The residual is that
a planted body within the grammar and the bounds shows wrong but in-range,
error-free numbers until the transcript changes, and its render cost is bounded
by the largest legitimate body. Every read is bounded: the signature line is
read with `read -r -n 64` (a real one is under 40 characters), so a planted
multi-megabyte file with no newline reads as a truncated signature, which cannot
match, and is a miss; with a plain `read -r` it cost about a second per 20 MB on
every render until overwritten. In a private state dir only the user can plant
a body at all, so this residual applies only to a loosened dir or an override.

**Only raw `jq` output is cached, never anything derived from `now`.** Running
turn duration, the idle check and expiry-versus-now stay in bash, so a cache hit
cannot show a stale time. The cache is keyed on the transcript's size and
mtime, so the first render after any new transcript line pays full cost; the
saving is on the redraws in between.

Measured with a `jq` shim: a warm render forks `jq` once (payload), a cold one
three (payload, `last`, line-2 stream). `get_api_provider` adds one when
`account-config.json` exists.

Rendered output was byte-identical against the pre-change script for plan and
API mode, `sparkline` and `stats`, at 120 and 60 columns, apart from the
`now`-dependent running-turn duration.

---

## 5. Rejected Alternatives

**Burn-rate `×N` on plan windows** (removed 2026-07-02). B (window-elapsed
percent) conveys the same information directly — burn = A/B — so the derived
metric was redundant. `format_burn_rate` deleted.

**"Both windows == 0 → hide plan section"** (replaced 2026-07-02). Presence of
the field, not its value, now decides; a genuine 0% is information.

**Dim/bright intensity to encode sparkline cell kind** (dropped 2026-05-27).
SGR 2 dims only the foreground, and the cells are background-coloured blocks —
the encoding was invisible. Position encodes kind instead.

**Per-turn `R_turn` subtraction in the stats `input` formula** (dropped
2026-07-18). It kept a cold turn's `input` at its true external size, but hid
the cold spike the `❄` marker is there to explain. The simpler formula plus the
marker communicates more.

**Time/TTL-based cache-expiry detection.** Ruled out by the measurements in
§4.9: no fixed TTL fits the observations.

**Reading the OAuth usage cache for full-precision limits** (considered
2026-07-29, §4.15). `claude-account _usage_data` already caches
`/api/oauth/usage` at `/tmp/claude/claude-usage-cache.json` with a 30s TTL, and
that response carries the true `100.0`, plus `is_active`/`severity` and the
overage balance the payload lacks entirely. Rejected for now: it would give the
statusline its first network dependency and a staleness/failure path on every
render, against NFR2. The 99 → 100 promotion buys the same display for no
runtime cost. Revisit if the overage balance itself becomes worth showing.

**A `>= 99` at-limit threshold** (considered 2026-07-29). Would have kept
displaying the literal `99%` and merely restyled it, matching
`account-switcher-design.md` §4.4. Rejected: the complaint was the number, not
the styling, and a threshold silently swallows a future genuine 100 — the
promotion plus warning glyph is self-retiring.

**Reading `~/.claude/settings.json` for thinking state** (superseded 2026-07-29).
The 😶 indicator inferred it from `alwaysThinkingEnabled` via
`get_thinking_state()`, deleted in `63e54a8`; the key is no longer in the user's
settings either. The payload's `.thinking.enabled` is authoritative, costs no
file read, and tracks per-session toggles the settings file never saw.

**Grading the effort glyph by colour** (2026-07-29). A green→red ramp over
`○◐●◉◈` was considered and rejected: the rank glyph immediately to its left
already carries a capability-risk colour gradient, and a second one beside it
competes for the same reading. The glyph shape alone is a sufficient ordinal.

**An `ultra` effort level** (2026-07-29). Specified initially, then dropped —
the bundle's `EL` enum tops out at `max`, and `ultracode` is an alias for
`xhigh`, not a sixth level.

**`context_window.total_*` cumulative fields** for context usage. GitHub #13783 —
they are session totals, not occupancy.

**Verbose mode via `/config`** for a token counter (top-right). Rejected: forces
verbose output even when unwanted. Parsing the statusbar payload allows a custom
statusline without that trade-off.

**Dropping line-1 sections when narrow** (superseded 2026-07-12 by reflow, §4.1).
The old ladder dropped model name → context bar → cost. Sections the user
actually watches were the ones disappearing.

**Cosmetic dir == branch merge on line 1** (dropped 2026-07-12). The reflow
tiers need dir and branch separable.

**Reserving the worst-case right-edge chrome width** (35 columns). Costs every
row permanently for labels usually absent; see §4.10.

**Removing the second statusline line entirely** (2026-01-09, "I do not find it
useful"). Reversed by the sparkline (2026-04-20) and stats mode (2026-06-29),
which give the line a purpose the old session-stats display lacked.

---

## 6. Known Limitations

**Ambiguous-width glyphs are counted as one cell.** `vislen` counts codepoints —
SGR stripped, UTF-8 continuation bytes dropped — so every glyph advances exactly
one column as far as the layout ladder is concerned. Several glyphs in use are
East-Asian *ambiguous* width: the rank digits `❶❷❸❹` and the effort glyphs
`○◐●◉◈` (§4.17), and the growth bar's elision `⋯` (U+22EF, §4.12). A terminal
configured to render ambiguous characters double-width overruns each row's
budget by one column per such glyph — the elided bar by one, the identity group
by up to five.

All of them are confirmed single-cell in iTerm2 at its default setting
(2026-07-29, §4.17), which is the only terminal this statusline runs in. Fixing
it properly means carrying a width table through `vislen` on every render (NFR2)
for a configuration nobody here uses, and the failure is cosmetic — one column
of overrun, absorbed by the truncation `…` or by one extra wrapped row. Picking
non-ambiguous glyphs instead would cost the rank/effort vocabulary §4.17
settled on. Recorded rather than fixed.

---

## 7. Changelog

| Date | Change |
|------|--------|
| 2026-01-09 | Second line (session stats) removed; account status added to line 1 |
| 2026-01-10 | Bold-red ≥100% utilization; 😶 thinking-disabled indicator; explicit `exit 0`; numeric input validation |
| 2026-01-18 | Context usage from transcript parsing |
| 2026-01-19 | Context usage switched to `context_window.current_usage` with transcript fallback |
| 2026-04-20 | Per-turn token sparkline as line 2 (`plans/2026-04-20-sparkline.md`) |
| 2026-04-22 | Width-aware truncation; `tput cols` probe |
| 2026-05-26 | `sparkline-always-on` flag file |
| 2026-05-27 | Sparkline cell encoding: single palette, kind by position, `·` separators |
| 2026-06-29 | Line 2 `stats` mode specified |
| 2026-06-30 | `stats` mode shipped and colourised (commits 8318a2f..9db1a23) |
| 2026-07-01 | `RESET_DIM` fix across four files; `BOLD` emits `\033[22m\033[1m` |
| 2026-07-02 | Plan display rework to `A%/B% C`; burn rate removed |
| 2026-07-06 | Turn trigger drops `promptSource == "system"` users |
| 2026-07-12 | Line-1 reflow engine (`lib/line1-layout.sh`); subagent cost |
| 2026-07-14 | Chrome reservation applied to every row, not just row 1 |
| 2026-07-18 | Cold spike surfaces in `input`; full-collapse (`cr == 0`) always cold |
| 2026-07-20 | Chrome reservation made tunable via `~/.claude/statusline-chrome-cols` |
| 2026-07-29 | Document split out of `claude/design-decisions.md` and restructured |
| 2026-07-29 | Saturated plan window: 99 promoted to 100, warning glyph on a literal 100; single colour close between bar and reset time |
| 2026-07-29 | Line-1 identity group (`lib/model-display.sh`): model rank ❶❷❸❹ with Fable, effort, fast mode, nothink — all payload-sourced; ladder reordered so identity labels elide before the context bar |
| 2026-07-30 | Context growth bar: unbounded past 200k, alternating magenta/bright-magenta from 250k (NFR7 exception); the space before the bar is omitted with it |
| 2026-07-30 | Bar elides its middle (`head ⋯ last two`, 8 cols) from 400k up; the elision rung is spent before the identity labels, refining the 2026-07-29 order |
| 2026-07-30 | §6 Known Limitations added, opening with `vislen`'s one-cell assumption for ambiguous-width glyphs |
| 2026-07-31 | Effort labels lowercased; output style added to the identity group after effort ( explanatory /  learning /  proactive / 󰴓 <name>), `default` omitted, name downcased in the `jq` extraction |
| 2026-08-25 | Output style `Concise` recognised:  concise (U+F0C4 nf-fa-scissors) instead of the fallback pen rune |
| 2026-10-08 | Payload read in one `jq` fork (U+001F-joined, `getval`/`eval` removed, six unused fields dropped, plan-limit fields read once); transcript `jq` output cached by size+mtime in `lib/transcript-cache.sh`; cache-expiry and context fallback share one `last` pass |
| 2026-10-08 | Transcript cache hits validated per kind (`_tx_valid_*`) before use: planted `a[$(cmd)]`, non-ISO timestamps or whitespace-smuggled `<req>`/`<stop>` fields are a miss, not evaluated by `$(( ))` / `date -d` |
| 2026-10-09 | Cache validation hardened after review: acceptance on positive evidence (immune to `pipefail` and `grep` failure), integers without leading zeros and capped at 18 digits, digits spelled out, unknown kinds fail closed, 1500-line and 384000-byte body caps shared with the producers' window; per-user 0700 directory moved to §5 with the corrected residual |
| 2026-10-09 | Signature line of a cache file read with `read -r -n 64` (a planted newline-less file is a miss, not slurped); dead digits check dropped from `_tx_lines_match`; `format_cache_expiry` on macOS strips the fraction and `Z` and parses as UTC (BSD `date -j -f` rejects trailing text and reads local time, so the expiry was empty or hours off) |
| 2026-10-09 | `vis_truncate` classifies UTF-8 continuation bytes by membership in a byte set (`_VT_CONT`) instead of by the value of `printf %d "'<byte>"`, which bash 3.2 (macOS `/bin/bash`) returns negative for a byte above 0x7F, so every continuation byte counted as a cell |
| 2026-11-06 | Extracted into the `cc-statusline` repository: `lib/` sourced relative to the resolved script location, `account-validation.sh` left with `claude-account` and located via `$CC_STATUSLINE_ACCOUNT_LIB` / pointer file / default with no-op fallbacks |
| 2026-11-06 | `/tmp/claude` replaced by a private per-user state dir (`$CC_STATUSLINE_STATE_DIR` / `$XDG_RUNTIME_DIR` / `~/.cache`, `cc-statusline`, 0700, owner-checked, not a symlink) for the payload dump, timing log, subagent cost cache and transcript cache; dump written by temp file + `mv`; subagent hits shape-checked; append-only files capped at 262144 bytes; per-user directory removed from §5 and adopted in §4.18 |
