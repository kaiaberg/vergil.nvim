local h = require("helpers")

local src = {}
for i = 1, 40 do src[#src + 1] = ("line %d"):format(i) end
src[5] = "\tindented `code` here  "
local root = h.tree({
  ["src/a.lua"] = table.concat(src, "\n") .. "\n",
  ["dir/x.txt"] = "",
  ["bin.dat"] = "a\0b\n",
})

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function selector_open()
  vim.wait(1000, function() return vim.api.nvim_win_get_config(0).relative ~= "" end)
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

local function floats()
  return #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
end

--- Types `#` after the reference at the end of `line`, waits for the selector.
local function trigger(lines, row)
  local bufnr = h.prompt(root, lines, "range")
  vim.api.nvim_win_set_cursor(0, { row or 1, 0 })
  feed("A#")
  h.truthy(selector_open(), "selector did not open")
  return bufnr
end

local function text(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

return {
  ["# after @path: Visual selection + Enter inserts a mention, dropping the @"] = function()
    local b = trigger({ "the check in @src/a.lua" })
    feed("11GV4j<CR>")
    h.eq(text(b), { "the check in `src/a.lua#L11-L15`" })
    h.eq(floats(), 0)
  end,
  ["Enter in Normal mode takes the current line; a count extends it"] = function()
    local b = trigger({ "@src/a.lua" })
    feed("7G<CR>")
    h.eq(text(b), { "`src/a.lua#L7`" })
    b = trigger({ "@src/a.lua" })
    feed("7G3<CR>")
    h.eq(text(b), { "`src/a.lua#L7-L9`" })
  end,
  ["# after a mention works too, and search motions are plain Vim"] = function()
    local b = trigger({ "see `src/a.lua`" })
    feed("/line 20<CR>V/line 22<CR><CR>")
    h.eq(text(b), { "see `src/a.lua#L20-L22`" })
  end,
  ["gs alone on a line: the snippet replaces the line, whitespace verbatim"] = function()
    local b = trigger({ "Before", "@src/a.lua", "After" }, 2)
    feed("4GVj" .. "gs")
    h.eq(text(b), { "Before", "", "From `src/a.lua#L4-L5`:", "", "```lua", "line 4", "\tindented `code` here  ", "```", "", "After" })
  end,
  ["gs mid-sentence: reference removed, snippet below"] = function()
    local b = trigger({ "it may be related to @src/a.lua" })
    feed("2Ggs")
    h.eq(text(b), { "it may be related to ", "", "From `src/a.lua#L2`:", "", "```lua", "line 2", "```", "" })
  end,
  ["gb: mention inline and snippet below"] = function()
    local b = trigger({ "look at @src/a.lua", "", "more" })
    feed("3Ggb")
    h.eq(text(b), { "look at `src/a.lua#L3`", "", "From `src/a.lua#L3`:", "", "```lua", "line 3", "```", "", "more" })
  end,
  ["q cancels and removes only the #"] = function()
    local b = trigger({ "keep  @src/a.lua" })
    feed("10Gq")
    h.eq(text(b), { "keep  @src/a.lua" })
    h.eq(floats(), 0)
  end,
  ["Esc in Visual mode keeps the selector open; Esc in Normal cancels"] = function()
    local b = trigger({ "@src/a.lua" })
    feed("V<Esc>")
    h.eq(floats(), 1)
    feed("<Esc>")
    vim.wait(100)
    h.eq(text(b), { "@src/a.lua" })
    h.eq(floats(), 0)
  end,
  ["closing the window counts as cancel"] = function()
    local b = trigger({ "@src/a.lua" })
    vim.cmd("close")
    vim.wait(200, function() return text(b)[1] == "@src/a.lua" end)
    h.eq(text(b), { "@src/a.lua" })
  end,
  ["the selector is a read-only scratch buffer, not the file"] = function()
    trigger({ "@src/a.lua" })
    local sb = vim.api.nvim_get_current_buf()
    h.eq({ vim.bo[sb].buftype, vim.bo[sb].modifiable, vim.bo[sb].swapfile, vim.bo[sb].filetype }, { "nofile", false, false, "" })
    h.eq(vim.fn.bufnr(root .. "/src/a.lua"), -1)
    h.eq(#vim.lsp.get_clients({ bufnr = sb }), 0)
    feed("q")
  end,
  ["# elsewhere is just a #"] = function()
    for _, line in ipairs({ "issue ", "@missing.ts", "@dir/", "@bin.dat", "(@src/a.lua)" }) do
      local b = h.prompt(root, { line }, "plain")
      feed("A#<Esc>")
      vim.wait(100)
      h.eq(floats(), 0, line)
      h.eq(text(b), { line .. "#" }, line)
    end
  end,
  [":Vergil range on an existing ranged mention preselects and replaces it"] = function()
    local b = h.prompt(root, { "fix `src/a.lua#L3-L4` please" }, "cmd")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.cmd("Vergil range")
    h.truthy(selector_open())
    h.eq({ vim.fn.line("v"), vim.fn.line(".") }, { 3, 4 })
    feed("j<CR>")
    h.eq(text(b), { "fix `src/a.lua#L3-L5` please" })
  end,
  [":Vergil range reports problems"] = function()
    h.prompt(root, { "nothing here" }, "cmd")
    h.eq({ require("vergil.range").select_at_cursor() }, { false, "no reference under the cursor" })
    h.prompt(root, { "@dir/" }, "cmd")
    h.eq({ require("vergil.range").select_at_cursor() }, { false, "not a file: dir" })
  end,
  ["colon mention format"] = function()
    require("vergil").setup({ root = root, mention = { format = "colon" } })
    local bufnr = vim.api.nvim_get_current_buf()
    local b = h.prompt(root, { "@src/a.lua" }, "colon")
    require("vergil").setup({ root = root, mention = { format = "colon" } })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("A#")
    h.truthy(selector_open())
    feed("2GVj<CR>")
    h.eq(text(b), { "`src/a.lua:2-3`" })
    require("vergil").setup({ root = root })
  end,
  ["undo restores the prompt in one step"] = function()
    local b = trigger({ "x @src/a.lua" })
    feed("3Ggb")
    vim.cmd("stopinsert")
    feed("<Esc>u")
    h.eq(text(b)[1]:find("`src/a.lua#L3`", 1, true) == nil, true, vim.inspect(text(b)))
  end,
  [":Vergil snippet replaces a ranged mention with its lines"] = function()
    local b = h.prompt(root, { "Before", "`src/a.lua#L4-L5`", "After" }, "snip")
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    vim.cmd("Vergil snippet")
    h.eq(text(b), { "Before", "", "From `src/a.lua#L4-L5`:", "", "```lua", "line 4", "\tindented `code` here  ", "```", "", "After" })
  end,
  [":Vergil snippet both keeps the mention; @file#range becomes a mention"] = function()
    local b = h.prompt(root, { "see @src/a.lua#L2-L3 here" }, "snip")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.cmd("Vergil snippet both")
    h.eq(text(b), { "see `src/a.lua#L2-L3` here", "", "From `src/a.lua#L2-L3`:", "", "```lua", "line 2", "line 3", "```", "" })
  end,
  [":Vergil snippet without a range opens the selector"] = function()
    local b = h.prompt(root, { "@src/a.lua" }, "snip")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    vim.cmd("Vergil snippet")
    h.truthy(selector_open())
    feed("2Ggs")
    h.eq(text(b), { "From `src/a.lua#L2`:", "", "```lua", "line 2", "```", "" })
  end,
  [":Vergil snippet reports problems"] = function()
    h.prompt(root, { "`src/a.lua#L39-L45`" }, "snip")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    h.eq({ require("vergil.range").snippet_at_cursor() }, { false, "lines 39-45 are past the end of src/a.lua (40 lines)" })
    h.eq({ require("vergil.range").snippet_at_cursor("sideways") }, { false, 'unknown snippet mode "sideways"; expected both or nothing' })
  end,
  ["keymaps: none by default; the preset maps gs/gb in prompt buffers only"] = function()
    local b = h.prompt(root, { "`src/a.lua#L1`" }, "keys")
    h.eq(vim.fn.maparg("gs", "n", false, true).buffer, nil)
    require("vergil").setup({ root = root, keymaps = { preset = true } })
    h.eq(vim.fn.maparg("gs", "n", false, true).rhs, "<Plug>(vergil-snippet)")
    h.eq(vim.fn.maparg("gb", "n", false, true).rhs, "<Plug>(vergil-snippet-both)")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    feed("gs")
    h.eq(text(b), { "From `src/a.lua#L1`:", "", "```lua", "line 1", "```", "" })
    vim.cmd.edit(vim.fn.tempname() .. "-other.md")
    h.eq(vim.fn.maparg("gs", "n", false, true).buffer, nil, "not in other buffers")
    require("vergil").setup({ root = root })
    vim.cmd.buffer(b)
    h.eq(vim.fn.maparg("gs", "n", false, true).buffer, nil, "preset off removes them")
  end,
}
