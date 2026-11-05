-- VERGIL_PACK=/dir/with/plugins nvim --clean -u prototype/m0/init_cmp.lua claude-prompt-x.md
-- Expects nvim-cmp and cmp-nvim-lsp checkouts directly under $VERGIL_PACK.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
local pack = assert(vim.env.VERGIL_PACK, "set VERGIL_PACK to a dir holding nvim-cmp and cmp-nvim-lsp")
vim.opt.rtp:prepend(pack .. "/nvim-cmp")
vim.opt.rtp:prepend(pack .. "/cmp-nvim-lsp")
vim.cmd("runtime! plugin/cmp.lua after/plugin/cmp_nvim_lsp.lua")
local cmp = require("cmp")
cmp.setup({
  sources = { { name = "nvim_lsp" } },
  mapping = cmp.mapping.preset.insert({ ["<CR>"] = cmp.mapping.confirm({ select = true }) }),
  window = { documentation = cmp.config.window.bordered() },
})
require("cmp_nvim_lsp").setup()
require("server").setup({ filter = vim.env.VERGIL_FILTER or "server" })
