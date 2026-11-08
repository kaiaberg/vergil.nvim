--- Asynchronous file discovery for a root directory.
---
--- Backends, first that runs wins: the configured command, `rg`, `fd`,
--- `git ls-files`, then a built-in scan. `rg`, `fd` and git respect
--- `.gitignore`. A backend that runs and finds nothing is an answer, not a
--- failure: in a root that `.gitignore` ignores entirely (`*`, or a root
--- inside a repo that ignores it), the list is empty rather than falling
--- through to the built-in scan, which would show ignored files such as
--- `.env`. Showing ignored files takes an explicit `files.command`.
---
--- Results are cached per root and refreshed in the background once stale,
--- so typing never waits on a scan after the first one. Concurrent requests
--- share one scan, and results of an outdated scan are discarded.
local M = {}

M.ttl_ms = 30000
M.timeout_ms = 10000

---@class vergil.FileCache
---@field files string[]? relative paths, sorted
---@field backend string? which backend produced them
---@field time integer? hrtime in ms of the last completed scan
---@field generation integer incremented per scan; stale results are dropped
---@field running vim.SystemObj|true|nil
---@field waiters fun(files: string[])[]

local caches = {} ---@type table<string, vergil.FileCache>

local function now_ms()
  return math.floor(vim.uv.hrtime() / 1e6)
end

local function backends()
  local custom = require("vergil.config").options.files.command
  local list = {}
  if custom then
    list[#list + 1] = { name = "command", cmd = custom }
  end
  -- rg exits 1 when there are no files, 2 on errors.
  list[#list + 1] = { name = "rg", cmd = { "rg", "--files", "--hidden", "--glob", "!.git" }, empty_code = 1 }
  list[#list + 1] = { name = "fd", cmd = { "fd", "--type", "f", "--hidden", "--exclude", ".git" } }
  list[#list + 1] = { name = "git", cmd = { "git", "ls-files", "--cached", "--others", "--exclude-standard" } }
  return list
end

local SKIP_DIRS = { [".git"] = true, ["node_modules"] = true, [".venv"] = true, ["__pycache__"] = true }

--- Built-in scan: no .gitignore support, so it skips common heavy directories.
local function builtin_scan(root, limit)
  local files = {}
  for name, type in
    vim.fs.dir(root, {
      depth = 20,
      skip = function(dir)
        return not SKIP_DIRS[vim.fs.basename(dir)]
      end,
    })
  do
    if type == "file" then
      files[#files + 1] = name
      if #files >= limit then
        break
      end
    end
  end
  return files
end

local function finish(root, cache, generation, files, backend)
  if cache.generation ~= generation then
    return -- a newer scan was started; drop this result
  end
  table.sort(files)
  cache.files, cache.backend, cache.time, cache.running = files, backend, now_ms(), nil
  local waiters = cache.waiters
  cache.waiters = {}
  for _, cb in ipairs(waiters) do
    cb(files)
  end
end

local function scan(root, cache)
  cache.generation = cache.generation + 1
  local generation = cache.generation
  local list = backends()
  local i = 0
  local function try_next()
    i = i + 1
    local b = list[i]
    if not b then
      cache.running = true
      vim.schedule(function()
        finish(root, cache, generation, builtin_scan(root, 200000), "builtin")
      end)
      return
    end
    if vim.fn.executable(b.cmd[1]) ~= 1 then
      return try_next()
    end
    local ok, obj = pcall(vim.system, b.cmd, { cwd = root, text = true, timeout = M.timeout_ms }, function(res)
      vim.schedule(function()
        if cache.generation ~= generation then
          return
        end
        local stdout = res.stdout or ""
        local ran = res.code == 0 or (b.empty_code and res.code == b.empty_code and stdout == "")
        if not ran then
          return try_next() -- an error, a timeout, or not a git repository
        end
        finish(root, cache, generation, vim.split(stdout, "\n", { trimempty = true }), b.name)
      end)
    end)
    if not ok then
      return try_next()
    end
    cache.running = obj
  end
  try_next()
end

local function get_cache(root)
  local cache = caches[root]
  if not cache then
    cache = { generation = 0, waiters = {} }
    caches[root] = cache
  end
  return cache
end

--- Calls `cb(files)` with the root's files: immediately (on the next tick)
--- when cached, after the first scan otherwise. Stale caches are served as
--- they are and refreshed in the background.
---@param root string
---@param cb fun(files: string[])
function M.list(root, cb)
  local cache = get_cache(root)
  if cache.files then
    if not cache.running and now_ms() - cache.time > M.ttl_ms then
      scan(root, cache)
    end
    local files = cache.files
    vim.schedule(function()
      cb(files)
    end)
    return
  end
  table.insert(cache.waiters, cb)
  if not cache.running then
    scan(root, cache)
  end
end

--- Cached files without scanning, or nil.
---@param root string
---@return string[]?
function M.cached(root)
  local cache = caches[root]
  return cache and cache.files
end

--- Starts a scan now so the first completion doesn't wait.
---@param root string
function M.prefetch(root)
  local cache = get_cache(root)
  if not cache.files and not cache.running then
    scan(root, cache)
  end
end

--- Drops the cache and stops a running scan; pending callbacks get `{}`.
---@param root string?
function M.invalidate(root)
  for r, cache in pairs(caches) do
    if root == nil or r == root then
      cache.generation = cache.generation + 1
      if type(cache.running) == "table" then
        pcall(cache.running.kill, cache.running, 15)
      end
      local waiters = cache.waiters
      caches[r] = nil
      for _, cb in ipairs(waiters) do
        cb({})
      end
    end
  end
end

--- A query for a path outside the root, browsed one directory at a time
--- like a shell: `~`, `~/co`, `/usr/lo`. Returns the directory as written
--- and the partial name after it; nil for queries searched in the root.
---@param query string
---@return string? dir ending in `/`
---@return string? name
function M.outside_query(query)
  if query == "~" then
    return "~/", ""
  end
  if query:sub(1, 2) ~= "~/" and query:sub(1, 1) ~= "/" then
    return nil
  end
  return query:match("^(.*/)([^/]*)$")
end

M.max_dir_entries = 5000
M.max_dir_matches = 1000

--- Entries of `dir` matching `name`, ranked fuzzy (sorted when `name` is
--- empty), as paths written like `dir`, with a trailing `/` on
--- directories. Dotfiles only once `name` starts with `.`.
---@param dir string as written, e.g. `~/code/`
---@param name string
---@return string[] paths
---@return integer[][] positions matched character indexes into each path
function M.list_dir(dir, name)
  local abs = vim.fs.normalize(dir)
  local names = {}
  pcall(function()
    for entry, type in vim.fs.dir(abs) do
      if name:sub(1, 1) == "." or entry:sub(1, 1) ~= "." then
        local is_dir = type == "directory" or (type == "link" and vim.fn.isdirectory(abs .. "/" .. entry) == 1)
        names[#names + 1] = entry .. (is_dir and "/" or "")
        if #names >= M.max_dir_entries then
          break
        end
      end
    end
  end)
  local positions = {}
  if name == "" then
    table.sort(names)
    names = vim.list_slice(names, 1, M.max_dir_matches)
  else
    local res = vim.fn.matchfuzzypos(names, name, { limit = M.max_dir_matches })
    names = res[1]
    local offset = vim.fn.strchars(dir)
    for i, pos in ipairs(res[2]) do
      positions[i] = vim.tbl_map(function(p)
        return p + offset
      end, pos)
    end
  end
  return vim.tbl_map(function(n)
    return dir .. n
  end, names), positions
end

M._builtin_scan = builtin_scan -- exposed for tests

--- Which backend produced the root's cache, for `:checkhealth`.
---@param root string
---@return string?
function M.backend(root)
  local cache = caches[root]
  return cache and cache.backend
end

return M
