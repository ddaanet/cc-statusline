# Review: transcript-cache hardening review fixes (code + tests)

**Scope**: `git diff 95e734b..HEAD` (commits b02fbaa, f20c349) on `claude/lib/transcript-cache.sh`, `claude/test-statusline-helpers.sh` (`_tx_cached` section, "planted cache bodies" section), and the `tail -n` window in `claude/lib/sparkline.sh` and `claude/lib/turn-stats.sh`. Checked against `plans/transcript-cache-hardening/outline.md` (D1-D5, Item 1.1, Item 1.2).
**Date**: 2026-10-09
**Mode**: review + fix

## Summary

The implementation matches D1-D5 and all five Item 1.1 interfaces. Every requirement has a test that a targeted mutation turns red. Six minor issues were found and fixed: dead test setup, a duplicate and a single-use test helper, two inaccurate comments, a missing `Globals consumed` entry, and a lost alignment space. After the fixes the suite passes (276 tests) and `shellcheck -x` is clean on all four files. Nothing was committed.

**Overall Assessment**: Ready

## Method

- Baseline: `bash claude/test-statusline-helpers.sh` passes 276 tests on Debian, GNU bash 5.2.37, and `shellcheck -x` is clean.
- Mutation runs used copies of `claude/` under `$TMPDIR/mut/<name>/`. The repo file was never mutated. The unmutated control fails only the known path-length artefact ("hostile model name rendered literally"), which is excluded below.

| Mutation | Killed by |
|---|---|
| `_tx_valid_stats` restored to the old `! printf \| grep -qvE` pipe | padded body rejected under pipefail, padded body ran nothing, validator rejects when grep cannot run, 1501 lines rejected, planted 1501-line body |
| `_TX_UINT` restored to `[0-9]+` | 9 tests: all leading-zero and 19-digit rejections, plus the spark leading-zero render and stderr checks |
| stats `U` relaxed to `_TX_WORD` | stats leading-zero U, planted U rejected, planted U renders baseline, stats nothing executed |
| spark `<o>` (and stats `<in>`) relaxed to `_TX_WORD` | spark 19-digit `<o>`, planted `<o>` rejected/renders, spark nothing executed, stats planted `<in>` rejected/renders |
| `[[ -z "$2" ]] \|\|` removed | empty spark stream is a cache hit, empty stats stream is a cache hit |
| unknown kind / byte cap fail open (`return 0`) | kind without a validator never hits, 400000-char `<req>`, planted 500000-byte body, two `last` tests |
| byte cap removed | spark: 400000-character `<req>` rejected |
| line cap removed | stats: 1501 lines rejected, planted 1501-line body renders the baseline |
| `-le` changed to `-lt` | stats: exactly 1500 lines accepted |
| `head -c` changed back to `cat` | **survives** (see Observations) |
| `[[ "$n" =~ ^[0123456789]+$ ]]` removed | **survives** (unreachable, see Observations) |

## Issues Found

### Critical Issues

None.

### Major Issues

None.

### Minor Issues

1. **Dead planted `last` body after m4**
   - Location: `claude/test-statusline-helpers.sh:1052` (pre-fix)
   - Note: `_hx_plant last $'tomorrow\n7003\n'` was kept when the m4 assertion became a direct `_hx_ok last …` check. Nothing reads the planted file, and the next line overwrites it. The test name's "(no date -d)" described the old render path.
   - **Status**: FIXED. The plant line was removed, and the test was renamed "last: non-ISO timestamp rejected".

2. **`_hx_count` duplicates `_hx_nil`**
   - Location: `claude/test-statusline-helpers.sh` (real-producer block)
   - Note: The two bodies are byte-identical (`echo x >> "$_hx_cnt"`). The new `_hx_nil` is the section's counting producer, so the m8 edit left two of them.
   - **Status**: FIXED. `_hx_count` and its shellcheck directive were removed, and the real-producer loop now uses `_hx_nil`.

3. **Single-use helper `_hx_sp`**
   - Location: `claude/test-statusline-helpers.sh:1068` (pre-fix)
   - Note: It was used once, while every neighbouring assertion spells its body as a literal.
   - **Status**: FIXED. The body was inlined as `$'U 1767261600\nA r1 1767261605 08 300 0 tool_use\n'`.

4. **`_tx_lines_match` comment gives a false rationale for the digits test**
   - Location: `claude/lib/transcript-cache.sh:54`
   - Note: "an empty operand would count as 0" is true of `[[ -le ]]` and `(( ))`, but not of the `[ -le ]` the code uses. `bash -c '[ "" -le 5 ]'` exits 2 and prints `[: : integer expression expected`. The case pattern `0$'\n'*` also rules out an empty `n`, because `$( )` strips trailing newlines, so a failed second grep leaves `out=0` and the case rejects. The check's real effect is to keep that message off stderr if a non-number ever reaches `[ ]` (M1's class). D4's rationale ("bash treats an empty operand as 0") is stale for the implemented form. The check stays, as D4 requires.
   - **Status**: FIXED. The comment now says that the digits test keeps a non-number away from `[ -le ]`, which would print `integer expression expected` on stderr.

5. **m5 section comment overstates output comparison for `last`**
   - Location: `claude/test-statusline-helpers.sh:1006-1008`
   - Note: After m4, the `last` timestamp is guarded by a direct validator check, not by output comparison. Only the token test compares renders.
   - **Status**: FIXED. The comment now says that `last` has no evaluating sink, and that its fields are guarded by output comparison or by a direct validator check.

6. **`_TX_MAX_LINES` missing from the consumers' `Globals consumed` headers**
   - Location: `claude/lib/sparkline.sh:4`, `claude/lib/turn-stats.sh:5`
   - Note: Both producers now read `_TX_MAX_LINES`, but neither header lists it. The `Deps` lines also omit transcript-cache.sh, but that omission predates this change (`_tx_cached` was already used), so it is not raised.
   - **Status**: FIXED. `_TX_MAX_LINES` was added to both headers.

7. **Alignment space lost on "miss runs producer"**
   - Location: `claude/test-statusline-helpers.sh:966`
   - Note: The diff dropped one space, so this assert no longer lines up with its column-aligned neighbours.
   - **Status**: FIXED. The space was restored.

## Fixes Applied

- `claude/lib/transcript-cache.sh:54-55`: corrected the digits-test rationale in the `_tx_lines_match` comment.
- `claude/lib/sparkline.sh:5`: added `_TX_MAX_LINES` to the globals consumed.
- `claude/lib/turn-stats.sh:5`: added `_TX_MAX_LINES` to the globals consumed.
- `claude/test-statusline-helpers.sh:966`: restored the alignment space.
- `claude/test-statusline-helpers.sh:1006-1008`: reworded the section comment for `last`.
- `claude/test-statusline-helpers.sh:1052`: removed the dead `_hx_plant last` and renamed the m4 test.
- `claude/test-statusline-helpers.sh:1068`: inlined `_hx_sp`.
- `claude/test-statusline-helpers.sh` real-producer block: removed the duplicate `_hx_count` and used `_hx_nil`.

Post-fix: `bash claude/test-statusline-helpers.sh` gives `PASS 276 tests`. `shellcheck -x` on all four files exits 0. `rg '_tc_(cnt|runs)'` matches only lines 953-982, inside the `_tx_cached` section. No assertion was added or removed.

## Requirements Validation

| Requirement | Status | Evidence |
|---|---|---|
| C1 (pipefail fail-open) | Satisfied | `_tx_lines_match` has no pipeline and accepts only on `out` = `0\n<digits>`. The old-pipe mutation is killed by the padded 1400-line pipefail test, its "ran nothing" check, and "validator rejects when grep cannot run". |
| M1 (leading zeros) | Satisfied | `_TX_UINT='(0\|[123456789][0123456789]{0,17})'`. The `[0-9]+` mutation kills 9 tests, including the spark render and empty-stderr checks. |
| M2 (per-field coverage) | Satisfied | Spark loop over `<ts> <c> <i> <o>` plus U; stats U plus a loop over `<ts> <cr> <cc> <out> <in>`. Both the statsU and sparkO mutations are killed. |
| M3 (empty body) | Satisfied | "empty spark/stats stream is a cache hit". The `-z` removal is killed. |
| m3 (fail closed) | Satisfied | `declare -F … \|\| return 1`, and the test kinds `k`/`other`/`e` are registered as pass-throughs. "kind without a validator never hits" kills fail-open. |
| m4 | Satisfied | Direct `_hx_ok last $'tomorrow\n7003\n'` expecting `bad`, with "last: well-formed body accepted" as the positive pair. |
| m5 | Satisfied | Section comment reworded (and corrected further by fix 5). |
| m6 | Satisfied | Digits are spelled out in `_TX_UINT` and `_TX_ISO_TS`. There is no deterministic test, as the outline states. |
| m8 | Satisfied | `_hx_cnt`/`_hx_runs` own the hostile section. `_tc_*` appears only in lines 953-982. |
| N1 (bounds) | Satisfied | `_TX_MAX_LINES`/`_TX_MAX_BYTES`, the `head -c` read, and both producers on `"$_TX_MAX_LINES"`. The line-cap, `-lt` and byte-cap mutations are each killed. |

**Item 1.1 interfaces**: all five match: `_TX_MAX_LINES=1500`; `_TX_MAX_BYTES=$(( _TX_MAX_LINES * 256 ))`; `_tx_lines_match <alternation> <body>`, with spark/stats as one-line calls; the `_tx_cached` hit read is `read -r` for the signature, then `head -c $(( _TX_MAX_BYTES + 1 ))`; `_tx_body_ok` checks validator-exists, then the byte cap, then empty-or-validator (the D5 order).

**Gaps:** none.

## Observations (not findings)

- **`head -c` read bound is not pinned by a test.** The `cat` mutation survives. For ASCII input the read bound never changes a verdict: anything it truncates is already over `_TX_MAX_BYTES` by `${#2}`, so it only bounds cost (D4: "the bound covers the read"). "stats: planted 500000-byte body renders the baseline" is guarded jointly. Remove only the byte cap and the `head -c`-truncated last line fails grep. Restore only `cat` and the byte cap rejects. The fail-open mutation kills it. The only verdict-level observable would be a multibyte fixture under a UTF-8 locale, which depends on the locale, so it was not added.
- **The digits check in `_tx_lines_match` is unreachable** with the current `case` (see Minor 4). It is kept because D4 requires it and it costs nothing.
- The stats loop also asserts the render for `<in>`, which the outline did not require (`<in>` was not shown to execute). The assertion can still fail: the sparkO mutation, which also relaxed stats `<in>`, kills it.

## Portability (unverified, no macOS / bash 3.2 here)

- `grep -c ''` (an empty pattern) on BSD grep.
- `{0,17}` / `{4}` ERE intervals in BSD `grep -E` (now reached via `_TX_UINT`) and in bash 3.2 `=~`.
- `head -c` on BSD head.
- `$'\n'` inside a `case` pattern and in `${out#0$'\n'}` under bash 3.2.
- `printf -v var '%0400000d'` / `'%0500000d'` (very large widths) in the bash 3.2 builtin, test-only.
- Here-string temp files on bash 3.2: a creation failure yields no `0` and rejects, which is the intended fail-closed path.

## Positive Observations

- `_tx_lines_match` puts both counts in one substitution and matches them with a single `case`, so every failure mode of either grep rejects without a status check.
- The C1 fixture (1400 lines of 95 bytes, about 134 KB) stays above pipe buffers and under both caps, so it keeps reaching grep now that the caps exist.
- The bounds are tested at the exact boundary (1500 accepted, 1501 rejected), and the byte cap is tested separately from the line cap (three lines, one giant `<req>`).
- The M2 per-field loops pair `_hx_ok` rejection with an end-to-end render, and each kind ends with a `_hx_ran` check.

## Recommendations

- Run `bash claude/test-statusline-helpers.sh` on a macOS host to close the portability list.
- When the design doc is next touched, note that the digits test exists to keep stderr quiet, not because of empty-as-zero (D4 rationale).
