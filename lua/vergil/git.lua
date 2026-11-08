--- Git helpers for `:Vergil pick changed` and `:Vergil diff`. Git is
--- optional: without it, or outside a repository, both report why.
local M = {}

M.timeout_ms = 3000

local function result(res)
  if res.code ~= 0 then
    local msg = vim.trim((res.stderr or ""):gsub("^fatal: ", ""))
    if msg == "" and (res.code == 124 or (res.signal or 0) ~= 0) then
      return nil, "git took too long" -- killed by the timeout
    end
    return nil, msg ~= "" and msg or ("git exited with %d"):format(res.code)
  end
  return res
end

--- Runs git in the root. Without `cb`, waits (up to `M.timeout_ms`) and
--- returns the result; with it, returns at once and calls `cb(res, err)`
--- later, on the main loop. The picker uses the latter, so opening it never
--- waits on git.
---@param root string
---@param args string[]
---@param cb fun(res: vim.SystemCompleted?, err: string?)?
---@return vim.SystemCompleted?
---@return string? err
local function run(root, args, cb)
  local function fail(err)
    if cb then
      vim.schedule(function()
        cb(nil, err)
      end)
      return
    end
    return nil, err
  end
  if vim.fn.executable("git") ~= 1 then
    return fail("git is not installed")
  end
  local cmd = vim.list_extend({ "git", "-C", root }, args)
  if cb then
    local ok, err = pcall(vim.system, cmd, { text = true, timeout = M.timeout_ms }, function(res)
      vim.schedule(function()
        cb(result(res))
      end)
    end)
    if not ok then
      return fail(tostring(err))
    end
    return
  end
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(M.timeout_ms)
  end)
  if not ok then
    return nil, tostring(res)
  end
  return result(res)
end

--- Whether the root is in a git repository, without running git: true when
--- git is installed and a `.git` (directory or file) is above the root.
---@param root string
---@return boolean
---@return string? err why not
function M.in_repo(root)
  if vim.fn.executable("git") ~= 1 then
    return false, "git is not installed"
  end
  if not vim.fs.root(root, ".git") then
    return false, "not a git repository"
  end
  return true
end

--- Runs git and parses its output: synchronously without `cb` (returning
--- the parsed result), else in the background through `cb`.
local function either(root, args, parse, cb)
  if cb then
    run(root, args, function(res, err)
      if not res then
        return cb(nil, err)
      end
      cb(parse(res))
    end)
    return
  end
  local res, err = run(root, args)
  if not res then
    return nil, err
  end
  return parse(res)
end

--- A path from the repository's top, written relative to the session root
--- when it's inside it, else absolute.
local function from_top(top, path, root)
  local abs = top .. "/" .. path
  local rel = vim.fs.relpath(root, abs)
  if not rel then -- e.g. /tmp vs /private/tmp on macOS
    local real_root, real_top = vim.uv.fs_realpath(root), vim.uv.fs_realpath(top)
    rel = real_root and real_top and vim.fs.relpath(real_root, real_top .. "/" .. path)
  end
  return rel or abs
end

local LABELS = { M = "modified", A = "added", R = "renamed", C = "copied", T = "type changed", U = "conflict" }

--- What changed about a file, from its two-letter porcelain status.
local function label(xy)
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  if xy == "??" then
    return "untracked"
  end
  if x == "U" or y == "U" or xy == "AA" or xy == "DD" then
    return "conflict"
  end
  local staged = x ~= " " and LABELS[x]
  local unstaged = y ~= " " and LABELS[y]
  if staged and unstaged then
    return ("%s, staged + modified"):format(staged)
  end
  return staged and (staged .. ", staged") or unstaged or "changed"
end

---@class vergil.ChangedFile
---@field path string relative to the session root when inside it
---@field status string e.g. "modified", "added, staged", "untracked"

--- Files that differ from HEAD, plus untracked ones. Deleted files are left
--- out: there is nothing to attach.
---@param root string
---@param cb fun(files: vergil.ChangedFile[]?, err: string?)? run in the background
---@return vergil.ChangedFile[]? files
---@return string? err
function M.changed(root, cb)
  local top_args = { "rev-parse", "--show-toplevel" }
  local status_args = { "status", "--porcelain=v1", "-z", "--untracked-files=all" }
  if cb then
    -- Both at once; parse when both are in.
    local top, res, err, left = nil, nil, nil, 2
    local function done()
      left = left - 1
      if left == 0 then
        if top and res then
          cb(M._parse_changed(top, res, root))
        else
          cb(nil, err)
        end
      end
    end
    run(root, top_args, function(r, e)
      top, err = r, err or e
      done()
    end)
    run(root, status_args, function(r, e)
      res, err = r, err or e
      done()
    end)
    return
  end
  local top, err = run(root, top_args)
  if not top then
    return nil, err
  end
  local res, serr = run(root, status_args)
  if not res then
    return nil, serr
  end
  return M._parse_changed(top, res, root)
end

function M._parse_changed(top, res, root)
  local toplevel = vim.trim(top.stdout)
  local out = {}
  local fields = vim.split(res.stdout or "", "\0", { plain = true })
  local i = 1
  while i <= #fields do
    local entry = fields[i]
    i = i + 1
    if #entry > 3 then
      local xy, path = entry:sub(1, 2), entry:sub(4)
      if xy:find("[RC]") then
        i = i + 1 -- the original path of a rename or copy follows
      end
      if not xy:find("D") then
        out[#out + 1] = { path = from_top(toplevel, path, root), status = label(xy) }
      end
    end
  end
  return out
end

---@class vergil.Commit
---@field hash string abbreviated
---@field subject string
---@field author string
---@field date string relative, e.g. "2 days ago"

--- Recent commits that touched the root, newest first.
---@param root string
---@param limit integer?
---@param cb fun(commits: vergil.Commit[]?, err: string?)? run in the background
---@return vergil.Commit[]? commits
---@return string? err
function M.commits(root, limit, cb)
  local args = { "log", "-n", tostring(limit or 200), "--format=%h%x1f%s%x1f%an%x1f%ar", "--", "." }
  return either(root, args, M._parse_commits, cb)
end

function M._parse_commits(res)
  local out = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local hash, subject, author, date = line:match("^([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$")
    if hash then
      out[#out + 1] = { hash = hash, subject = subject, author = author, date = date }
    end
  end
  return out
end

--- A commit as prompt text: `` `abc1234` (Fix token refresh) ``. The agent
--- can run `git show` on the hash; the subject says what it is.
---@param commit vergil.Commit
---@return string
function M.reference(commit)
  local subject = vim.trim((commit.subject or ""):gsub("`", "'"))
  return subject == "" and ("`%s`"):format(commit.hash) or ("`%s` (%s)"):format(commit.hash, subject)
end

--- `git show` for a commit, for previews.
---@param root string
---@param hash string
---@param cb fun(lines: string[])? run in the background
---@return string[]?
function M.show(root, hash, cb)
  local args = { "show", "--stat", "--patch", "--no-color", "--no-ext-diff", hash, "--", "." }
  local function parse(res, err)
    if not res then
      return { err }
    end
    return vim.split((res.stdout or ""):gsub("\n$", ""), "\n", { plain = true })
  end
  if cb then
    run(root, args, function(res, err)
      cb(parse(res, err))
    end)
    return
  end
  return parse(run(root, args))
end

--- Completion candidates for `:Vergil diff`: `staged`, branches, tags and
--- recent commits. Empty outside a repository.
---@param root string
---@return string[]
function M.revisions(root)
  local out = { "staged" }
  local refs = run(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags", "refs/remotes" })
  for name in ((refs and refs.stdout) or ""):gmatch("[^\n]+") do
    if not name:find("/HEAD$") then
      out[#out + 1] = name
    end
  end
  for _, c in ipairs(M.commits(root, 30) or {}) do
    out[#out + 1] = c.hash
  end
  return out
end

---@class vergil.Branch
---@field name string e.g. "main" or "origin/feature"
---@field current boolean checked out
---@field remote boolean
---@field track string upstream status, e.g. "↑2 ↓1", or ""
---@field date string relative, e.g. "3 days ago"
---@field subject string of its last commit

--- Local and remote branches: the current one first, then by last commit.
---@param root string
---@param cb fun(branches: vergil.Branch[]?, err: string?)? run in the background
---@return vergil.Branch[]? branches
---@return string? err
function M.branches(root, cb)
  local args = {
    "for-each-ref",
    "--sort=-committerdate",
    "--format=%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:track,nobracket)%1f%(committerdate:relative)%1f%(subject)",
    "refs/heads",
    "refs/remotes",
  }
  return either(root, args, M._parse_branches, cb)
end

function M._parse_branches(res)
  local out = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local ref, name, head, track, date, subject =
      line:match("^([^\31]*)\31([^\31]*)\31([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$")
    if ref and not ref:find("/HEAD$") and name ~= "" then
      track = track:gsub("ahead (%d+)", "↑%1"):gsub("behind (%d+)", "↓%1"):gsub(", ", " ")
      local b = {
        name = name,
        current = head == "*",
        remote = ref:find("^refs/remotes/") ~= nil,
        track = track,
        date = date,
        subject = subject,
      }
      if b.current then
        table.insert(out, 1, b)
      else
        out[#out + 1] = b
      end
    end
  end
  return out
end

--- A branch as prompt text: `` `feature/login` (branch) ``. The suffix tells
--- vergil (and the agent) it's a branch, not a file.
---@param branch vergil.Branch|{ name: string }
---@return string
function M.branch_reference(branch)
  return ("`%s` (branch)"):format(branch.name)
end

--- The checked-out branch, or nil (e.g. detached HEAD).
---@param root string
---@return string?
function M.current_branch(root)
  local res = run(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local name = res and vim.trim(res.stdout or "")
  return name ~= "" and name or nil
end

---@class vergil.GitObject
---@field type "commit"|"branch"
---@field name string as written in the prompt
---@field hash string? full hash, for commits

--- What a word in the prompt names in git: a branch, or a commit (also a
--- tag or other revision). Asks git, so it's only used on `K` and `gd`.
---@param root string
---@param name string
---@return vergil.GitObject?
function M.object(root, name)
  if not name or #name > 200 or not name:match("^[%w%._/%-~^]+$") or name:sub(1, 1) == "-" then
    return nil
  end
  for _, ref in ipairs({ "refs/heads/" .. name, "refs/remotes/" .. name }) do
    if run(root, { "show-ref", "--verify", "--quiet", ref }) then
      return { type = "branch", name = name }
    end
  end
  local res = run(root, { "rev-parse", "--verify", "--quiet", name .. "^{commit}" })
  local hash = res and vim.trim(res.stdout or "")
  if hash and hash ~= "" then
    return { type = "commit", name = name, hash = hash }
  end
end

local function lines_of(res)
  return vim.split(((res and res.stdout) or ""):gsub("\n$", ""), "\n", { plain = true })
end

--- Markdown for `K` on a commit or branch.
---@param root string
---@param obj vergil.GitObject
---@return string[]
function M.object_hover(root, obj)
  if obj.type == "commit" then
    local head = run(root, { "show", "-s", "--format=%h%x1f%an%x1f%ar%x1f%B", obj.hash })
    local h, author, date, body = ((head and head.stdout) or ""):match("^([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$")
    local out = { ("**%s** · commit · %s, %s"):format(h or obj.name, author or "?", date or "?"), "" }
    vim.list_extend(out, vim.split(vim.trim(body or ""), "\n", { plain = true }))
    local stat = run(root, { "show", "--stat", "--format=", "--no-color", obj.hash })
    if stat and vim.trim(stat.stdout or "") ~= "" then
      vim.list_extend(out, { "", "```" })
      vim.list_extend(out, lines_of(stat))
      out[#out + 1] = "```"
    end
    return out
  end
  local info
  for _, b in ipairs(M.branches(root) or {}) do
    if b.name == obj.name then
      info = b
    end
  end
  local parts = { ("**%s** · branch"):format(obj.name) }
  if info then
    if info.current then
      parts[#parts + 1] = "checked out"
    end
    if info.track ~= "" then
      parts[#parts + 1] = info.track
    end
    parts[#parts + 1] = "last commit " .. info.date
  end
  local out = { table.concat(parts, " · "), "", "```" }
  vim.list_extend(out, lines_of(run(root, { "log", "--oneline", "--no-color", "-n", "15", obj.name, "--" })))
  out[#out + 1] = "```"
  return out
end

--- The text `gd` shows for a commit (`git show`) or branch (`git log`).
---@param root string
---@param obj vergil.GitObject
---@param cb fun(lines: string[])? run in the background
---@return string[]?
function M.object_lines(root, obj, cb)
  local args = obj.type == "commit" and { "show", "--stat", "--patch", "--no-color", "--no-ext-diff", obj.hash }
    or { "log", "--no-color", "--date=short", "--format=%h %ad %an%n    %s%n", "-n", "200", obj.name, "--" }
  if cb then
    run(root, args, function(res)
      cb(lines_of(res))
    end)
    return
  end
  return lines_of(run(root, args))
end

--- A read-only buffer named `vergil://git/<type>/<name>` showing a commit
--- or branch, for `gd` and `:Vergil open`.
---@param root string
---@param obj vergil.GitObject
---@return integer bufnr
---@return string uri
function M.object_buffer(root, obj)
  local uri = ("vergil://git/%s/%s"):format(obj.type, obj.type == "commit" and obj.hash:sub(1, 12) or obj.name)
  local bufnr = vim.fn.bufnr("^" .. vim.fn.escape(uri, "\\/.*$^~[]") .. "$")
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, uri)
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.object_lines(root, obj))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = "git"
  return bufnr, uri
end

--- The commit or branch named by the inline code at a position in a prompt
--- buffer: `` `abc1234` ``, `` `main` `` or `` `feature/x` (branch) ``. Only
--- words that aren't existing files are asked about.
---@param session vergil.Session
---@param row integer 0-based
---@param col integer 0-based
---@return vergil.GitObject?
---@return vergil.Reference?
function M.object_at(session, row, col)
  local parser = require("vergil.reference.parser")
  local ref = parser.at(parser.parse_buffer(session.bufnr), row, col)
  if not ref or ref.mode ~= "mention" or ref.start_line or ref.in_fence then
    return nil
  end
  local target = require("vergil.reference.resolver").resolve(ref, session.root)
  if target and target.exists then
    return nil
  end
  return M.object(session.root, ref.path), ref
end

--- `git diff` arguments for `:Vergil diff [staged|<rev>]`.
---@param what string? nil: all uncommitted changes; "staged"; or a revision or range
---@return string[]? args
---@return string? err
function M.diff_args(what)
  if what == nil or what == "" then
    return { "diff", "HEAD" }
  elseif what == "staged" then
    return { "diff", "--staged" }
  elseif what:sub(1, 1) == "-" then
    return nil, ("not a revision: %s"):format(what)
  end
  return { "diff", what }
end

--- The output of `git diff`, as lines.
---@param root string
---@param what string?
---@return string[]? lines
---@return string? err
---@return string? command the command shown in the header, e.g. `git diff HEAD`
function M.diff(root, what)
  local args, aerr = M.diff_args(what)
  if not args then
    return nil, aerr
  end
  local res, err = run(root, vim.list_extend(vim.deepcopy(args), { "--no-color", "--no-ext-diff", "--relative" }))
  if not res then
    return nil, err
  end
  local text = (res.stdout or ""):gsub("\n$", "")
  return text == "" and {} or vim.split(text, "\n", { plain = true }), nil, "git " .. table.concat(args, " ")
end

return M
