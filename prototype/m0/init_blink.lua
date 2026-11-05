-- VERGIL_BLINK=/path/to/blink.cmp nvim --clean -u prototype/m0/init_blink.lua claude-prompt-x.md
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
package.path = here .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(assert(vim.env.VERGIL_BLINK, "set VERGIL_BLINK to a blink.cmp checkout"))
require("blink.cmp").setup({
  fuzzy = { implementation = "lua" }, -- no prebuilt binary download
  sources = { default = { "lsp" } },
  completion = { documentation = { auto_show = true, auto_show_delay_ms = 0 } },
  keymap = { preset = "default" }, -- <C-n>/<C-p> select, <C-y> accept
})
require("server").setup({ filter = vim.env.VERGIL_FILTER or "server" })
