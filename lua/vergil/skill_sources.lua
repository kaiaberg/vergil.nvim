--- Discovers skills and commands for the `/` menu from an agent's skill
--- sources (`vergil.SkillSource`, see `:help vergil-agents`).
---
--- Rules:
--- - Sources are read in order; the first item with a name wins, and the
---   later ones become its `shadows` (shown in hover). Within one source, a
---   repeated name keeps the most recently modified file (e.g. several
---   installed versions of a plugin).
--- - A relative glob is searched in the root, then each parent up to the
---   repository root; `~` and absolute globs are searched once.
--- - `name = "dir"`: the frontmatter `name`, else the file's directory.
---   `name = "path"`: the part of the path from the glob's first `**` on (or
---   just the file name without one), without `.md`, with `/` as `:`
---   (`commands/**/*.md` names `commands/sub/deep.md` `sub:deep`).
--- - `prefix` goes before the name; `{n}` is what the n-th wildcard (`*` or
---   `**`) of the glob matched. With `on_clash`, a taken name gets that prefix
---   instead of being skipped.
--- - Without a description, the body's first non-empty line is used.
local frontmatter = require("vergil.frontmatter")

local M = {}

--- Overridable for tests.
M.home = nil

local uv = vim.uv

local function home()
  return M.home or vim.fs.normalize("~")
end

local file_cache = {} ---@type table<string, { sig: string, mtime: number, fields: table, body: string[] }>

--- Frontmatter of a file, reparsed only when its mtime or size changes.
local function read(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  local sig = ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
  local hit = file_cache[path]
  if hit and hit.sig == sig then
    return hit
  end
  local fields, body = frontmatter.read(path)
  hit = { sig = sig, mtime = st.mtime.sec + st.mtime.nsec / 1e9, fields = fields, body = vim.list_slice(body, 1, 40) }
  file_cache[path] = hit
  return hit
end

local function item(path, name, kind, origin, fields, body)
  local desc = fields.description
  if type(desc) ~= "string" or desc == "" then
    desc = frontmatter.first_line(body)
  end
  return {
    name = name,
    description = desc and vim.trim(desc) or nil,
    argument_hint = type(fields["argument-hint"]) == "string" and fields["argument-hint"] or nil,
    kind = kind,
    origin = origin,
    path = path,
    user_invocable = fields["user-invocable"] ~= false,
    model_invocable = fields["disable-model-invocation"] ~= true,
  }
end

--- The root and its parents up to the repository root (or just the root).
local function project_dirs(root)
  local dirs = { root }
  local repo = vim.fs.root(root, ".git")
  if repo and repo ~= root then
    for dir in vim.fs.parents(root) do
      dirs[#dirs + 1] = dir
      if dir == repo then
        break
      end
    end
  end
  return dirs
end

--- A Lua pattern matching what `glob` matches, capturing each wildcard, and
--- how many leading path segments a `path` name drops: those before the
--- first `**`, or all but the file name.
---@param glob string
---@return string pattern
---@return integer skip
local function compile(glob)
  local star2 = glob:find("**", 1, true)
  local base = star2 and glob:sub(1, star2 - 1) or (glob:match("^(.*/)") or "")
  local _, skip = base:gsub("/", "")
  local pat, i = "^", 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if glob:sub(i, i + 2) == "**/" then
      pat, i = pat .. "(.-)", i + 3 -- `**/` also matches nothing
    elseif glob:sub(i, i + 1) == "**" then
      pat, i = pat .. "(.-)", i + 2
    elseif c == "*" then
      pat, i = pat .. "([^/]*)", i + 1
    elseif c == "?" then
      pat, i = pat .. "([^/])", i + 1
    else
      pat, i = pat .. vim.pesc(c), i + 1
    end
  end
  return pat .. "$", skip
end

local function expand_prefix(prefix, captures)
  return (prefix:gsub("{(%d+)}", function(n)
    return (captures[tonumber(n)] or ""):gsub("/$", "")
  end))
end

--- Items from one source, in path order; a repeated name keeps the newest file.
local function scan(source, root)
  local glob = source.glob
  local origin = source.origin
  local bases
  if glob:sub(1, 1) == "~" then
    glob = home() .. glob:sub(2)
    bases = { "" }
    origin = origin or "personal"
  elseif glob:sub(1, 1) == "/" then
    bases = { "" }
    origin = origin or "system"
  else
    bases = vim.tbl_map(function(d)
      return d .. "/"
    end, project_dirs(root))
    origin = origin or "project"
  end
  local kind = source.kind or (source.name == "dir" and "skill" or "command")
  local out, at = {}, {}
  for _, base in ipairs(bases) do
    local full = base .. glob
    local pat, skip = compile(full)
    for _, path in ipairs(vim.fn.glob(full, true, true)) do
      local captures = { path:match(pat) }
      local f = captures[1] ~= nil and read(path)
      if f then
        local name
        if source.name == "dir" then
          name = type(f.fields.name) == "string" and f.fields.name ~= "" and f.fields.name
            or vim.fs.basename(vim.fs.dirname(path))
        else
          local parts = vim.split(path, "/", { plain = true })
          name = table.concat(vim.list_slice(parts, skip + 1), ":"):gsub("%.md$", "")
        end
        name = expand_prefix(source.prefix or "", captures) .. name
        local it = item(path, name, kind, origin, f.fields, f.body)
        it.mtime = f.mtime
        local i = at[name]
        if not i then
          out[#out + 1] = it
          at[name] = #out
        elseif it.mtime > out[i].mtime then
          out[i] = it
        end
      end
    end
  end
  return out
end

--- All skills and commands from a list of sources, one item per name, each
--- with `shadows` listing the same-named definitions it beats.
---@param root string
---@param sources vergil.SkillSource[]
---@return vergil.Skill[]
function M.discover(root, sources)
  local by_name, order = {}, {}
  for _, source in ipairs(sources) do
    for _, c in ipairs(scan(source, root)) do
      c.mtime = nil
      if by_name[c.name] and source.on_clash then
        c.name = source.on_clash .. c.name
      end
      local winner = by_name[c.name]
      if not winner then
        by_name[c.name] = c
        order[#order + 1] = c.name
      else
        winner.shadows = winner.shadows or {}
        table.insert(winner.shadows, c)
      end
    end
  end
  local out = {}
  for _, name in ipairs(order) do
    out[#out + 1] = by_name[name]
  end
  return out
end

return M
