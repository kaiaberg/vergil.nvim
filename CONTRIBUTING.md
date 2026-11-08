# Contributing

## Conventions

- **Neovim:** minimum 0.11, tested on 0.11.7 and 0.12.6 (see `docs/m0-findings.md`). Use `vim.uv`, not `vim.loop`.
- **Dependencies:** the core depends on nothing but Neovim. Completion engines are optional; the picker is built in.
- **Layout:** follow the plan's repository layout, and add modules only when they are implemented.
- **Agent isolation:** nothing outside `lua/vergil/adapters/claude/` may mention `.claude` or Claude's syntax.
- **Non-destructive:** edits replace exact parser spans only, and never trim or reformat prompt text.
- **Style:** StyLua (`make fmt`), 2-space indent, double quotes, LuaCATS annotations on public functions.
- **Commits:** imperative subject of 72 characters or fewer, e.g. `Add mention parser`.
- **Changelog:** add user-visible changes under `[Unreleased]`.

## Tests

- `make test` runs the unit and headless specs (`tests/**/*_spec.lua`) with the bundled runner.
- `make contract` runs the Claude Code contract suite, and `make handoff` the end-to-end `Ctrl+G` test through vergil. Both drive a real `claude` session in tmux and cost a few small API calls. Run them locally after Claude Code updates; both exit non-zero if a check fails. `make verify` runs both and, if they pass, records the Claude Code version in `lua/vergil/adapters/claude/verified.lua` and the docs.
- Run `make test` on the oldest supported Neovim (0.11) as well as the latest release.

## Continuous integration

- **Tests** (`.github/workflows/tests.yml`) runs `make test` on every push and pull request: Neovim 0.11.7, stable and nightly on Linux. Run it on macOS locally. `VERGIL_PERF_FACTOR=3` loosens the timing limits on the shared runners. A second job runs `stylua --check` with the version pinned in the workflow; update it there when you upgrade StyLua locally.
