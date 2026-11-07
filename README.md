# vergil.nvim

[![Tests](https://github.com/kaiaberg/vergil.nvim/actions/workflows/tests.yml/badge.svg)](https://github.com/kaiaberg/vergil.nvim/actions/workflows/tests.yml)

> Let us not speak of them, but look, and pass.
>
> — Virgil, *Inferno* III (trans. Longfellow)

A Vim-native guide for writing prompts for coding agents, starting with
[Claude Code](https://claude.com/claude-code). Press `Ctrl+G` in Claude Code,
and vergil helps you point at the right code inside Neovim: attach files,
mention them, pick exact lines, paste verbatim snippets and find skills. It
uses the motions, Visual mode, splits and LSP features you already know.

vergil only helps you write the prompt. It never sends anything, never runs
skills, and never rewrites text you didn't ask it to change. Claude Code still
holds the conversation.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick tour](#quick-tour)
- [Attach or mention?](#attach-or-mention)
- [Writing prompts ahead of time](#writing-prompts-ahead-of-time)
- [The picker](#the-picker)
- [Git](#git)
- [Completion setup](#completion-setup)
- [Commands](#commands)
- [Mappings](#mappings)
- [Configuration](#configuration)
- [Observed behaviour](#observed-behaviour)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## Requirements

- Neovim 0.11 or newer
- Optional: Claude Code, with Neovim as its editor, to hand prompts over with
  `Ctrl+G` (see [Installation](#installation)). Without it, vergil still helps
  you [write prompts ahead of time](#writing-prompts-ahead-of-time).
- Optional: a completion engine. [blink.cmp](https://github.com/Saghen/blink.cmp)
  and [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) both work, and so does
  Neovim's built-in LSP completion (`completion.native = true`).
- Optional: [ripgrep](https://github.com/BurntSushi/ripgrep), `fd` or `git` for
  fast file discovery that respects `.gitignore`.
- Optional: a [Nerd Font](https://www.nerdfonts.com/) for completion icons,
  for example `brew install --cask font-jetbrains-mono-nerd-font`, selected
  as your terminal font. Without one, icons show as boxes; see
  [Troubleshooting](#icons-show-as-boxes) to turn them off.

## Installation

With Neovim's built-in `vim.pack` (0.12+):

```lua
vim.pack.add({ "https://github.com/kaiaberg/vergil.nvim" })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "kaiaberg/vergil.nvim", opts = {} }
```

vergil works without calling `setup()`. To change options, call it once:

```lua
require("vergil").setup({
  keymaps = { preset = true }, -- optional: gs, gb, gf, ZZ, ZQ … in prompt buffers
})
```

Then make Claude Code open Neovim. Claude Code uses **`$VISUAL` before
`$EDITOR`**, so set:

```sh
export VISUAL=nvim
```

Run `:checkhealth vergil` to check the setup.

vergil turns itself on in Claude Code's prompt files (`claude-prompt-*.md`)
and nowhere else. Use `:Vergil enable` for any other buffer.

## Quick tour

Press `Ctrl+G` in Claude Code. Neovim opens with your prompt.

**`@` attaches a file.** Type `@` and part of a name:

```markdown
Why does this fail when the token expires? @sess
                                            ▸ src/auth/session.ts   4.2 KB
```

Accepting inserts `@src/auth/session.ts`, or `@"docs/my notes.md"` with quotes
when the path has spaces. Files you already attached are marked `· attached`.

**`@@` mentions a file** without loading it: `@@sess` becomes
`` `src/auth/session.ts` ``.

**`#` picks lines.** Type `#` straight after a reference. A float opens with
the file, read-only and highlighted. Move with any Vim motion or `/` search,
select with `V`, then:

| Key | Inserts |
|---|---|
| `Enter` | the mention `` `src/auth/session.ts#L12-L35` ``, replacing the reference |
| `gs` | a verbatim snippet in place of the reference |
| `gb` | the mention, plus the snippet below the line |
| `gO` | nothing yet: lists the file's functions and classes, and selects the one you choose |
| `q` / `Esc` | nothing: cancels and removes the `#` |

When the lines are exactly one function, class or method, its name follows
the range: `` `src/range.lua#L96-L135` (`M.apply`) ``. The agent gets exact
lines and a name to fall back on, and vergil warns when the file changes and
the range no longer matches, with a code action to update it. Symbols come
from Neovim's treesitter parsers: Lua, C and Vimscript ship with Neovim,
other languages need a parser installed (e.g. with nvim-treesitter).

A snippet looks like this. Its header is a mention, never an `@`, so the code
isn't loaded twice:

````markdown
From `src/auth/session.ts#L12-L15`:

```typescript
if (!token) {
  throw new AuthError();
}
```
````

**Need more room? `<C-g>`** (with the preset) turns what you're typing into
the full [picker](#the-picker): `@sess` opens the Files tab searching for
`sess`, with a preview, and the other tabs one key away.

**`/` completes skills and commands**, from your project, your personal
`~/.claude` and enabled plugins, with descriptions and argument hints.
Accepting inserts the command; whether it runs is up to Claude Code.

**Look before you leap.** `K` previews a reference: the referenced lines, or
the start of the file. On a `/skill` it shows the skill's description. `gd`
opens the target at its line, and `:Vergil open split|vsplit|tab` opens it
elsewhere. `:q` in a file opened this way brings you back to the prompt.

**Send lines back.** In a file opened with `gd`, select lines with any motion
and run `:'<,'>Vergil send` (`<CR>` in Visual mode with the preset; `gs` sends
a snippet, `gb` both). The reference you opened becomes a ranged mention, and
you're back in the prompt. `<C-^>` returns to the file for more.

**Review what you changed.** `:Vergil pick changed` lists files changed in
git with their status; mark several with `<Tab>` to attach them at once.
`:Vergil diff` inserts the uncommitted changes as a `diff` block (`staged`, or
a revision like `HEAD~1`, for others). `:Vergil pick commits` inserts commits
as `` `abc1234` (Fix token refresh) ``. See [Git](#git).

**Fix what vergil flags.** Diagnostics point out files attached twice,
large attachments, line ranges past the end of a file or out of step with
their function, and missing files. `gra` offers fixes: convert an attachment to a mention,
replace a ranged mention with its snippet, or select lines.

**Hand it back.** `:Vergil submit` (or `ZZ` with the preset) writes the prompt
and exits. It asks what to do with other files you changed, and never
discards them silently. `:Vergil abort` (or `ZQ`) restores the prompt from
before `Ctrl+G`: it writes the original text back and exits with an error, so
either one is enough.

## Attach or mention?

Virgil's advice to Dante works here too: often it's enough to *look, and pass*.

| | Attachment `@file` | Mention `` `file` `` |
|---|---|---|
| Effect | The agent loads the whole file into the conversation | The agent knows where to look, and reads it only if needed |
| Context cost | Immediate | Only if the agent reads it |
| Line ranges | Usually ignored: attachments are whole files | `` `file#L12-L35` `` points at exact lines |
| Large files | May be skipped or cut ([details](#observed-behaviour)) | No limit |

Attach the files the agent must read in full, once. Mention everything else,
especially with line ranges. vergil never flags mentions of a file you already
attached, because attaching once and then mentioning is the pattern to use.

How an agent treats attachments isn't documented and changes between releases.
[Observed behaviour](#observed-behaviour) lists what vergil last saw.

## Writing prompts ahead of time

vergil doesn't need a running agent. To draft prompts or an execution plan
in advance, open any Markdown file and run `:Vergil enable`: completion,
line selection, snippets, previews and diagnostics all work. To switch on
automatically, add your own file names:

```lua
require("vergil").setup({
  activation = { filename_patterns = { "claude-prompt-*.md", "*.prompt.md" } },
})
```

Paths are relative to the project root, which is the directory Neovim started
in. Start Neovim in the project the prompt is for, or set `root`.

## The picker

One picker for everything that can go into a prompt, with tabs:

| # | Tab | Inserts |
|---|---|---|
| 1 | All | everything below, with its kind on the right |
| 2 | Files | `@path`, or `` `path` `` after `<C-t>` |
| 3 | Changed | files changed in git, with their status (only in a repository) |
| 4 | Branches | `` `feature/login` (branch) ``; `<C-d>` inserts its changes since it split off (only in a repository) |
| 5 | Commits | `` `abc1234` (subject) ``; `<C-d>` inserts its diff (only in a repository) |
| 6 | Skills | `/name` |

Choose the tabs and their order with `picker.tabs`; a tab left out is gone
from All too:

```lua
picker = { tabs = { "all", "files", "changed", "skills" } } -- no branches or commits
```

Open it with `:Vergil pick [tab]` (`all`, `attach`, `mention`, `changed`,
`branches`, `commits`, `skills`; default All, or the first tab), or press `<C-g>` (preset) while typing
`@sess`, `@@sess` or `/rev`: it opens on the matching tab with what you typed,
and replaces it with your choice. Type to filter; the query stays when you
switch tabs.

| Key | Does |
|---|---|
| `Enter` | insert the item, or every marked one |
| `<Tab>` / `<S-Tab>` | mark / unmark; a mark shows in every tab |
| `<C-n>` `<C-p>` `<Down>` `<Up>` | move |
| `<C-Right>` `<C-l>` `<M-l>` / `<C-Left>` `<C-h>` `<M-h>` | next / previous tab (cycles) |
| `<M-1>`…`<M-9>` | go to a tab (`<C-1>`… where the terminal sends them) |
| `<C-t>` | switch between attaching and mentioning files (for the next marks) |
| `<C-o>` | join several items with spaces, commas, or one per line |
| `<C-r>` | select lines of the file |
| `<C-d>` | insert a commit's diff |
| `<C-f>` / `<C-b>` | scroll the preview |
| `Esc` | close |

Marked items show a sign: `@` a file to attach, `` ` `` a file to mention,
`/` a skill, `◆` a commit, `⎇` a branch. Each mark keeps the attach/mention mode it was
marked with, so you can mark some files to attach and others to mention. The
**Marked** panel under the preview lists them in order, with the exact text
each will insert.

`<M-…>` keys need your terminal to send Option as Meta (iTerm2: Profiles →
Keys). Change any key with `picker.keys`, e.g.
`picker = { keys = { next_tab = { "<C-l>" }, toggle_mode = { "<C-y>" } } }`.
Names: `confirm`, `close`, `down`, `up`, `mark`, `unmark`, `next_tab`,
`prev_tab`, `scroll_down`, `scroll_up`, `toggle_mode`, `separator`,
`select_lines`, `diff`.

`picker.on_trigger = true` opens the picker as soon as you type `@` or `/`
where a reference can start, instead of the inline menu.

## Git

vergil turns git state into prompt text; it doesn't browse history. Git is
optional, and every command says so when there's no repository.

| You want | Use |
|---|---|
| Attach the files you changed | `:Vergil pick changed` (`<Tab>` marks several) |
| Show the agent your changes | `:Vergil diff` (all uncommitted), `:Vergil diff staged`, `:Vergil diff main...` |
| Point at a commit | `:Vergil pick commits`: inserts `` `abc1234` (subject) ``; the agent can `git show` it |
| Show a commit's changes | `<C-d>` in `:Vergil pick commits`, or `:Vergil diff abc1234^!` |
| Point at a branch | `:Vergil pick branches`: inserts `` `feature/login` (branch) ``; `<C-d>` inserts what it changed since it split off |

`K` on a commit or branch in the prompt (`` `abc1234` ``, `` `main` ``,
`` `feature/login` (branch) ``) shows its message and changed files, or its
recent commits and how far it's ahead or behind. `gd` opens the whole commit
(`git show`) or the branch's log in a read-only buffer; `:q` returns to the
prompt. vergil only asks git when you press the key, and never flags these
words as missing files.

`:Vergil diff <Tab>` completes `staged`, branches, tags and recent commits.
Commits, diffs and changed files are limited to the root, with paths relative
to it.

For everything else, use the plugins built for it:

- **Browsing history and diffs:** [vim-fugitive](https://github.com/tpope/vim-fugitive)
  (`:Git log`, `:Gclog`, `:Gdiffsplit`, `:Git blame`) or
  [diffview.nvim](https://github.com/sindrets/diffview.nvim).
- **Finding commits and branches:** telescope's `git_commits`, `git_bcommits`
  and `git_branches` pickers.
- **Hunks and blame in a file:** [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim).
- **Commit hashes while typing:** [blink-cmp-git](https://github.com/Kaiser-Yang/blink-cmp-git)
  completes commits after `:` (plain git is enough). Add it to the prompt
  buffer's sources:

  ```lua
  sources = {
    default = function()
      if vim.b.vergil_enabled then
        return { "lsp", "git" }
      end
      return { "lsp", "path", "snippets", "buffer" }
    end,
    providers = {
      git = { module = "blink-cmp-git", name = "Git" },
    },
  },
  ```

  Its GitHub and GitLab completions use `@` (users) and `#` (issues and pull
  requests), which are vergil's triggers too. If you use them, move them with
  its `git_centers.github.mention.triggers`, `issue.triggers` and
  `pull_request.triggers` options (the same under `gitlab`).

## Completion setup

vergil is an LSP server running inside Neovim, so any LSP completion engine
shows its items. A few settings make prompt buffers nicer.

**blink.cmp.** Use only the LSP source in prompt buffers, so snippets don't
pop up while you type prose:

```lua
require("blink.cmp").setup({
  sources = {
    default = function()
      if vim.b.vergil_enabled then
        return { "lsp" }
      end
      return { "lsp", "path", "snippets", "buffer" }
    end,
  },
})
```

**nvim-cmp.** Do the same with a buffer-local source list:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "VergilEnable",
  callback = function(ev)
    vim.api.nvim_buf_call(ev.data.bufnr, function()
      require("cmp").setup.buffer({ sources = { { name = "nvim_lsp" } } })
    end)
  end,
})
```

**Built-in completion.** Set `completion.native = true`, and include `popup`
in `completeopt` to see skill descriptions:

```lua
vim.o.completeopt = "menuone,noselect,popup,fuzzy"
require("vergil").setup({ completion = { native = true } })
```

Leave `completion.native` off if you use a completion plugin, or two menus
will open.

## Commands

| Command | Does |
|---|---|
| `:Vergil preview` | Preview the reference or skill under the cursor (like `K`) |
| `:Vergil open [split\|vsplit\|tab]` | Open the target at its line |
| `:Vergil range` | Select lines for the reference under the cursor |
| `:Vergil snippet [both]` | Replace a ranged reference with its lines (`both`: keep it, add the lines below) |
| `:Vergil send [snippet\|both]` | Send the cursor line, or a range (`:'<,'>`), of the current file to the prompt as a mention, snippet or both |
| `:Vergil toggle` | Convert between attachment and mention |
| `:Vergil pick [all\|attach\|mention\|skills\|changed\|commits]` | Open [the picker](#the-picker) on that tab (default All) |
| `:Vergil diff [staged\|<rev>]` | Insert `git diff` (default: all uncommitted changes) as a fenced `diff` block |
| `:Vergil submit` | Write the prompt, settle other modified buffers, exit |
| `:Vergil abort` | Restore the previous prompt and exit |
| `:Vergil enable` / `disable` | Turn vergil on or off in the current buffer |

Neovim's LSP defaults cover the rest: `K` (hover), `gd`/`<C-]>` (definition),
`gra` (code actions), and `]d`/`[d` (diagnostics).

## Mappings

vergil maps nothing unless you ask. Every action has a `<Plug>` mapping:

`<Plug>(vergil-snippet)`, `<Plug>(vergil-snippet-both)`, `<Plug>(vergil-range)`,
`<Plug>(vergil-toggle)`, `<Plug>(vergil-preview)`, `<Plug>(vergil-open)`,
`<Plug>(vergil-open-split)`, `<Plug>(vergil-open-vsplit)`,
`<Plug>(vergil-open-tab)`, `<Plug>(vergil-submit)`, `<Plug>(vergil-abort)`,
`<Plug>(vergil-pick)`, `<Plug>(vergil-pick-attach)`, `<Plug>(vergil-pick-mention)`,
`<Plug>(vergil-pick-skills)`, `<Plug>(vergil-pick-changed)`,
`<Plug>(vergil-pick-branches)`, `<Plug>(vergil-pick-commits)`,
`<Plug>(vergil-pick-expand)` (these also in Insert mode),
`<Plug>(vergil-hover)`, `<Plug>(vergil-close-preview)`, and
`<Plug>(vergil-send)`, `<Plug>(vergil-send-snippet)` and
`<Plug>(vergil-send-both)` (Normal and Visual mode).

`keymaps = { preset = true }` maps these in prompt buffers only:

| Key | Action |
|---|---|
| `K` | Preview; pressed again, closes it (`preview.on_repeat = "focus"` moves into it instead, as Neovim's own `K` does) |
| `gs` / `gb` | Snippet from a ranged reference: replace it / keep it and add the lines below |
| `<C-g>` (Insert mode) | Open the picker on what you're typing |
| `gf` / `<C-w>f` / `<C-w>gf` | Open the reference here / in a split / in a tab; the native key elsewhere |
| `ZZ` / `ZQ` | `:Vergil submit` / `:Vergil abort` |
| `<Esc>` | Close an open preview (also inside it); a normal `<Esc>` otherwise |

and, in Visual mode in other files while a prompt is open, the line
selector's keys: `<CR>` sends the selection as a mention, `gs` as a snippet,
`gb` both.

## Configuration

The defaults:

```lua
require("vergil").setup({
  agent = "claude",
  root = nil, -- project root; defaults to the directory Neovim started in
  activation = { filename_patterns = nil }, -- nil: { "claude-prompt-*.md" }
  mention = {
    format = "github", -- "colon", or { single = "{path}#L{start}", range = "{path}#L{start}-L{end}" }
    symbols = true, -- add the function or class name after a range that covers exactly one
  },
  triggers = { attach = "@", mention = "@@", range = "#", skills = "/" },
  skills = { extra_items = {} }, -- e.g. { { name = "compact", description = "Summarize the conversation" } }
  selector = { keys = { mention = "<CR>", snippet = "gs", both = "gb", symbols = "gO", cancel = { "q", "<Esc>" } } },
  completion = { native = false, reopen_on_backspace = true },
  -- Custom discovery command run in the root, e.g. { "fd", "-t", "f" }. Files
  -- that .gitignore ignores aren't listed; to list them too:
  -- { "rg", "--files", "--hidden", "--no-ignore", "--glob", "!.git" }
  files = { command = nil },
  keymaps = { preset = false },
  return_to_prompt = true, -- :q in a file opened from the prompt returns to the prompt
  picker = {
    on_trigger = false, -- open the picker on @ and / instead of inline completion
    keys = {}, -- e.g. { next_tab = { "<C-l>" }, prev_tab = { "<C-h>" } }
    tabs = { "all", "files", "changed", "branches", "commits", "skills" }, -- order; leave out to drop
  },
  preview = { on_repeat = "close" }, -- K (preset) again: "close" the preview, or "focus" it
  diagnostics = {
    attachment_token_warning = 20000, -- estimated as bytes / 3
    severity = { -- "error", "warn", "info", "hint", or false
      duplicate = "warn",
      large = "info",
      range = "warn",
      ignored_range = "hint",
      missing_mention = "warn",
      missing_attachment = "info",
      fenced = "hint",
      symbol = "warn", -- a named range no longer matches its function
    },
  },
})
```

The `colon` format writes mentions as `` `src/a.ts:12-35` ``. Custom templates
must start with `{path}`, put a separator after it, and put `{start}` before
`{end}`.

See `:help vergil` for details.

## Observed behaviour

Last checked with Claude Code 2.1.319. None of this is documented, and any
release may change it. `:checkhealth vergil` shows whether your version
differs. vergil's own output doesn't depend on it: it inserts plain `@path`
references and Markdown mentions, and the diagnostics only hint at what the
agent might do.

- `@` starts an attachment only at line start or after whitespace, so `(@a)`,
  `` `@a` `` and `me@example.com` attach nothing.
- Trailing punctuation (``.,;:!?)]}>'"` ``) after an unquoted path isn't part
  of it; quote paths with spaces: `@"my notes.md"`.
- `@file#L5` attaches the whole file; the range is ignored.
- `@word` inside a fenced code block is still attached when a file of that
  name exists.
- Mentions (`` `file#L12-L35` ``) aren't parsed, so nothing is loaded.
- Attachments above about 25k tokens are dropped without notice; from 256 KB
  the agent is told the file was too large.
- Exiting the editor with an error discards the edit and restores the prompt.
- Unchanged pasted text collapses again after `Ctrl+G`, except a paste at the
  very end of the prompt.
- If the editor fails to start, the prompt stays as it was, with no error.

Contributors: `make verify` re-runs these checks against the installed
Claude Code and records its version.

## Limitations

- **Agent behaviour changes.** See [Observed behaviour](#observed-behaviour).
- **Only the `Ctrl+G` editor session.** vergil targets the short-lived Neovim
  Claude Code opens. Long-running Neovim support is planned.
- **Only the current prompt.** vergil can't see files attached earlier in the
  conversation.
- **Pasted text looks like typed text.** An `@word` in a pasted log may be
  reported as a missing file, which is why that check is only Info.
- **Sizes are estimates.** The large-attachment note estimates tokens from
  bytes; the agent's real limit depends on content.
- **Mentions are a convention.** Claude followed `` `file#L12-L35` `` in
  testing, but nothing enforces it, and it hasn't been measured across many
  prompts.
- **Plugin skills are best effort.** They're found through `enabledPlugins` and
  marketplace manifests. Synced claude.ai skills follow naming observed in
  Claude Code, not documented naming.
- **`user-invocable: false` skills are listed**, because Claude Code's own menu
  lists them too.
- **Format-on-save breaks pasted text.** Claude Code collapses unchanged pastes
  again after editing. Trimming whitespace or reformatting on save stops that,
  so `:checkhealth vergil` warns about it.
- Tested on macOS. Linux should work; Windows is untested.

## Troubleshooting

Start with `:checkhealth vergil`.

### Nothing happens when I type `@`

- Is vergil on? `:echo b:vergil_enabled` should print `v:true`. It only turns
  on for `claude-prompt-*.md`; use `:Vergil enable` elsewhere.
- Is Neovim the editor Claude Code opens? Claude Code prefers `$VISUAL` over
  `$EDITOR`. If your shell sets `VISUAL`, setting only `EDITOR` changes nothing.
- Is there a completion engine? Without one, set `completion.native = true`.

### `Ctrl+G` does nothing

If the editor fails to start, Claude Code silently keeps the prompt and shows
no error. Run the command in `$VISUAL` (or `$EDITOR`) yourself to see what
fails.

### Snippets or file paths pop up while I type prose

That's your completion engine's other sources. Limit them in prompt buffers;
see [Completion setup](#completion-setup).

### Icons show as boxes

Your terminal font lacks the icons. Install a Nerd Font, or hide icons in
prompt buffers. For blink.cmp:

```lua
completion = {
  menu = {
    draw = {
      columns = function()
        if vim.b.vergil_enabled then
          return { { "label", "label_description", gap = 1 } }
        end
        return { { "kind_icon" }, { "label", "label_description", gap = 1 } }
      end,
    },
  },
},
```

### `:wq` leaves Claude Code waiting, or `:q` drops me back into Claude Code

With other windows open, `:wq` doesn't exit Neovim, and with modified buffers
it refuses to. Use `:Vergil submit` (`ZZ` with the preset), which settles both.
`:q` in a file opened from the prompt returns to the prompt; in the prompt
itself it exits.

### Pasted text no longer collapses in Claude Code

Something rewrote the prompt on save, such as format-on-save or trailing
whitespace trimming. Exclude `claude-prompt-*.md`; `:checkhealth vergil` lists
what it finds.

### The large-file note appears for a file that attached fine

The note uses an estimate. Raise `diagnostics.attachment_token_warning`,
or turn the check off with `severity.large = false`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `make test` runs the test suite.
`make contract` and `make handoff` check against a real Claude Code; they cost
a few small API calls.

Named after Dante's guide in the *Divine Comedy*, who shows the way and
leaves the walking to you. *Ars celare artem*: the art is to conceal the art.

## License

[MIT](LICENSE)
