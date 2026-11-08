local h = require("helpers")

local root = h.tree({
  ["src/a.lua"] = table.concat(vim.fn.range(1, 50), "\n") .. "\n",
  ["dir/x.txt"] = "",
})

local function setup(line)
  local bufnr, client = h.prompt(root, { line }, "def")
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  return bufnr, client
end

local function close_others()
  vim.cmd("silent! tabonly | silent! only")
end

return {
  ["definition points at the mention's first line"] = function()
    local bufnr, client = setup("`src/a.lua#L12-L20`")
    local loc = h.request(client, bufnr, "textDocument/definition", 0, 3)
    h.eq(loc, {
      uri = vim.uri_from_fname(root .. "/src/a.lua"),
      range = { start = { line = 11, character = 0 }, ["end"] = { line = 11, character = 0 } },
    })
  end,
  ["definition of an attachment is line 1; missing targets give nothing"] = function()
    local bufnr, client = setup("@src/a.lua")
    h.eq(h.request(client, bufnr, "textDocument/definition", 0, 2).range.start.line, 0)
    bufnr, client = setup("@missing.ts")
    h.eq(h.request(client, bufnr, "textDocument/definition", 0, 2), nil)
  end,
  [":Vergil open split/vsplit/tab opens at the line and keeps the prompt"] = function()
    for _, how in ipairs({ "split", "vsplit", "tab" }) do
      close_others()
      local bufnr = setup("`src/a.lua#L30`")
      local wins, tabs = #vim.api.nvim_tabpage_list_wins(0), #vim.api.nvim_list_tabpages()
      vim.cmd("Vergil open " .. how)
      h.eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.uv.fs_realpath(root .. "/src/a.lua"), how)
      h.eq(vim.api.nvim_win_get_cursor(0)[1], 30, how)
      if how == "tab" then
        h.eq(#vim.api.nvim_list_tabpages(), tabs + 1)
      else
        h.eq(#vim.api.nvim_tabpage_list_wins(0), wins + 1)
      end
      h.eq(vim.api.nvim_buf_is_loaded(bufnr), true)
    end
    close_others()
  end,
  [":Vergil open respects :vertical, :botright and :tab"] = function()
    close_others()
    setup("`src/a.lua#L30`")
    vim.cmd("vertical Vergil open split")
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    h.eq(vim.fn.winlayout()[1], "row", ":vertical split is side by side")
    close_others()
    setup("`src/a.lua#L30`")
    vim.cmd("botright Vergil open vsplit")
    h.eq(vim.fn.winnr(), vim.fn.winnr("$"), ":botright puts it last")
    close_others()
    setup("`src/a.lua#L30`")
    local tabs = #vim.api.nvim_list_tabpages()
    vim.cmd("tab Vergil open split")
    h.eq(#vim.api.nvim_list_tabpages(), tabs + 1, ":tab split opens a tab")
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 30)
    close_others()
  end,
  [":Vergil open reports problems instead of opening"] = function()
    setup("@missing.ts")
    h.eq({ require("vergil").open() }, { false, "not found: " .. root .. "/missing.ts" })
    h.eq(
      { require("vergil").open("sideways") },
      { false, 'unknown open mode "sideways"; expected split, vsplit or tab' }
    )
  end,
  [":Vergil preview opens a float"] = function()
    setup("@src/a.lua")
    h.eq(require("vergil").preview(), true)
    local floats = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative ~= ""
    end, vim.api.nvim_list_wins())
    h.eq(#floats, 1)
    vim.api.nvim_win_close(floats[1], true)
  end,
  ["disable detaches the client"] = function()
    local bufnr = setup("@src/a.lua")
    vim.cmd("Vergil disable")
    h.eq(#vim.lsp.get_clients({ bufnr = bufnr, name = "vergil" }), 0)
    vim.cmd("Vergil enable")
    vim.wait(1000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = "vergil" }) == 1
    end)
    h.eq(#vim.lsp.get_clients({ bufnr = bufnr, name = "vergil" }), 1)
  end,
}
