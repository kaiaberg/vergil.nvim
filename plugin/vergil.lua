if vim.g.loaded_vergil then
  return
end
vim.g.loaded_vergil = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("vergil.nvim requires Neovim 0.11 or newer", vim.log.levels.ERROR)
  return
end

local session = require("vergil.session")

-- Captured here, at load time, so later `:cd` doesn't move the root.
session.capture_root()

local group = vim.api.nvim_create_augroup("vergil", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = group,
  callback = function(ev)
    session.maybe_enable(ev.buf)
  end,
})
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = group,
  callback = function(ev)
    session.forget(ev.buf)
  end,
})

-- Buffers opened before a lazy-loaded plugin.
for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(bufnr) then
    session.maybe_enable(bufnr)
  end
end

vim.api.nvim_create_user_command("Vergil", function(opts)
  require("vergil.commands").run(opts)
end, {
  nargs = "+",
  desc = "vergil.nvim",
  complete = function(arglead, cmdline)
    return require("vergil.commands").complete(arglead, cmdline)
  end,
})
