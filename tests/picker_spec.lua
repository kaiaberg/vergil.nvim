local h = require("helpers")
-- Don't resize the screen here: a headless Neovim keeps its 80x24 grid, and
-- the next full redraw (e.g. after diagnostics) writes past it and crashes.
require("vergil.ui.picker").preview_min_width = 0
local picker = require("vergil.picker")
local ui = require("vergil.ui.picker")

local root = h.tree({
  ["src/a.lua"] = "one\ntwo\n",
  ["src/b.lua"] = "bee\n",
  ["docs/my notes.md"] = "x\n",
  [".claude/commands/go.md"] = "Go now.\n",
})

--- Types keys. "x" leaves Insert mode once they run out ("x!" would wait
--- for more input, which a headless test doesn't have), so text typed into
--- the picker starts with `A`; its keys work in Normal mode too.
local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function line(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
end

--- Waits until the open picker's tab has loaded, and returns the picker.
local function loaded()
  vim.wait(2000, function()
    local p = ui.current()
    return p and p.tab_spec().items ~= nil
  end)
  return assert(ui.current(), "picker did not open")
end

local function list()
  return vim.api.nvim_buf_get_lines(ui.current().bufs.list, 0, -1, false)
end

--- Opens the picker the way users do (a command), so its Insert mode is
--- active before the next keys arrive, and waits for the tab to load.
local function open(kind)
  feed(":Vergil pick" .. (kind and (" " .. kind) or "") .. "<CR>")
  return loaded()
end

local function tab_name()
  return ui.current().tab_spec().name
end

--- A prompt buffer with `text`, the cursor at `col` (Normal mode).
local function prompt(text, col, name, setup)
  ui.close()
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    feed("<Esc>")
  end
  vim.cmd("silent! %bwipeout!")
  local b = h.prompt(root, { text }, name or "pick")
  if setup then
    require("vergil").setup(vim.tbl_extend("force", { root = root }, setup))
  end
  vim.api.nvim_win_set_cursor(0, { 1, col or 0 })
  return b
end

return {
  ["Files: type to filter, Enter attaches after the cursor"] = function()
    local b = prompt("look", 3)
    open("attach")
    h.eq(tab_name(), "Files")
    feed("Aa.lua")
    h.eq(list()[1]:match("^%s*(%S+)"), "src/a.lua")
    feed("<CR>")
    h.eq(line(b), "look @src/a.lua")
    h.eq(ui.current(), nil, "closed")
    h.eq(vim.api.nvim_get_current_buf(), b, "back in the prompt")
  end,
  ["mention mode, quoting, and <C-t> switching"] = function()
    local b = prompt("")
    open("mention")
    feed("Anotes<CR>")
    h.eq(line(b), "`docs/my notes.md`")
    b = prompt("", 0, "pick-quoted")
    open("attach")
    feed("Anotes<CR>")
    h.eq(line(b), '@"docs/my notes.md"')
    b = prompt("", 0, "pick-toggle")
    open("attach")
    feed("Aa.lua<C-t>")
    h.truthy(vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]:find("Mention", 1, true))
    feed("<CR>")
    h.eq(line(b), "`src/a.lua`")
  end,
  ["Skills tab inserts /name with a trailing space"] = function()
    local b = prompt("then", 3)
    open("skills")
    h.eq(tab_name(), "Skills")
    feed("Ago<CR>")
    h.eq(line(b), "then /go ")
  end,
  ["tabs cycle, keep the query, and can be chosen by number"] = function()
    prompt("")
    open("all")
    h.eq(tab_name(), "All")
    feed("Aa.l")
    feed("<C-Left>")
    h.eq(tab_name(), "Skills", "previous from the first is the last (no git tabs here)")
    feed("<C-Right>")
    h.eq(tab_name(), "All")
    feed("<C-l>")
    loaded()
    h.eq(tab_name(), "Files")
    h.eq(ui.current().query, "a.l", "query kept")
    h.eq(list()[1]:match("^%s*(%S+)"), "src/a.lua")
    feed("<M-3>")
    h.eq(tab_name(), "Skills")
    feed("<M-1>")
    h.eq(tab_name(), "All")
    feed("<Esc>")
  end,
  ["All lists files and skills with their kind"] = function()
    local b = prompt("")
    open()
    local all = table.concat(list(), "\n")
    h.truthy(all:find("/go  Go now%.%s+command"), all)
    h.truthy(all:find("src/b%.lua%s+file"), all)
    feed("A/go<CR>")
    h.eq(line(b), "/go ")
  end,
  ["Tab marks several items, Enter inserts them all"] = function()
    local b = prompt("Look:", 4)
    open("attach")
    feed("Asrc/<Tab><Tab>")
    h.eq(#ui.current().marked, 2)
    feed("<CR>")
    h.truthy(line(b):match("^Look: @src/[ab]%.lua @src/[ab]%.lua$"), line(b))
  end,
  ["Esc cancels and inserts nothing"] = function()
    local b = prompt("keep", 3)
    open("attach")
    local wins = #vim.api.nvim_list_wins()
    feed("Aa<Esc>")
    h.eq(line(b), "keep")
    h.eq(ui.current(), nil)
    h.truthy(#vim.api.nvim_list_wins() < wins, "windows closed")
    h.eq(vim.api.nvim_get_current_buf(), b)
  end,
  ["preview shows the selected file"] = function()
    prompt("")
    open("attach")
    feed("Aa.lua")
    vim.wait(500, function()
      return (vim.api.nvim_buf_get_lines(ui.current().bufs.preview, 0, 1, false)[1] or "") == "one"
    end)
    h.eq(vim.api.nvim_buf_get_lines(ui.current().bufs.preview, 0, 2, false), { "one", "two" })
    feed("<Esc>")
  end,
  ["<C-g> expands what you're typing into the picker, replacing it"] = function()
    local preset = { keymaps = { preset = true } }
    local b = prompt("see", 2, "pick-expand", preset)
    feed("A @src/a<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "Files", "src/a" })
    feed("<CR>")
    h.eq(line(b), "see @src/a.lua")
    b = prompt("x", 0, "pick-expand-skill", preset)
    feed("A /g<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "Skills", "g" })
    feed("<CR>")
    h.eq(line(b), "x /go ")
    b = prompt("plain", 4, "pick-expand-none", preset)
    feed("A <C-g>")
    loaded()
    h.eq(tab_name(), "All")
    feed("<Esc>")
    require("vergil").setup({ root = root })
  end,
  ["picker.on_trigger opens the picker on @ instead of completion"] = function()
    local b = prompt("ask", 2, "pick-trigger", { picker = { on_trigger = true } })
    -- "!": stay in Insert mode after the keys, as when typing.
    feed("A @")
    loaded()
    h.eq(tab_name(), "Files")
    feed("Ab.lua<CR>")
    h.eq(line(b), "ask @src/b.lua")
    feed("A me@x")
    vim.wait(100)
    vim.wait(0)
    h.eq(ui.current(), nil, "not inside a word")
    feed("<Esc>")
    require("vergil").setup({ root = root })
  end,
  ["select_for_path inserts a ranged mention at the position"] = function()
    local b = prompt("see ")
    h.eq(require("vergil.range").select_for_path({ bufnr = b, win = 0, row = 0, col = 4, path = "src/a.lua", from_insert = false }), true)
    vim.wait(1000, function() return vim.api.nvim_win_get_config(0).relative ~= "" end)
    feed("2G<CR>")
    h.eq(line(b), "see `src/a.lua#L2`")
  end,
  ["errors"] = function()
    prompt("")
    h.eq({ picker.pick("nope") }, { false, 'unknown picker "nope"; expected all, attach, mention, skills, changed, commits' })
    h.eq({ picker.pick("commits") }, { false, "not a git repository (or any of the parent directories): .git" })
    h.errors(function() require("vergil").setup({ picker = { on_trigger = "yes" } }) end, "picker.on_trigger")
    vim.cmd.enew()
    h.eq({ picker.pick() }, { false, "not enabled in this buffer (use :Vergil enable)" })
  end,
  ["a mark keeps the mode it was marked with; the marked list shows the text"] = function()
    local b = prompt("Look:", 4, "pick-modes")
    open("attach")
    feed("Asrc/a.lua<Tab>")
    feed("<C-t>")
    feed("Ssrc/b.lua<Tab>")
    local marks = vim.api.nvim_buf_get_lines(ui.current().bufs.marks, 0, -1, false)
    h.truthy(marks[1]:match("^@ @src/a%.lua%s+attach$"), marks[1])
    h.truthy(marks[2]:match("^` `src/b%.lua`%s+mention$"), marks[2])
    h.eq(vim.api.nvim_win_get_config(ui.current().wins.marks).title[1][1], " Marked (2) ")
    feed("Ssrc/")
    local rows = list()
    h.truthy(vim.tbl_contains(vim.tbl_map(function(l) return l:match("^(.)%s+src/a%.lua") end, rows), "@"), vim.inspect(rows))
    h.truthy(vim.tbl_contains(vim.tbl_map(function(l) return l:match("^(.)%s+src/b%.lua") end, rows), "`"), vim.inspect(rows))
    feed("<CR>")
    h.eq(line(b), "Look: @src/a.lua `src/b.lua`")
  end,
  ["skills look the same in either mode, with their own sign"] = function()
    local b = prompt("", 0, "pick-skillmark")
    open("all")
    feed("A<C-t>/go<Tab>")
    local marks = vim.api.nvim_buf_get_lines(ui.current().bufs.marks, 0, -1, false)
    h.truthy(marks[1]:match("^/ /go%s+skill$"), marks[1])
    feed("<CR>")
    h.eq(line(b), "/go ")
  end,
  ["<C-o> joins with spaces, commas, or one per line"] = function()
    local b = prompt("", 0, "pick-join")
    open("attach")
    feed("Asrc/a<Tab><C-u>src/b<Tab><C-o>")
    h.truthy(vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]:find("joined by commas", 1, true))
    feed("<CR>")
    h.eq(line(b), "@src/a.lua, @src/b.lua")
    b = prompt("", 0, "pick-lines")
    open("attach")
    feed("Asrc/a<Tab><C-u>src/b<Tab><C-o><C-o><CR>")
    h.eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "@src/a.lua", "@src/b.lua" })
  end,
  ["picker.keys changes vergil's keys too"] = function()
    local b = prompt("", 0, "pick-keys", { picker = { keys = { toggle_mode = { "<C-y>" }, next_tab = { "<C-x>" } } } })
    open("attach")
    h.truthy(vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]:find("(C-y: mention)", 1, true))
    feed("<C-x>")
    h.eq(tab_name(), "Skills")
    feed("<C-x>")
    loaded()
    h.eq(tab_name(), "All")
    feed("Aa.lua<C-y><CR>")
    h.eq(line(b), "`src/a.lua`")
    require("vergil").setup({ root = root })
  end,
}
