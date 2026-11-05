#!/usr/bin/env bash
# End-to-end Ctrl+G handoff test (plan Milestone 6). Drives an interactive
# `claude` in tmux with vergil as the editor, using a clean Neovim with
# native completion so the result doesn't depend on a personal config:
#   1. @ completion attaches a file
#   2. @@ completion plus # line selection inserts a ranged mention
#   3. ZZ (:Vergil submit) hands the prompt back; the transcript must show
#      the attachment loaded and the mention not loaded
#   4. ZQ (:Vergil abort) restores the prompt from before Ctrl+G
#   5. a collapsed paste collapses again after editing around it
#
# Usage: tests/contract/handoff.sh [workdir]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=${1:-$(mktemp -d "${TMPDIR:-/tmp}/vergil-handoff.XXXXXX")}
mkdir -p "$W/work"; cd "$W/work"
S=vergil-handoff-$$
U=$(uuidgen | tr 'A-Z' 'a-z')

printf 'HANDOFF_ATTACH_\n' > attached.txt
printf 'line one\nHANDOFF_MENTION_ line two\nline three\n' > mentioned.txt
git init -q . 2>/dev/null || true

cat > "$W/editor.sh" <<SH
#!/bin/sh
exec nvim -n --clean --cmd "set rtp^=$REPO" --cmd "set completeopt=menuone,noselect,popup,fuzzy" \\
  --cmd "lua require('vergil').setup({ completion = { native = true }, keymaps = { preset = true } })" "\$@"
SH
chmod +x "$W/editor.sh"

tmux new-session -d -s "$S" -x 160 -y 40 -c "$W/work" "VISUAL=$W/editor.sh claude --tools '' --session-id $U"
trap 'tmux kill-session -t "$S" 2>/dev/null || true' EXIT
sleep 8
if tmux capture-pane -p -t "$S" | grep -q 'trust this folder'; then tmux send-keys -t "$S" Down Enter; sleep 5; fi

typ() { local s="$1" i; for ((i=0; i<${#s}; i++)); do tmux send-keys -t "$S" -l "${s:$i:1}"; sleep 0.15; done; sleep 0.8; }
pane() { tmux capture-pane -p -t "$S"; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fi; }

# 1-3: compose with completion and line selection, then submit with ZZ.
tmux send-keys -t "$S" C-g; sleep 3
tmux send-keys -t "$S" i; typ 'Reply OK. '
typ '@attac'; tmux send-keys -t "$S" C-n; sleep 0.3; tmux send-keys -t "$S" C-y; sleep 0.5
typ ' and '
typ '@@mentio'; tmux send-keys -t "$S" C-n; sleep 0.3; tmux send-keys -t "$S" C-y; sleep 0.5
typ '#'; sleep 1; tmux send-keys -t "$S" 2 G Enter; sleep 1
tmux send-keys -t "$S" Escape; sleep 0.3
composed=$(pane | grep -m1 'Reply OK' | sed 's/^ *[0-9]* *//')
tmux send-keys -t "$S" Z Z; sleep 2
check "prompt composed in Neovim" 'Reply OK. @attached.txt and `mentioned.txt#L2`' "$composed"
check "ZZ hands the prompt to Claude Code" yes "$(pane | grep -q "Reply OK. @attached.txt and .mentioned.txt#L2." && ! pane | grep -q "claude-prompt-" && echo yes || echo no)"
tmux send-keys -t "$S" Enter; sleep 15
T=$(ls ~/.claude/projects/*/"$U".jsonl)
check "attachment loaded" yes "$(grep -q HANDOFF_ATTACH_ "$T" && echo yes || echo no)"
check "mention not loaded" no "$(grep -q HANDOFF_MENTION_ "$T" && echo yes || echo no)"

# 4: abort with ZQ restores the prompt typed before Ctrl+G.
tmux send-keys -t "$S" -l 'BEFORE_CTRL_G'; sleep 0.5
tmux send-keys -t "$S" C-g; sleep 3
tmux send-keys -t "$S" G o; typ 'discard me'; tmux send-keys -t "$S" Escape; sleep 0.3
tmux send-keys -t "$S" Z Q; sleep 2
# The space after Claude Code's ❯ is not a plain space, so match the text only.
check "ZQ restores the prompt" yes "$(pane | grep -q "BEFORE_CTRL_G" && ! pane | grep -q "claude-prompt-" && echo yes || echo no)"
check "ZQ drops the edit" no "$(pane | grep -q 'discard me' && echo yes || echo no)"
tmux send-keys -t "$S" C-u; sleep 0.5

# 5: a collapsed paste stays collapsed when editing around it. (A paste at
# the very end of the prompt never re-collapses after Ctrl+G, even with plain
# Neovim and no write; that's Claude Code, so the test adds text after it.)
for i in $(seq 1 30); do echo "pasted log line $i with @fake$i.ts trailing  "; done > "$W/paste.txt"
tmux send-keys -t "$S" -l 'Intro text. '; tmux load-buffer -b vergil-paste "$W/paste.txt"
tmux paste-buffer -p -b vergil-paste -t "$S"; sleep 2
check "paste collapses in Claude Code" yes "$(pane | grep -q 'Pasted text #1' && echo yes || echo no)"
tmux send-keys -t "$S" C-g; sleep 4
tmux send-keys -t "$S" g g I; typ 'EDITED '; tmux send-keys -t "$S" Escape; sleep 0.3
tmux send-keys -t "$S" G o; typ 'Outro.'; tmux send-keys -t "$S" Escape; sleep 0.5
tmux send-keys -t "$S" Z Z; sleep 2
check "paste collapses again after editing around it" yes "$(pane | grep -q 'EDITED Intro text. \[Pasted text #1 +30 lines\]' && echo yes || echo no)"
tmux send-keys -t "$S" C-u
echo "transcript: $T"
