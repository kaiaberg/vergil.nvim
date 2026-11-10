# Agent guide

Read `CONTRIBUTING.md` first. It has the conventions, test commands and
commit style, and they all apply here.

## Direction

- vergil should stay lean and work with any coding agent that hands its
  prompt to `$EDITOR`, not only Claude Code. The code knows no agent:
  users define agents under `agents` in their config, and anything
  specific to one agent goes in its README recipe, phrased defensively.
- Don't assume how an agent will behave. Agent CLIs change often, so
  docs and code should rely only on what the contract tests check
  (`docs/m0-findings.md` records those results).

## Working rules

- Run `make fmt` and `make test` before every commit.
- Ask before running `make contract`, `make handoff` or `make verify`:
  they start a real agent session and make paid API calls.
- When you add or change a command, a `<Plug>` mapping or a config option,
  update `doc/vergil.txt` and `README.md` in the same change.
  `tests/docs_spec.lua` fails on undocumented commands and mappings.
