# Review: transcript-cache hit validation (`git diff 05fc99f`, commit 1d5d637)

**Scope**: claude/lib/transcript-cache.sh (validators, hit path), "planted cache bodies" section of claude/test-statusline-helpers.sh, §4.18 paragraph + changelog row of claude/statusline-design.md
**Date**: 2026-10-08T18:23:10Z
**Mode**: review + fix

## Summary

The commit validates each `_tx_cached` hit per kind before consumers feed it to `date -d` and `$(( ))`. The `last` validator was sound; the `spark`/`stats` validators had an exploitable false accept: `[^ ]+` for `<req>`/`<stop>` admits a tab, while consumers split `A` lines with default-IFS `read -r`, so a tab in `<req>` shifts a planted `a[$(cmd)]` into `<epoch>`, which reaches arithmetic. Reproduced end to end (validator accepted, `$(( now - _ts ))` ran the payload). Fixed, along with decorative test assertions and a doc overstatement.

Note: during this review the test file was being edited concurrently by another agent (payload changed to `PASS[$(touch${IFS}…)]`, "last: extra line rejected" rewritten to call `_tx_body_ok` directly). Those edits are uncommitted and were kept; my edits were applied on top of them.

**Overall Assessment**: Ready

## Issues Found

### Critical Issues

1. **Tab inside `<req>` smuggles a payload into an arithmetic field**
   - Location: claude/lib/transcript-cache.sh:29,34 (committed version)
   - Problem: `A [^ ]+ …` accepts `A r1<TAB>a[$(cmd)] 1 300 0 10 end_turn`. grep sees seven space-separated fields; `read -r _ _r _ts …` (sparkline.sh:239/310, turn-stats.sh:105) splits on tab too, so `_ts='a[$(cmd)]'`, evaluated in `_spark_trailing` (`$(( now - ref ))`) and `dur=$(( ${t_lastapi} - … ))`. Verified: `_tx_body_ok spark/stats` returned success on the planted body and the payload executed. Same applies to `<stop>` (CR/tab inside it).
   - Fix: `_TX_WORD='[^[:space:]]+'` for `<req>`/`<stop>` (rejects tab, CR, VT, FF); grep run under `LC_ALL=C` so `[0-9]`/`[:space:]` are ASCII-defined regardless of locale.
   - **Status**: FIXED

### Major Issues

1. **"nothing executed" assertions were decorative**
   - Location: claude/test-statusline-helpers.sh, planted section (committed version)
   - Problem: committed payload `a[$(touch /path)]` contains a space, so `read -r` split it (`_cr='a[$(touch'`) and the marker could never be created; with the validator disabled all three "nothing executed" assertions still passed. Also the spark tests only planted payloads in `<cr>` (consumed by `[ -gt ]`, not arithmetic) and in a `U` line with no following `A` (never reaches arithmetic), so even a space-free payload would not have executed there.
   - Fix: the concurrent edit made the payload space-free (`PASS[$(touch${IFS}…)]`). I added a spark test with the payload in the `A` epoch field and tab-smuggle tests for spark and stats, and reset the marker per kind (`rm -f "$_hx_mark"`) so each "nothing executed" covers only its own kind. Verified: with the committed validator, "spark/stats: tab-smuggled field rejected" and "spark/stats: nothing executed" FAIL ("executed"); with no validator, every rejection and "nothing executed" assertion FAILs.
   - **Status**: FIXED

2. **"last: extra line rejected" passed without the fix**
   - Location: claude/test-statusline-helpers.sh (committed version)
   - Problem: consumers read only two lines, so an extra third line changes no observable output; the assertion passed with validation disabled.
   - Fix: already rewritten concurrently to assert `_tx_body_ok last …` directly; now RED with no validator.
   - **Status**: FIXED

3. **No positive control against false rejects of real producer output**
   - Location: claude/test-statusline-helpers.sh (committed lines 1043-1046)
   - Problem: the block populated the cache through the real producers and then `rm -rf`'d it with no assertion (dead code). A validator that rejected every real body would turn every render into a silent `jq` re-run, and no test would notice.
   - Fix: replaced with "real producer bodies are cache hits": populate via `get_transcript_context`/`display_turn_sparkline`/`display_turn_stats`, then call `_tx_cached` for each kind with a counting producer and assert it ran 0 times. Mutation check: narrowing `_TX_WORD` to `[a-z]+` makes it FAIL (got 2).
   - **Status**: FIXED

### Minor Issues

1. **`last` validator allowed lines after a blank third line**
   - Location: claude/lib/transcript-cache.sh `_tx_valid_last`
   - Problem: it read only three lines, so `ts\ntok\n\nextra` passed; the doc and comment say "nothing else". Consumers read two lines, so this was not exploitable.
   - Fix: reject any body that has more than one newline once a single trailing newline is stripped (`[[ "${1%$'\n'}" != *$'\n'*$'\n'* ]]`), and drop the `extra` read. Producer output (`"\n"`, `"ts\n"`, `"\ntok\n"`, `"ts\ntok\n"`) still passes. Added tests "line after a blank line rejected" (RED against the committed validator) and "CR-terminated token rejected" (regression guard).
   - **Status**: FIXED

2. **Design doc overstated the residual risk**
   - Location: claude/statusline-design.md §4.18
   - Problem: "a planted body can then at worst force a re-run". A well-formed planted body with a matching signature is accepted and displayed, so it can also show wrong numbers. The paragraph also did not mention the whitespace rule or the C-locale grep.
   - Fix: paragraph now names the whitespace-free `<req>`/`<stop>` rule and why it matters, the C-locale grep, and "at worst show well-formed but wrong numbers or force a re-run". Changelog row extended with "whitespace-smuggled `<req>`/`<stop>` fields".
   - **Status**: FIXED

## Fixes Applied

- claude/lib/transcript-cache.sh:19-22 — added `_TX_WORD='[^[:space:]]+'` with a comment on the tab shift
- claude/lib/transcript-cache.sh:25-30 — `_tx_valid_last`: newline-count check replaces the third `read`
- claude/lib/transcript-cache.sh:33-40 — spark/stats regexes use `_TX_WORD`; grep runs with `LC_ALL=C`
- claude/test-statusline-helpers.sh (planted section) — added last blank-line and CR tests; spark `A` epoch and tab-smuggle tests; stats tab-smuggle test; reset marker per kind; replaced the dead populate-then-delete block with "real producer bodies are cache hits"
- claude/statusline-design.md §4.18 + changelog row — as above

Suite: `bash claude/test-statusline-helpers.sh` → PASS 236 tests (230 baseline + 6 new). Nothing committed.

## Criteria Checks (no finding)

- **Column counts/order**: spark `A req ts c i o stop` (7 tokens) matches `_spark_stream_jq` and `read -r _ _r _ts _c _i _o _stop`. Stats `A req ts cr cc out in stop` (8 tokens) matches `_stats_stream_jq` and `read -r _ _r _ts _cr _cc _out _in _stop`. `last` matches `_tx_last_jq` (`.ts, .tok`, then `printf '%s\n'`).
- **Real data shapes**: scanned `~/.claude/projects`. Every `timestamp` matches `_TX_ISO_TS`, every `requestId` is `req_[A-Za-z0-9]+`, and `stop_reason` is only `tool_use`/`end_turn`/`stop_sequence`. No false rejects.
- **`<req>` in `[[ == *"|$req|"* ]]`**: quoted, so it is literal; no glob or evaluation risk.
- **Anchoring**: bash `=~` and grep `^…$` both anchor the whole line, and `read` has already split on `\n`. CR is rejected by the digit/ISO classes and now by `_TX_WORD`.
- **Invalid bytes**: GNU grep 3.11 rejects `\xff` lines (exit 0 on `-qv`) in both C and C.utf8. Bash command substitution strips NUL before validation.
- **Locale in `=~` (`_tx_valid_last`)**: still uses the process locale. A non-ASCII digit accepted there could only cause an arithmetic or `date` error, not execution. Left as is.
- **Bash 3.2**: `declare -F`, `=~` with an unquoted pattern variable, here-strings, `$'…'` inside `${…%…}` (extquote, default on; already used at context-display.sh:122) and `[[:space:]]` in BSD grep all exist on macOS. No issue.
- **Performance**: one `printf | grep` per spark/stats hit costs a few ms, compared with `tail | jq` over 1500 lines on a miss. A bash `read` loop over up to 1500 lines would be slower. Not a concern.
- **Other paths to arithmetic/`date -d`**: all three cached kinds go through `_tx_body_ok`. Kinds without a validator are accepted (documented); only the tests' ad-hoc kinds use that.

## Positive Observations

- Validation sits in one choke point (`_tx_body_ok` in the hit path), so consumers stay unchanged.
- A failed validation falls through to the normal miss path, so the planted file is overwritten, not just ignored.
- Rejection tests compare against a baseline rendered from the real transcript rather than hard-coded strings.

## Recommendations

- The "kind without validator is accepted" fallback fails open: a future cached kind added without a `_tx_valid_<kind>` silently reintroduces the issue. Consider failing closed for non-test kinds (e.g. an explicit allowlist of unvalidated test kinds) when the next kind is added.
- When run from an interactive shell that defines a `grep` function (Claude Code's tool shell wraps `grep` as ugrep with `-I`, which treats an invalid-byte line as "no match" under `-qv`), validation behaviour would differ. Not reachable from the statusline or the test runner (the function is not exported), so no change made.
