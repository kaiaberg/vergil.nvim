#!/bin/sh
# Records the installed Claude Code version as verified. Run by `make verify`
# after `make contract` and `make handoff` have passed.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
version=$(claude --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$version" ] || { echo "couldn't read claude --version" >&2; exit 1; }
cat > "$here/lua/vergil/adapters/claude/verified.lua" <<LUA
-- The Claude Code version vergil's assumptions were last checked against.
-- Written by \`make verify\` after the contract and handoff tests pass.
return "$version"
LUA
# Keep the "last checked with" line in the docs in sync.
for f in "$here/README.md" "$here/doc/vergil.txt"; do
  sed -i.bak -E "s/(ast checked with Claude Code )[0-9]+\.[0-9]+\.[0-9]+/\1$version/" "$f" && rm "$f.bak"
done
echo "verified against Claude Code $version"
