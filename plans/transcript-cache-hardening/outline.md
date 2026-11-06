# Outline: transcript-cache hardening, review fixes

Fixes for `reports/deliverable-review-code-tests-docs.md` (commits 1d5d637, 87ce595).
Classification: Moderate, production (`classification.md`).

## Provenance

- **Derived from:** `plans/transcript-cache-hardening/reports/deliverable-review-code-tests-docs.md` (and the earlier `reports/review-code.md`), superseding none. No prior outline or design exists for this job.
- **Base:** `05fc99fe19218d621c43a0c136359471d4d6e8fc`. This is the start of the reviewed range (`git diff 05fc99f..HEAD`), copied from the review rather than recomputed, so the next deliverable review sees the whole hardening and not only these fixes.

## Verification of the review's claims

The scripts were run on Debian with GNU bash 5.2.37 against scratch copies under `$TMPDIR/tch/`. The repo was never mutated.

| Finding | Verdict | Evidence |
|---|---|---|
| C1 | **Holds, and is wider than reported** | A 132 KB stats body with the payload on line 1 is accepted 0/20 times without `pipefail` and 20/20 times with it. The reviewer's fix (`! grep -qvE … <<<`) closes the `pipefail` hole but still **accepts** when grep exits 2 (bad regex) or 127 (grep not on PATH), because `!` turns every failure into acceptance. |
| M1 | Holds | `08` passes `_tx_body_ok`. A planted spark/stats body then prints `value too great for base` (sparkline.sh:48, turn-stats.sh:147) and line 2 disappears. Stats `010` renders as `8`. |
| M2 | Holds | Relaxing stats `U` to `_TX_WORD`, or spark `<o>` to `_TX_WORD`, leaves the suite at the control result (only the path-length artefact "hostile model name rendered literally" fails). With validation bypassed, the payload **executes** in spark `<ts> <c> <i> <o>` and in stats `U`, `<ts> <cr> <cc> <out>`. Spark `U` and stats `<in>` do not execute with a one-turn fixture. |
| M3 | Holds | Removing `[[ -z "$2" ]] \|\|` leaves the suite at the control result. `_tx_valid_spark ""` and `_tx_valid_stats ""` both reject an empty body. |
| N1 (new) | **Not in the review.** Found while checking whether m1's corrected wording would be true. | A well-formed planted body of any length is accepted, and consumer cost is superlinear. A planted stats/spark body renders in 0.7 s at 1500 lines, 5.8 s at 6000, and takes more than 4 min at 10000. Every render pays that until the transcript changes. The producers emit at most one line per input line of `tail -n 1500`, so no legitimate body exceeds 1500 lines. **Needs the user's confirmation at `/proof`** because it is a scope addition. |
| m1-m9 | See the Minor findings table below | |

## Decisions

**D1 (C1): accept only on positive evidence.** Spark/stats bodies are checked by one shared helper. It runs `LC_ALL=C grep -cvE` with the anchored alternation on a here-string of the body (trailing newline stripped), with stderr discarded. The body is accepted only if the substitution's output is exactly `0`. Why this form:
- There is no pipeline, so the sourcing shell's `pipefail` cannot change the verdict.
- A grep that cannot run, a bad regex, or a here-string temp file that cannot be created (bash 3.2 always uses a temp file) yields no `0` and therefore rejects.

Prototype: it rejects the C1 body under none, `pipefail`, and `-e -o pipefail`. It rejects with a bad regex or no grep, and it accepts a valid 1500-line body. It costs 11 ms per hit against 12 ms for the current form.

**D2 (M1 + m6): integers without leading zeros, with digits spelled out.**
- `_TX_UINT` becomes `0` or a nonzero digit followed by digits. `0` must still pass, because producers emit `0` for a missing timestamp and for zero counts.
- Digits are written as the explicit list `[0123456789]` in `_TX_UINT` and `_TX_ISO_TS`, not as the range `[0-9]`. That makes `_tx_valid_last`'s `[[ =~ ]]` locale-independent without assigning `LC_ALL` inside a function, whose local scoping on bash 3.2 is unverified here.
- `_TX_ISO_TS` keeps its fixed-width fields with zeros allowed, because it goes to `date`, not to arithmetic.
- `_TX_UINT` is also capped at 18 digits (a nonzero digit followed by up to 17 more), so every value fits a signed 64-bit integer.
  - Verified with validation on: a 20-digit `<c>`/`<i>`/`<o>` in spark, or a 20-digit `last` token, passes today. `[ -gt ]`/`[ -lt ]` (sparkline.sh:29,39; context-display.sh:15,17) then print `integer expression expected` on every render, and stats `$(( ))` wraps silently (`7766279631452.2M`).
  - This is M1's class: a validated body must not produce errors. Real values (epochs, token counts) are at most about 10 digits.
  - ERE intervals are fine in BSD `grep -E` and bash `=~`.

**D3 (m3): fail closed for unknown kinds, with pass-through validators registered by the tests.**
- `_tx_body_ok` returns failure when no `_tx_valid_<kind>` is defined. A kind is cacheable only if it has a validator.
- The tests register pass-throughs for their ad-hoc kinds (`k`, `other`, `e`) next to the `_tx_cached` section.
- Rejected: an allowlist of test kinds in the lib. It puts test vocabulary in production code, and it would still need a lib edit for every new test kind.
- The cost of forgetting a validator becomes a miss on every render: a `jq` fork per render, not unvalidated content reaching `$(( ))`.
- No production path depended on fail-open: the only three `_tx_cached` callers are `last` (context-display.sh:135,148), `spark` (sparkline.sh:194) and `stats` (turn-stats.sh:80), and all three have validators.

**D4 (N1): bound the body at the producers' window.**
- New constant `_TX_MAX_LINES=1500` in transcript-cache.sh. Both stream producers use it in place of their literal `tail -n 1500` (sparkline.sh:138, turn-stats.sh:37), so the window and the bound cannot drift apart. `_tx_last_jq`'s window in context-display.sh is left alone, because `last` is bounded at two lines by its validator.
- Spark/stats bodies over `_TX_MAX_LINES` lines are a miss.
  - The shared helper takes the line count from a second `grep -c ''` in the same command substitution.
  - It accepts only when the bad-line count is the string `0` **and** the line count printed after it is ≤ `_TX_MAX_LINES`.
  - No separate digits check is needed. The `case` pattern `0$'\n'*` requires a second line after the `0`, and a count that the second grep did not print leaves a bare `0` (command substitution strips the trailing newline), which rejects. `grep -c` prints only a number, so `[ -le ]` never sees an empty or non-numeric operand. (An earlier draft justified a digits check with "an empty operand counts as 0"; that holds for `(( ))` and `[[ ]]`, not for the `[ -le ]` the code uses, where it is an error with status 2.)
- Any body over `_TX_MAX_BYTES` (`_TX_MAX_LINES` × 256 = 384000) is a miss.
  - The bound covers the read, not just the check: `_tx_cached` reads the body with `head -c $(( _TX_MAX_BYTES + 1 ))` in place of `cat` (GNU and BSD both have it). A planted gigabyte file is never slurped, and an oversized file arrives one byte over the cap and is rejected.
  - The check is `${#body}` before any fork. It counts characters, not bytes.
    - A multibyte-heavy oversized file can therefore come back truncated (at most `_TX_MAX_BYTES + 1` bytes) and still pass, instead of being a miss.
    - That is accepted, because cost is already bounded by the `head -c` read and the line cap, and a truncated planted body is just another well-formed planted body (the wrong-numbers residual).
  - It bounds a single giant field (each distinct `<req>` grows the consumers' `seen_req` scan), which the line count alone does not. Real lines are about 75-105 bytes.

**D5: the empty-body rule stays in `_tx_body_ok`**, after the validator-exists check and the byte cap. An empty body is valid for every kind that has a validator, so a transcript with no turns keeps hitting. M3 adds the test that pins this.

**D6 (m1, m2, m9): placement in the design doc.**
- §4.18's "A hit is validated before use" paragraph is rewritten to state current truth:
  - the per-kind shapes, with "no extra lines" scoped to `last` and spark/stats bounded at `_TX_MAX_LINES`;
  - no leading zeros, and why (octal);
  - explicit digits and the C-locale grep;
  - the whitespace rule;
  - acceptance on positive evidence, independent of the sourcing shell's options;
  - the byte and line caps, with the measured cost curve;
  - the empty-body rule;
  - fail-closed for unknown kinds;
  - the corrected residual: a well-formed planted body within the bounds shows wrong (but in-range, error-free) numbers until the transcript changes, and its render cost is bounded by the largest legitimate body. It no longer says "at worst … or force a re-run".
- The per-user 0700 directory moves to §5 Rejected Alternatives as its own entry, "considered 2026-10-08, §4.18". Its rationale is restated against the corrected residual, not just relocated. §4.18 keeps a one-clause back-reference, which follows the convention of the OAuth-usage-cache entry and §4.15.
- One §7 changelog row is added, dated the day of implementation.

## Minor findings

| # | Decision | Reason |
|---|---|---|
| m1 | Fix (D6) | The "at worst" sentence is false today (M1, C1, N1). |
| m2 | Fix (D6) | §5 is where this doc records rejected alternatives. |
| m3 | Fix (D3) | Fail-open is the inverse of the stated goal. |
| m4 | Fix | Replace the `format_cache_expiry` comparison, which is weak on Linux and vacuous on macOS's `date -j -f`, with a direct `_tx_body_ok last` rejection of `tomorrow`. That check behaves the same on both platforms. |
| m5 | Fix wording only | Reword the section comment: only spark/stats fields reach evaluation, and `last` fields are guarded by output comparison. A marker check around `last` cannot fail (no evaluating sink), so it would be decoration. The commit message is history and is not rewritten. |
| m6 | Fix (D2) | Free once digits are spelled out. There is no deterministic test, because no available locale makes `[0-9]` match a non-ASCII digit. |
| m7 | Reject | A statusline has no log channel, and logging would add per-render I/O. The likely cause of silent rejection, validator/producer drift, is already caught by "real producer bodies are cache hits". |
| m8 | Fix | The hostile section gets its own counter file and runs helper (`_hx_cnt`, `_hx_runs`), since M2/M3 edit that section anyway. |
| m9 | Fix (D6) | Folded into the §4.18 rewrite. |

## Scope

**IN:**
- `claude/lib/transcript-cache.sh`
- `claude/test-statusline-helpers.sh` (the `_tx_cached` section and the "planted cache bodies" section)
- the `tail -n` literal in `claude/lib/sparkline.sh:138` and `claude/lib/turn-stats.sh:37`
- `claude/statusline-design.md` §4.18, §5, §7

**OUT:**
- The consumers' superlinear cost on legitimate bodies (`seen_req` scan, per-line `read`). This is a pre-existing performance trait, and is a follow-up candidate.
- OSC 11 / `fish_preexec` / tmux theme work.
- Other `/tmp/claude` caches (`subagent-cost-cache`, the usage cache).
- The user's working-tree edits to `dotfiles/.config/fish/conf.d/abbr.fish` and `dotfiles/.config/micro/settings.json`.

## Phase 1: Cache validation (type: tdd)

- Item 1.1: claude/lib/transcript-cache.sh, claude/test-statusline-helpers.sh — implement D1-D5. Make the stream producers in claude/lib/sparkline.sh and claude/lib/turn-stats.sh read `_TX_MAX_LINES`. Requirements: C1, M1, m6, m3, N1, M2, M3.
  Slices (each test is an `assert` in the "planted cache bodies" section unless stated otherwise; the file already runs under `set -uo pipefail`):
  1. **C1, `pipefail`.** "stats: padded planted body rejected under pipefail".
     - Plant a stats body: `U 1767261600`, then `A r1 1767261605 $_hx_sub 0 0 0 end_turn`, then 1400 valid `A` lines, each about 96 bytes (a 40-character `<req>` and seven-digit counts).
     - The total is about 134 KB. That is above the Linux 64 KiB and macOS pipe buffers, and under both D4 caps, so the slice keeps exercising grep after Slice 4 lands.
     - Assert that `display_turn_stats` output equals `$_hx_stats` and that `_hx_ran` is `clean`.
     - Also add "validator rejects when grep cannot run": in a subshell with `PATH` set to a nonexistent directory, `_tx_body_ok stats` on a valid two-line body prints `bad`.
     - RED today: the first test executes the payload, and the second accepts (`!` of 127).
  2. **M1.**
     - `_tx_body_ok` rejects `08` as spark `<c>`, stats `<cr>`, a `U` epoch (`U 0123`) and a `last` token.
     - It also rejects a 19-digit value as spark `<o>` and as a `last` token.
     - `_tx_body_ok` accepts `0` and an 18-digit value in the same positions (positive control).
     - Integration: plant spark `U 1767261600` / `A r1 1767261605 08 300 0 tool_use`. Make two assertions: `display_turn_sparkline` stdout equals `$_hx_spark`, and its stderr (captured separately to a file) is empty.
     - RED today on the rejections and on the stderr assertion ("value too great for base").
  3. **m3.** In the `_tx_cached` section, register pass-through `_tx_valid_k`, `_tx_valid_other` and `_tx_valid_e`, with a comment that a kind needs a validator to be cacheable.
     - Add "kind without a validator never hits": two `_tx_cached nov …` calls with the counting producer, and assert that the producer ran 2 times.
     - RED today: it runs 1 time.
  4. **N1.**
     - `_tx_body_ok stats` is `bad` for 1501 valid lines and `ok` for exactly 1500 (boundary).
     - `_tx_body_ok spark` is `bad` for a three-line body whose `<req>` is 400000 characters.
     - Integration: plant a 1501-line valid stats body. `display_turn_stats` equals `$_hx_stats`.
     - RED today: everything is accepted, and the integration test renders the planted numbers.
     - GREEN also swaps both producers' `tail -n 1500` to `"$_TX_MAX_LINES"`, and replaces `cat` with `head -c $(( _TX_MAX_BYTES + 1 ))` in `_tx_cached`'s hit read.
     - Add one more assertion: a planted 500000-byte stats file read through `display_turn_stats` renders `$_hx_stats`.
  5. **M2: per-field coverage.** This replaces the existing spark "numeric field / U epoch / A epoch" and stats "numeric field / timestamp" planted tests. The tab-smuggle tests stay.
     - For every numeric position, assert that `_tx_body_ok` rejects a body that is valid except for `$_hx_sub` in that one field. Spark positions: `U`, `<ts>`, `<c>`, `<i>`, `<o>`. Stats positions: `U`, `<ts>`, `<cr>`, `<cc>`, `<out>`, `<in>`. Each body is `U 1767261600` plus one `A` line, or for the `U` position, the planted `U` followed by a valid `A`.
     - For the positions proven to execute (spark `<ts> <c> <i> <o>`; stats `U <ts> <cr> <cc> <out>`), also assert that the render equals the baseline.
     - Check `_hx_ran` is `clean` once per kind.
     - **RED is obtained by mutation, not on the repo file.** These assertions pass on current code, because the gap is coverage. Run them against a scratch copy of `claude/` under `$TMPDIR` with stats `U` relaxed to `_TX_WORD`, then with spark `<o>` relaxed to `_TX_WORD`. Each mutation must turn its field's assertions red. In copies, ignore the path-length artefact "hostile model name rendered literally".
  6. **M3.**
     - "empty spark stream is a cache hit" and "empty stats stream is a cache hit": two `_tx_cached spark|stats` calls with a counting producer that prints nothing, and assert that it ran 1 time.
     - RED by mutation on a scratch copy: remove the `-z` short-circuit, and each test reports 2.
  Interfaces:
  - `_TX_MAX_LINES=1500`: the line window shared by `_spark_stream_jq` and `_stats_stream_jq`, and the spark/stats body bound.
  - `_TX_MAX_BYTES=$(( _TX_MAX_LINES * 256 ))`: the byte bound for every kind's body.
  - `_tx_lines_match <alternation> <body>` → status 0 only if the bad-line count printed is the string `0` and the line count printed after it is ≤ `_TX_MAX_LINES`. `_tx_valid_spark` and `_tx_valid_stats` become one-line calls to it.
  - `_tx_cached` hit read: `head -c $(( _TX_MAX_BYTES + 1 ))` replaces `cat`. The signature line is still read first, now with `read -r -n 64` so a planted file with no newline is not slurped (follow-up to the docs review).
  - `_tx_body_ok <kind> <body>` → status 1 if `_tx_valid_<kind>` is undefined or the body exceeds `_TX_MAX_BYTES`. Otherwise status 0 if the body is empty, else the validator's status.

- Item 1.2: claude/test-statusline-helpers.sh — test hygiene, no behaviour change. Requirements: m4, m5, m8. Depends on: Item 1.1.
  - m4: replace "last: non-ISO timestamp rejected (no date -d)" with a direct `_tx_body_ok last $'tomorrow\n7003\n'` assertion expecting `bad`.
  - m5: reword the section comment as in the Minor findings table.
  - m8: replace the hostile section's uses of `_tc_cnt` and `_tc_runs` with its own `_hx_cnt` and `_hx_runs`.
  - Done when the suite passes and `rg '_tc_(cnt|runs)'` matches only inside the `_tx_cached` section.

## Phase 2: Design doc (type: general)

- Item 2.1: claude/statusline-design.md — rewrite the §4.18 validation paragraph, add the §5 entry and the §7 row, as specified in D6. Requirements: m1, m2, m9 (and the doc side of C1, M1, m3, m6, N1). Depends on: Item 1.1.
  - Every number quoted (1500, 384000, the 0.7 s / 5.8 s curve) must match the merged code and this outline's measurements.
  - Do not touch any other section.

## Portability notes for the executor

These forms exist on macOS bash 3.2 and BSD userland: here-strings, `grep -c` (POSIX), `grep -E` with `[[:space:]]`, `${#var}`, `declare -F`, and bracket lists of literal digits. The `{4}` intervals live only in `_tx_valid_last`'s bash `=~`, as today.

None of this was run on macOS here. If a macOS host is available, run `bash claude/test-statusline-helpers.sh` there before closing. Otherwise record it as unverified in the build report.

## Documentation Perimeter

- `claude/statusline-design.md` §4.18, §5 (format of the entries), §7
- `plans/transcript-cache-hardening/reports/deliverable-review-code-tests-docs.md`, `reports/review-code.md`
- `claude/lib/transcript-cache.sh`; the consumers `claude/lib/sparkline.sh` (194-330), `claude/lib/turn-stats.sh` (80-180), `claude/lib/context-display.sh` (100-165)

## Skills to load before executing

- `craft:test-discipline`
- `shell-scripting:shell-gotchas`
- `craft:design-doc-writing` (Item 2.1)

## Route

Recommendation: `/build plans/transcript-cache-hardening`.
- One lib, one test file and one doc.
- There is no runtime cross-file sequencing beyond Item 1.1 → 1.2/2.1.
- No runbook discriminator holds.

Pending: `/edify:proof plans/transcript-cache-hardening/outline.md`, which is interactive, then a commit of this outline. N1 needs explicit acceptance or removal at that step.
