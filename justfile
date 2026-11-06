# cc-statusline — Claude Code statusline

link := "~/.claude/statusline-command.sh"

[private]
default:
    @just --list --unsorted

# Symlink the statusline into ~/.claude and print the settings.json block
install:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.claude
    ln -sf "{{ justfile_directory() }}/statusline-command.sh" {{ link }}
    echo "Installed {{ link }} -> {{ justfile_directory() }}/statusline-command.sh"
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
    echo "Optional: point the account badge at the claude-account lib with"
    echo "  echo /path/to/account-validation.sh > ~/.claude/statusline-account-lib"
    echo "  (default: ~/code/cc-switch/lib/account-validation.sh)"

# Remove the symlink (the settings.json block stays; remove it by hand)
uninstall:
    @rm -f {{ link }}
    @echo "Removed {{ link }}"

# Run the test suite
test:
    bash test-statusline-helpers.sh

# shellcheck every script
lint:
    shellcheck -x statusline-command.sh lib/*.sh test-statusline-helpers.sh

# lint + test
precommit: lint test
