# Milestone 0 findings

Recorded 2026-11-05 on macOS (arm64), Claude Code 2.1.318, Neovim 0.12.6 and 0.11.7.

## Name

No GitHub repository is named `vergil.nvim` (search API, 0 results), no LuaRocks
module matches `vergil`, and there is no entry in awesome-neovim. Free to use.

## Claude Code contract results (plan §4.3)

Tested through the real interactive `Ctrl+G` path: `claude` runs in tmux with
a fake `$EDITOR` and `--tools ''`, so Claude can't read files itself. Results
come from transcript markers. Reproduce with `make contract`.

| Question | Result | Consequence for vergil |
|---|---|---|
| Does `@"path with space"` attach on submit? | **Yes** | Quoting is correct attachment syntax |
| Does `:w` then `:cq` restore the original prompt? | **Yes**: any non-zero exit discards the edit, even after a write | `:Vergil abort` can use `:cq` unconditionally |
| Is `@Override` / `@app.route` expanded inside fenced code? | **Yes**, when a file of that name exists in the root | **Changes the plan**; see below |
| Where is the attachment size limit? | **Token-based, not bytes.** Prose: 78 KB attached, 80 KB dropped. Dense hex: 30 KB attached, 40 KB dropped. | See below |
| What happens between that limit and 256 KB? | **Silently dropped**: no attachment, no notice to Claude, nothing in the UI | The large-file warning matters more than the plan assumed |
| What happens at 256 KB or more? | `"unread":"too_large"`; Claude is told to read in portions | As the plan describes |
| Several large files in one prompt | Each file is judged on its own; files under the limit attach | No total budget was observed |
| Which editor does `Ctrl+G` run? | **`$VISUAL` before `$EDITOR`**; plain `nvim` is launched as `nvim +1 <file>` | Only wrappers are affected: the real plugin activates inside whichever `nvim` opens. Troubleshooting docs should mention `VISUAL`, and vergil must not rely on the `+1` argument |
| Which `@` counts as a reference? (M1) | Only at line start or after whitespace (space, tab). `(@a)`, `"@a"`, `` `@a` `` and `x@a` are **not** references | The parser's boundary rule; completion triggers must use the same rule |
| Trailing punctuation after an unquoted path (M1) | Any run of ``.,;:!?)]}>'"` `` (backtick included) is stripped: `@a.ts),` and `@a.ts...` attach `a.ts` | Spans exclude trailing punctuation, so conversions keep it |
| `@dir/` (M1) | Lists the directory | Directories are attachments |
| Temp file name | `/tmp/claude-501/claude-prompt-<uuid>.md` (a UUID, not a hash) | Pattern `claude-prompt-*.md` still fits |

Still open, since they don't affect the grammar: how reliably Claude interprets
`` `path#L12-L35` `` across prompts, and where plugin skills can be discovered.

### Proposed plan changes

1. **Fenced code (§6.6, §7.4).** Claude Code does not skip fences. Keep
   *completion triggers* off inside fences, but the parser should still return
   fenced `@tokens`, marked `in_fence = true`. A new diagnostic (Hint) can then
   flag a fenced `@token` that resolves to a real file: "Claude Code will attach
   this file". Fenced tokens that don't resolve stay silent, and duplicate checks
   still ignore fences.
2. **Size warning (§6.6, §7.6).** Estimate tokens instead of comparing bytes.
   The observed cutoff sits near 25k tokens. Default: warn when
   `bytes / 3 > 20000` (about 60 KB for code), with the message "may be silently
   dropped". Keep the threshold configurable, because the limit is undocumented.
3. **Snippet safety (§6.4).** A verbatim snippet containing `@Decorator` can
   attach an unrelated file named `Decorator`. That's rare, and the new
   diagnostic covers it, so no escaping is needed. Never rewrite the snippet.

## Prototype gate (plan §7.1)

The prototype is in `prototype/m0/`: an in-process server (`vim.lsp.start` with
a Lua `cmd`), plus minimal inits for native completion, nvim-cmp and blink.cmp.

Engines: native `vim.lsp.completion`, nvim-cmp (your installed copy), and
blink.cmp v1.10.2 (latest release, Lua fuzzy matcher). Each ran in isolation
with `nvim --clean`, on Neovim 0.12.6 and on 0.11.7 from the release tarball.

| Check | Native 0.12 | Native 0.11 | nvim-cmp 0.12 / 0.11 | blink.cmp 0.12 / 0.11 |
|---|---|---|---|---|
| `@` attachments, ranked fuzzy | ✅ | ✅ | ✅ / ✅ | ✅ / ✅ |
| `@@` mentions, replacing the whole token | ✅ | ✅ | ✅ / ✅ | ✅ / ✅ |
| `@"path with space"` inserted whole | ✅ | ❌ cut at the space, see lesson 7 | ✅ / ✅ | ✅ / ✅ |
| `me@example` doesn't trigger | ✅ | ✅ | ✅ / ✅ | ✅ / ✅ |
| No trigger inside fences | ✅ | – | – | ✅ |
| `/` with description while browsing | ✅ | ✅ raw Markdown | ✅ / ✅ | ✅ |
| Hidden skill excluded | ✅ | ✅ | ✅ / ✅ | ✅ / ✅ |
| Size shown next to file | ✅ | ❌ no `labelDetails` (cosmetic) | ✅ / ✅ | ✅ / ✅ |

blink.cmp preselects the first item, so `<C-y>` accepts the top match directly.

### What the prototype taught us

1. **File results must always be `isIncomplete = true`.** Native completion
   ignores a second trigger character while the menu is open unless the last
   result was incomplete (`runtime/lua/vim/lsp/completion.lua`, `trigger()`),
   so `@` → `@@` never re-queried. Separately, once a result is complete, Vim
   refilters the open menu itself against each item's *inserted word*, ignoring
   `filterText`. A mention inserts `` `path` ``, so it never matches the typed
   `@@que`, and the menu closes on the first keystroke.
2. **Filter and rank on the server.** Native completion orders items by
   `sortText` rather than fuzzy score, so client-side filtering ranked
   `session.ts` fourth for `@@ses`. The server scores and sorts, caps at 100
   items, and sets `filterText` to the typed token so that prefix-filtering
   engines keep every item. This works the same in native and nvim-cmp.
3. **Performance.** Scoring takes 0.5–4 ms per keystroke on about 2k files, and
   up to 36 ms on a synthetic 50k-file repo. On that repo, synchronous discovery
   took 300 ms, so M2 discovery must be async and cached, as the plan already says.
4. **Discovery fallbacks.** On this machine `rg` exists only as a shell
   function, not an executable. Also, a root inside a repo that ignores it makes
   `git ls-files` succeed with empty output. The chain must treat empty output as
   failure, and `:checkhealth` should report which backend is in use.
5. **Native quirks to document.** Native completion debounces triggers by 25 ms
   and resets the timer on any keystroke, so text typed in a burst or pasted
   doesn't open the menu. Backspace doesn't re-query. Users need
   `completeopt+=popup` to see skill descriptions.
6. **Show the size in one place only.** blink shows both `detail` and
   `labelDetails.description`, so file items set only the latter.
7. **Native completion on 0.11 truncates text with spaces.** It builds the
   inserted word as `textEdit.newText:match('^(%S*)')`, and 0.12 fixed this.
   nvim-cmp and blink apply the full edit. Fix in M2: on 0.11 with native
   completion, a `CompleteDone` handler replaces the shortened text with the
   item's full `newText`. This only matters for paths with whitespace.
8. **Position encoding.** The server advertises `positionEncoding = "utf-8"`,
   so spans are byte columns, which matches the parser.

### Real-config check: blink.cmp with extra sources

Tested with your own config: blink.cmp v1.10.2, the Rust fuzzy matcher, and the
sources `lsp`, `path`, `snippets` and `buffer`. Vergil's items work and rank
first, including with the Rust matcher. The other sources add noise in prompt
buffers:

- `snippets` (friendly-snippets' Markdown set) opens a menu **while typing
  prose**, e.g. "bold and italic" after typing "fail". That breaks principle 7.
- `path` reacts to `/` and lists root directories (`Applications/`, `bin/`)
  below the skills.

Consequence: document a per-buffer source list for blink (and the nvim-cmp
equivalent), keyed on a buffer variable vergil sets, such as
`vim.b.vergil_enabled`. Vergil shouldn't rewrite other plugins' configuration.

### Hands-on feedback (round 1)

1. **`.` closed the menu in blink.** blink hides the menu on any character
   that is neither a keyword character nor a server trigger character. Fix:
   `.` is now a trigger character. Prose stays quiet, because the server
   returns nothing outside a reference.
2. **Icons showed as boxes.** blink's kind icons are Nerd Font glyphs, and no
   Nerd Font is installed. This is unrelated to vergil; the README should
   mention it.
3. **Re-searching a wrong pick.** Manual completion (`<C-Space>`, LSP
   `triggerKind = Invoked`) on an existing `@path`, `@"path"` or `` `path` ``
   now re-searches it in place. The query is the path up to the cursor, and
   the whole reference gets replaced. The reference being edited no longer
   marks itself as "attached". Limitation: blink hides the menu when Backspace
   crosses `/` or `.`, and `<C-Space>` reopens it. The real plugin should also
   offer a `<Plug>` mapping for this.

### Hands-on feedback (round 2)

1. **Nerd Font.** Installing one fixed the icons. It's now an optional
   requirement in the README, and icons should be configurable (plan §7.6,
   `ui.icons`). Completion-menu icons belong to the engine; blink accepts a
   function for `completion.menu.draw.columns`, so the docs can show how to
   drop `kind_icon` in prompt buffers only.
2. **Backspace after re-searching closed the menu at `.`.** Fixed in vergil,
   not in engine config. blink's trigger options are global booleans, and
   native completion never re-queries on Backspace. Vergil watches Backspace in
   prompt buffers, and when the cursor is still inside a reference it reopens
   completion (`blink.show()`, `cmp.complete()`, or `vim.lsp.completion.get()`).
   Verified in blink and native; nvim-cmp is no longer installed, so that path
   is untested. Pitfall: `CursorMovedI` fires before `TextChangedI`, so the
   snapshot must ignore cursor moves that changed the text. Side effect:
   Backspace also reopens a menu you dismissed with `<C-e>`. Option name in
   the prototype: `reopen_on_backspace`.

### Verdict

**Passed: use LSP completion.** Use server-side filtering, always-incomplete
file results, `.` as a trigger character, re-search in place on manual
invocation, reopening on Backspace, and the 0.11 native fix from lesson 7. All
three engines work on both Neovim versions, and the hands-on check in the real
`Ctrl+G` flow with blink.cmp passed after the two feedback rounds above. The
parser, data model and validation stay as planned, and no custom popup is
needed.

### Minimum Neovim version

**0.11**, tested on 0.11.7 and 0.12.6. 0.11 needs the native-completion fix
from lesson 7. CI should cover 0.11.x and the latest stable release.

### Trying it

The prototype was removed in Milestone 2, when the real plugin replaced it
(see git history at `a0d51bc`). To try the plugin in the real `Ctrl+G` flow:

```sh
cd /some/project
VISUAL=~/code/vergil.nvim/scripts/dev-editor.sh claude
```

### Other notes

- Your config includes `vim-better-whitespace`. If strip-on-save is enabled,
  it would break paste re-collapsing (§6.11), so `:checkhealth vergil` should
  detect it.
