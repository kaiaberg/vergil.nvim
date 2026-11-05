--- Skills and commands for `/` completion, hover and definition.
--- Discovery is the adapter's job; this merges in configured extra items and
--- finds `/name` tokens in prompt text.
local config = require("vergil.config")

local M = {}

---@class vergil.Skill
---@field name string what follows `/`
---@field description string?
---@field argument_hint string? display only
---@field kind "skill"|"command"|"builtin"
---@field origin string "project", "personal", "enterprise", "plugin", "synced" or "config"
---@field path string? definition file
---@field user_invocable boolean
---@field model_invocable boolean
---@field shadows vergil.Skill[]? same-named definitions this one beats

--- All items for a root: discovered ones, then configured extras whose name
--- isn't taken.
---@param root string
---@return vergil.Skill[]
function M.items(root)
  local adapter = config.adapter()
  local items = adapter.discover_skills and adapter.discover_skills(root) or {}
  local taken = {}
  for _, it in ipairs(items) do
    taken[it.name] = true
  end
  for _, extra in ipairs(config.options.skills.extra_items) do
    local name = extra.name:gsub("^/", "")
    if not taken[name] then
      taken[name] = true
      items[#items + 1] = {
        name = name,
        description = extra.description,
        argument_hint = extra.argument_hint,
        kind = "builtin",
        origin = "config",
        user_invocable = true,
        model_invocable = false,
      }
    end
  end
  return items
end

---@param root string
---@param name string
---@return vergil.Skill?
function M.find(root, name)
  for _, it in ipairs(M.items(root)) do
    if it.name == name then
      return it
    end
  end
end

local NAME = "[%w_%-:%.]"

--- The `/query` being typed before the cursor: the trigger at line start or
--- after whitespace, then no whitespace and no further `/`.
---@param line string
---@param col integer 0-based cursor column
---@return { start_col: integer, end_col: integer, query: string }?
function M.typing_token(line, col)
  local trigger = config.options.triggers.skills
  local before = line:sub(1, col)
  local s = before:match("^()" .. vim.pesc(trigger) .. "[^%s/]*$")
    or before:match("%s()" .. vim.pesc(trigger) .. "[^%s/]*$")
  if not s then
    return nil
  end
  return { start_col = s - 1, end_col = col, query = before:sub(s + #trigger) }
end

--- A `/name` token in the text at a position (for hover and definition).
---@param line string
---@param col integer 0-based
---@return { name: string, start_col: integer, end_col: integer }?
function M.token_at(line, col)
  local trigger = vim.pesc(config.options.triggers.skills)
  local init = 1
  while true do
    local s, name, e = line:match("()" .. trigger .. "(" .. NAME .. "+)()", init)
    if not s then
      return nil
    end
    local boundary = s == 1 or line:sub(s - 1, s - 1):match("%s") ~= nil
    local next_char = line:sub(e, e)
    if boundary and next_char ~= "/" and col >= s - 1 and col <= e - 1 then
      return { name = name:gsub("[%.:]+$", ""), start_col = s - 1, end_col = e - 1 }
    end
    init = e
  end
end

local function show_path(path, root)
  if root then
    local rel = vim.fs.relpath(root, path)
    if rel then
      return rel
    end
  end
  return vim.fn.fnamemodify(path, ":~")
end

--- Markdown describing a skill. Paths are shown relative to `root` when
--- inside it.
---@param skill vergil.Skill
---@param root string?
---@return string[]
function M.contents(skill, root)
  local trigger = config.options.triggers.skills
  local out = { ("**%s%s**%s"):format(trigger, skill.name, skill.argument_hint and (" `" .. skill.argument_hint .. "`") or "") }
  if skill.description then
    out[#out + 1] = ""
    out[#out + 1] = skill.description
  end
  out[#out + 1] = ""
  local meta = ("_%s %s_"):format(skill.origin, skill.kind)
  if skill.path then
    meta = meta .. " · `" .. show_path(skill.path, root) .. "`"
  end
  out[#out + 1] = meta
  local notes = {}
  if not skill.user_invocable then
    notes[#notes + 1] = "`user-invocable: false`"
  end
  if skill.kind ~= "builtin" and not skill.model_invocable then
    notes[#notes + 1] = "`disable-model-invocation: true`"
  end
  for _, s in ipairs(skill.shadows or {}) do
    notes[#notes + 1] = ("overrides %s %s `%s`"):format(s.origin, s.kind, show_path(s.path or "", root))
  end
  if #notes > 0 then
    out[#out + 1] = ""
    for _, n in ipairs(notes) do
      out[#out + 1] = "- " .. n
    end
  end
  return out
end

return M
