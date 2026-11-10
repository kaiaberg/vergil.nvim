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
vim.api.nvim_create_autocmd("QuitPre", {
  group = group,
  callback = function()
    session.on_quit_pre()
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

require("vergil.keymaps").define_plugs()

-- After the user's setup() has had its chance (lazy loaders call it right
-- after sourcing this file).
local function notice()
  vim.schedule(function()
    require("vergil.config").notice_no_agents()
  end)
end
if vim.v.vim_did_enter == 1 then
  notice()
else
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = notice })
end

vim.api.nvim_create_user_command("Vergil", function(opts)
  require("vergil.commands").run(opts)
end, {
  nargs = "+",
  range = true, -- :'<,'>Vergil send
  desc = "vergil.nvim",
  complete = function(arglead, cmdline)
    return require("vergil.commands").complete(arglead, cmdline)
  end,
})
