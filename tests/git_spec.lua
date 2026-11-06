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
    local clean = h.tree({ ["x.lua"] = "x\n" })
    sh(clean, "init", "-q")
    sh(clean, "add", ".")
    sh(clean, "commit", "-q", "-m", "init")
    h.eq(git.changed(clean), {})
    vim.cmd("silent! %bwipeout!")
    h.prompt(clean, { "" }, "git-clean")
    h.eq({ require("vergil.picker").pick("changed") }, { false, "no changed files" })
  end,
  [":Vergil pick changed shows the status and attaches the choice"] = function()
    local top = repo()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(top, { "Review" }, "git-pick")
    vim.cmd("silent write") -- an untracked file in the repository now
    require("vergil").setup({ root = top, picker = { backend = "select" } })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    local shown
    local select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      shown = vim.tbl_map(opts.format_item, items)
      on_choice(items[1])
    end
    local ok, err = require("vergil.picker").pick("changed")
    vim.ui.select = select
    h.eq({ ok, err }, { true, nil })
    h.eq(shown[1], "a.lua  (modified)")
    h.eq(shown[2], "c.lua  (added, staged)")
    h.eq(vim.tbl_filter(function(s) return s:find("claude-prompt", 1, true) end, shown), {}, "not the prompt itself")
    h.eq(text(b), { "Review @a.lua" })
    require("vergil").setup({ root = top })
  end,
  ["several files at once are inserted space-separated"] = function()
    local top = repo()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(top, { "Review" }, "git-many")
    require("vergil").setup({ root = top, picker = { backend = "select" } })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    local backend = require("vergil.picker.select")
    local pick_files = backend.pick_files
    backend.pick_files = function(files, kind, api)
      api.choose_many(kind, { files[1], files[4] })
    end
    require("vergil.picker").pick("changed")
    backend.pick_files = pick_files
    h.eq(text(b), { "Review @a.lua @sub/s.lua" })
    require("vergil").setup({ root = top })
  end,
  ["inserting mid-line keeps words apart"] = function()
    local top = repo()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(top, { "Review this" }, "git-mid")
    require("vergil").setup({ root = top, picker = { backend = "select" } })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local backend = require("vergil.picker.select")
    local pick_files = backend.pick_files
    backend.pick_files = function(files, kind, api)
      api.choose_many(kind, { files[1], files[2] })
    end
    require("vergil.picker").pick("changed")
    backend.pick_files = pick_files
    h.eq(text(b), { "R @a.lua @c.lua eview this" })
    require("vergil").setup({ root = top })
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
}
