## Open decisions

- Glyphs and colours for the new AgentStatus values in statusSec (hooks/agent-row.ts): pending, waiting, idle. Suggested default: waiting ⏸ in CYAN with elapsed time, idle ◌ uncoloured, pending … uncoloured; 16 base ANSI colours only, no intensity change.
- Publishing: public repos ddaanet/cc-statusline and ddaanet/cc-statusline-memory exist, origin remotes are set (parent and memory submodule, ssh), nothing is pushed; the auto-mode classifier denied /gitlore:push earlier. A release needs both pushed: ask the user to run /gitlore:push and `git push -u origin main` (memory first, so the gitlink resolves), or to authorize them.

## Remaining

- Release after the status change: `just release` per plugin-dev/README.md Conventions (first release, bare, no bump argument); use plugin-craft:toolkit-release if it half-lands.
- The user runs `just dogfood` and restarts Claude Code to see the rows live (dist/plugin is write-denied to the agent); ask them to check the timer ticks on a quiet running agent and whether engine-named background agents now read `name (type)`.
- Remove the old renderer with craft:removing-cleanly: subagent-statusline.sh, lib/subagent-display.sh, the sublink and subagentStatusLine block in `just install`/`uninstall`, the lint target, the subagent sections of test-statusline-helpers.sh and its sa_row load check; then update CLAUDE.md, statusline-design.md §4.19 (now the mod: AgentRow body, 5 s re-ask, nested rows not width-fitted), §3 file table, §6, a §7 row, and docs/decisions/statusline.md.
- Tell the user to delete the subagentStatusLine block from ~/.claude/settings.json and the ~/.claude/subagent-statusline.sh symlink (both write-denied to the agent).