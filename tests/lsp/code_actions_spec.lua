local h = require("helpers")

local root = h.tree({ ["src/a.ts"] = "one\ntwo\nthree\n", ["big.txt"] = string.rep("x", 70000) })

local function actions(lines, row, col, with_diags)
  local bufnr, client = h.prompt(root, lines, "ca")
  local diagnostics = {}
  if with_diags then
    vim.wait(2000, function() return #vim.diagnostic.get(bufnr) > 0 end)
    for _, d in ipairs(vim.diagnostic.get(bufnr, { lnum = row })) do
      diagnostics[#diagnostics + 1] = d.user_data and d.user_data.lsp or d
    end
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
    context = { diagnostics = diagnostics },
  }
  local res = client:request_sync("textDocument/codeAction", params, 2000, bufnr)
  return res.result, bufnr, client
end

local function titles(list)
  return vim.tbl_map(function(a) return a.title .. " [" .. a.kind .. "]" end, list)
end

local function apply(action, client)
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
  else
    client:exec_cmd(action.command)
  end
end

return {
  ["attachment: convert, plus line selection"] = function()
    local list = actions({ "see @src/a.ts" }, 0, 6)
    h.eq(titles(list), { "Convert to mention [refactor.rewrite]", "Select lines… [refactor.rewrite]" })
  end,
  ["ranged mention: convert and both snippet actions"] = function()
    local list = actions({ "`src/a.ts#L2`" }, 0, 3)
    h.eq(titles(list), {
      "Convert to attachment [refactor.rewrite]",
      "Replace with snippet [refactor.rewrite]",
      "Add snippet below [refactor.rewrite]",
      "Select lines… [refactor.rewrite]",
    })
  end,
  ["a large attachment gets a preferred quickfix with the diagnostic"] = function()
    local list = actions({ "@big.txt" }, 0, 2, true)
    h.eq(list[1].title, "Convert to mention")
    h.eq({ list[1].kind, list[1].isPreferred, list[1].diagnostics[1].code }, { "quickfix", true, "large" })
  end,
  ["applying the conversion edits exactly the span"] = function()
    local list, bufnr, client = actions({ "fix @src/a.ts), ok" }, 0, 6)
    apply(list[1], client)
    h.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "fix `src/a.ts`), ok" })
  end,
  ["running the snippet command replaces the mention"] = function()
    local list, bufnr, client = actions({ "`src/a.ts#L2-L3`" }, 0, 2)
    apply(list[2], client)
    h.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "From `src/a.ts#L2-L3`:", "", "```typescript", "two", "three", "```", "" })
  end,
  ["nothing for prose or ordinary inline code"] = function()
    h.eq(actions({ "call `refresh` now" }, 0, 7), {})
    h.eq(actions({ "plain words" }, 0, 2), {})
  end,
}
