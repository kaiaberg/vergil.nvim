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
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  for the full-size picker (`:Vergil pick`). Without it, vergil falls back to
  `vim.ui.select`.
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
| `q` / `Esc` | nothing: cancels and removes the `#` |

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

**`/` completes skills and commands**, from your project, your personal
`~/.claude` and enabled plugins, with descriptions and argument hints.
Accepting inserts the command; whether it runs is up to Claude Code.

**Look before you leap.** `K` previews a reference: the referenced lines, or
the start of the file. On a `/skill` it shows the skill's description. `gd`
opens the target at its line, and `:Vergil open split|vsplit|tab` opens it
elsewhere. `:q` in a file opened this way brings you back to the prompt.

**Fix what vergil flags.** Diagnostics point out files attached twice,
large attachments, line ranges past the end of a file, and missing files. `gra` offers fixes: convert an attachment to a mention,
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
| `:Vergil toggle` | Convert between attachment and mention |
| `:Vergil pick [attach\|mention\|skills]` | Full-size picker: `Enter` inserts, `<C-t>` switches type, `<C-r>` selects lines |
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
`<Plug>(vergil-pick-attach)`, `<Plug>(vergil-pick-mention)`,
`<Plug>(vergil-pick-skills)` and `<Plug>(vergil-close-preview)`.

`keymaps = { preset = true }` maps these in prompt buffers only:

| Key | Action |
|---|---|
| `gs` / `gb` | Snippet from a ranged reference: replace it / keep it and add the lines below |
| `gf` / `<C-w>f` / `<C-w>gf` | Open the reference here / in a split / in a tab; the native key elsewhere |
| `ZZ` / `ZQ` | `:Vergil submit` / `:Vergil abort` |
| `<Esc>` | Close an open preview (also inside it); a normal `<Esc>` otherwise |

## Configuration

The defaults:

```lua
require("vergil").setup({
  agent = "claude",
  root = nil, -- project root; defaults to the directory Neovim started in
  activation = { filename_patterns = nil }, -- nil: { "claude-prompt-*.md" }
  mention = { format = "github" }, -- "colon", or { single = "{path}#L{start}", range = "{path}#L{start}-L{end}" }
  triggers = { attach = "@", mention = "@@", range = "#", skills = "/" },
  skills = { extra_items = {} }, -- e.g. { { name = "compact", description = "Summarize the conversation" } }
  selector = { keys = { mention = "<CR>", snippet = "gs", both = "gb", cancel = { "q", "<Esc>" } } },
  completion = { native = false, reopen_on_backspace = true },
  files = { command = nil }, -- custom discovery command run in the root, e.g. { "fd", "-t", "f" }
  keymaps = { preset = false },
  return_to_prompt = true, -- :q in a file opened from the prompt returns to the prompt
  picker = { backend = "auto" }, -- "telescope" or "select"
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
