#!/usr/bin/env bash
# shellcheck disable=SC2034
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
# The one bright variant (NFR7 otherwise bans them): the context growth bar
# alternates MAGENTA/BRMAGENTA past 200k so its blocks stay countable.
BRMAGENTA=$'\033[95m'
# Leading \033[22m clears any inherited intensity (esp. DIM from RESET_DIM)
# before setting bold: Claude CLI's renderer doesn't treat bold(1)/faint(2) as
# a single tri-state like most real terminals -- \033[1m alone, applied right
# after a \033[2m, still rendered as dim instead of overriding to bold.
BOLD=$'\033[22m\033[1m'
RESET_FG=$'\033[39m'
RESET_BG=$'\033[49m'
RESET_BOLD=$'\033[22m'
RESET_BLINK=$'\033[25m'
INVERSE=$'\033[7m'
RESET_INVERSE=$'\033[27m'
DIM=$'\033[2m'
RESET=$RESET_FG$RESET_BOLD$RESET_BLINK
# RESET_BOLD (\033[22m, "normal intensity") clears bold AND dim -- they share
# one intensity slot. Claude CLI dims the whole line before the script runs,
# so plain RESET (used deliberately by sparkline.sh to force full, uniform
# intensity) permanently kills that dim for anything after it. RESET_DIM
# reasserts DIM afterward, for segments that should return to the ambient
# dim baseline instead.
RESET_DIM=$RESET$DIM
