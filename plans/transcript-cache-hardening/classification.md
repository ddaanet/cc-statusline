# Classification: transcript-cache hardening, deliverable-review fixes

**Requirements source:** `reports/deliverable-review-code-tests-docs.md` (C1, M1-M3,
m1-m9) plus the caller's brief. **Completeness:** every finding names a location
and a fix direction; the outline turns each into a mechanism. **Routing:** proceed
to triage.

**Triage recall:** `memory/feedback_plan_granularity.md` (prefer few, larger items),
`memory/feedback_reversing_a_design_decision.md` (m3 reverses the 1d5d637 "kind
with no validator is accepted" rule: its write-time record is commit 1d5d637 and
`reports/review-code.md` §Recommendations, which already proposed failing closed.
No production kind relies on fail-open, because all three `_tx_cached` callers
(`last`, `spark`, `stats`) have validators). No `agents/decisions/` entry covers the
transcript cache.

**Multi-item decomposition:** implicit bundling (one deliverable-review report).

| Item | Trigger | Behavioural code? | Class |
|---|---|---|---|
| C1 grep fails open under `pipefail` (and on any grep failure) | review | yes, changes the validator's logic | Moderate |
| M1 leading-zero integers accepted | review | yes, changes the regex | Moderate |
| M2 per-field rejection coverage | review | no (tests only) | Simple |
| M3 empty-body short-circuit untested | review | no (tests only) | Simple |
| m3 fail-open for unknown kinds | review | yes, changes a branch | Moderate |
| N1 oversized well-formed body stalls renders | found during verification | yes, adds a check | Moderate |
| m6 locale-dependent digit ranges | review | yes, changes the regex | Moderate (folds into M1) |
| m4, m5, m8 test hygiene | review | no | Simple |
| m1, m2, m9 §4.18 / §5 wording | review | no | Simple |
| m7 silent rejections | review | (rejected) | n/a |

## Overall

- **Classification:** Moderate
- **Implementation certainty:** High. Every mechanism was prototyped in `$TMPDIR` on bash 5.2.
- **Requirement stability:** High. Each finding has been re-verified (see outline §Verification).
- **Behavioural code check:** Yes (C1, M1, m3, N1), so Moderate is the minimum.
- **Work type:** Production
- **Artifact destination:** production (`claude/lib/`, `claude/test-statusline-helpers.sh`, `claude/statusline-design.md`)
- **Evidence:** reproduction scripts for C1/M1, a mutation run for M2/M3, a field-sink probe and a body-size timing run, all summarised in `outline.md`.

**Author-corrector coupling:** not applicable, because no author skill is modified.
