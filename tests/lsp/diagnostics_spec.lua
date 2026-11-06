local h = require("helpers")

local big = string.rep("x", 70000) -- ~23k estimated tokens
local root = h.tree({
  ["src/a.ts"] = "1\n2\n3\n",
  ["big.txt"] = big,
  ["Override"] = "",
  ["dir/x"] = "",
})

local function diags(lines)
  local bufnr = h.prompt(root, lines, "diag")
  local got
  vim.wait(2000, function()
    got = vim.diagnostic.get(bufnr)
    return #got > 0
  end)
  table.sort(got, function(a, b) return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col) end)
  return vim.tbl_map(function(d)
    return { line = d.lnum, col = d.col, code = d.code, severity = d.severity, message = d.message }
  end, got), bufnr
end

local function codes(lines)
  return vim.tbl_map(function(d) return d.code end, (diags(lines)))
end

local S = vim.diagnostic.severity

return {
  ["duplicate attachment, normalized paths"] = function()
    local d = diags({ "@src/a.ts and", "@./src/a.ts" })
    h.eq(#d, 1)
    h.eq({ d[1].line, d[1].code, d[1].severity, d[1].message }, { 1, "duplicate", S.WARN, "src/a.ts is already attached on line 1." })
  end,
  ["mentions of an attached file are fine"] = function()
    local d = diags({ "@src/a.ts then `src/a.ts#L2`", "@missing.ts" })
    h.eq(vim.tbl_map(function(x) return x.code end, d), { "missing_attachment" })
  end,
  ["large attachment uses the token estimate"] = function()
    local d = diags({ "@big.txt" })
    h.eq(d[1].code, "large")
    h.truthy(d[1].message:find("~23k tokens, 68 KB", 1, true), d[1].message)
    h.truthy(d[1].message:find("may skip or cut", 1, true))
    h.eq(d[1].severity, S.INFO)
  end,
  ["range past the end, ignored range, missing targets"] = function()
    h.eq(codes({ "`src/a.ts#L2-L9`", "@src/a.ts#L1", "`nope/x.ts`", "@nope.ts" }), { "range", "ignored_range", "missing_mention", "missing_attachment" })
    local d = diags({ "`src/a.ts#L7`" })
    h.eq(d[1].message, "Line 7 is past the end of src/a.ts (3 lines).")
  end,
  ["severities"] = function()
    local d = diags({ "@src/a.ts#L1", "@nope.ts" })
    h.eq({ d[1].severity, d[2].severity }, { S.HINT, S.INFO })
  end,
  ["fenced code: only the will-attach hint, no duplicates"] = function()
    local d = diags({ "@src/a.ts", "```java", "@Override", "@src/a.ts", "@NotAFile", "```" })
    h.eq(vim.tbl_map(function(x) return { x.line, x.code } end, d), { { 2, "fenced" }, { 3, "fenced" } })
  end,
  ["inline code that might be a path, prose and resources are quiet"] = function()
    local bufnr = h.prompt(root, { "call `refresh` and mail me@x.com and @srv:res and @dir/" }, "diag")
    vim.wait(300)
    h.eq(vim.diagnostic.get(bufnr), {})
  end,
  ["diagnostics follow edits"] = function()
    local d, bufnr = diags({ "@src/a.ts", "@src/a.ts" })
    h.eq(#d, 1)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "fixed" })
    vim.wait(2000, function() return #vim.diagnostic.get(bufnr) == 0 end)
    h.eq(vim.diagnostic.get(bufnr), {})
  end,
  ["checks can be turned off and thresholds changed"] = function()
    require("vergil").setup({ root = root, diagnostics = { attachment_token_warning = 100000, severity = { missing_attachment = false } } })
    local bufnr = h.prompt(root, { "@big.txt @nope.ts" }, "diag")
    require("vergil").setup({ root = root, diagnostics = { attachment_token_warning = 100000, severity = { missing_attachment = false } } })
    require("vergil.lsp.server").refresh(bufnr)
    vim.wait(300)
    h.eq(vim.diagnostic.get(bufnr), {})
    require("vergil").setup({ root = root })
  end,
  ["setup validates severities"] = function()
    h.errors(function() require("vergil").setup({ diagnostics = { severity = { duplicate = "loud" } } }) end, "diagnostics.severity.duplicate")
  end,
}
