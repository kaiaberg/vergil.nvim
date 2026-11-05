--- Claude Code attachment syntax: `@path` and `@"path with spaces"`.
---
--- Rules come from contract tests against Claude Code (docs/m0-findings.md):
--- - `@` starts a reference only at line start or after whitespace, so
---   `(@a)`, `"@a"`, `` `@a` `` and `me@example.com` are not references.
--- - Claude Code strips any run of trailing ``.,;:!?)]}>'"` `` from an unquoted
---   path, so the span ends before it and edits keep the punctuation.
--- - A `#range` suffix does not limit the attachment; it is reported as
---   `ignored_range` so diagnostics can say so.
--- - `@dir/` lists a directory; `@server:resource` is an MCP resource.
local M = {}

local TRAILING = "[%.,;:!%?%)%]}>'\"`]"

---@class vergil.RawAttachment
---@field start_col integer 0-based byte column of `@`
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

--- Finds every attachment in one line of text.
---@param line string
---@return vergil.RawAttachment[]
function M.find_attachments(line)
  local out = {}
  local i = 1
  while true do
    local s = line:find("@", i, true)
    if not s then
      break
    end
    i = s + 1
    local boundary = s == 1 or line:sub(s - 1, s - 1):match("%s") ~= nil
    local next_char = line:sub(s + 1, s + 1)
    if boundary and next_char ~= "" and not next_char:match("[%s@]") then
      if next_char == '"' then
        local close = line:find('"', s + 2, true)
        local path = line:sub(s + 2, close and close - 1 or #line)
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
        local token = line:match("^[^%s]+", s + 1)
        while token ~= "" and token:sub(-1):match(TRAILING) do
          token = token:sub(1, -2)
        end
        if token ~= "" then
          local path, range = split_range(token)
          out[#out + 1] = {
            start_col = s - 1,
            end_col = s + #token,
            path = path,
            quoted = false,
            resource = path:match("^[%w_%-]+:[^/]") ~= nil or nil,
            ignored_range = range,
          }
          i = s + 1 + #token
        end
      end
    end
  end
  return out
end

--- Formats an attachment, quoting when Claude Code would otherwise
--- misread the path (whitespace, or trailing punctuation it would strip).
---@param path string
---@return string
function M.attachment(path)
  if path:find("%s") or path:sub(-1):match(TRAILING) or path:sub(1, 1) == '"' then
    return '@"' .. path .. '"'
  end
  return "@" .. path
end

return M
