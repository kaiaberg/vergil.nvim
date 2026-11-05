#!/bin/sh
# Try this checkout in Claude Code's Ctrl+G flow without installing it:
#   VISUAL=~/code/vergil.nvim/scripts/dev-editor.sh claude
# (Claude Code uses $VISUAL before $EDITOR.) Loads your normal config and
# adds this repository to the runtimepath.
here=$(cd "$(dirname "$0")/.." && pwd)
exec nvim --cmd "set rtp^=$here" "$@"
