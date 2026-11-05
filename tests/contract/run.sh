#!/usr/bin/env bash
# Claude Code contract tests (plan §4.4). Drives an interactive `claude` in
# tmux through the real Ctrl+G external-editor path, using a fake $EDITOR
# that writes a canned prompt, then greps the session transcript for markers.
#
# Usage: tests/contract/run.sh [workdir]
# Requires: claude, tmux, python3. Costs a few tiny API calls. With no
# workdir, uses a fresh temp dir; Claude Code will ask to trust it once
# (the script accepts the prompt, since it created every file in it).
set -euo pipefail

W=${1:-$(mktemp -d "${TMPDIR:-/tmp}/vergil-contract.XXXXXX")}
mkdir -p "$W/work"; cd "$W/work"
S=vergil-contract-$$
U=$(uuidgen | tr 'A-Z' 'a-z')

printf 'MARK1_\n' > 'my file.txt'
printf 'MARK2_\n' > Override
printf 'MARK3_\n' > ctrl.txt
printf 'MARK4_\n' > small.txt
python3 - <<'PY'
line = "filler line of text for size testing 0123456789\n"
for k in (70, 100, 260):
    open(f"sz{k}.txt", "w").write(f"SZ{k}_\n" + line * (k * 1024 // len(line)))
import random; random.seed(1)
open("dense40.txt", "w").write("DENSE40_\n" + " ".join("%03x" % random.randrange(4096) for _ in range(10240)))
PY

cat > "$W/editor.sh" <<'SH'
#!/bin/sh
D="$(dirname "$0")"; cat "$(cat "$D/src")" > "$1"; exit "$(cat "$D/exit")"
SH
chmod +x "$W/editor.sh"; echo 0 > "$W/exit"

tmux new-session -d -s "$S" -x 180 -y 50 -c "$W/work" "EDITOR=$W/editor.sh claude --tools '' --session-id $U"
trap 'tmux kill-session -t "$S" 2>/dev/null || true' EXIT
sleep 8
if tmux capture-pane -p -t "$S" | grep -q 'trust this folder'; then tmux send-keys -t "$S" Down Enter; sleep 5; fi

send() { # $1 = prompt text
  printf '%s\n' "$1" > "$W/p.txt"; echo "$W/p.txt" > "$W/src"
  tmux send-keys -t "$S" C-g; sleep 2; tmux send-keys -t "$S" Enter; sleep 15
}
T() { ls ~/.claude/projects/*/"$U".jsonl; }
has() { grep -q "$1" "$(T)"; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fi; }
yn() { if has "$1"; then echo yes; else echo no; fi; }

send $'Contract test. Reply OK.\n\n@ctrl.txt\n\n@"my file.txt"\n\n```java\n@Override\n```\n\nSee `small.txt#L1`.'
check "control @file attaches"                yes "$(yn MARK3_)"
check "@\"quoted path\" attaches"             yes "$(yn MARK1_)"
check "@Name inside fenced code attaches"     yes "$(yn MARK2_)"
check "backtick mention attaches nothing"     no  "$(yn MARK4_)"

for f in sz70 sz100 dense40 sz260; do send "Size test. Reply OK. @$f.txt"; done
check "70 KB prose attaches"                  yes "$(yn SZ70_)"
check "100 KB prose silently dropped"         no  "$(yn SZ100_)"
check "40 KB dense text silently dropped"     no  "$(yn DENSE40_)"
check "260 KB gets too_large notice"          yes "$(yn '"unread": *"too_large"')"

echo 1 > "$W/exit"; printf 'EDITED THEN CQ\n' > "$W/p.txt"; echo "$W/p.txt" > "$W/src"
tmux send-keys -t "$S" 'ORIGINAL_PROMPT'; sleep 1; tmux send-keys -t "$S" C-g; sleep 3
check ":w then non-zero exit restores prompt" yes "$(tmux capture-pane -p -t "$S" | grep -q 'ORIGINAL_PROMPT' && echo yes || echo no)"
tmux send-keys -t "$S" C-u
echo "transcript: $(T)"
