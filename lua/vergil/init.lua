--- vergil.nvim public API. Works without calling `setup()`.
local M = {}

---@param opts table?
function M.setup(opts)
  local config = require("vergil.config")
  config.set(opts)
  -- Re-check open buffers: activation patterns may have changed.
  local session = require("vergil.session")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      session.maybe_enable(bufnr)
    end
  end
end

---@param bufnr integer?
function M.enable(bufnr)
  return require("vergil.session").enable(bufnr or 0)
end

---@param bufnr integer?
function M.disable(bufnr)
  require("vergil.session").disable(bufnr or 0)
end

--- References in a buffer, in order.
---@param bufnr integer?
---@return vergil.Reference[]
function M.references(bufnr)
  return require("vergil.reference.parser").parse_buffer(bufnr or 0)
end

--- Converts the reference under the cursor to the other type.
---@return boolean ok
---@return string? err
function M.toggle()
  local session = require("vergil.session")
  local bufnr = vim.api.nvim_get_current_buf()
  local s = session.get(bufnr)
  if not s then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local parser = require("vergil.reference.parser")
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local ref = parser.at(parser.parse_buffer(bufnr), row - 1, col)
  if not ref then
    return false, "no reference under the cursor"
  end
  if ref.mode == "mention" and not ref.explicit then
    -- Could be ordinary inline code; only convert if the target exists.
    local target = require("vergil.reference.resolver").resolve(ref, s.root)
    if not (target and target.exists) then
      return false, ("`%s` doesn't look like a path"):format(ref.path)
    end
  end
  local config = require("vergil.config")
  local convert = require("vergil.reference.convert")
  local edit, err = convert.toggle(ref, { adapter = config.adapter(), mention_format = config.options.mention.format })
  if not edit then
    return false, err
  end
  convert.apply(bufnr, edit)
  -- Keep the cursor inside the converted reference.
  vim.api.nvim_win_set_cursor(0, { row, math.min(col, edit.span.start_col + #edit.text - 1) })
  return true
end

return M
