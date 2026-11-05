# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- M0 LSP completion prototype (`prototype/m0/`), dependency-free test runner,
  and scripted Claude Code contract tests.
- Reference core: parser with exact spans, resolver, mention formatter
  (`github`, `colon` or custom templates) and attachment/mention conversion.
- Claude Code adapter: attachment syntax following contract-tested rules for
  boundaries, quoting and trailing punctuation.
- Sessions: activation on `claude-prompt-*.md`, a root captured at startup,
  and `:Vergil enable`, `:Vergil disable` and `:Vergil toggle`.
- In-process LSP server attached to prompt buffers: `@` and `@@` file
  completion with server-side fuzzy ranking, re-search in place on manual
  completion, and reopening the menu after Backspace.
- Asynchronous, cached file discovery (`rg`, `fd`, `git ls-files` or a
  built-in scan) with an optional custom command.
- Hover previews (`K`, `:Vergil preview`) and go-to-definition, plus
  `:Vergil open [split|vsplit|tab]`.
- `completion.native` to enable Neovim's built-in completion.
- Line selector: `#` typed right after a reference, or `:Vergil range`, opens
  a float with a read-only copy of the file. `Enter` inserts a mention, `gs`
  a verbatim snippet, `gb` both; `q`/`Esc` cancels and removes only the `#`.
  Keys are configurable under `selector.keys`.
- `:Vergil snippet [both]` turns a ranged reference in the prompt into its
  lines (or adds them below), with `<Plug>(vergil-snippet)` and
  `<Plug>(vergil-snippet-both)`. Without a range it opens the selector.
- `keymaps.preset = true` maps `gs`/`gb` to those in prompt buffers only,
  and `<Esc>` to close an open preview (`K` or `:Vergil preview`, also when
  focused), falling back to a normal `<Esc>`. Also available as
  `<Plug>(vergil-close-preview)`. There are no mappings by default.
- `/` completion for skills and commands: project (up to the repository
  root), personal, enterprise, synced claude.ai skills and enabled plugins
  (best effort), with descriptions, argument hints and origin; precedence
  and naming follow Claude Code's own menu. Configurable extra items
  (`skills.extra_items`) cover built-ins such as `/compact`.
- Hover, go-to-definition, `:Vergil preview` and `:Vergil open` for `/skill`
  tokens in the prompt.
- `:q` in a file opened from the prompt (with `gd` or `:Vergil open`) returns
  to the prompt instead of exiting Neovim and handing back to the agent
  (`return_to_prompt`, on by default).
- A YAML-frontmatter subset reader (quoted and block scalars) that never
  breaks completion on malformed files.

### Removed

- The M0 prototype, superseded by the plugin.
