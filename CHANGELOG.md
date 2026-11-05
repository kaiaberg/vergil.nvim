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

### Removed

- The M0 prototype, superseded by the plugin.
