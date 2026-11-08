local h = require("helpers")
local completion = require("vergil.lsp.completion")

local root = h.tree({
  ["src/auth/session.ts"] = "export {}\n",
  ["src/auth/token.ts"] = "x\n",
  ["src/auth/views.py"] = "x\n",
  ["docs/my notes.md"] = "x\n",
  ["README.md"] = "readme\n",
})

local INVOKED = { triggerKind = 1 }

local function complete(line, col, context)
  local bufnr, client = h.prompt(root, { line })
  return h.request(client, bufnr, "textDocument/completion", 0, col or #line, context), bufnr
end

return {
  ["typing_token: triggers, boundary and quoting"] = function()
    h.eq(completion.typing_token("see @src", 8), { mode = "attach", start_col = 4, end_col = 8, query = "src" })
    h.eq(completion.typing_token("@@ses", 5), { mode = "mention", start_col = 0, end_col = 5, query = "ses" })
    h.eq(completion.typing_token('@"my no', 7), { mode = "attach", start_col = 0, end_col = 7, query = "my no" })
    h.eq(completion.typing_token("@my no", 6), nil)
    h.eq(completion.typing_token("me@ex", 5), nil)
    h.eq(completion.typing_token("(@a", 3), nil, "( is not a boundary, as in Claude Code")
    h.eq(completion.typing_token("@@a @b", 6), { mode = "attach", start_col = 4, end_col = 6, query = "b" })
  end,
  ["@ attaches, ranked fuzzy, with the size"] = function()
    local res = complete("look at @sess")
    h.eq(res.isIncomplete, true)
    h.eq(res.items[1].label, "src/auth/session.ts")
    h.eq(res.items[1].textEdit, { range = { start = { line = 0, character = 8 }, ["end"] = { line = 0, character = 13 } }, newText = "@src/auth/session.ts" })
    h.eq(res.items[1].filterText, "@sess")
    h.eq(res.items[1].labelDetails.description, "10 B")
  end,
  ["@@ mentions replace the whole token"] = function()
    local res = complete("@@tok")
    h.eq(res.items[1].label, "src/auth/token.ts")
    h.eq(res.items[1].textEdit.newText, "`src/auth/token.ts`")
    h.eq(res.items[1].textEdit.range.start.character, 0)
  end,
  ["paths with spaces are quoted; snippet-escaped on 0.11 only"] = function()
    local item = complete("@my").items[1]
    if vim.fn.has("nvim-0.12") == 1 then
      h.eq({ item.textEdit.newText, item.insertTextFormat }, { '@"docs/my notes.md"', nil })
    else
      h.eq({ item.textEdit.newText, item.insertTextFormat }, { '@"docs/my notes.md"', 2 })
    end
  end,
  ["outside_query: ~ and absolute paths, one directory at a time"] = function()
    h.eq({ require("vergil.files").outside_query("~") }, { "~/", "" })
    h.eq({ require("vergil.files").outside_query("~/co") }, { "~/", "co" })
    h.eq({ require("vergil.files").outside_query("~/code/ve") }, { "~/code/", "ve" })
    h.eq({ require("vergil.files").outside_query("/usr/lo") }, { "/usr/", "lo" })
    h.eq(require("vergil.files").outside_query("src/a"), nil)
    h.eq(require("vergil.files").outside_query("~user"), nil)
  end,
  ["@~ lists the home directory, directories with a slash, no dotfiles"] = function()
    local home = h.tree({ ["code/x.lua"] = "x\n", ["notes.md"] = "hello\n", [".secret"] = "x\n" })
    local saved = vim.env.HOME
    vim.env.HOME = home
    local ok, err = pcall(function()
      local res = complete("@~")
      h.eq(h.labels(res), { "~/code/", "~/notes.md" })
      h.eq(res.items[1].textEdit.newText, "@~/code/")
      h.eq(res.items[2].labelDetails.description, "6 B")
      h.eq(h.labels(complete("@~/no")), { "~/notes.md" })
      h.eq(h.labels(complete("@~/.s")), { "~/.secret" })
      h.eq(h.labels(complete("@~/code/")), { "~/code/x.lua" })
      h.eq(complete("@@~/no").items[1].textEdit.newText, "`~/notes.md`")
    end)
    vim.env.HOME = saved
    assert(ok, err)
  end,
  ["@/abs lists that directory"] = function()
    local res = complete("@" .. root .. "/src/auth/to")
    h.eq(h.labels(res), { root .. "/src/auth/token.ts" })
    h.eq(complete("@/no/such/dir/").items, {})
  end,
  ["a dot in the query keeps matching"] = function()
    h.eq(complete("@views.py").items[1].label, "src/auth/views.py")
  end,
  ["nothing in prose, emails or fenced code"] = function()
    h.eq(complete("plain words").items, {})
    h.eq(complete("me@ex").items, {})
    local bufnr, client = h.prompt(root, { "```", "@" })
    h.eq(h.request(client, bufnr, "textDocument/completion", 1, 1).items, {})
  end,
  ["already attached files are marked, but not the one being edited"] = function()
    local bufnr, client = h.prompt(root, { "@README.md", "@READ" })
    local res = h.request(client, bufnr, "textDocument/completion", 1, 5)
    h.eq(res.items[1].labelDetails.description, "7 B · attached")
    -- 0.11's native menu only shows `detail`; elsewhere it stays unset for blink.
    h.eq(res.items[1].detail, vim.fn.has("nvim-0.12") == 0 and "7 B · attached" or nil)
    bufnr, client = h.prompt(root, { "@README.md" })
    res = h.request(client, bufnr, "textDocument/completion", 0, 10, INVOKED)
    h.eq(res.items[1].labelDetails.description, "7 B")
  end,
  ["manual completion re-searches an existing reference in place"] = function()
    local line = "fix `src/auth/session.ts` now"
    local res = complete(line, 14, INVOKED) -- cursor after "src/auth/"
    h.eq(#res.items, 3)
    h.eq(res.items[1].textEdit.range, { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 25 } })
    h.eq(res.items[1].textEdit.newText:sub(1, 1), "`")
  end,
  ["manual completion on ordinary inline code does nothing"] = function()
    h.eq(complete("call `refresh` now", 8, INVOKED).items, {})
  end,
  ["custom triggers"] = function()
    require("vergil").setup({ root = root, triggers = { attach = "+", mention = "++" } })
    h.eq(completion.typing_token("x +ses", 6).mode, "attach")
    h.eq(completion.typing_token("++ses", 5).mode, "mention")
    h.eq(vim.tbl_contains(completion.trigger_characters(), "+"), true)
    require("vergil").setup({ root = root })
  end,
}
