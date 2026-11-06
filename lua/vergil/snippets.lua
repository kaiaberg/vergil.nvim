--- Verbatim snippets (plan §6.4): a mention-style header, never an `@`
--- reference (that would load the same code again), then the lines in a
--- fenced block that preserves whitespace exactly.
local formatter = require("vergil.reference.formatter")

local M = {}

--- A fence longer than any backtick run in the lines, at least three.
---@param lines string[]
---@return string
function M.fence(lines)
  local longest = 0
  for _, line in ipairs(lines) do
    for run in line:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return string.rep("`", math.max(3, longest + 1))
end

--- Fence language for a file, from Neovim's filetype detection.
---@param abs string
---@return string
function M.language(abs)
  return vim.filetype.match({ filename = abs }) or ""
end

--- The snippet's lines, header included.
---@param path string as it should appear in the header
---@param start_line integer
---@param end_line integer
---@param lines string[] the source lines, verbatim
---@param opts { mention_format: string|vergil.MentionTemplates, language: string, symbol: string? }
---@return string[]? block
---@return string? err
function M.block(path, start_line, end_line, lines, opts)
  local mention, err = formatter.mention(path, start_line, end_line, opts.mention_format)
  if not mention then
    return nil, err
  end
  local fence = M.fence(lines)
  local block = { ("From %s:"):format(formatter.with_symbol(mention, opts.symbol)), "", fence .. opts.language }
  vim.list_extend(block, lines)
  block[#block + 1] = fence
  return block
end

return M
