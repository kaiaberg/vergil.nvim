--- `textDocument/definition`: jump to a reference's target at its line.
local hover = require("vergil.lsp.hover")
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
  local ref = require("vergil.reference.bare").ref_at(bufnr, row, col, root)
  if not ref then
    return nil, "no reference under the cursor"
  end
  if ref.resource then
    return nil, "resource references can't be opened"
  end
  local target = resolver.resolve(ref, root)
  if ref.git or not target or not hover.is_file_ref(ref, target) then
    return nil, "no reference under the cursor"
  end
  if not target.exists then
    return nil, ("not found: %s"):format(target.abs)
  end
  return {
    abs = target.abs,
    line = ref.start_line or (ref.ignored_range and ref.ignored_range[1]) or 1,
    type = target.type,
  }
end

--- Answers `textDocument/definition` through `respond`: at once for files
--- and skills, after asking git for commits and branches.
---@param params table LSP DefinitionParams
---@param session vergil.Session
---@param respond fun(result: table?)
function M.handle(params, session, respond)
  local row, col = params.position.line, params.position.character
  local t = M.target_at(session.bufnr, row, col, session.root)
  if not t then
    local top = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }
    local _, skill = hover.skill_at(session, row, col)
    if skill and skill.path then
      return respond({ uri = vim.uri_from_fname(skill.path), range = top })
    end
    local git = require("vergil.git")
    git.object_at(session, row, col, function(obj)
      if not obj then
        return respond(nil)
      end
      git.object_buffer(session.root, obj, function(_, uri)
        respond({ uri = uri, range = top })
      end)
    end)
    return
  end
  session.jump = { row = row, col = col, abs = t.abs } -- for :Vergil send
  local line = math.max(0, t.line - 1)
  respond({
    uri = vim.uri_from_fname(t.abs),
    range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 0 } },
  })
end

return M
