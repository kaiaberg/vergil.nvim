local h = require("helpers")
local send = require("vergil.send")

local root = h.tree({
  ["src/a.lua"] = "line 1\nline 2\nline 3\nline 4\n",
  ["src/b.lua"] = "b 1\nb 2\n",
})

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function text(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- A prompt with the cursor at (row, col), then `file` opened in its window,
--- as `gd` would.
local function from_prompt(lines, cursor, file, name)
  vim.cmd("silent! %bwipeout!")
  local b = h.prompt(root, lines, name or "send")
  vim.api.nvim_win_set_cursor(0, cursor)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. file))
  return b
end

--- A prompt with the cursor at (row, col) on a reference, opened with
--- `:Vergil open`, as `gd` would.
local function opened(lines, cursor, name)
  vim.cmd("silent! %bwipeout!")
  local b = h.prompt(root, lines, name or "send-open")
  vim.api.nvim_win_set_cursor(0, cursor)
  assert(require("vergil").open())
  return b
end

return {
  ["the first send after opening a reference replaces it, as # would"] = function()
    local b = opened({ "Why does @src/a.lua fail?" }, { 1, 12 })
    local real = vim.uv.fs_realpath(root .. "/src/a.lua")
    h.eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), real)
    h.eq(send.send("mention", 2, 3), true)
    h.eq(vim.api.nvim_get_current_buf(), b, "back in the prompt")
    h.eq(text(b), { "Why does `src/a.lua#L2-L3` fail?" })
    h.eq(vim.api.nvim_win_get_cursor(0), { 1, 26 }, "cursor after the mention")
    h.eq(vim.uv.fs_realpath(vim.fn.bufname("#")), real, "<C-^> goes back to the file")
    vim.cmd.buffer("#")
    send.send("mention", 4, 4)
    h.eq(text(b), { "Why does `src/a.lua#L2-L3` `src/a.lua#L4` fail?" }, "a second send adds")
  end,
  ["gd records the reference too"] = function()
    vim.cmd("silent! %bwipeout!")
    local b, client = h.prompt(root, { "See `src/b.lua`" }, "send-gd")
    local params = { textDocument = { uri = vim.uri_from_bufnr(b) }, position = { line = 0, character = 6 } }
    client:request_sync("textDocument/definition", params, 2000, b)
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/b.lua"))
    send.send("mention", 2, 2)
    h.eq(text(b), { "See `src/b.lua#L2`" })
  end,
  ["without opening, a reference under the cursor isn't replaced"] = function()
    local b = from_prompt({ "Why @src/a.lua" }, { 1, 6 }, "src/a.lua")
    send.send("mention", 1, 1)
    h.eq(text(b), { "Why @src/a.lua `src/a.lua#L1`" })
  end,
  ["inserts after the cursor, with spaces where needed"] = function()
    local b = from_prompt({ "Compare this", "next" }, { 1, 11 }, "src/b.lua")
    h.eq(send.send(nil, 2, 2), true)
    h.eq(text(b), { "Compare this `src/b.lua#L2`", "next" })
    from_prompt({ "AB" }, { 1, 0 }, "src/b.lua", "send-mid")
    send.send("mention", 1, 1)
    h.eq(vim.api.nvim_get_current_line(), "A `src/b.lua#L1` B")
    from_prompt({ "" }, { 1, 0 }, "src/b.lua", "send-empty")
    send.send("mention", 1, 2)
    h.eq(vim.api.nvim_get_current_line(), "`src/b.lua#L1-L2`")
  end,
  ["a reference to another file is left alone"] = function()
    local b = from_prompt({ "@src/a.lua" }, { 1, 3 }, "src/b.lua")
    send.send("mention", 1, 1)
    h.eq(text(b), { "@src/a.lua `src/b.lua#L1`" })
  end,
  ["snippet and both, like the selector"] = function()
    local b = opened({ "See @src/a.lua here" }, { 1, 6 })
    send.send("snippet", 3, 4)
    h.eq(text(b), { "See  here", "", "From `src/a.lua#L3-L4`:", "", "```lua", "line 3", "line 4", "```", "" })
    b = from_prompt({ "Look:" }, { 1, 4 }, "src/b.lua", "send-both")
    send.send("both", 1, 1)
    h.eq(text(b), { "Look: `src/b.lua#L1`", "", "From `src/b.lua#L1`:", "", "```lua", "b 1", "```", "" })
  end,
  ["sends the unsaved buffer lines and warns"] = function()
    local b = from_prompt({ "x" }, { 1, 0 }, "src/b.lua")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "changed" })
    local warned
    local notify = vim.notify
    vim.notify = function(msg) warned = msg end
    send.send("snippet", 1, 1)
    vim.notify = notify
    h.truthy(vim.tbl_contains(text(b), "changed"), vim.inspect(text(b)))
    h.truthy(warned and warned:find("unsaved changes", 1, true), warned)
    vim.cmd("silent! bwipeout! " .. vim.fn.fnameescape(root .. "/src/b.lua"))
  end,
  ["files outside the root use their full path"] = function()
    local outside = h.tree({ ["x.lua"] = "out\n" })
    local b = from_prompt({ "" }, { 1, 0 }, "src/b.lua")
    vim.cmd.edit(vim.fn.fnameescape(outside .. "/x.lua"))
    local full = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~")
    send.send("mention", 1, 1)
    h.eq(text(b), { "`" .. full .. "#L1`" })
  end,
  ["the prompt in another window is used in place"] = function()
    local b = from_prompt({ "Here" }, { 1, 3 }, "src/b.lua")
    vim.cmd.buffer(b)
    vim.cmd.split(vim.fn.fnameescape(root .. "/src/b.lua"))
    local prompt_win = vim.fn.win_getid(vim.fn.winnr("j"))
    send.send("mention", 2, 2)
    h.eq(vim.api.nvim_get_current_win(), prompt_win)
    h.eq(text(b), { "Here `src/b.lua#L2`" })
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "the file stays open above")
  end,
  ["reports problems"] = function()
    local b = from_prompt({ "x" }, { 1, 0 }, "src/b.lua")
    vim.cmd.buffer(b)
    h.eq({ send.send("mention", 1, 1) }, { false, "this is the prompt; send lines from a file, or use # here" })
    vim.cmd.enew()
    h.eq({ send.send("mention", 1, 1) }, { false, "not a file on disk" })
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/a.lua"))
    h.eq({ send.send("sideways", 1, 1) }, { false, 'unknown action "sideways"; expected snippet or both' })
    vim.cmd("silent! %bwipeout!")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/a.lua"))
    h.eq({ send.send("mention", 1, 1) }, { false, "no prompt buffer (use :Vergil enable)" })
  end,
  [":Vergil send takes a range"] = function()
    local b = from_prompt({ "Q" }, { 1, 0 }, "src/a.lua")
    vim.cmd("2,3Vergil send")
    h.eq(text(b), { "Q `src/a.lua#L2-L3`" })
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/a.lua"))
    vim.cmd("4Vergil send both")
    h.eq(text(b)[1], "Q `src/a.lua#L2-L3` `src/a.lua#L4`")
  end,
  ["preset: Visual keys in files, not in the prompt or without a prompt"] = function()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(root, { "Why @src/a.lua?" }, "send-keys")
    require("vergil").setup({ root = root, keymaps = { preset = true } })
    h.eq(vim.fn.maparg("<CR>", "x", false, true).buffer, nil, "not in the prompt")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    assert(require("vergil").open())
    h.eq(vim.fn.maparg("<CR>", "x", false, true).rhs, "<Plug>(vergil-send)")
    h.eq(vim.fn.maparg("gs", "x", false, true).rhs, "<Plug>(vergil-send-snippet)")
    h.eq(vim.fn.maparg("gb", "x", false, true).rhs, "<Plug>(vergil-send-both)")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    feed("Vj<CR>")
    h.eq(text(b), { "Why `src/a.lua#L2-L3`?" })
    h.eq(vim.fn.mode(), "n", "Visual mode ended")
    vim.cmd.enew()
    h.eq(vim.fn.maparg("<CR>", "x", false, true).buffer, nil, "not in scratch buffers")
    require("vergil").setup({ root = root })
  end,
}
