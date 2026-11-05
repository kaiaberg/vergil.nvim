# Contributing

## Conventions

- **Neovim:** minimum 0.11, tested on 0.11.7 and 0.12.6 (see `docs/m0-findings.md`). Use `vim.uv`, not `vim.loop`.
- **Dependencies:** the core depends on nothing but Neovim. Pickers and completion engines are optional adapters.
- **Layout:** follow the plan's repository layout, and add modules only when they are implemented.
- **Agent isolation:** nothing outside `lua/vergil/adapters/claude/` may mention `.claude` or Claude's syntax.
- **Non-destructive:** edits replace exact parser spans only, and never trim or reformat prompt text.
- **Style:** StyLua (`make fmt`), 2-space indent, double quotes, LuaCATS annotations on public functions.
- **Commits:** imperative subject of 72 characters or fewer, e.g. `Add mention parser`.
- **Changelog:** add user-visible changes under `[Unreleased]`.

## Tests

- `make test` runs the unit and headless specs (`tests/**/*_spec.lua`) with the bundled runner.
- `make contract` runs the Claude Code contract suite, and `make handoff` the end-to-end `Ctrl+G` test through vergil. Both drive a real `claude` session in tmux and cost a few small API calls, so run them manually, and again after Claude Code updates.
- Run `make test` on the oldest supported Neovim (0.11) as well as the latest release.
