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
  -- Let a deferred return to Insert mode (after a picker) happen first.
  vim.wait(20)
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
  ["an agent without attach or skills: mentions, no toggle, no Skills tab"] = function()
    local b = prompt("look", 3, "pick-plain", { agents = { claude = { match = { "claude-prompt-*.md" } } } })
    open("attach")
    local names = vim.tbl_map(function(t)
      return t.name
    end, ui.current().opts.tabs)
    h.eq(vim.tbl_contains(names, "Skills"), false, table.concat(names, ","))
    local title = vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]
    h.truthy(title:find("Mention", 1, true) and not title:find("C-t", 1, true), title)
    feed("Aa.lua<C-t><CR>")
    h.eq(line(b), "look `src/a.lua`")
    require("vergil").setup({ root = root })
  end,
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
    feed("<C-g>2")
    h.eq(tab_name(), "Files")
    h.eq(ui.current().query, "a.l", "the digit isn't typed")
    feed("<C-g>9")
    h.eq(tab_name(), "Files", "no ninth tab")
    feed("<C-g><Esc>")
    h.truthy(ui.current(), "<Esc> after the prefix cancels it, not the picker")
    h.eq(tab_name(), "Files")
    feed("<C-g>3")
    h.eq(tab_name(), "Skills")
    feed("<Esc>")
  end,
  -- Through `ui.footer` rather than a resized screen: setting 'columns' in a
  -- headless Neovim 0.12 overruns its screen grid and can crash it.
  ["the footer hints the go-to-tab prefix, and drops it when narrow"] = function()
    local keys = vim.tbl_extend("force", ui.default_keys, {})
    local actions = { "C-t mention", "C-o join" }
    local wide = ui.footer(keys, actions, 5, 200)
    h.eq(wide, " Enter insert · Tab mark · C-t mention · C-o join · C-Left/Right, C-g 1-5 tabs · Esc close ")
    h.eq(#actions, 2, "the caller's list is left alone")
    h.truthy(ui.footer(keys, {}, 12, 200):find("C-g 1-9 tabs", 1, true), "at most 9")
    h.truthy(ui.footer(keys, {}, 1, 200):find("C-Left/Right tabs", 1, true), "one tab: nothing to go to")
    local nogoto = vim.tbl_extend("force", keys, { goto_tab = { "<M-%d>" } })
    h.truthy(ui.footer(nogoto, {}, 5, 200):find("C-Left/Right tabs", 1, true), "no prefix")
    local width = vim.fn.strdisplaywidth(" Enter insert · Tab mark · C-Left/Right, C-g 1-5 tabs · Esc close ")
    h.eq(
      ui.footer(keys, actions, 5, width),
      " Enter insert · Tab mark · C-Left/Right, C-g 1-5 tabs · Esc close ",
      "actions go first"
    )
    h.eq(
      ui.footer(keys, actions, 5, width - 1),
      " Enter insert · Tab mark · C-Left/Right tabs · Esc close ",
      "then the prefix"
    )
    h.eq(ui.footer(keys, actions, 5, 20), " Enter insert · C-Left/Right tabs · Esc close ", "then mark")
    prompt("")
    open()
    local f = vim.api.nvim_win_get_config(ui.current().wins.prompt).footer
    h.truthy(f[1][1]:find("tabs", 1, true), "the picker uses it")
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
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    h.truthy(
      #lines == 2 and lines[1]:match("^Look: @src/[ab]%.lua$") and lines[2]:match("^@src/[ab]%.lua$"),
      vim.inspect(lines)
    )
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
  ["<C-g> after a plain word searches for it; Enter replaces it, Esc keeps it"] = function()
    local preset = { keymaps = { preset = true } }
    local b = prompt("look", 3, "pick-expand-word", preset)
    feed("A src/a<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "All", "src/a" })
    feed("<CR>")
    h.eq(line(b), "look @src/a.lua")
    b = prompt("look", 3, "pick-expand-word-esc", preset)
    feed("A src/a<C-g>")
    loaded()
    feed("<Esc>")
    h.eq(line(b), "look src/a")
    require("vergil").setup({ root = root })
  end,
  ["<C-g> inside a word searches what's before the cursor, replaces it all"] = function()
    local preset = { keymaps = { preset = true } }
    local b = prompt("x", 0, "pick-expand-inside-word", preset)
    feed("A src/bxyz<Left><Left><Left><C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "All", "src/b" })
    feed("<CR>")
    h.eq(line(b), "x @src/b.lua")
    b = prompt("x", 0, "pick-expand-inside-ref", preset)
    feed("A @src/bxyz now<Left><Left><Left><Left><Left><Left><Left><C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "Files", "src/b" })
    feed("<CR>")
    h.eq(line(b), "x @src/b.lua now")
    require("vergil").setup({ root = root })
  end,
  ["<C-g> in Normal mode: on a reference it searches and replaces, else All"] = function()
    local preset = { keymaps = { preset = true } }
    local b = prompt("see @src/b.lua now", 6, "pick-expand-normal", preset)
    feed("<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "Files", "src/b.lua" })
    feed("Sa.lua<CR>")
    h.eq(line(b), "see @src/a.lua now")
    h.eq(vim.api.nvim_get_mode().mode, "n")
    b = prompt("run /g. now", 6, "pick-expand-normal-skill", preset)
    feed("<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "Skills", "g" })
    feed("<CR>")
    h.eq(line(b), "run /go . now")
    -- On a word: the whole word, without the punctuation around it.
    b = prompt("check (b), then", 8, "pick-expand-normal-word", preset)
    feed("<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "All", "b" })
    feed("<Esc>")
    h.eq(line(b), "check (b), then", "Esc keeps it")
    feed("<C-g>")
    loaded()
    feed("<CR>")
    -- Spaced: agents only see `@` after whitespace.
    h.eq(line(b), "check ( @src/b.lua ), then")
    -- On whitespace: empty, inserted there.
    b = prompt("plain text", 5, "pick-expand-normal-space", preset)
    feed("<C-g>")
    loaded()
    h.eq({ tab_name(), ui.current().query }, { "All", "" })
    feed("Aa.lua<CR>")
    h.eq(line(b), "plain @src/a.lua text")
    require("vergil").setup({ root = root })
  end,
  ["the picker returns to the mode it was opened from"] = function()
    local preset = { keymaps = { preset = true } }
    --- Where Insert mode was (re)entered in `b` after the picker opened.
    local function entries(b)
      local seen = {}
      vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = b,
        callback = function()
          seen[#seen + 1] = vim.api.nvim_win_get_cursor(0)
        end,
      })
      return seen
    end
    -- From Insert mode: Enter comes back in Insert mode after the text.
    local b = prompt("see", 2, "pick-mode-insert", preset)
    local seen = entries(b)
    feed("A @src/a<C-g>")
    loaded()
    local before = #seen
    feed("<CR>")
    vim.wait(500, function()
      return #seen > before
    end)
    h.eq(line(b), "see @src/a.lua")
    h.eq(seen[#seen], { 1, 14 }, "Insert mode at the end of the text")
    -- From Insert mode: Esc comes back in Insert mode where it was opened.
    b = prompt("one two", 2, "pick-mode-insert-esc", preset)
    seen = entries(b)
    feed("a <C-g>")
    loaded()
    before = #seen
    feed("<Esc>")
    vim.wait(500, function()
      return #seen > before
    end)
    h.eq(#seen > before, true, "back in Insert mode")
    h.eq(seen[#seen], { 1, 4 }, "where the picker was opened")
    -- From Normal mode: stays in Normal mode, cursor on the inserted text.
    b = prompt("look", 3, "pick-mode-normal", preset)
    seen = entries(b)
    open("attach")
    feed("Aa.lua<CR>")
    vim.wait(100)
    h.eq(#seen, 0, "no Insert mode")
    h.eq(vim.api.nvim_get_mode().mode, "n")
    h.eq(vim.api.nvim_win_get_cursor(0), { 1, 14 }, "on the last inserted character")
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
  ["~ and / browse outside the project; Enter opens a directory"] = function()
    local home = h.tree({ ["code/x.lua"] = "ex\n", ["notes.md"] = "hello\n", [".secret"] = "s\n" })
    local saved = vim.env.HOME
    vim.env.HOME = home
    local ok, err = pcall(function()
      local b = prompt("", 0, "pick-home")
      open("attach")
      feed("A~")
      h.eq(
        vim.tbl_map(function(l)
          return l:match("^%s*(%S+)")
        end, list()),
        { "~/code/", "~/notes.md" }
      )
      feed("<CR>")
      h.truthy(ui.current(), "a directory opens instead of closing")
      h.eq(line(ui.current().bufs.prompt), "~/code/")
      h.eq(list()[1]:match("^%s*(%S+)"), "~/code/x.lua")
      feed("<CR>")
      h.eq(line(b), "@~/code/x.lua")

      b = prompt("", 0, "pick-home-dir")
      open("attach")
      feed("A~/co<Tab><CR>")
      h.eq(line(b), "@~/code/", "a marked directory is inserted")

      b = prompt("", 0, "pick-home-all")
      open()
      h.eq(tab_name(), "All")
      feed("A~/no<CR>")
      h.eq(line(b), "@~/notes.md")
      b = prompt("", 0, "pick-slash-all")
      open()
      feed("A/go<CR>")
      h.eq(line(b), "/go ", "/ still searches skills in All")

      b = prompt("", 0, "pick-abs")
      open("attach")
      feed("A" .. home .. "/no<CR>")
      h.eq(line(b), "@" .. home .. "/notes.md")

      b = prompt("see", 2, "pick-home-expand", { keymaps = { preset = true } })
      feed("A @~/no<C-g>")
      loaded()
      h.eq(list()[1]:match("^%s*(%S+)"), "~/notes.md")
      feed("<CR>")
      h.eq(line(b), "see @~/notes.md")
    end)
    vim.env.HOME = saved
    require("vergil").setup({ root = root })
    assert(ok, err)
  end,
  ["select_for_path inserts a ranged mention at the position"] = function()
    local b = prompt("see ")
    h.eq(
      require("vergil.range").select_for_path({
        bufnr = b,
        win = 0,
        row = 0,
        col = 4,
        path = "src/a.lua",
        from_insert = false,
      }),
      true
    )
    vim.wait(1000, function()
      return vim.api.nvim_win_get_config(0).relative ~= ""
    end)
    feed("2G<CR>")
    h.eq(line(b), "see `src/a.lua#L2`")
  end,
  ["errors"] = function()
    prompt("")
    h.eq(
      { picker.pick("nope") },
      { false, 'unknown picker "nope"; expected all, attach, mention, skills, changed, branches, commits' }
    )
    h.eq({ picker.pick("commits") }, { false, "not a git repository" })
    h.errors(function()
      require("vergil").setup({ picker = { on_trigger = "yes" } })
    end, "picker.on_trigger")
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
    h.truthy(
      vim.tbl_contains(
        vim.tbl_map(function(l)
          return l:match("^(.)%s+src/a%.lua")
        end, rows),
        "@"
      ),
      vim.inspect(rows)
    )
    h.truthy(
      vim.tbl_contains(
        vim.tbl_map(function(l)
          return l:match("^(.)%s+src/b%.lua")
        end, rows),
        "`"
      ),
      vim.inspect(rows)
    )
    feed("<CR>")
    h.eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Look: @src/a.lua", "`src/b.lua`" })
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
  ["<C-o> joins one per line by default, then with spaces or commas"] = function()
    local b = prompt("", 0, "pick-lines")
    open("attach")
    h.truthy(vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]:find("joined one per line", 1, true))
    feed("Asrc/a<Tab><C-u>src/b<Tab><CR>")
    h.eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "@src/a.lua", "@src/b.lua" })
    b = prompt("", 0, "pick-spaces")
    open("attach")
    feed("Asrc/a<Tab><C-u>src/b<Tab><C-o><CR>")
    h.eq(line(b), "@src/a.lua @src/b.lua")
    b = prompt("", 0, "pick-join")
    open("attach")
    feed("Asrc/a<Tab><C-u>src/b<Tab><C-o><C-o>")
    h.truthy(vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]:find("joined by commas", 1, true))
    feed("<CR>")
    h.eq(line(b), "@src/a.lua, @src/b.lua")
  end,
  ["picker.remember: confirm keeps the choices, Esc doesn't; always and never"] = function()
    local function title()
      return vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]
    end
    vim.fn.delete(require("vergil.picker").state_file)
    -- confirm (the default): a confirmed choice is kept, a cancelled one not.
    local b = prompt("", 0, "pick-rem1", { picker = { remember = "confirm" } })
    open("files")
    feed("A<C-t><C-o>src/a<CR>")
    h.eq(line(b), "`src/a.lua`")
    prompt("", 0, "pick-rem2", { picker = { remember = "confirm" } })
    open("files")
    h.truthy(title():find("Mention", 1, true) and title():find("joined by spaces", 1, true), title())
    feed("<C-t><C-o><Esc>")
    prompt("", 0, "pick-rem3", { picker = { remember = "confirm" } })
    open("files")
    h.truthy(title():find("Mention", 1, true) and title():find("joined by spaces", 1, true), "Esc kept: " .. title())
    feed("<Esc>")
    -- `@@`/`:Vergil pick attach` ask for a mode; that alone isn't remembered.
    b = prompt("", 0, "pick-rem4", { picker = { remember = "confirm" } })
    open("attach")
    h.truthy(title():find("Attach", 1, true), title())
    feed("Asrc/a<CR>")
    prompt("", 0, "pick-rem5", { picker = { remember = "confirm" } })
    open("files")
    h.truthy(title():find("Mention", 1, true), "still the toggled mode: " .. title())
    feed("<Esc>")
    -- always: also when closing.
    prompt("", 0, "pick-rem6", { picker = { remember = "always" } })
    open("files")
    feed("<C-t><Esc>")
    prompt("", 0, "pick-rem7", { picker = { remember = "always" } })
    open("files")
    h.truthy(title():find("Attach", 1, true), title())
    feed("<Esc>")
    -- never: always the defaults.
    prompt("", 0, "pick-rem8", { picker = { remember = "never" } })
    open("files")
    h.truthy(title():find("Attach", 1, true) and title():find("joined one per line", 1, true), title())
    feed("<Esc>")
    h.errors(function()
      require("vergil").setup({ picker = { remember = "sometimes" } })
    end, "picker.remember")
    require("vergil").setup({ root = root })
  end,
  ["picker.keys changes vergil's keys too"] = function()
    local b = prompt("", 0, "pick-keys", {
      picker = { keys = { toggle_mode = { "<C-y>" }, next_tab = { "<C-x>" }, goto_tab = { "<C-s>", "<M-%d>" } } },
    })
    open("attach")
    h.truthy(vim.api.nvim_win_get_config(ui.current().wins.prompt).title[1][1]:find("(C-y: mention)", 1, true))
    feed("<C-x>")
    h.eq(tab_name(), "Skills")
    feed("<C-x>")
    loaded()
    h.eq(tab_name(), "All")
    feed("<C-s>3")
    h.eq(tab_name(), "Skills", "a goto_tab prefix")
    feed("<M-1>")
    h.eq(tab_name(), "All", "a goto_tab pattern")
    feed("<C-s>2")
    loaded()
    feed("Aa.lua<C-y><CR>")
    h.eq(line(b), "`src/a.lua`")
    require("vergil").setup({ root = root })
  end,
  ["picker.tabs sets the order and which tabs exist, All included"] = function()
    prompt("", 0, "pick-tabs", { picker = { tabs = { "skills", "all", "files" } } })
    open()
    h.eq(
      vim.tbl_map(function(t)
        return t.name
      end, ui.current().opts.tabs),
      { "Skills", "All", "Files" }
    )
    h.eq(tab_name(), "All")
    feed("<Esc>")
    prompt("", 0, "pick-tabs-noskills", { picker = { tabs = { "all", "files" } } })
    open()
    h.eq(
      vim.tbl_filter(function(l)
        return l:match("^%s*/go")
      end, list()),
      {},
      "no skills in All"
    )
    feed("<Esc>")
    h.eq({ picker.pick("skills") }, { false, "the skills tab is turned off (picker.tabs)" })
    prompt("", 0, "pick-tabs-noall", { picker = { tabs = { "files", "skills" } } })
    open()
    h.eq(tab_name(), "Files", "no All tab: the first one")
    feed("<Esc>")
    h.errors(function()
      require("vergil").setup({ picker = { tabs = { "files", "nope" } } })
    end, 'unknown picker tab "nope"')
    h.errors(function()
      require("vergil").setup({ picker = { tabs = { "files", "files" } } })
    end, "listed twice")
    h.errors(function()
      require("vergil").setup({ preview = { on_repeat = "maybe" } })
    end, "preview.on_repeat")
    require("vergil").setup({ root = root })
  end,
  ["the picker uses 'winborder', or rounded when it has no top edge"] = function()
    local function border()
      local cfg = vim.api.nvim_win_get_config(ui.current().wins.list)
      return cfg.border and cfg.border[1]
    end
    local saved = vim.o.winborder
    local ok, err = pcall(function()
      for value, top in pairs({ double = "╔", single = "┌", none = "╭", shadow = "╭", [""] = "╭" }) do
        vim.o.winborder = value
        prompt("")
        open()
        h.eq(border(), top, ("winborder=%q"):format(value))
        ui.close()
      end
    end)
    vim.o.winborder = saved
    assert(ok, err)
  end,
  ["picker buffers have their own filetypes"] = function()
    prompt("")
    local p = open()
    local fts = {}
    for name, buf in pairs(p.bufs) do
      fts[name] = vim.bo[buf].filetype
    end
    h.eq(fts.prompt, "vergil-picker")
    h.eq(fts.list, "vergil-picker-list")
    h.eq(fts.preview, "vergil-picker-preview")
    h.eq(fts.marks, "vergil-picker-marks")
    ui.close()
  end,
}
