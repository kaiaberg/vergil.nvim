# vergil.nvim

A lightweight, Vim-native toolkit for composing prompts for coding agents,
starting with Claude Code's `Ctrl+G` external editor.

> **Status:** pre-alpha. The reference core exists (`:Vergil toggle` converts
> between `@path` and `` `path` ``); completion, line selection and the rest
> are still to come. See `docs/m0-findings.md`.

## Requirements

- Neovim 0.11 or newer
- [Claude Code](https://claude.com/claude-code)
- Optional: a completion engine. Native `vim.lsp.completion`, blink.cmp and nvim-cmp are supported.
- Optional: a [Nerd Font](https://www.nerdfonts.com/) for icons, for example
  `brew install --cask font-jetbrains-mono-nerd-font`, selected as your
  terminal's font. Without one, icons show as boxes. Set `ui.icons = false` to
  turn off vergil's own icons; icons in the completion menu come from your
  completion engine and are configured there.

*ars celare artem*
