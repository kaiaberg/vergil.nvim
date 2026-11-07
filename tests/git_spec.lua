local h = require("helpers")
local git = require("vergil.git")

local function sh(dir, ...)
  local cmd = { "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", ... }
  local res = vim.system(cmd, { text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
  return res.stdout
end

--- A repository with one change of each kind, and a session root in `sub/`.
local function repo()
  local top = h.tree({
    ["a.lua"] = "old\n",
    ["b.lua"] = "gone soon\n",
    ["e.lua"] = "moved\n",
    ["sub/s.lua"] = "one\ntwo\n",
    ["sub/keep.lua"] = "keep\n",
  })
  sh(top, "init", "-q")
  sh(top, "add", ".")
  sh(top, "commit", "-q", "-m", "init")
  vim.fn.writefile({ "new" }, top .. "/a.lua") -- modified
  vim.fn.delete(top .. "/b.lua") -- deleted: left out
  vim.fn.writefile({ "c" }, top .. "/c.lua")
  sh(top, "add", "c.lua") -- added, staged
  sh(top, "mv", "e.lua", "f.lua") -- renamed, staged
  vim.fn.writefile({ "one", "TWO" }, top .. "/sub/s.lua") -- modified
  vim.fn.writefile({ "d" }, top .. "/sub/d.lua") -- untracked
  return top
end

local function text(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local ui = require("vergil.ui.picker")
ui.preview_min_width = 0

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

--- Opens the picker on a tab through the command and waits for it to load.
local function open(kind)
  feed(":Vergil pick " .. kind .. "<CR>")
  vim.wait(2000, function()
    local p = ui.current()
    return p and p.tab_spec().items ~= nil
  end)
  return assert(ui.current(), "picker did not open")
end

local function shown()
  return vim.api.nvim_buf_get_lines(ui.current().bufs.list, 0, -1, false)
end

--- A prompt in a fresh session rooted at `top`.
local function prompt_in(top, lines, name)
  ui.close()
  vim.cmd("silent! %bwipeout!")
  return h.prompt(top, lines, name)
end

local function contains(lines, line)
  return vim.tbl_contains(lines, line)
end

return {
  ["changed files with their status; deleted ones left out"] = function()
    local top = repo()
    local files = assert(git.changed(top))
    h.eq(vim.tbl_map(function(f) return f.path .. " (" .. f.status .. ")" end, files), {
      "a.lua (modified)",
      "c.lua (added, staged)",
      "f.lua (renamed, staged)",
      "sub/s.lua (modified)",
      "sub/d.lua (untracked)",
    })
  end,
  ["paths are relative to the session root, absolute outside it"] = function()
    local top = repo()
    local paths = vim.tbl_map(function(f) return f.path end, assert(git.changed(top .. "/sub")))
    h.truthy(contains(paths, "s.lua") and contains(paths, "d.lua"), vim.inspect(paths))
    local outside = vim.tbl_filter(function(p) return p:match("a%.lua$") end, paths)[1]
    h.eq(outside:sub(1, 1), "/", outside)
  end,
  ["outside a repository, or with nothing changed"] = function()
    local plain = h.tree({ ["x.lua"] = "" })
    local files, err = git.changed(plain)
    h.eq(files, nil)
    h.truthy(err:find("not a git repository", 1, true), err)
    prompt_in(plain, { "" }, "git-plain")
    local ok, perr = require("vergil.picker").pick("changed")
    h.eq(ok, false)
    h.truthy(perr:find("not a git repository", 1, true), perr)
    open("all")
    local names = vim.tbl_map(function(t) return t.name end, ui.current().opts.tabs)
    h.eq(names, { "All", "Files", "Skills" }, "no git tabs outside a repository")
    feed("<Esc>")
    local clean = h.tree({ ["x.lua"] = "x\n" })
    sh(clean, "init", "-q")
    sh(clean, "add", ".")
    sh(clean, "commit", "-q", "-m", "init")
    h.eq(git.changed(clean), {})
    prompt_in(clean, { "" }, "git-clean")
    open("changed")
    h.eq(shown(), { "  Nothing here" })
    feed("<Esc>")
  end,
  [":Vergil pick changed shows the status and attaches the choice"] = function()
    local top = repo()
    local b = prompt_in(top, { "Review" }, "git-pick")
    vim.cmd("silent write") -- an untracked file in the repository now
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    open("changed")
    h.eq(ui.current().tab_spec().name, "Changed")
    local list = shown()
    h.truthy(list[1]:match("^  a%.lua%s+modified$"), list[1])
    h.truthy(list[2]:match("^  c%.lua%s+added, staged$"), list[2])
    h.eq(vim.tbl_filter(function(l) return l:find("claude-prompt", 1, true) end, list), {}, "not the prompt itself")
    feed("<CR>")
    h.eq(text(b), { "Review @a.lua" })
  end,
  ["several files at once are inserted space-separated"] = function()
    local top = repo()
    local b = prompt_in(top, { "Review" }, "git-many")
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    open("changed")
    feed("<Tab><Down><Down><Tab><CR>")
    h.eq(text(b), { "Review @a.lua @sub/s.lua" }) -- Tab marks and moves down
  end,
  ["inserting mid-line keeps words apart"] = function()
    local top = repo()
    local b = prompt_in(top, { "Review this" }, "git-mid")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    open("changed")
    feed("<Tab><Tab><CR>")
    h.eq(text(b), { "R @a.lua @c.lua eview this" })
  end,
  [":Vergil diff inserts all uncommitted changes as a diff block"] = function()
    local top = repo()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(top, { "What do you think?" }, "git-diff")
    vim.cmd("Vergil diff")
    local lines = text(b)
    h.eq({ lines[1], lines[2], lines[3], lines[4] }, { "What do you think?", "", "Output of `git diff HEAD`:", "" })
    h.eq(lines[5], "```diff")
    h.truthy(contains(lines, "-old") and contains(lines, "+new"), vim.inspect(lines))
    h.truthy(contains(lines, "+c"), "staged changes are included")
    h.eq(lines[#lines - 1], "```")
    h.eq(lines[#lines], "")
    h.eq(vim.api.nvim_win_get_cursor(0)[1], #lines, "cursor after the block")
  end,
  [":Vergil diff staged, a revision, and errors"] = function()
    local top = repo()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(top, { "" }, "git-staged")
    h.eq({ require("vergil.diff").insert("staged") }, { true, nil })
    local lines = text(b)
    h.truthy(contains(lines, "Output of `git diff --staged`:"), vim.inspect(lines))
    h.truthy(contains(lines, "+c") and not contains(lines, "+new"), "only staged changes")
    h.eq({ require("vergil.diff").insert("--output=x") }, { false, "not a revision: --output=x" })
    local ok, err = require("vergil.diff").insert("no-such-rev")
    h.eq(ok, false)
    h.truthy(err:find("no-such-rev", 1, true), err)
    sh(top, "commit", "-q", "-m", "staged")
    h.eq({ require("vergil.diff").insert("staged") }, { false, "no changes (git diff --staged)" })
    h.eq({ require("vergil.diff").insert("HEAD~1") }, { true, nil })
  end,
  [":Vergil diff in a subdirectory root only shows changes there"] = function()
    local top = repo()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(top .. "/sub", { "" }, "git-sub")
    require("vergil.diff").insert()
    local lines = text(b)
    h.truthy(contains(lines, "+TWO"), vim.inspect(lines))
    h.truthy(not contains(lines, "+new"), "a.lua is outside the root")
    h.truthy(contains(lines, "--- a/s.lua"), "paths relative to the root")
  end,
  ["a large diff inserts with a warning"] = function()
    local top = repo()
    local big = {}
    for i = 1, 3000 do big[i] = ("line %d with some text to make it longer"):format(i) end
    vim.fn.writefile(big, top .. "/a.lua")
    vim.cmd("silent! %bwipeout!")
    h.prompt(top, { "" }, "git-big")
    local warned
    local notify = vim.notify
    vim.notify = function(msg) warned = msg end
    local ok = require("vergil.diff").insert()
    vim.notify = notify
    h.eq(ok, true)
    h.truthy(warned and warned:find("large diff", 1, true), warned)
  end,
  ["commits that touched the root, as references"] = function()
    local top = repo()
    sh(top, "add", "-A")
    sh(top, "commit", "-q", "-m", "Use `new` in a.lua")
    local commits = assert(git.commits(top))
    h.eq(vim.tbl_map(function(c) return c.subject end, commits), { "Use `new` in a.lua", "init" })
    h.eq(commits[1].author, "t")
    h.truthy(commits[1].hash:match("^%x+$") and #commits[1].hash >= 7, commits[1].hash)
    h.eq(git.reference(commits[1]), ("`%s` (Use 'new' in a.lua)"):format(commits[1].hash))
    h.eq(git.reference({ hash = "abc1234", subject = "" }), "`abc1234`")
    vim.fn.writefile({ "x" }, top .. "/a.lua")
    sh(top, "commit", "-q", "-am", "outside sub")
    local sub = vim.tbl_map(function(c) return c.subject end, assert(git.commits(top .. "/sub")))
    h.eq(sub, { "Use `new` in a.lua", "init" }, "only commits that touched the root")
    h.truthy(table.concat(git.show(top, commits[1].hash), "\n"):find("+new", 1, true))
  end,
  [":Vergil pick commits inserts references; <C-d> inserts the diff"] = function()
    local top = repo()
    sh(top, "add", "-A")
    sh(top, "commit", "-q", "-m", "Second")
    local hash = git.commits(top)[1].hash
    local b = prompt_in(top, { "See" }, "git-commits")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    open("commits")
    h.truthy(shown()[1]:match("^  " .. hash .. "  Second%s+t, "), shown()[1])
    feed("<CR>")
    h.eq(text(b), { ("See `%s` (Second)"):format(hash) })

    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "Both:" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    open("commits")
    feed("<Tab><Tab><CR>")
    h.truthy(text(b)[1]:match("^Both: `%x+` %(Second%) `%x+` %(init%)$"), text(b)[1])

    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "What changed?" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    open("commits")
    feed("<C-d>")
    local lines = text(b)
    h.eq(lines[3], ("Output of `git diff %s^!`:"):format(hash))
    h.truthy(contains(lines, "+new") and contains(lines, "+c"), vim.inspect(lines))
  end,
  [":Vergil diff completes staged, branches, tags and commits"] = function()
    local top = repo()
    sh(top, "tag", "v1")
    local branch = vim.trim(sh(top, "branch", "--show-current"))
    local hash = git.commits(top)[1].hash
    vim.cmd("silent! %bwipeout!")
    h.prompt(top, { "" }, "git-complete")
    local all = require("vergil.commands").complete("", "Vergil diff ")
    for _, want in ipairs({ "staged", branch, "v1", hash }) do
      h.truthy(contains(all, want), want .. " missing: " .. vim.inspect(all))
    end
    h.eq(require("vergil.commands").complete("v", "Vergil diff v"), { "v1" })
    h.truthy(contains(require("vergil.commands").complete("", "Vergil pick "), "commits"))
  end,
  ["a repository without commits"] = function()
    local empty = h.tree({ ["x.lua"] = "" })
    sh(empty, "init", "-q")
    local commits, err = git.commits(empty)
    h.eq(commits, nil)
    h.truthy(err and err ~= "", err)
    h.eq(git.revisions(empty), { "staged" })
  end,
  ["a file marked in one tab is marked in the others"] = function()
    local top = repo()
    local b = prompt_in(top, { "" }, "git-crosstab")
    open("changed")
    feed("<Tab>") -- a.lua, the first changed file
    feed("<M-1>")
    vim.wait(2000, function() return ui.current().tab_spec().items ~= nil end)
    local row = vim.tbl_filter(function(l) return l:find("a%.lua") end, shown())[1]
    h.truthy(row:match("^@ a%.lua"), row)
    feed("<M-4>") -- Commits
    feed("<Tab>")
    local marks = vim.api.nvim_buf_get_lines(ui.current().bufs.marks, 0, -1, false)
    h.truthy(marks[2]:match("^◆ `%x+` %(init%)%s+commit$"), marks[2])
    feed("<CR>")
    h.truthy(text(b)[1]:match("^@a%.lua `%x+` %(init%)$"), text(b)[1])
  end,
}
