# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `@~` and `@/` complete paths outside the project one directory at a
  time, like a shell: `@~` lists your home directory, `@~/co` narrows it.
  The picker browses them the same way (Files: `~` and `/`, All: `~`);
  `Enter` on a directory opens it.
- One picker with tabs, built into vergil: All, Files, Changed, Commits and
  Skills, with fuzzy search, a preview, and cycling tabs
  (`<C-Right>`/`<C-Left>`, `<C-l>`/`<C-h>`, `<M-l>`/`<M-h>`,
  `<M-1>`…`<M-9>`). `:Vergil pick [tab]` opens it on a tab (default All).
- Marks in the picker show in every tab, with a sign (`@` attach,
  `` ` `` mention, `/` skill, `◆` commit), and each keeps the attach/mention
  mode it was marked with. A Marked panel lists them with the text each
  inserts. `<C-o>` joins them with spaces, commas, or one per line.
- `picker.keys` customizes every picker key, including `<C-t>`, `<C-o>`,
  `<C-r>` and `<C-d>`.
- `picker.tabs` chooses the picker's tabs and their order; a tab left out is
  gone from All too.
- A Branches tab: local and remote branches, the checked-out one first,
  inserted as `` `feature/login` (branch) ``; `<C-d>` inserts the changes since
  the branch split off.
- `K` and `gd` on commits and branches in the prompt: `K` shows the message
  and changed files, or recent commits and ahead/behind; `gd` and
  `:Vergil open` show `git show` or the branch's log in a read-only buffer.
- `preview.on_repeat`: `K` (now in the preset) or `:Vergil preview` again
  closes the preview (default) or moves into it (`"focus"`).
- `<C-g>` (preset) and `<Plug>(vergil-pick-expand)` turn the `@`, `@@` or
  `/` completion being typed into the picker, keeping the query; any other
  word before the cursor opens the All tab searching for it. Either is
  replaced by your choice; inside a word, the search is what's before the
  cursor and the whole word is replaced. In Normal mode, `<C-g>` turns the
  reference, `/skill` or word under the cursor into what you choose.
- Choosing or closing the picker returns to the mode it was opened from:
  Insert mode with the cursor after the inserted text, or Normal mode.
- From Normal mode, the picker inserts after the word under the cursor
  instead of splitting it.
- `picker.on_trigger` opens the picker on `@` and `/` instead of inline
  completion; `picker.keys` overrides its keys.

- `:Vergil pick commits`: recent commits that touched the root, with a
  `git show` preview, inserted as `` `abc1234` (subject) ``; `<C-d>` inserts
  the commit's diff instead, `<Tab>` marks several.
- `:Vergil diff <Tab>` completes `staged`, branches, tags and recent commits.
- README "Git" section: what vergil does with git, and which plugins to use
  for the rest (fugitive, telescope, gitsigns, blink-cmp-git).

### Changed

- The picker opens without waiting on git: changed files, branches, commits
  and their previews load in the background, only for tabs that are turned
  on, and fill in as git answers. Files show up first and get their git
  status a moment later.
- The picker no longer uses telescope.nvim or `vim.ui.select`, and
  `picker.backend` is gone (`:checkhealth vergil` warns if it's still set).
  `:Vergil pick` without an argument opens the All tab instead of Files.

### Fixed

- File discovery no longer lists ignored files when `.gitignore` ignores
  the whole root (e.g. `*`): an empty answer from rg, fd or git is kept
  instead of falling through to the built-in scan, which would show `.env`
  and the like. Listing ignored files takes an explicit `files.command`;
  `:checkhealth vergil` mentions it when the root has no files.
- `:checkhealth vergil` waits up to 3 seconds for the agent's `--version`,
  instead of 1, so a slow start no longer hides the version check.

## [0.2.0] - 2026-11-06

Send lines back from files, reference functions by name, and review git
changes, while depending less on Claude Code's undocumented behaviour.
Behaviour changes: the large-attachment diagnostic is now Info instead of
Warning, and `:Vergil abort` writes the prompt file back before exiting.
Verified against Claude Code 2.1.319.

### Added

- `:checkhealth vergil` shows the agent's version and which version vergil's
  assumptions were last checked against.
- `make verify` runs the Claude Code checks and records the version they
  passed with.
- Tests run on GitHub for Neovim 0.11.7, stable and nightly.
- `:Vergil send [snippet|both]`: select lines in a file opened with `gd` and
  send them back to the prompt as a mention, snippet or both. The first send
  replaces the reference you opened. With the preset, `<CR>`, `gs` and `gb`
  in Visual mode, in files only, while a prompt is open.
- Function and class references: `gO` in the line selector lists the file's
  functions, classes and methods (from Neovim's treesitter parsers) and
  selects one. A range covering exactly one symbol gets its name:
  `` `a.lua#L96-L135` (`M.apply`) ``, also in snippet headers and with
  `:Vergil send`. A new `symbol` diagnostic flags a range that no longer
  matches its name, with a code action to update it. `mention.symbols`
  turns names off.
- `:Vergil pick changed`: files changed in git (modified, staged, renamed,
  untracked) with their status, to attach. With telescope, `<Tab>` marks
  several files to insert at once, in every file picker.
- `:Vergil diff [staged|<rev>]`: inserts `git diff` as a fenced `diff` block,
  limited to the root.
- README and `:help vergil-ahead-of-time`: drafting prompts without a running
  agent.

### Changed

- `:Vergil abort` also writes the prompt file back as it was when Neovim
  opened it, so it doesn't depend on the agent honouring the exit code.
- Diagnostics no longer predict what Claude Code will do: the large,
  ignored-range and fenced messages hint instead, and the large-attachment
  check defaults to Info instead of Warning.
- Claude Code is optional: `:checkhealth vergil` only reports on it when it's
  installed.
- Version-specific Claude Code behaviour is collected under "Observed
  behaviour" in the README and `:help vergil-observed`.

### Fixed

- Text inserted by `:Vergil pick` gets a space after it when needed, so an
  attachment no longer runs into the following word.

## [0.1.0] - 2026-11-05

First release: a Vim-native toolkit for writing Claude Code prompts in the
`Ctrl+G` editor. Requires Neovim 0.11+. Verified against Claude Code 2.1.318.

### Added

- Dependency-free test runner (`make test`), Claude Code contract tests
  (`make contract`) and an end-to-end `Ctrl+G` handoff test (`make handoff`).
- README and `:help vergil`.
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
- Diagnostics: duplicate attachments, large attachments (estimated tokens;
  Claude Code drops them silently), mention ranges past the end, ignored
  `@file#range`, missing targets, and fenced `@file` that still gets
  attached. Severities and the token threshold are configurable.
- Code actions (`gra`): convert between attachment and mention (as a
  quickfix for duplicate, large and ranged attachments), replace with
  snippet, add snippet below, select lines.
- `:Vergil submit` writes the prompt, asks about other modified buffers
  and exits; `:Vergil abort` exits with `:cquit` so Claude Code restores
  the prompt.
- `:Vergil pick [attach|mention|skills]`: telescope.nvim picker with file
  previews (`<C-t>` switches type, `<C-r>` selects lines), falling back to
  `vim.ui.select`.
- `<Plug>` mappings for every action; the preset adds `gf`, `<C-w>f`,
  `<C-w>gf`, `ZZ` and `ZQ` in prompt buffers.
- `:checkhealth vergil`.
- A YAML-frontmatter subset reader (quoted and block scalars) that never
  breaks completion on malformed files.

### Removed

- The M0 prototype, superseded by the plugin.

[Unreleased]: https://github.com/kaiaberg/vergil.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kaiaberg/vergil.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kaiaberg/vergil.nvim/releases/tag/v0.1.0
