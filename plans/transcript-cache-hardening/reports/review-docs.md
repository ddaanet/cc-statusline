# Review: statusline-design.md §4.18, §5, §7 (transcript-cache hardening, Item 2.1)

**Scope**: `claude/statusline-design.md` as changed in d66d488, diffed against baseline 95e734b. Checked against `plans/transcript-cache-hardening/outline.md` (D6, N1, D1-D5) and the merged `claude/lib/transcript-cache.sh`, `sparkline.sh`, `turn-stats.sh` and `context-display.sh`.
**Date**: 2026-10-09
**Mode**: review + fix

## Summary

The rewrite of §4.18, the new §5 entry and the §7 row together cover D6: per-kind shapes, no leading zeros and the 18-digit cap, explicit digits, the C-locale grep, the whitespace rule, positive-evidence acceptance, the line and byte caps with the measured curve, the empty-body rule, fail-closed handling of unknown kinds, and the corrected residual with a §5 back-reference. Two statements did not match the code. One was a claim about the bounded read and the other a claim about 19-digit overflow. A third passage narrated the prior implementation in the past tense, and one phrase contradicted itself. All four are fixed in §4.18. Nothing outside §4.18 was edited.

**Overall Assessment**: Ready. The code-side observation under Major #2 goes to the orchestrator.

## Issues Found

### Critical Issues

None.

### Major Issues

1. **Past-tense narration of the prior implementation in a current-truth bullet**
   - Location: claude/statusline-design.md:797-800 (*Positive evidence* bullet)
   - Problem: "An earlier `! printf … | grep -q` form accepted … and `!` turned that into acceptance" tells the story of a previous version inside a mechanism description. That breaks the present-tense rule for §4.18 (craft:design-doc-writing, "No draft archaeology" and "Present-tense standing truth"). The before-to-after history is already in the §7 row ("immune to `pipefail` and `grep` failure").
   - Fix: restate it as standing rationale. A negated pipeline accepts on any pipeline failure, which covers both the SIGPIPE-under-`pipefail` case and a missing `grep`, so the helper neither pipes nor negates a status.
   - **Status**: FIXED

2. **"a huge planted file is never slurped" is false**
   - Location: claude/statusline-design.md:809-810 (*Caps* bullet)
   - Problem: `_tx_cached` (transcript-cache.sh:100) reads the signature line with an unbounded `IFS= read -r first` before the bounded `head -c` body read. Probe: a planted 20 MB cache file with no newline took 1.2 s through `_tx_cached` before it missed and was overwritten. Only the body read is bounded.
   - Fix: narrow the claim to what the code does: "`_tx_cached` reads the body of a hit with `head -c …`, so a huge planted body is never slurped."
   - **Status**: FIXED (doc wording).
   - **Code-side gap, OUT-OF-SCOPE for this group** (code and tests are scope OUT and were reviewed already). The orchestrator should decide on it:
     - The unbounded signature-line read means "render cost bounded by the largest legitimate body" (§4.18 residual sentence, §5 entry) holds only after a planted file has been read once.
     - A miss normally overwrites the file through `mktemp` + `mv`, so the cost is paid once. When the cache directory is not writable by the user (the hostile pre-created directory case that §5 names), the overwrite fails and every render pays the full read.
     - A bounded signature read closes the gap, for example `IFS= read -r -n 64 first` or reading the first line through `head -c`.
     - If the code is not changed, the residual sentence should be qualified.

### Minor Issues

1. **19-digit overflow claim is inaccurate**
   - Location: claude/statusline-design.md:785-786 (*Integers* bullet)
   - Problem: "19 or more digits overflow signed 64-bit arithmetic and `[ -gt ]` errors on every render" is wrong. Probe: `[ 1000000000000000000 -gt 1 ]` (19 digits) succeeds, while `[ 9999999999999999999 -gt 1 ]` prints `integer expression expected` (rc 2). Only values past 2^63−1 fail. The 18-digit cap is the largest digit count whose every value fits.
   - Fix: "18 digits always fit a signed 64-bit integer; a value past 2^63−1 makes `[ -gt ]` print `integer expression expected` on every render and `$(( ))` wrap silently". This matches outline D2.
   - **Status**: FIXED

2. **Self-contradicting phrase in the *Shapes* bullet**
   - Location: claude/statusline-design.md:778-779
   - Problem: "bounded by the line cap below rather than by a line count" contradicts itself, because a line cap is a line count. The intent, from D6, is that `last` has a fixed line count while spark/stats bodies have any length up to `_TX_MAX_LINES`.
   - Fix: "take any number of `U <epoch>` and `A …` lines, up to the line cap below."
   - **Status**: FIXED

## Fixes Applied

- claude/statusline-design.md:778-779: spark/stats shape sentence reworded to "any number of … lines, up to the line cap below".
- claude/statusline-design.md:785-787: overflow sentence restated against 2^63−1, with both failure modes (`[ -gt ]` error, silent `$(( ))` wrap).
- claude/statusline-design.md:798-802: past-tense "earlier form" narrative replaced by present-tense rationale for why the helper neither pipes nor negates a status.
- claude/statusline-design.md:811-813: bounded-read claim scoped to the body of a hit.

`git diff HEAD` shows four hunks, all within §4.18 (lines 778-813). The §7 section hashes identically to HEAD, so the nerd-font glyphs in the 2026-07-31 and 2026-08-25 rows are intact. §5 is unchanged. Nothing was committed and the stash was not touched.

## Requirements Validation

| Requirement | Status | Evidence |
|-------------|--------|----------|
| D6: §4.18 rewritten to current truth | Satisfied (after fixes) | §4.18 *Shapes* / *Integers* / *Positive evidence* / *Caps* / *Empty and unknown* bullets |
| D6: "no extra lines" scoped to `last`; spark/stats bounded at `_TX_MAX_LINES` | Satisfied | *Shapes* bullet; `_tx_valid_last` (transcript-cache.sh:43), `_tx_lines_match` (:66) |
| D6: no leading zeros and why (octal) | Satisfied | *Integers* bullet; `_TX_UINT` (:23) |
| D6: explicit digits, C-locale grep | Satisfied | *Integers* and *Positive evidence* bullets; :23, :25, :59-60, :66 |
| D6: whitespace rule | Satisfied | *Shapes* bullet; `_TX_WORD` (:29) |
| D6: positive evidence, independent of shell options | Satisfied | *Positive evidence* bullet; `_tx_lines_match` (:56-67) |
| D6: byte and line caps with measured curve | Satisfied | *Caps* bullet; :37-38, :84, :100; 0.7 s / 5.8 s / over 4 min matches outline N1 |
| D6: empty-body rule | Satisfied | *Empty and unknown* bullet; `_tx_body_ok` (:85), ordered after the validator-exists check and byte cap as D5 requires |
| D6: fail closed for unknown kinds | Satisfied | *Empty and unknown* bullet; :83 |
| D6: corrected residual, no "at worst … or force a re-run" | Satisfied, with the code caveat in Major #2 | §4.18 closing paragraph; §5 entry |
| D6: 0700 directory in §5 as its own entry, "considered 2026-10-08, §4.18", rationale restated | Satisfied | §5 entry; format matches the OAuth-usage-cache neighbour (bold title, "(considered <date>, §N)", "Rejected: …", "Revisit if …") |
| D6: one-clause back-reference in §4.18 | Satisfied | "it was considered and rejected (§5)" |
| D6: one §7 row dated 2026-10-09 | Satisfied | §7 last row; design-significant content, no mutable-state measurement |
| No other section touched | Satisfied | d66d488 hunks are in §4.18, §5 and §7 only, and the fixes are in §4.18 only |

**Gaps:** None in the doc. The code-side signature-line read is reported under Major #2.

---

## Positive Observations

- Every constant quoted matches the code: 1500 (`_TX_MAX_LINES`), 384000 (`_TX_MAX_LINES * 256`), 18 digits (`[123456789][0123456789]{0,17}`), `head -c $(( _TX_MAX_BYTES + 1 ))`, `grep -cvE` / `grep -c ''` under `LC_ALL=C` on here-strings, and the `declare -F` fail-closed check.
- The "error-free" residual was verified by probe:
  - Planted spark and stats bodies with every numeric field at 18 digits are accepted and render with empty stderr.
  - A planted `last` body with an out-of-range ISO date (`2026-99-99T99:99:99Z`) is accepted, and `format_cache_expiry` prints nothing and no error, because the `date` stderr is discarded.
- The producers' "at most one line per input line" claim holds: both jq programs emit one `U`/`A` line or `empty` per record, under `tail -n "$_TX_MAX_LINES"`.
- The §5 rationale is restated against the corrected residual rather than moved unchanged, and it carries a concrete Revisit-if condition.
- The character-versus-byte caveat on the byte check is stated honestly, with the reason it is acceptable.

## Recommendations

- Close the unbounded signature-line read in `_tx_cached` (Major #2) or qualify the residual sentence. The orchestrator decides which, since code is outside this group's scope.
