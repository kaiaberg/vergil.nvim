--- Discovers Claude Code skills and commands for the `/` menu.
---
--- Sources and rules, from https://code.claude.com/docs/en/skills and from
--- probing Claude Code 2.1.318's own `/` menu (docs/m0-findings.md):
--- - Project: `.claude/skills/<name>/SKILL.md` and `.claude/commands/**/*.md`
---   in the root and every parent up to the repository root.
--- - Personal: the same under `~/.claude`. Enterprise: the same under the
---   managed settings directory.
--- - A skill's command is its frontmatter `name`, else its directory name.
---   Commands use their path: `commands/sub/deep.md` is `/sub:deep`.
--- - Precedence on a name clash: a skill beats a command; then enterprise
---   beats personal beats project.
--- - Without a description, the menu shows the body's first non-empty line.
--- - Synced claude.ai skills (`~/.claude/skills/synced/<bucket>/<name>/`)
---   appear under their bare name, or as `anthropic-skills:<name>` when that
---   name is taken. Undocumented; best effort.
--- - Plugin skills are always `/<plugin>:<name>`. Best effort: plugins are
---   found through `enabledPlugins` in settings and the marketplace manifests.
local frontmatter = require("vergil.frontmatter")

local M = {}

--- Overridable for tests.
M.home = nil
M.managed_dirs = { "/Library/Application Support/ClaudeCode", "/etc/claude-code" }

local uv = vim.uv

local function home()
  return M.home or vim.fs.normalize("~")
end

local file_cache = {} ---@type table<string, { sig: string, fields: table, body: string[] }>

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
  hit = { sig = sig, fields = fields, body = vim.list_slice(body, 1, 40) }
  file_cache[path] = hit
  return hit
end

local function glob(pattern)
  return vim.fn.glob(pattern, true, true)
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

--- Skills and commands under one `.claude`-style directory.
local function scan_dir(base, origin, prefix)
  local out = {}
  for _, path in ipairs(glob(base .. "/skills/*/SKILL.md")) do
    local f = read(path)
    if f then
      local dir = vim.fs.basename(vim.fs.dirname(path))
      local name = type(f.fields.name) == "string" and f.fields.name ~= "" and f.fields.name or dir
      out[#out + 1] = item(path, (prefix or "") .. name, "skill", origin, f.fields, f.body)
    end
  end
  local cmd_root = base .. "/commands/"
  for _, path in ipairs(glob(cmd_root .. "**/*.md")) do
    local f = read(path)
    if f then
      local rel = path:sub(#cmd_root + 1):gsub("%.md$", ""):gsub("/", ":")
      out[#out + 1] = item(path, (prefix or "") .. rel, "command", origin, f.fields, f.body)
    end
  end
  return out
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

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local ok2, data = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
  return ok2 and type(data) == "table" and data or nil
end

--- Directories of enabled plugins: { name, dir } (best effort).
local function plugin_dirs(root)
  local enabled = {}
  for _, settings in ipairs({
    home() .. "/.claude/settings.json",
    root .. "/.claude/settings.json",
    root .. "/.claude/settings.local.json",
  }) do
    local data = read_json(settings)
    if data and type(data.enabledPlugins) == "table" then
      for key, on in pairs(data.enabledPlugins) do
        enabled[key] = on == true
      end
    end
  end
  local markets = read_json(home() .. "/.claude/plugins/known_marketplaces.json") or {}
  local out = {}
  for key, on in pairs(enabled) do
    local plugin, market = key:match("^(.-)@(.+)$")
    if on and plugin then
      local candidates = {}
      -- Installed copies: cache/<marketplace>/<plugin>/<version>/, newest first.
      local versions = glob(("%s/.claude/plugins/cache/%s/%s/*/"):format(home(), market, plugin))
      table.sort(versions, function(a, b)
        return a > b
      end)
      vim.list_extend(candidates, versions)
      local loc = markets[market] and markets[market].installLocation
      if loc then
        local manifest = read_json(loc .. "/.claude-plugin/marketplace.json")
        for _, p in ipairs(manifest and manifest.plugins or {}) do
          if p.name == plugin and type(p.source) == "string" then
            candidates[#candidates + 1] = vim.fs.normalize(vim.fs.joinpath(loc, p.source))
          end
        end
        candidates[#candidates + 1] = loc .. "/plugins/" .. plugin
        candidates[#candidates + 1] = loc .. "/external_plugins/" .. plugin
      end
      for _, dir in ipairs(candidates) do
        dir = dir:gsub("/$", "")
        if uv.fs_stat(dir) then
          local meta = read_json(dir .. "/.claude-plugin/plugin.json")
          out[#out + 1] = { name = meta and meta.name or plugin, dir = dir }
          break
        end
      end
    end
  end
  return out
end

local RANK_KIND = { skill = 1, command = 2 }
local RANK_ORIGIN = { enterprise = 1, personal = 2, project = 3 }

--- All skills and commands for a root, one item per command name, each with
--- `shadows` listing the same-named definitions it beats.
---@param root string
---@return vergil.Skill[]
function M.discover(root)
  local candidates = {}
  for _, dir in ipairs(M.managed_dirs) do
    vim.list_extend(candidates, scan_dir(dir .. "/.claude", "enterprise"))
  end
  vim.list_extend(candidates, scan_dir(home() .. "/.claude", "personal"))
  for _, dir in ipairs(project_dirs(root)) do
    vim.list_extend(candidates, scan_dir(dir .. "/.claude", "project"))
  end

  local by_name, order = {}, {}
  for _, c in ipairs(candidates) do
    local cur = by_name[c.name]
    if not cur then
      by_name[c.name] = c
      order[#order + 1] = c.name
    else
      local better = RANK_KIND[c.kind] < RANK_KIND[cur.kind]
        or (RANK_KIND[c.kind] == RANK_KIND[cur.kind] and RANK_ORIGIN[c.origin] < RANK_ORIGIN[cur.origin])
      local winner, loser = cur, c
      if better then
        winner, loser = c, cur
      end
      winner.shadows = winner.shadows or {}
      table.insert(winner.shadows, loser)
      vim.list_extend(winner.shadows, loser.shadows or {})
      loser.shadows = nil
      by_name[c.name] = winner
    end
  end

  -- Synced skills: bare name unless taken, then namespaced.
  for _, path in ipairs(glob(home() .. "/.claude/skills/synced/*/*/SKILL.md")) do
    local f = read(path)
    if f then
      local dir = vim.fs.basename(vim.fs.dirname(path))
      local name = type(f.fields.name) == "string" and f.fields.name ~= "" and f.fields.name or dir
      if by_name[name] then
        name = "anthropic-skills:" .. name
      end
      if not by_name[name] then
        by_name[name] = item(path, name, "skill", "synced", f.fields, f.body)
        order[#order + 1] = name
      end
    end
  end

  for _, p in ipairs(plugin_dirs(root)) do
    for _, c in ipairs(scan_dir(p.dir, "plugin", p.name .. ":")) do
      if not by_name[c.name] then
        by_name[c.name] = c
        order[#order + 1] = c.name
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
