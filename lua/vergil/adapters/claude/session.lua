--- Claude Code session facts.
local M = {}

--- Claude Code's `Ctrl+G` writes the prompt to `<tmpdir>/claude-prompt-<uuid>.md`.
--- Match the file name only: the directory varies (`CLAUDE_CODE_TMPDIR`,
--- `/tmp` vs `/private/tmp`).
M.filename_patterns = { "claude-prompt-*.md" }

return M
