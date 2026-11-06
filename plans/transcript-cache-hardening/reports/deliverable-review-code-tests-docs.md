# Deliverable review: transcript-cache hardening (code, tests, docs)

Scope: `git diff 05fc99f..HEAD` (commits 1d5d637, 87ce595) on
`claude/lib/transcript-cache.sh`, `claude/test-statusline-helpers.sh`,
`claude/statusline-design.md`. Baseline: the §4.18 "A hit is validated before
use" paragraph plus the commit claims. Consumers read: `lib/context-display.sh`
(`get_transcript_context`, `format_cache_expiry`, `display_token_bar`,
`get_token_color`), `lib/format-utils.sh` (`kilos`, `humanize_tokens`),
`lib/sparkline.sh` (`display_turn_sparkline`, `spark_char`), `lib/turn-stats.sh`
(`display_turn_stats`), `statusline-command.sh`.

## Test-suite result

`bash claude/test-statusline-helpers.sh` (the `justfile` recipe), Debian, GNU bash
5.2.37: **PASS 236 tests, exit 0.** Matches the author's count. Not run on macOS
/ bash 3.2 (none available here).

## Method notes

- Mutation testing ran on copies of `claude/` under `$TMPDIR/mut/<name>/`, never on
  the repo file. Every copy, including an unmutated control, fails one unrelated
  test ("hostile model name rendered literally") because of the copy's longer
  path; that failure is a harness artefact and is excluded below.
- Mutation results (validation-related failures only):

| Mutation | Killed by |
|---|---|
| `_tx_body_ok` always returns 0 | 14 tests incl. both "nothing executed" |
| `_TX_WORD` allows tabs | spark/stats tab tests + "nothing executed" |
| `_TX_UINT` any non-space | 9 tests |
| `_TX_ISO_TS` any non-space | "non-ISO timestamp rejected" (Linux only, see m4) |
| `last` token regex `.*` | 2 tests |
| `last` line-count check removed | 2 tests |
| stats/spark regex arity changed | "real producer bodies are cache hits" |
| **stats `U` field relaxed** | **nothing** (M2) |
| **spark `<out>` field relaxed** | **nothing** (M2) |
| **`[[ -z "$2" ]] \|\|` short-circuit removed** | **nothing** (M3) |
| `LC_ALL=C` removed | nothing (expected; no locale test) |
| stats `<stop>` relaxed to `.*` | nothing (not exploitable: last field) |

- Real-data check: ran the three real producers over 150 recent transcripts under
  `~/.claude/projects`; all 450 bodies pass `_tx_body_ok` (no perpetual-miss
  regression on real data).

## Inventory

| File | Lines changed |
|---|---|
| `claude/lib/transcript-cache.sh` | +39 / -2 (now 74 lines) |
| `claude/test-statusline-helpers.sh` | +74 / -0 (section at 994-1066) |
| `claude/statusline-design.md` | +16 / -0 (§4.18 paragraph 770-784, changelog row) |

## Critical

### C1. Spark/stats validation fails open under `set -o pipefail` for bodies above the pipe buffer

- **Location:** `claude/lib/transcript-cache.sh:34`, `:39`
- **Axis:** Code / functional correctness, robustness (security control)
- **Description:** `! printf '%s\n' "$body" | LC_ALL=C grep -qvE '…'`. `grep -q` exits
  at the first non-matching (hostile) line. If the body is larger than the pipe
  buffer, `printf` is still writing and dies of SIGPIPE (status 141). Under
  `pipefail` the pipeline status becomes 141, and `!` turns that into success, so
  the body is accepted as valid. The verdict depends on an option the sourcing
  shell controls, not the library.
- **Scenario (verified):** `$TMPDIR/pipefail.sh` builds a stats body with the payload
  `A r1 1767261605 PASS[$(touch${IFS}/x)] 0 0 0 end_turn` on line 1, followed by
  4000 valid `A` lines (132 KB). Without pipefail it was rejected 20/20 times. With
  pipefail it was **accepted 20/20 times**. End to end (`$TMPDIR/pipefail-e2e.sh`): the
  same body planted as a signature-valid `.stats` file, then a call to
  `display_turn_stats`, **executes the payload** under `set -o pipefail`. Without
  pipefail the run is clean.
- **Exposure:** `statusline-command.sh` and the libs do not set `pipefail` (grep
  verified), and `~/.claude/settings.json` runs the script directly, so the
  current production entry point is not exploitable. However, the lib is sourced
  and has no control over its caller's options. The test harness itself runs
  `set -uo pipefail` (`test-statusline-helpers.sh:4`), so the hostile tests pass
  only because their planted bodies are small. If `SHELLOPTS` with pipefail ever
  reaches the statusline, the hole is live.
- **Fix direction (verified on bash 5.2):** feed grep with a here-string instead of a
  pipe: `! LC_ALL=C grep -qvE "…" <<< "${1%$'\n'}"`. With that change the same
  harness rejects 20/20 times under pipefail. Add a padded-body test to the
  hostile section, which already runs under pipefail.

## Major

### M1. `_TX_UINT` accepts leading zeros: `08`/`09` abort line 2 on every render, `010` reads as 8

- **Location:** `claude/lib/transcript-cache.sh:17` (`_TX_UINT='[0-9]+'`)
- **Axis:** Code / correctness, robustness; conformance with the §4.18 claim
- **Description:** bash arithmetic reads a leading `0` as octal. Producers never
  emit leading zeros (jq integers; the 150-transcript sweep found none). A
  planted body with `08` therefore passes validation and becomes a cache hit. Every
  render then hits `08: value too great for base` until the transcript changes.
- **Scenario (verified, full `statusline-command.sh` run):**
  - Spark body `U 1767261600\nA r1 1767261605 08 300 0 tool_use`: line 2 is
    replaced by an empty reset sequence, and `sparkline.sh: line 48: 08: value too
    great for base` goes to stderr.
  - Stats mode, body `A r1 1767261605 08 1 1 1 tool_use`: line 2 vanishes with
    `turn-stats.sh: line 147` on stderr.
  - `last` body token `08`: context shows ` 0`, plus `printf: 08: invalid octal
    number` and two arithmetic errors.
  - `010` in stats renders `cr` as 8.
- **Fix direction:** `_TX_UINT='(0|[1-9][0-9]*)'`.

### M2. Per-field rejection coverage incomplete: stats `U <epoch>` and spark `<out>` have no planted test

- **Location:** `claude/test-statusline-helpers.sh:1031-1052`
- **Axis:** Tests / coverage, specificity
- **Description:** The spark section plants payloads in `U <epoch>`, `A <epoch>` and
  `<cr>`. The stats section plants them only in `A <epoch>`, `<cr>` and a tab
  smuggle. There is no stats `U` test, and no test reaches spark `<in>`/`<out>` or
  stats `<cc>`/`<out>`/`<in>`.
- **Evidence:** relaxing only the stats `U` alternative to `U [^[:space:]]+` leaves the
  suite green. With validation disabled, a planted stats `U PASS[$(touch…)]`
  **executes** at `turn-stats.sh:174` (`dur=$(( … - ${t_anchor[$g]} ))`), verified
  by `$TMPDIR/probe.sh`. Relaxing only spark's last numeric field (`<out>`, an
  arithmetic sink via `spark_char`) also leaves the suite green.

### M3. Empty-body short-circuit for validated kinds is untested

- **Location:** `claude/lib/transcript-cache.sh:45` (`[[ -z "$2" ]] || …`);
  `claude/test-statusline-helpers.sh:968`
- **Axis:** Tests / coverage of specified behaviour ("empty producer output hits")
- **Description:** `_tx_valid_spark ""` and `_tx_valid_stats ""` both return
  *invalid* (verified): `printf '%s\n' ""` gives a blank line, which grep flags. The
  `-z` branch is therefore what keeps an empty spark/stats stream (a transcript
  with no turns) a cache hit. The only empty-body test (`:968`) uses kind `e`, which
  has no validator. Removing the branch leaves the suite green, and empty
  spark/stats streams would silently re-run `jq` on every render.

## Minor

### m1. §4.18's "at worst … wrong numbers or force a re-run" is inaccurate

- **Location:** `claude/statusline-design.md:781-784`
- **Axis:** Docs / accuracy
- **Description:** This sentence is the stated reason for not moving to a per-user
  0700 directory. M1 shows that a validated planted body can also suppress line 2
  with stderr errors on every render. C1 shows that evaluation is still reachable
  when the sourcing shell has pipefail set. The trade-off as recorded rests on both
  being impossible.

### m2. Rejected alternative recorded only inline

- **Location:** `claude/statusline-design.md:780-784` vs §5 (`:801`)
- **Axis:** Docs / consistency with neighbouring sections
- **Description:** The doc's convention puts rejected alternatives in §5 with a
  back-reference (for example the OAuth usage cache entry cites §4.15). The
  per-user 0700 directory rejection appears only inside §4.18.

### m3. Fail-open default for kinds without a validator

- **Location:** `claude/lib/transcript-cache.sh:16`, `:44`
- **Axis:** Code / robustness; excess
- **Description:** `declare -F … || return 0` accepts any kind with no `_tx_valid_*`.
  It exists only for the tests' ad-hoc kinds (`k`, `other`, `e`), as documented.
  The effect is that a future production kind added without a validator feeds
  unvalidated shared-dir content to its consumer with no warning. This is the
  inverse of the stated goal. Fail-closed for unknown kinds (with the tests
  registering a pass-through validator) would remove it.

### m4. "last: non-ISO timestamp rejected" is weak on Linux and vacuous on macOS

- **Location:** `claude/test-statusline-helpers.sh:1021-1022`
- **Axis:** Tests / vacuity, specificity
- **Description:** The expected value is the baseline `_hx_exp`, which is `""`
  because the fixture's timestamp is long expired. On Linux the test is
  non-vacuous: with validation disabled `date -d tomorrow` yields `01:36`
  (verified by mutation). Any other path that returns empty would still pass. On
  macOS, `format_cache_expiry` uses `date -j -f "%Y-%m-%dT%H:%M:%S"`, which cannot
  parse `tomorrow`, so the output is `""` with or without validation (reasoned from
  BSD `date -j -f` semantics; **unverified**, no macOS available).

### m5. The "payload executes if bypassed" property holds for spark/stats only, not `last`

- **Location:** `claude/test-statusline-helpers.sh:1021-1029`
- **Axis:** Tests / claim accuracy
- **Description:** With validation stripped, the planted `last` token is echoed back
  as a string but never evaluated. Its sinks are regex-guarded
  (`get_token_color`, `display_token_bar`, `humanize_tokens`) or use `[ -lt ]` and
  `bc` (`kilos`), and `date -d` cannot exec. The `last` assertions still detect a
  bypass through output mismatch (mutation-killed), so this is not a defect. The
  commit claim ("tests … execute the payload") is broader than what the tests
  show. Also, `_hx_mark` is not cleared or checked around the `last` block.

### m6. Locale asymmetry between validators

- **Location:** `claude/lib/transcript-cache.sh:29` vs `:34`, `:39`;
  `claude/statusline-design.md:778-779`
- **Axis:** Code / portability; Docs / completeness
- **Description:** `_tx_valid_last` runs `[[ =~ ]]` in the caller's locale, while
  spark/stats force `LC_ALL=C`. The doc mentions only the C-locale grep. On Debian
  `C.UTF-8`, `[0-9]` matched none of `０ ٣ ² ① ߀`. macOS locales are **unverified**.

### m7. Rejections are silent

- **Location:** `claude/lib/transcript-cache.sh:62`
- **Axis:** Code / error signalling
- **Description:** A rejected hit is indistinguishable from a signature miss. Repeated
  planting, or a validator/producer drift, shows up only as extra `jq` forks.
  Acceptable for a statusline, but nothing records it.

### m8. Hostile section couples to earlier section state

- **Location:** `claude/test-statusline-helpers.sh:1054-1065`
- **Axis:** Tests / independence
- **Description:** It reuses `_tc_cnt` and `_tc_runs` defined in the `_tx_cached`
  section (`:953-957`), so reordering or removing that section breaks this one.

### m9. "no extra lines" reads as applying to all kinds

- **Location:** `claude/statusline-design.md:775`
- **Axis:** Docs / clarity
- **Description:** "no extra lines" applies to `last` only. Spark/stats accept any
  number of well-shaped lines.

### Unverified portability items (no bash 3.2 / BSD userland available)

These are listed as unverified, not as findings:

- `"${1%$'\n'}"` and `*$'\n'*$'\n'*` under bash 3.2. The analogous
  `"${out//$'\n'/}"` already ships in `context-display.sh:122`, which suggests it
  works.
- `grep -E` with `{4}` intervals and `[:space:]` on BSD grep.
- `declare -F` exists in bash 3.2.

## Gap Analysis

| Design claim | Status | Finding |
|---|---|---|
| Hit validated per kind before `date -d` / arithmetic | Covered, except under pipefail with large bodies, and leading-zero numbers | C1, M1 |
| Exact line shapes: ISO timestamp, unsigned ints, no extra lines (`last`) | Covered (CR, blank-line, extra-line, non-ISO tests; mutations killed) | m4, m9 |
| `<req>`/`<stop>` free of any whitespace (tab smuggling) | Covered (tab tests for spark and stats; `wordtab` mutation killed) | — |
| Failing body is a miss, regenerated and overwritten | Covered (miss path unchanged; tests compare to fresh output) | m7 |
| Spark/stats checked with one grep in the C locale | Implemented; `last` not in C locale | m6 |
| Validation in one place, kind with no validator accepted | Implemented as stated | m3 |
| Planted-cache tests execute the payload if validation is bypassed | spark/stats yes (verified by mutation); `last` no evaluating sink; stats `U` and spark `<out>` untested | M2, m5 |
| Real producer output validates (no perpetual miss) | Covered (test + 150-transcript sweep); empty-stream case untested | M3 |
| Per-user dir rejected: at worst wrong numbers or a re-run | Inaccurate | m1, m2, C1, M1 |
| Portability macOS bash 3.2 / BSD | Unverified | (unverified list) |

## Summary

- Critical: 1
- Major: 3
- Minor: 9
