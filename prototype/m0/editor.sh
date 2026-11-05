#!/bin/sh
# Use as Claude Code's editor to try the prototype in the real Ctrl+G flow:
#   VISUAL=~/code/vergil.nvim/prototype/m0/editor.sh claude
# (Claude Code uses $VISUAL before $EDITOR, so setting only EDITOR is not enough.)
# Loads your normal config, then attaches the prototype server to
# claude-prompt-*.md buffers. The project root is the directory claude runs in.
here=$(cd "$(dirname "$0")" && pwd)
exec nvim --cmd "lua package.path = '$here/?.lua;' .. package.path; require('server').setup()" "$@"
