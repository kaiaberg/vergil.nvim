--- Attachment syntax, as an agent's `attach` spec describes it
--- (`vergil.AttachSpec`): `@path`, and `@"path with spaces"` with a quote.
---
--- Fixed rules, the same for every agent:
--- - The prefix starts an attachment only at line start or after whitespace,
---   so `(@a)`, `"@a"`, `` `@a` `` and `me@example.com` are not attachments.
--- - An unquoted path runs to the next whitespace, minus any trailing run of
---   `strip` characters, so edits keep the punctuation.
--- - `name:thing` (no `/` after the colon) is a resource, not a file.
--- - A `#L3-L9` suffix is split off; with `ranges = "ignored"` it's reported
---   as `ignored_range` so diagnostics can say so.
local M = {}

---@class vergil.RawAttachment
---@field start_col integer 0-based byte column of the prefix
---@field end_col integer 0-based exclusive byte column
---@field path string
---@field quoted boolean
---@field unterminated boolean? quoted path without a closing quote (while typing)
---@field resource boolean? looks like `server:resource`
---@field ignored_range integer[]? { start, end } from a `#range` suffix

local function split_range(path)
  local p, s, e = path:match("^(.+)#L?(%d+)%-L?(%d+)$")
  if p then
    return p, { tonumber(s), tonumber(e) }
  end
  p, s = path:match("^(.+)#L?(%d+)$")
  if p then
    return p, { tonumber(s), tonumber(s) }
  end
  return path, nil
end

local function strips(spec, char)
  return char ~= "" and spec.strip:find(char, 1, true) ~= nil
end

--- Finds every attachment in one line of text.
---@param line string
---@param spec vergil.AttachSpec
---@return vergil.RawAttachment[]
function M.find(line, spec)
  local out = {}
  local prefix, quote = spec.prefix, spec.quote
  local i = 1
  while true do
    local s = line:find(prefix, i, true)
    if not s then
      break
    end
    i = s + 1
    local after = s + #prefix -- first byte after the prefix
    local boundary = s == 1 or line:sub(s - 1, s - 1):match("%s") ~= nil
    local next_char = line:sub(after, after)
    if
      boundary
      and next_char ~= ""
      and not next_char:match("%s")
      and line:sub(after, after + #prefix - 1) ~= prefix
    then
      if quote and next_char == quote then
        local close = line:find(quote, after + 1, true)
        local path = line:sub(after + 1, close and close - 1 or #line)
        if path ~= "" then
          out[#out + 1] = {
            start_col = s - 1,
            end_col = close or #line,
            path = path,
            quoted = true,
            unterminated = close == nil or nil,
          }
        end
        i = (close or #line) + 1
      else
        local token = line:match("^[^%s]+", after)
        while token ~= "" and strips(spec, token:sub(-1)) do
          token = token:sub(1, -2)
        end
        if token ~= "" then
          local path, range = split_range(token)
          out[#out + 1] = {
            start_col = s - 1,
            end_col = after - 1 + #token,
            path = path,
            quoted = false,
            resource = path:match("^[%w_%-]+:[^/]") ~= nil or nil,
            ignored_range = spec.ranges == "ignored" and range or nil,
          }
          i = after + #token
        end
      end
    end
  end
  return out
end

--- Formats an attachment, quoting when the agent would otherwise misread the
--- path (whitespace, a trailing `strip` character, or a leading quote).
--- Nil when the path needs quoting and the agent has no quote.
---@param path string
---@param spec vergil.AttachSpec
---@return string?
function M.format(path, spec)
  local q = spec.quote
  if path:find("%s") or strips(spec, path:sub(-1)) or (q and path:sub(1, 1) == q) then
    if not q or path:find(q, 1, true) then
      return nil
    end
    return spec.prefix .. q .. path .. q
  end
  return spec.prefix .. path
end

return M
