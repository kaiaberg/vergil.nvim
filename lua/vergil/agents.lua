--- Agents, as the user defines them in `agents` (see `:help vergil-agents`).
---
--- vergil knows no agent itself. Each entry says which prompt files belong to
--- an agent (`match`), how it writes attachments (`attach`), and where its
--- skills live (`skills`). A prompt buffer gets the first agent whose rules
--- match its path; `:Vergil enable` without a match uses `M.plain`.
local M = {}

---@class vergil.AttachSpec
---@field prefix string starts an attachment, e.g. "@"
---@field quote string? wraps a path that needs it, e.g. '"'; nil: such paths can't be attached
---@field strip string characters the agent drops from the end of an unquoted path
---@field ranges "ignored"? a `#L3-L9` suffix doesn't limit the attachment (hinted)

---@class vergil.SkillSource
---@field glob string relative: searched in the root and its parents up to the repository root
---@field name "dir"|"path" frontmatter `name`, else the directory; or the path below the glob's fixed part, `/` as `:`
---@field prefix string? put before the name; `{n}` is what the n-th wildcard matched
---@field on_clash string? when the name is taken, put this before it instead of skipping
---@field origin string? shown in hover; default from the glob: project, personal or system
---@field kind string? shown in hover; default skill for `dir`, command for `path`

---@class vergil.Agent
---@field key string the name under `agents`
---@field name string shown in `:checkhealth`
---@field executable string?
---@field match string[] globs on the file name, or on the full path when they contain `/`
---@field attach vergil.AttachSpec?
---@field skills vergil.SkillSource[]?

--- For `:Vergil enable` in a buffer no agent matches: mentions only.
---@type vergil.Agent
M.plain = { key = "plain", name = "plain", match = {} }

local FIELDS = { name = true, executable = true, match = true, attach = true, skills = true }
local ATTACH_FIELDS = { prefix = true, quote = true, strip = true, ranges = true }
local SOURCE_FIELDS = { glob = true, name = true, prefix = true, on_clash = true, origin = true, kind = true }

local function fail(key, msg)
  error(("vergil: agents.%s%s"):format(key, msg), 0)
end

local function check_string(key, field, v, optional)
  if v == nil and optional then
    return
  end
  if type(v) ~= "string" or v == "" then
    fail(key, ("%s must be a non-empty string"):format(field))
  end
end

--- Checks one agent's definition; errors name the field.
---@param key string
---@param spec table
function M.validate(key, spec)
  if type(key) ~= "string" or not key:match("^[%w_%-]+$") then
    error(("vergil: agent names must be letters, digits, _ or -, got %s"):format(vim.inspect(key)), 0)
  end
  if key == M.plain.key then
    fail(key, ": the name is reserved for prompts no agent matches")
  end
  if type(spec) ~= "table" then
    fail(key, " must be a table")
  end
  for field in pairs(spec) do
    if not FIELDS[field] then
      fail(key, ("." .. tostring(field) .. " is unknown (expected name, executable, match, attach or skills)"))
    end
  end
  check_string(key, ".name", spec.name, true)
  check_string(key, ".executable", spec.executable, true)
  if type(spec.match) ~= "table" or #spec.match == 0 then
    fail(key, '.match must be a list of globs, e.g. { "claude-prompt-*.md" }')
  end
  for i, g in ipairs(spec.match) do
    check_string(key, (".match[%d]"):format(i), g)
  end
  if spec.attach ~= nil and spec.attach ~= false then
    local a = spec.attach
    if type(a) ~= "table" then
      fail(key, '.attach must be a table (e.g. { prefix = "@" }) or false')
    end
    for field in pairs(a) do
      if not ATTACH_FIELDS[field] then
        fail(key, (".attach.%s is unknown (expected prefix, quote, strip or ranges)"):format(tostring(field)))
      end
    end
    check_string(key, ".attach.prefix", a.prefix)
    if a.prefix:find("%s") then
      fail(key, ".attach.prefix can't contain whitespace")
    end
    check_string(key, ".attach.quote", a.quote, true)
    if a.quote and vim.fn.strchars(a.quote) ~= 1 then
      fail(key, ".attach.quote must be one character")
    end
    if a.strip ~= nil and type(a.strip) ~= "string" then
      fail(key, ".attach.strip must be a string of characters")
    end
    if a.ranges ~= nil and a.ranges ~= "ignored" then
      fail(key, '.attach.ranges must be "ignored" or nil')
    end
  end
  if spec.skills ~= nil and spec.skills ~= false then
    if type(spec.skills) ~= "table" then
      fail(key, ".skills must be a list of sources or false")
    end
    for i, s in ipairs(spec.skills) do
      local at = (".skills[%d]"):format(i)
      if type(s) ~= "table" then
        fail(key, at .. ' must be a table, e.g. { glob = ".agent/skills/*/SKILL.md", name = "dir" }')
      end
      for field in pairs(s) do
        if not SOURCE_FIELDS[field] then
          fail(key, ("%s.%s is unknown"):format(at, tostring(field)))
        end
      end
      check_string(key, at .. ".glob", s.glob)
      if s.name ~= "dir" and s.name ~= "path" then
        fail(key, at .. '.name must be "dir" or "path"')
      end
      for _, f in ipairs({ "prefix", "on_clash", "origin", "kind" }) do
        if s[f] ~= nil and type(s[f]) ~= "string" then
          fail(key, ("%s.%s must be a string"):format(at, f))
        end
      end
    end
  end
end

--- An agent as vergil uses it: defaults filled in, `false` turned into nil.
---@param key string
---@param spec table
---@return vergil.Agent
function M.normalize(key, spec)
  local attach = spec.attach or nil
  if attach then
    attach = { prefix = attach.prefix, quote = attach.quote, strip = attach.strip or "", ranges = attach.ranges }
  end
  return {
    key = key,
    name = spec.name or key,
    executable = spec.executable,
    match = spec.match,
    attach = attach,
    skills = spec.skills or nil,
  }
end

--- The configured agents, sorted by key.
---@return vergil.Agent[]
function M.list()
  local agents = require("vergil.config").options.agents or {}
  local keys = vim.tbl_keys(agents)
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    if agents[key] then
      out[#out + 1] = M.normalize(key, agents[key])
    end
  end
  return out
end

--- A configured agent by its key.
---@param key string
---@return vergil.Agent?
function M.get(key)
  for _, a in ipairs(M.list()) do
    if a.key == key then
      return a
    end
  end
end

--- Whether a path matches a glob: on the file name, or on the whole path
--- when the glob has a `/` (`~` expanded, separators normalized).
---@param path string
---@param glob string
---@return boolean
function M.glob_matches(path, glob)
  path = vim.fs.normalize(path)
  local subject = path
  if not glob:find("/", 1, true) then
    subject = vim.fs.basename(path)
  else
    glob = vim.fs.normalize(glob)
    if glob:sub(1, 1) ~= "/" and glob:sub(1, 1) ~= "*" then
      glob = "*/" .. glob
    end
  end
  if subject == "" then
    return false
  end
  return vim.regex(vim.fn.glob2regpat(glob)):match_str(subject) ~= nil
end

--- The first agent (by key) whose `match` covers a path.
---@param path string
---@return vergil.Agent?
function M.match(path)
  if path == "" then
    return nil
  end
  for _, a in ipairs(M.list()) do
    for _, glob in ipairs(a.match) do
      if M.glob_matches(path, glob) then
        return a
      end
    end
  end
end

--- The agent of a prompt buffer; `M.plain` for any other buffer.
---@param bufnr integer
---@return vergil.Agent
function M.for_buffer(bufnr)
  -- Looked up each time, so `setup()` changing an agent applies at once.
  local s = require("vergil.session").get(bufnr)
  return s and M.get(s.agent) or M.plain
end

return M
