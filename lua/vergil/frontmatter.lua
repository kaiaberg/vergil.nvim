--- A small YAML-frontmatter reader for Markdown files (plan §6.7).
---
--- Neovim has no YAML parser, so this supports the subset skill and command
--- files use: top-level `key: value` pairs with plain, single- or
--- double-quoted values, multi-line plain values, block scalars (`|`, `>`,
--- with `-`/`+` chomping), and `true`/`false`. Anything else (lists, nested
--- maps) is kept as raw text or skipped. It never errors: unreadable or
--- malformed frontmatter gives an empty table, so completion keeps working.
local M = {}

local function unquote_double(s)
  local map = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
  return (s:gsub("\\(.)", function(c)
    return map[c] or ("\\" .. c)
  end))
end

--- Parses a value that may span the following indented lines.
---@return any value
---@return integer next index of the first line not consumed
local function read_value(lines, i, raw)
  -- Block scalar: `|`, `>`, optionally with chomping indicator.
  local style, chomp = raw:match("^([|>])([+-]?)%s*$")
  if style then
    local block, indent = {}, nil
    local j = i + 1
    while j <= #lines do
      local l = lines[j]
      if l:match("^%s*$") then
        block[#block + 1] = ""
      else
        local lead = #l:match("^(%s*)")
        if lead == 0 then
          break
        end
        indent = indent or lead
        if lead < indent then
          break
        end
        block[#block + 1] = l:sub(indent + 1)
      end
      j = j + 1
    end
    local trailing = 0
    while #block > 0 and block[#block] == "" do
      table.remove(block)
      trailing = trailing + 1
    end
    local text
    if style == "|" then
      text = table.concat(block, "\n")
    else
      -- Folded: single newlines become spaces, blank lines stay newlines.
      local parts, para = {}, {}
      for _, l in ipairs(block) do
        if l == "" then
          parts[#parts + 1] = table.concat(para, " ")
          para = {}
        else
          para[#para + 1] = l
        end
      end
      parts[#parts + 1] = table.concat(para, " ")
      text = table.concat(parts, "\n")
    end
    if chomp == "+" then
      text = text .. string.rep("\n", trailing + 1)
    elseif chomp ~= "-" and text ~= "" then
      text = text .. "\n"
    end
    return text, j
  end

  local dq = raw:match('^"(.*)"%s*$')
  if dq then
    return unquote_double(dq), i + 1
  end
  local sq = raw:match("^'(.*)'%s*$")
  if sq then
    return (sq:gsub("''", "'")), i + 1
  end

  -- Plain value, possibly continued on more-indented lines.
  local parts = { raw }
  local j = i + 1
  while j <= #lines and lines[j]:match("^%s+%S") and not lines[j]:match("^%s*%- ") do
    parts[#parts + 1] = vim.trim(lines[j])
    j = j + 1
  end
  local value = vim.trim(table.concat(parts, " "))
  value = value:gsub("%s+#.*$", "") -- trailing comment
  if value == "true" then
    return true, j
  elseif value == "false" then
    return false, j
  elseif value == "" then
    return nil, j
  end
  return value, j
end

--- Splits a Markdown file's lines into frontmatter fields and body lines.
---@param lines string[]
---@return table<string, any> fields
---@return string[] body lines after the frontmatter (all lines if none)
function M.parse(lines)
  if lines[1] == nil or not lines[1]:match("^%-%-%-%s*$") then
    return {}, lines
  end
  local close
  for i = 2, #lines do
    if lines[i]:match("^%-%-%-%s*$") or lines[i]:match("^%.%.%.%s*$") then
      close = i
      break
    end
  end
  if not close then
    return {}, lines
  end
  local fm = vim.list_slice(lines, 2, close - 1)
  local fields = {}
  local ok = pcall(function()
    local i = 1
    while i <= #fm do
      local key, raw = fm[i]:match("^([%w_%-]+):%s*(.-)%s*$")
      if key then
        local value
        value, i = read_value(fm, i, raw)
        fields[key] = value
      else
        i = i + 1 -- comment, list item or anything unsupported
      end
    end
  end)
  if not ok then
    fields = {}
  end
  return fields, vim.list_slice(lines, close + 1, #lines)
end

--- Reads a file's frontmatter, or `{}`, `{}` when unreadable.
---@param path string
---@return table<string, any> fields
---@return string[] body
function M.read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return {}, {}
  end
  return M.parse(lines)
end

--- Claude Code's fallback when there is no description: the first non-empty
--- body line, without Markdown heading markers.
---@param body string[]
---@return string?
function M.first_line(body)
  for _, l in ipairs(body) do
    local t = vim.trim((l:gsub("^%s*#+%s*", "")))
    if t ~= "" then
      return t
    end
  end
end

return M
