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
    h.eq(session.matches("/claude-prompt-x/notes.md"), nil)
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
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = { "VergilEnable", "VergilDisable" },
      callback = function(ev)
        events[#events + 1] = ev.match
      end,
    })
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
  ["agents match by file name, or by full path with a /"] = function()
    require("vergil").setup({
      agents = {
        txt = { match = { "prompt-*.txt" } },
        deep = { match = { ".tool/editor/*.md" } },
        abs = { match = { "/srv/prompts/*.md" } },
      },
    })
    h.eq(session.matches("/tmp/prompt-1.txt").key, "txt")
    h.eq(session.matches("/tmp/claude-prompt-1.md"), nil)
    h.eq(session.matches("/home/me/.tool/editor/x.md").key, "deep")
    h.eq(session.matches("/home/me/.tool/other/x.md"), nil)
    h.eq(session.matches("/srv/prompts/a.md").key, "abs")
    h.eq(session.matches("/x/srv/prompts/a.md"), nil, "an absolute glob is anchored")
    require("vergil").setup({})
    h.eq(session.matches("/tmp/claude-prompt-1.md").key, "claude")
  end,
  ["each prompt gets its own agent; :Vergil enable picks one or plain"] = function()
    require("vergil").setup({
      agents = { claude = h.recipe("claude"), other = { match = { "other-*.md" } } },
    })
    local agents = require("vergil.agents")
    local a = edit(vim.fn.tempname() .. "/claude-prompt-a.md")
    local b = edit(vim.fn.tempname() .. "/other-b.md")
    h.eq({ session.get(a).agent, session.get(b).agent }, { "claude", "other" })
    h.eq(agents.for_buffer(a).attach.prefix, "@")
    h.eq(agents.for_buffer(b).attach, nil, "no attach: mentions only")
    local c = edit(vim.fn.tempname() .. "/notes.md")
    h.eq(session.is_enabled(c), false)
    vim.cmd("Vergil enable")
    h.eq(session.get(c).agent, "plain")
    vim.cmd("Vergil enable claude")
    h.eq(session.get(c).agent, "claude")
    require("vergil").setup({})
  end,
  [":Vergil enable refuses an unnamed buffer with a hint"] = function()
    vim.cmd.enew()
    local b = vim.api.nvim_get_current_buf()
    local warned, notify = {}, vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned[#warned + 1] = msg
      end
    end
    local ok, err = pcall(vim.cmd, "Vergil enable")
    vim.notify = notify
    assert(ok, err)
    h.eq(session.is_enabled(b), false)
    h.eq(vim.b[b].vergil_enabled, nil)
    h.eq(warned, { "vergil: this buffer has no name; name it first, e.g. :file draft.md" })
    vim.cmd.file(vim.fn.fnameescape(vim.fn.tempname() .. "-draft.md"))
    vim.cmd("Vergil enable")
    h.eq(session.is_enabled(b), true, "works once named")
    vim.cmd("bwipeout!")
  end,
  ["setup validates options"] = function()
    h.errors(function()
      require("vergil").setup({ mention = { format = "nope" } })
    end, "mention.format")
    h.errors(function()
      require("vergil").setup({ root = 1 })
    end, "root")
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
    h.eq(require("vergil.commands").complete("", "Vergil "), {
      "abort",
      "diff",
      "disable",
      "enable",
      "open",
      "pick",
      "preview",
      "range",
      "send",
      "snippet",
      "submit",
      "toggle",
    })
    h.eq(require("vergil.commands").complete("v", "Vergil open v"), { "vsplit" })
  end,
}
