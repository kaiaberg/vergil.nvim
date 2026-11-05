local h = require("helpers")

local root = h.tree({ ["src/a.lua"] = "local x = 1\n" })

local function floats()
  return vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function prompt(preset)
  local b = h.prompt(root, { "see @src/a.lua" }, "keys")
  require("vergil").setup({ root = root, keymaps = { preset = preset } })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  return b
end

local function wait_float()
  vim.wait(2000, function() return #floats() > 0 end)
  return #floats()
end

return {
  ["Esc closes :Vergil preview"] = function()
    prompt(true)
    require("vergil").preview()
    h.eq(#floats(), 1)
    feed("<Esc>")
    h.eq(#floats(), 0)
    require("vergil").setup({ root = root })
  end,
  ["Esc closes the LSP hover (K), also when focused inside it"] = function()
    local b = prompt(true)
    vim.lsp.buf.hover()
    h.eq(wait_float(), 1)
    feed("<Esc>")
    h.eq(#floats(), 0)
    vim.lsp.buf.hover()
    h.eq(wait_float(), 1)
    vim.lsp.buf.hover() -- second K focuses the float
    vim.wait(1000, function() return vim.api.nvim_win_get_config(0).relative ~= "" end)
    h.eq(vim.api.nvim_win_get_config(0).relative ~= "", true)
    feed("<Esc>")
    h.eq(#floats(), 0)
    h.eq(vim.api.nvim_get_current_buf(), b)
    require("vergil").setup({ root = root })
  end,
  ["Esc without a preview is a plain Esc, or the user's global mapping"] = function()
    prompt(true)
    feed("<Esc>")
    h.eq(vim.api.nvim_get_mode().mode, "n")
    local hit = false
    vim.keymap.set("n", "<Esc>", function() hit = true end)
    feed("<Esc>")
    h.eq(hit, true)
    vim.keymap.del("n", "<Esc>")
    require("vergil").setup({ root = root })
  end,
  ["no Esc mapping without the preset"] = function()
    prompt(false)
    h.eq(vim.fn.maparg("<Esc>", "n", false, true).buffer, nil)
  end,
  ["preset gf opens the reference; falls back to native gf elsewhere"] = function()
    vim.cmd("silent! tabonly | silent! only")
    local b = prompt(true)
    feed("gf")
    h.eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.uv.fs_realpath(root .. "/src/a.lua"))
    vim.cmd.buffer(b)
    vim.fn.writefile({}, root .. "/plain.txt")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "see " .. root .. "/plain.txt" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    feed("gf")
    h.eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.uv.fs_realpath(root .. "/plain.txt"))
    vim.cmd.buffer(b)
    require("vergil").setup({ root = root })
  end,
  ["preset <C-w>f splits, ZZ submits, ZQ aborts"] = function()
    vim.cmd("silent! tabonly | silent! only")
    local submit = require("vergil.submit")
    local exits = {}
    submit.exit = function(cmd) exits[#exits + 1] = cmd end
    prompt(true)
    feed("<C-w>f")
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    vim.cmd("close")
    feed("ZQ")
    feed("ZZ")
    h.eq(exits, { "cquit", "qall" })
    require("vergil").setup({ root = root })
  end,
  ["every <Plug> mapping exists"] = function()
    for _, name in ipairs({ "snippet", "snippet-both", "range", "toggle", "preview", "open", "open-split", "open-vsplit", "open-tab", "submit", "abort", "pick-attach", "pick-mention", "pick-skills", "close-preview" }) do
      h.truthy(vim.fn.maparg(("<Plug>(vergil-%s)"):format(name), "n") ~= "", name)
    end
  end,
}
