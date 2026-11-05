--- `textDocument/definition`: jump to a reference's target at its line.
local hover = require("vergil.lsp.hover")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

--- The target of the reference at a position: absolute path and 1-based line.
---@param bufnr integer
---@param row integer 0-based
---@param col integer 0-based
---@param root string
---@return { abs: string, line: integer, type: string }?
---@return string? err
function M.target_at(bufnr, row, col, root)
  local ref = parser.at(parser.parse_buffer(bufnr), row, col)
  if not ref then
    return nil, "no reference under the cursor"
  end
  if ref.resource then
    return nil, "resource references can't be opened"
  end
  local target = resolver.resolve(ref, root)
  if not target or not hover.is_file_ref(ref, target) then
    return nil, "no reference under the cursor"
  end
  if not target.exists then
    return nil, ("not found: %s"):format(target.abs)
  end
  return { abs = target.abs, line = ref.start_line or (ref.ignored_range and ref.ignored_range[1]) or 1, type = target.type }
end

---@param params table LSP DefinitionParams
---@param session vergil.Session
function M.handle(params, session)
  local t = M.target_at(session.bufnr, params.position.line, params.position.character, session.root)
  if not t then
    return nil
  end
  local line = math.max(0, t.line - 1)
  return {
    uri = vim.uri_from_fname(t.abs),
    range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 0 } },
  }
end

return M
