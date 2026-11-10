--- File sizes as text, the way vergil writes them everywhere.
local M = {}

local UNITS = { "KB", "MB", "GB", "TB" }

--- `512 B`, `1.5 KB`, `2.0 MB`: binary units (1 KB = 1024 B), one decimal.
---@param bytes integer
---@return string
function M.format(bytes)
  if bytes < 1024 then
    return ("%d B"):format(bytes)
  end
  local n, unit = bytes / 1024, 1
  while n >= 1024 and unit < #UNITS do
    n, unit = n / 1024, unit + 1
  end
  return ("%.1f %s"):format(n, UNITS[unit])
end

--- Rough token count for text or a file of this size: a third of its
--- bytes. Agents tokenize differently; this is only for comparing.
---@param bytes integer
---@return integer
function M.tokens(bytes)
  return math.floor(bytes / 3)
end

return M
