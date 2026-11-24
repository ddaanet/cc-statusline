import 'plugin-dev/release.just'

# cc-statusline — Claude Code statusline

link := "~/.claude/statusline-command.sh"
sublink := "~/.claude/subagent-statusline.sh"

[private]
default:
    @just --list --unsorted

# Symlink both status lines into ~/.claude and print the settings.json blocks
install:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.claude
    ln -sf "{{ justfile_directory() }}/statusline-command.sh" {{ link }}
    ln -sf "{{ justfile_directory() }}/subagent-statusline.sh" {{ sublink }}
    echo "Installed {{ link }} -> {{ justfile_directory() }}/statusline-command.sh"
    echo "Installed {{ sublink }} -> {{ justfile_directory() }}/subagent-statusline.sh"
    echo
    echo "Add this to ~/.claude/settings.json (the path must be absolute, ~ is not expanded):"
    cat <<JSON
    {
      "statusLine": {
        "type": "command",
        "command": "$HOME/.claude/statusline-command.sh",
        "refreshInterval": 60
      }
    }
    JSON
    echo
    echo "and, for the agent panel rows:"
    cat <<JSON
    {
      "subagentStatusLine": {
        "type": "command",
        "command": "$HOME/.claude/subagent-statusline.sh"
      }
    }
    JSON
    echo
    echo "Optional: point the account badge at the claude-account lib with"
    echo "  echo /path/to/account-validation.sh > ~/.claude/statusline-account-lib"
    echo "  (default: ~/code/cc-switch/lib/account-validation.sh)"

# Remove both symlinks (the settings.json blocks stay; remove them by hand)
uninstall:
    @rm -f {{ link }} {{ sublink }}
    @echo "Removed {{ link }} and {{ sublink }}"

# Run the test suite
test:
    bash test-statusline-helpers.sh

# shellcheck every script
lint:
    shellcheck -x statusline-command.sh subagent-statusline.sh lib/*.sh test-statusline-helpers.sh

# Run the suite again under /bin/bash when it is bash 3.2 (macOS): a PATH shim
# makes the entry points the suite spawns run under 3.2 too. Skipped elsewhere.
test-bash32:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! /bin/bash -c '(( BASH_VERSINFO[0] < 4 ))' 2>/dev/null; then
        echo "test-bash32: /bin/bash is not bash 3.2, skipped"
        exit 0
    fi
    shim=$(mktemp -d "${TMPDIR:-/tmp}/bash32-shim.XXXXXX")
    trap 'rm -rf "$shim"' EXIT
    ln -s /bin/bash "$shim/bash"
    PATH="$shim:$PATH" /bin/bash test-statusline-helpers.sh

# lint + test (+ the bash 3.2 run on macOS)
precommit: check-refs lint test test-bash32

# the gate `release` depends on
prerelease: precommit
