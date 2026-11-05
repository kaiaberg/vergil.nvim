local h = require("helpers")
local picker = require("vergil.picker")

local root = h.tree({ ["src/a.lua"] = "one\ntwo\n", ["docs/my notes.md"] = "x\n", [".claude/commands/go.md"] = "Go now.\n" })

local function with_select(answer, fn)
  local orig = vim.ui.select
  local seen
  vim.ui.select = function(items, opts, cb)
    seen = { items = items, opts = opts }
    cb(answer(items))
  end
  require("vergil").setup({ root = root, picker = { backend = "select" } })
  local ok, err = pcall(fn, function() return seen end)
  vim.ui.select = orig
  require("vergil").setup({ root = root })
  if not ok then error(err, 0) end
end

local function line(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false)[1] end

return {
  ["pick attach inserts after the cursor, with a space when needed"] = function()
    with_select(function() return "src/a.lua" end, function()
      local b = h.prompt(root, { "look" }, "pick")
      vim.api.nvim_win_set_cursor(0, { 1, 3 })
      h.eq(picker.pick("attach"), true)
      vim.wait(1000, function() return line(b) ~= "look" end)
      h.eq(line(b), "look @src/a.lua")
    end)
  end,
  ["pick mention and quoted attachments"] = function()
    with_select(function(items) return vim.tbl_contains(items, "docs/my notes.md") and "docs/my notes.md" end, function()
      local b = h.prompt(root, { "" }, "pick")
      picker.pick("mention")
      vim.wait(1000, function() return line(b) ~= "" end)
      h.eq(line(b), "`docs/my notes.md`")
      b = h.prompt(root, { "" }, "pick")
      picker.pick("attach")
      vim.wait(1000, function() return line(b) ~= "" end)
      h.eq(line(b), '@"docs/my notes.md"')
    end)
  end,
  ["pick skills"] = function()
    with_select(function(items) return items[#items] end, function(seen)
      local b = h.prompt(root, { "then" }, "pick")
      vim.api.nvim_win_set_cursor(0, { 1, 3 })
      picker.pick("skills")
      h.truthy(vim.tbl_contains(vim.tbl_map(function(s) return s.name end, seen().items), "go"))
      h.truthy(line(b):match("^then /%S+ $"), line(b))
    end)
  end,
  ["cancelling inserts nothing"] = function()
    with_select(function() return nil end, function()
      local b = h.prompt(root, { "keep" }, "pick")
      picker.pick("attach")
      vim.wait(200)
      h.eq(line(b), "keep")
    end)
  end,
  ["select_for_path inserts a ranged mention at the position"] = function()
    local b = h.prompt(root, { "see " }, "pick")
    h.eq(require("vergil.range").select_for_path({ bufnr = b, win = 0, row = 0, col = 4, path = "src/a.lua", from_insert = false }), true)
    vim.wait(1000, function() return vim.api.nvim_win_get_config(0).relative ~= "" end)
    vim.api.nvim_feedkeys(vim.keycode("2G<CR>"), "xt", false)
    h.eq(line(b), "see `src/a.lua#L2`")
  end,
  ["errors"] = function()
    h.prompt(root, { "" }, "pick")
    h.eq({ picker.pick("nope") }, { false, 'unknown picker "nope"; expected attach, mention or skills' })
    h.errors(function() require("vergil").setup({ picker = { backend = "fzf" } }) end, "picker.backend")
  end,
}
