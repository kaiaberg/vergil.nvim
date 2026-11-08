local h = require("helpers")
local submit = require("vergil.submit")

local root = h.tree({ ["src/a.lua"] = "x = 1\n" })

local function setup(lines)
  vim.cmd("silent! %bwipeout!")
  local b = h.prompt(root, lines or { "hello @src/a.lua" }, "submit")
  local exits, asked = {}, {}
  submit.exit = function(cmd)
    exits[#exits + 1] = cmd
  end
  submit.confirm = function(msg)
    asked[#asked + 1] = msg
    return submit._answer
  end
  return b, exits, asked
end

local function on_disk(path)
  return vim.fn.readfile(path)
end

return {
  ["submit writes the prompt and quits"] = function()
    local b, exits, asked = setup()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "final text" })
    h.eq(submit.submit(), true)
    h.eq(on_disk(vim.api.nvim_buf_get_name(b)), { "final text" })
    h.eq({ exits, #asked }, { { "qall" }, 0 })
  end,
  ["other modified buffers: save all"] = function()
    local b, exits, asked = setup()
    vim.cmd.split(vim.fn.fnameescape(root .. "/src/a.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 2" })
    vim.cmd.wincmd("p")
    submit._answer = 1
    h.eq(submit.submit(), true)
    h.truthy(asked[1]:find("1 other modified buffer:", 1, true), asked[1])
    h.truthy(asked[1]:find("a.lua", 1, true))
    h.eq(on_disk(root .. "/src/a.lua"), { "x = 2" })
    h.eq(exits, { "qall" })
    vim.fn.writefile({ "x = 1" }, root .. "/src/a.lua")
  end,
  ["other modified buffers: discard only when chosen"] = function()
    local b, exits = setup()
    vim.cmd.split(vim.fn.fnameescape(root .. "/src/a.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 3" })
    submit._answer = 2
    h.eq(submit.submit(), true)
    h.eq(on_disk(root .. "/src/a.lua"), { "x = 1" })
    h.eq(exits, { "qall!" })
  end,
  ["cancel keeps everything open"] = function()
    local b, exits = setup()
    vim.cmd.split(vim.fn.fnameescape(root .. "/src/a.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 4" })
    submit._answer = 3
    h.eq({ submit.submit() }, { false, "cancelled" })
    h.eq(exits, {})
    h.eq(vim.bo.modified, true)
    vim.cmd("silent! edit!")
  end,
  ["submit from a file opened with gd finds the prompt"] = function()
    local b, exits = setup()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/a.lua"))
    h.eq(submit.submit(), true)
    h.eq(exits, { "qall" })
  end,
  ["submit with the selector open removes the typed # first"] = function()
    local b, exits = setup({ "see @src/a.lua" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("A#"), "xt", false)
    vim.wait(1000, function()
      return vim.api.nvim_win_get_config(0).relative ~= ""
    end)
    h.eq(submit.submit(), true)
    h.eq(on_disk(vim.api.nvim_buf_get_name(b)), { "see @src/a.lua" })
  end,
  ["abort exits with cquit and doesn't write the prompt"] = function()
    local b, exits = setup()
    vim.cmd("silent write")
    local before = on_disk(vim.api.nvim_buf_get_name(b))
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "changed" })
    h.eq(submit.abort(), true)
    h.eq(exits, { "cquit" })
    h.eq(on_disk(vim.api.nvim_buf_get_name(b)), before)
  end,
  ["abort writes back the prompt as it was when opened"] = function()
    vim.cmd("silent! %bwipeout!")
    local path = root .. "/claude-prompt-original.md"
    vim.fn.writefile({ "ORIGINAL @src/a.lua", "" }, path, "b")
    vim.cmd.edit(vim.fn.fnameescape(path))
    local b = vim.api.nvim_get_current_buf()
    h.truthy(require("vergil.session").is_enabled(b))
    local exits = {}
    submit.exit = function(cmd)
      exits[#exits + 1] = cmd
    end
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "edited and written" })
    vim.cmd("silent write")
    require("vergil").disable(b) -- a re-enable must not take a new copy
    require("vergil").enable(b)
    h.eq(submit.abort(), true)
    h.eq(exits, { "cquit" })
    h.eq(vim.fn.readfile(path, "b"), { "ORIGINAL @src/a.lua", "" })
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(path)
  end,
  ["abort still asks about other modified buffers"] = function()
    local b, exits, asked = setup()
    vim.cmd.split(vim.fn.fnameescape(root .. "/src/a.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 5" })
    submit._answer = 3
    h.eq({ submit.abort() }, { false, "cancelled" })
    h.truthy(asked[1]:find("Save before aborting?", 1, true))
    h.eq(exits, {})
    vim.cmd("silent! edit!")
  end,
  ["no prompt buffer"] = function()
    vim.cmd("silent! %bwipeout!")
    vim.cmd.edit(vim.fn.tempname() .. ".txt")
    h.eq({ submit.submit() }, { false, "no prompt buffer (use :Vergil enable)" })
  end,
}
