## Open decisions

- Publishing: public repos ddaanet/cc-statusline and ddaanet/cc-statusline-memory exist, origin remotes are set (parent and memory submodule, ssh) and .gitmodules points at the https memory url, but nothing is pushed: the auto-mode classifier denied /gitlore:push. Ask the user to run /gitlore:push and `git push -u origin main` (memory first, so the gitlink resolves), or to authorize them explicitly.

## Remaining

- After the AgentRow port: remove subagent-statusline.sh, lib/subagent-display.sh and the subagentStatusLine block in just install; update CLAUDE.md, statusline-design.md §4.19/§3/§7 and docs/decisions/statusline.md.
- After any hooks/ change, the user runs `just dogfood` and restarts Claude Code: dist/plugin is write-denied to the agent and a stale copy fails silently.
