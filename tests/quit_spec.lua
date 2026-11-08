local h = require("helpers")

local root = h.tree({ ["src/a.lua"] = table.concat(vim.fn.range(1, 20), "\n") .. "\n" })

local function only_window()
  vim.cmd("silent! tabonly | silent! only")
end

local function wins()
  return #vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ""
  end, vim.api.nvim_list_wins())
end

return {
  [":q in a file opened with gd returns to the prompt"] = function()
    only_window()
    local b, client = h.prompt(root, { "`src/a.lua#L5`" }, "quit")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    local loc = h.request(client, b, "textDocument/definition", 0, 2)
    vim.lsp.util.show_document(loc, "utf-8", { focus = true })
    h.eq(vim.api.nvim_get_current_buf() ~= b, true)
    vim.cmd("quit")
    h.eq(vim.api.nvim_get_current_buf(), b)
    h.eq(wins(), 1)
  end,
  [":q after :Vergil open (same window) returns to the prompt"] = function()
    only_window()
    local b = h.prompt(root, { "@src/a.lua" }, "quit")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    require("vergil").open()
    vim.cmd("quit")
    h.eq(vim.api.nvim_get_current_buf(), b)
  end,
  ["splits and tabs behave as usual"] = function()
    only_window()
    local b = h.prompt(root, { "@src/a.lua" }, "quit")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    require("vergil").open("split")
    h.eq(wins(), 2)
    vim.cmd("quit")
    h.eq({ vim.api.nvim_get_current_buf(), wins() }, { b, 1 })
  end,
  [":q in the prompt itself is untouched"] = function()
    only_window()
    h.prompt(root, { "x" }, "quit")
    local opened = false
    local id = vim.api.nvim_create_autocmd("WinNew", {
      callback = function()
        opened = true
      end,
    })
    require("vergil.session").on_quit_pre()
    vim.api.nvim_del_autocmd(id)
    h.eq(opened, false)
  end,
  ["can be turned off"] = function()
    only_window()
    h.prompt(root, { "@src/a.lua" }, "quit")
    require("vergil").setup({ root = root, return_to_prompt = false })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    require("vergil").open()
    require("vergil.session").on_quit_pre()
    h.eq(wins(), 1)
    require("vergil").setup({ root = root })
  end,
}
