local h = require("helpers")
local files = require("vergil.files")
local config = require("vergil.config")

local function list_sync(root)
  local got
  files.list(root, function(f) got = f end)
  vim.wait(5000, function() return got ~= nil end)
  return got
end

return {
  ["lists files relative to the root, sorted"] = function()
    local root = h.tree({ ["b.ts"] = "", ["a/x.lua"] = "", [".claude/skills/s/SKILL.md"] = "" })
    h.eq(list_sync(root), { ".claude/skills/s/SKILL.md", "a/x.lua", "b.ts" })
    files.invalidate(root)
  end,
  ["built-in scan skips .git and node_modules"] = function()
    local root = h.tree({ ["src/a.ts"] = "", ["node_modules/p/i.js"] = "", [".git/config"] = "", ["a/node_modules/x"] = "" })
    h.eq(files._builtin_scan(root, 100), { "src/a.ts" })
  end,
  ["git backend respects .gitignore"] = function()
    if vim.fn.executable("git") ~= 1 then return end
    local root = h.tree({ ["keep.ts"] = "", ["ignored.log"] = "", [".gitignore"] = "*.log\n" })
    vim.system({ "git", "init", "-q" }, { cwd = root }):wait()
    local got = list_sync(root)
    h.eq(vim.tbl_contains(got, "keep.ts"), true)
    h.eq(vim.tbl_contains(got, "ignored.log"), false)
    files.invalidate(root)
  end,
  ["custom command wins; empty output falls through"] = function()
    local root = h.tree({ ["real.ts"] = "" })
    config.set({ files = { command = { "printf", "custom/one.ts\\ncustom/two.ts\\n" } } })
    h.eq(list_sync(root), { "custom/one.ts", "custom/two.ts" })
    files.invalidate(root)
    config.set({ files = { command = { "true" } } })
    h.eq(list_sync(root), { "real.ts" })
    files.invalidate(root)
    config.set({})
  end,
  ["concurrent requests share one scan and get the same result"] = function()
    local root = h.tree({ ["a"] = "" })
    local results = {}
    for i = 1, 3 do files.list(root, function(f) results[i] = f end) end
    vim.wait(5000, function() return #results == 3 end)
    h.eq(results[1], results[2])
    h.eq(results[2], results[3])
    files.invalidate(root)
  end,
  ["cached results are served without rescanning"] = function()
    local root = h.tree({ ["a"] = "" })
    list_sync(root)
    vim.fn.writefile({}, root .. "/new")
    h.eq(list_sync(root), { "a" })
    h.eq(files.cached(root), { "a" })
    files.invalidate(root)
  end,
  ["invalidate drops the cache and answers waiters"] = function()
    local root = h.tree({ ["a"] = "" })
    local got
    files.list(root, function(f) got = f end)
    files.invalidate(root)
    h.eq(got, {})
    h.eq(files.cached(root), nil)
    vim.wait(200)
    h.eq(got, {}, "late result of the cancelled scan must be dropped")
  end,
  ["stale cache is refreshed in the background"] = function()
    local root = h.tree({ ["a"] = "" })
    list_sync(root)
    vim.fn.writefile({}, root .. "/b")
    local ttl = files.ttl_ms
    files.ttl_ms = -1
    h.eq(list_sync(root), { "a" }, "stale result served first")
    files.ttl_ms = ttl
    vim.wait(5000, function() return #(files.cached(root) or {}) == 2 end)
    h.eq(files.cached(root), { "a", "b" })
    files.invalidate(root)
  end,
}
