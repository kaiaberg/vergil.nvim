--- Formats references as text. Mention syntax is agent-independent and
--- configurable via templates; attachment syntax comes from the adapter.
local M = {}

---@type table<string, vergil.MentionTemplates>
M.presets = {
  github = { single = "{path}#L{start}", range = "{path}#L{start}-L{end}" },
  colon = { single = "{path}:{start}", range = "{path}:{start}-{end}" },
}

---@class vergil.CompiledFormat
---@field single string
---@field range string
---@field single_pat string Lua pattern capturing path, start
---@field range_pat string Lua pattern capturing path, start, end

local cache = {} ---@type table<string|table, vergil.CompiledFormat>

local function to_pattern(tpl, fields)
  local pat, order = "", {}
  local pos = 1
  while true do
    local s, e, name = tpl:find("{(%w+)}", pos)
    local literal = tpl:sub(pos, (s or 0) - 1)
    if not s then
      literal = tpl:sub(pos)
    end
    pat = pat .. literal:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    if not s then
      break
    end
    if not vim.tbl_contains(fields, name) then
      error(("vergil: unknown field {%s} in mention template %q"):format(name, tpl), 0)
    end
    if vim.tbl_contains(order, name) then
      error(("vergil: field {%s} appears twice in mention template %q"):format(name, tpl), 0)
    end
    order[#order + 1] = name
    pat = pat .. (name == "path" and "(.-)" or "(%d+)")
    pos = e + 1
  end
  for _, f in ipairs(fields) do
    if not vim.tbl_contains(order, f) then
      error(("vergil: mention template %q needs {%s}"):format(tpl, f), 0)
    end
  end
  if order[1] ~= "path" then
    error(("vergil: mention template %q must start with {path}"):format(tpl), 0)
  end
  if tpl:match("{path}{") then
    error(("vergil: mention template %q needs a separator after {path}"):format(tpl), 0)
  end
  return "^" .. pat .. "$", order
end

--- Compiles a preset name or template table, validating it.
---@param fmt string|vergil.MentionTemplates
---@return vergil.CompiledFormat
function M.compile(fmt)
  if cache[fmt] then
    return cache[fmt]
  end
  local t = type(fmt) == "string" and M.presets[fmt] or fmt
  if type(t) ~= "table" or type(t.single) ~= "string" or type(t.range) ~= "string" then
    error(
      ("vergil: mention.format must be %s or { single = ..., range = ... }"):format(table.concat(
        vim.tbl_map(function(k)
          return ("%q"):format(k)
        end, vim.tbl_keys(M.presets)),
        ", "
      )),
      0
    )
  end
  local single_pat, single_order = to_pattern(t.single, { "path", "start" })
  local range_pat, range_order = to_pattern(t.range, { "path", "start", "end" })
  if range_order[2] ~= "start" then
    error(("vergil: mention template %q must put {start} before {end}"):format(t.range), 0)
  end
  local compiled = { single = t.single, range = t.range, single_pat = single_pat, range_pat = range_pat }
  assert(single_order[2] == "start")
  cache[fmt] = compiled
  return compiled
end

local function fill(tpl, path, s, e)
  -- Function replacements so `%` in paths is never interpreted.
  return (
    tpl:gsub("{(%w+)}", function(name)
      return name == "path" and path or tostring(name == "start" and s or e)
    end)
  )
end

--- Mention text including backticks: `` `path` ``, `` `path#L12` `` or `` `path#L12-L35` ``.
---@param path string
---@param start_line integer?
---@param end_line integer?
---@param fmt string|vergil.MentionTemplates
---@return string? text nil when the path contains a backtick
---@return string? err
function M.mention(path, start_line, end_line, fmt)
  if path:find("`", 1, true) then
    return nil, "path contains a backtick"
  end
  local f = M.compile(fmt)
  local body = path
  if start_line and end_line and end_line ~= start_line then
    body = fill(f.range, path, start_line, end_line)
  elseif start_line then
    body = fill(f.single, path, start_line)
  end
  return "`" .. body .. "`"
end

--- Splits mention content (between backticks) into path and range.
---@param content string
---@param fmt string|vergil.MentionTemplates
---@return string path
---@return integer? start_line
---@return integer? end_line
function M.parse_mention(content, fmt)
  local f = M.compile(fmt)
  local p, s, e = content:match(f.range_pat)
  if p and p ~= "" then
    return p, tonumber(s), tonumber(e)
  end
  p, s = content:match(f.single_pat)
  if p and p ~= "" then
    return p, tonumber(s), tonumber(s)
  end
  return content, nil, nil
end

--- Attachment text, in the adapter's syntax.
---@param path string
---@param adapter vergil.Adapter
---@return string
function M.attachment(path, adapter)
  return adapter.attachment(path)
end

--- A mention followed by the symbol it covers: `` `a.lua#L3-L9` (`M.apply`) ``.
--- Without a usable name, the mention alone.
---@param mention string
---@param symbol string?
---@return string
function M.with_symbol(mention, symbol)
  if not symbol or symbol == "" or symbol:find("`", 1, true) then
    return mention
  end
  return ("%s (`%s`)"):format(mention, symbol)
end

return M
