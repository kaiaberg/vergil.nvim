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
