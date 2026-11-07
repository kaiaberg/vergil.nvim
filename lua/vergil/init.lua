--- vergil.nvim public API. Works without calling `setup()`.
local M = {}

---@param opts table?
function M.setup(opts)
  local config = require("vergil.config")
  config.set(opts)
  -- Re-check open buffers: activation patterns or the preset may have changed.
  local session = require("vergil.session")
  local keymaps = require("vergil.keymaps")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      session.maybe_enable(bufnr)
      if session.is_enabled(bufnr) then
        keymaps.detach(bufnr)
        keymaps.attach(bufnr)
      end
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

local function current_session()
  local s = require("vergil.session").get(vim.api.nvim_get_current_buf())
  if not s then
    return nil, "not enabled in this buffer (use :Vergil enable)"
  end
  return s
end

--- Shows a preview of the reference under the cursor in a float.
---@return boolean ok
---@return string? err
function M.preview()
  local s, err = current_session()
  if not s then
    return false, err
  end
  local parser = require("vergil.reference.parser")
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local hover = require("vergil.lsp.hover")
  local ref = parser.at(parser.parse_buffer(s.bufnr), row - 1, col)
  local contents = ref and hover.contents(ref, s.root)
  if not contents and not ref then
    local _, skill = hover.skill_at(s, row - 1, col)
    contents = skill and require("vergil.skills").contents(skill, s.root)
  end
  if not contents or (ref and ref.git) then
    local git = require("vergil.git")
    local obj = git.object_at(s, row - 1, col)
    contents = obj and git.object_hover(s.root, obj) or contents
  end
  if not contents then
    return false, "no reference under the cursor"
  end
  -- Pressing it again with the preview open: close it, or move into it.
  local open_win = vim.b.lsp_floating_preview
  if open_win and vim.api.nvim_win_is_valid(open_win) and require("vergil.config").options.preview.on_repeat == "close" then
    vim.api.nvim_win_close(open_win, true)
    return true
  end
  vim.lsp.util.open_floating_preview(contents, "markdown", { border = "rounded", focus_id = "vergil-preview" })
  return true
end

local OPEN_CMDS = { split = "split", vsplit = "vsplit", tab = "tabedit" }

--- Opens the target of the reference under the cursor at its line.
---@param how? "split"|"vsplit"|"tab" nil opens in the current window
---@return boolean ok
---@return string? err
function M.open(how)
  if how ~= nil and not OPEN_CMDS[how] then
    return false, ("unknown open mode %q; expected split, vsplit or tab"):format(how)
  end
  local s, err = current_session()
  if not s then
    return false, err
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local target, terr = require("vergil.lsp.definition").target_at(s.bufnr, row - 1, col, s.root)
  if not target then
    local _, skill = require("vergil.lsp.hover").skill_at(s, row - 1, col)
    if not (skill and skill.path) then
      local git = require("vergil.git")
      local obj = git.object_at(s, row - 1, col)
      if not obj then
        return false, terr
      end
      s.jump = nil
      local bufnr = git.object_buffer(s.root, obj)
      if how then
        vim.cmd(OPEN_CMDS[how])
      end
      vim.api.nvim_win_set_buf(0, bufnr)
      return true
    end
    target = { abs = skill.path, line = 1, type = "file" }
  end
  s.jump = { row = row - 1, col = col, abs = target.abs } -- for :Vergil send
  vim.cmd({ cmd = how and OPEN_CMDS[how] or "edit", args = { target.abs }, magic = { file = false } })
  if target.type == "file" then
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(target.line, last), 0 })
    vim.cmd("normal! zz")
  end
  return true
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
