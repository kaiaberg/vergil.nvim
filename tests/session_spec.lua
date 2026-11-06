local h = require("helpers")
local root = vim.fn.getcwd()
vim.cmd.source(vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"), "plugin/vergil.lua"))
local session = require("vergil.session")
local config = require("vergil.config")

local function edit(name)
  vim.cmd.edit(vim.fn.fnameescape(name))
  return vim.api.nvim_get_current_buf()
end

return {
  ["activates on the prompt file name in any directory"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/x", "p")
    local b = edit(dir .. "/x/claude-prompt-0b10639a.md")
    h.eq(session.is_enabled(b), true)
    h.eq(vim.b[b].vergil_enabled, true)
  end,
  ["does not activate in other Markdown buffers"] = function()
    local b = edit(vim.fn.tempname() .. "-notes.md")
    h.eq(session.is_enabled(b), false)
    h.eq(session.matches("/claude-prompt-x/notes.md"), false)
  end,
  ["root is the startup cwd and survives :cd"] = function()
    local b = edit(vim.fn.tempname() .. "/claude-prompt-r.md")
    vim.cmd.cd(vim.fn.tempname():match("^(.*)/"))
    h.eq(session.get(b).root, vim.fs.normalize(root))
    h.eq(session.root(), vim.fs.normalize(root))
    vim.cmd.cd(root)
  end,
  ["explicit root wins"] = function()
    require("vergil").setup({ root = "/explicit/root" })
    h.eq(session.root(), "/explicit/root")
    require("vergil").setup({})
  end,
  ["enable/disable are idempotent and fire User events"] = function()
    local events = {}
    local id = vim.api.nvim_create_autocmd("User", { pattern = { "VergilEnable", "VergilDisable" }, callback = function(ev) events[#events + 1] = ev.match end })
    local b = edit(vim.fn.tempname() .. "-plain.md")
    vim.cmd("Vergil enable")
    vim.cmd("Vergil enable")
    h.eq(session.is_enabled(b), true)
    vim.cmd("Vergil disable")
    vim.cmd("Vergil disable")
    h.eq({ session.is_enabled(b), vim.b[b].vergil_enabled }, { false, nil })
    h.eq(events, { "VergilEnable", "VergilDisable" })
    vim.api.nvim_del_autocmd(id)
  end,
  ["custom filename patterns via setup"] = function()
    require("vergil").setup({ activation = { filename_patterns = { "prompt-*.txt" } } })
    h.eq(session.matches("/tmp/prompt-1.txt"), true)
    h.eq(session.matches("/tmp/claude-prompt-1.md"), false)
    require("vergil").setup({})
    h.eq(session.matches("/tmp/claude-prompt-1.md"), true)
  end,
  ["setup validates options"] = function()
    h.errors(function() require("vergil").setup({ mention = { format = "nope" } }) end, "mention.format")
    h.errors(function() require("vergil").setup({ root = 1 }) end, "root")
    h.eq(config.options.mention.format, "github")
  end,
  ["wiped buffers are forgotten"] = function()
    local b = edit(vim.fn.tempname() .. "/claude-prompt-w.md")
    vim.cmd("bwipeout!")
    h.eq(session.is_enabled(b), false)
  end,
  [":Vergil toggle converts the reference under the cursor"] = function()
    local b = edit(vim.fn.tempname() .. "/claude-prompt-t.md")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "fix @src/a.ts please" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.cmd("Vergil toggle")
    h.eq(vim.api.nvim_get_current_line(), "fix `src/a.ts` please")
    vim.cmd("Vergil toggle")
    h.eq(vim.api.nvim_get_current_line(), "fix @src/a.ts please")
  end,
  [":Vergil toggle leaves ordinary inline code alone"] = function()
    local b = edit(vim.fn.tempname() .. "/claude-prompt-c.md")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "call `refresh` first" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    local ok, err = require("vergil").toggle()
    h.eq({ ok, err }, { false, "`refresh` doesn't look like a path" })
    h.eq(vim.api.nvim_get_current_line(), "call `refresh` first")
  end,
  ["command completion"] = function()
    h.eq(require("vergil.commands").complete("t", "Vergil t"), { "toggle" })
    h.eq(require("vergil.commands").complete("", "Vergil "), { "abort", "disable", "enable", "open", "pick", "preview", "range", "send", "snippet", "submit", "toggle" })
    h.eq(require("vergil.commands").complete("v", "Vergil open v"), { "vsplit" })
  end,
}
