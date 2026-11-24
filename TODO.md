## Open decisions

- Make the gitlore launcher fix in ~/code/gitlore (scripts/install/launcher-shim): replace the pre-trust `git ls-files -s` gitlink check with `git ls-tree HEAD -- <mempath>` (user prefers it; cost: refuses between /gitlore:install and its first commit), plus a bats test. ~/code/gitlore is on branch dev with uncommitted .envrc/memory changes and is outside this session's sandbox scope: ask whether to do it here or leave it to a gitlore session.
- GitHub origin for cc-statusline and a public gitlore memory remote (probe steps `origin`, `memory-url`): outward-facing, create nothing until the user says.

## Remaining

- Once fable-probe confirms the path, remove the probe breadcrumb from hooks/register.ts and its mention in statusline-design.md §4.20; check a Fable turn shows the block (user deferred the Fable turn to this session).
- Port the subagent rows to the mod: ui.render hook on component AgentRow returning `body` (SGR allowed, `columns` given; AgentInfo has status, type, name, model, effort, tokenCount, contextWindowSize, startTime, tokenSamples). Match lib/subagent-display.sh (status glyph + elapsed, label, model rank/effort glyphs from lib/model-display.sh, kilos, token growth bar, width fitting); never change intensity. Then remove subagent-statusline.sh, lib/subagent-display.sh, the subagentStatusLine block in just install, and update CLAUDE.md, design §4.19/§3/§7 and docs/decisions.
- dist.include ships hooks/*.test.ts and claude plugin test also runs dist/plugin's copy: consider keeping tests out of the shipped tree.