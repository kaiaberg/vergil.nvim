--- Git helpers for `:Vergil pick changed` and `:Vergil diff`. Git is
--- optional: without it, or outside a repository, both report why.
local M = {}

M.timeout_ms = 3000

---@return vim.SystemCompleted?
---@return string? err
local function run(root, args)
  if vim.fn.executable("git") ~= 1 then
    return nil, "git is not installed"
  end
  local cmd = vim.list_extend({ "git", "-C", root }, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(M.timeout_ms)
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    local msg = vim.trim((res.stderr or ""):gsub("^fatal: ", ""))
    return nil, msg ~= "" and msg or ("git exited with %d"):format(res.code)
  end
  return res
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
---@return vergil.ChangedFile[]? files
---@return string? err
function M.changed(root)
  local top, err = run(root, { "rev-parse", "--show-toplevel" })
  if not top then
    return nil, err
  end
  local res, serr = run(root, { "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  if not res then
    return nil, serr
  end
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
---@return vergil.Commit[]? commits
---@return string? err
function M.commits(root, limit)
  local res, err = run(root, { "log", "-n", tostring(limit or 200), "--format=%h%x1f%s%x1f%an%x1f%ar", "--", "." })
  if not res then
    return nil, err
  end
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
---@return string[]
function M.show(root, hash)
  local res, err = run(root, { "show", "--stat", "--patch", "--no-color", "--no-ext-diff", hash, "--", "." })
  if not res then
    return { err }
  end
  return vim.split((res.stdout or ""):gsub("\n$", ""), "\n", { plain = true })
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
