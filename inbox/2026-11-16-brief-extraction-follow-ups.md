## Brief: follow-ups from the extraction out of the home repository

2026-11-16. From the home session that extracted this repo. Nothing was
changed here; these are the items the home repo no longer tracks.

### 1. Two memory facts await a gitlore store

`inbox/statusline-line2-stats.md` and
`inbox/anthropic-cache-persistence-unstable.md` are gitlore memory facts
moved here from the home memory store because they concern the statusline.
This repo has no gitlore store yet. Either install one (`/gitlore:install`)
and move them in through the memory-writing skill, or fold their content into
`statusline-design.md` and delete them.

Both cite home commit hashes in the range `8318a2f..9db1a23`. A
`git filter-repo` rewrite of home invalidated every hash in that range; drop
the hashes or describe the commits by subject instead.

### 2. Decide whether the statusline stands alone

`statusline-command.sh` sources `account-validation.sh` for the account
badge, resolving it from `~/.claude/statusline-account-lib`, then
`$HOME/code/cc-switch/lib/account-validation.sh`, and silently shows no badge
when neither exists (README.md:72-77, CLAUDE.md:64). Options:

- Keep the dependency and document it as the install step, as today.
- Move `account-validation.sh` into this repo and have cc-switch source it
  from here, inverting the dependency.
- Duplicate the three functions here and accept drift.

cc-switch's CLAUDE.md promises stable `get_mode`, `get_api_provider` and
`validate_state` signatures for this repo's sake; any move changes that
promise on both sides.

### Constraints

- The statusline runs under macOS bash 3.2 and Linux bash 5; the precommit
  already tests under 3.2.
- A plugin cannot ship a `statusLine` setting, so this repo stays installed
  by its justfile rather than as a plugin. Plugin wrappers were considered
  in the home repo and rejected as over-engineering.
