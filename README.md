# cc-statusline

A two-to-three line status line for Claude Code, in plain bash: model, effort,
directory, git branch, cost (main thread, as Claude Code reports it) and
context usage on line 1; account mode or plan
rate limits on line 2; an optional per-call token sparkline or per-turn stats
line. A second script renders the rows of the agent panel, one per subagent.
The living design document is `statusline-design.md`; decisions are in
`docs/decisions/`, dated specs and plans in `plans/`.

## Requirements

- bash 3.2 or newer (macOS `/bin/bash` is enough)
- `jq`
- `git` (branch and dirty state on line 1)

## Install

```sh
just install
```

This symlinks `~/.claude/statusline-command.sh` and
`~/.claude/subagent-statusline.sh` to the scripts in this checkout and prints
the settings blocks. Then add to `~/.claude/settings.json`, with the paths
written out in full (Claude Code does not expand `~`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/david/.claude/statusline-command.sh",
    "refreshInterval": 60
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "/Users/david/.claude/subagent-statusline.sh"
  }
}
```

`just uninstall` removes both symlinks. `just test`, `just lint` and
`just precommit` run the suite and shellcheck.

Installation is a script rather than a plugin because a plugin's `settings`
cannot carry `statusLine`: only the `agent` and `subagentStatusLine` keys take
effect from a plugin. A plugin wrapper could later ship a setup skill that runs
the same steps.

## Subagent rows

With `subagentStatusLine` set, each row of the agent panel shows, left to right:

```
▶ 4m12  general-purpose  ❷ Opus ● high  ⛁ 117k ██▃
```

- status: `▶` running (with its running time), `✔` completed, `✘` failed,
  `■` killed
- the agent type, with its name when it has one
- model and effort, in the same glyphs as line 1
- the agent's current context, coloured and barred like line 1's

No cost is shown: Claude Code reports none per agent. When the row is narrow,
the bar goes first, then the labels. If the
payload cannot be read, the script prints nothing and Claude Code keeps its
default rows.

## Account badge (optional)

The account mode badge (`plan` / `API`, consistency check) comes from
`account-validation.sh`, which belongs to the `claude-account` switcher in the
`../cc-switch` repository and is not part of this one. The statusline looks for it in this order:

1. `$CC_STATUSLINE_ACCOUNT_LIB`
2. the first line of `~/.claude/statusline-account-lib`
3. `$HOME/code/cc-switch/lib/account-validation.sh`

When none exists the badge is skipped: mode defaults to `plan`, the state is
treated as consistent, and the script still exits 0. The test suite resolves
the library the same way and says which it used.

## Configuration

Flag files under `~/.claude/`:

- `statusline-line2` selects the last line: `sparkline` (per API call, the
  default), `stats` (per user turn) or `off` (no last line).
  `echo off > ~/.claude/statusline-line2`.
- `sparkline-always-on` keeps the sparkline visible while the session is idle;
  by default it is hidden. `touch` to enable, `rm` to go back to the default.
  When always-on and idle, the trailing value is the final turn's completed
  duration, dropped once the prompt cache has expired (over an hour idle).
- `statusline-chrome-cols` overrides the number of columns reserved for Claude
  Code's own chrome around the status line.

State (caches, a debug dump of the last payload, a timing log) lives in a
private per-user directory: `$CC_STATUSLINE_STATE_DIR` if set, else
`$XDG_RUNTIME_DIR/cc-statusline`, else `~/.cache/cc-statusline`. It is created
mode 0700; if it is a symlink or not owned by you, the statusline runs uncached
and writes nothing.

## Layout

```
statusline-command.sh        entry point (always exits 0)
subagent-statusline.sh       agent-panel rows (subagentStatusLine; always exits 0)
lib/                         rendering modules, sourced relative to the script
test-statusline-helpers.sh   assert harness: bash test-statusline-helpers.sh
statusline-design.md         living design doc
docs/decisions/              decision records
plans/                       dated specs and implementation plans
```
