-- nvim --clean -u prototype/m0/init_native.lua claude-prompt-x.md
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
vim.o.completeopt = "menuone,noselect,popup,fuzzy"
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev)
    vim.lsp.completion.enable(true, ev.data.client_id, ev.buf, { autotrigger = true })
  end,
})
require("server").setup({ filter = vim.env.VERGIL_FILTER or "server" })
