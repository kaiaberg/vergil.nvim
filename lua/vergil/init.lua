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

--- The prompt status of a buffer (see `:help vergil-status`), or nil when
--- vergil isn't on there or hasn't checked the buffer yet.
---@param bufnr integer?
---@return vergil.Status?
function M.status(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local s = require("vergil.session").get(bufnr)
  return s and s.status
end

--- A size as vergil writes it: `512 B`, `1.5 KB`, `2.0 MB`.
---@param bytes integer
---@return string
function M.format_size(bytes)
  return require("vergil.size").format(bytes)
end

local function current_session()
  local s = require("vergil.session").get(vim.api.nvim_get_current_buf())
  if not s then
    return nil, "not enabled in this buffer (use :Vergil enable)"
  end
  return s
end

--- A check that the cursor is still where it was, for answers that arrive
--- later: if the user moved on, they're dropped.
local function still_here()
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  return function()
    local now = vim.api.nvim_win_get_cursor(0)
    return vim.api.nvim_get_current_buf() == buf and now[1] == cursor[1] and now[2] == cursor[2]
  end
end

local function warn(msg)
  vim.notify("vergil: " .. msg, vim.log.levels.WARN)
end

--- Shows a preview of the reference under the cursor in a float. Commits
--- and branches need git, so their preview opens once git answers.
---@return boolean ok
---@return string? err
function M.preview()
  local s, err = current_session()
  if not s then
    return false, err
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local hover = require("vergil.lsp.hover")
  local ref = require("vergil.reference.bare").ref_at(s.bufnr, row - 1, col, s.root)
  local contents = ref and hover.contents(ref, s.root)
  if not contents and not ref then
    local _, skill = hover.skill_at(s, row - 1, col)
    contents = skill and require("vergil.skills").contents(skill, s.root)
  end
  local git = require("vergil.git")
  local candidate = not contents and ref and git.candidate_at(s, row - 1, col)
  if not contents and not candidate then
    return false, "no reference under the cursor"
  end
  -- Pressing it again with the preview open: close it, or move into it.
  local open_win = vim.b.lsp_floating_preview
  if
    open_win
    and vim.api.nvim_win_is_valid(open_win)
    and require("vergil.config").options.preview.on_repeat == "close"
  then
    vim.api.nvim_win_close(open_win, true)
    return true
  end
  local function show(lines)
    -- No title here, so any 'winborder' works; unset, vergil's default.
    local border = vim.o.winborder == "" and "rounded" or nil
    vim.lsp.util.open_floating_preview(lines, "markdown", { border = border, focus_id = "vergil-preview" })
  end
  if contents then
    show(contents)
    return true
  end
  local here = still_here()
  git.object(s.root, candidate.path, function(obj)
    if not here() then
      return
    elseif not obj then
      return warn("no reference under the cursor")
    end
    git.object_hover(s.root, obj, function(lines)
      if here() then
        show(lines)
      end
    end)
  end)
  return true
end

local OPEN_CMDS = { split = "split", vsplit = "vsplit", tab = "tabedit" }

--- Opens the target of the reference under the cursor at its line. Commits
--- and branches need git, so they open once git answers.
---@param how? "split"|"vsplit"|"tab" nil opens in the current window
---@param mods? vim.api.keyset.cmd.mods command modifiers, e.g. from `:vertical Vergil open split`
---@return boolean ok
---@return string? err
function M.open(how, mods)
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
      local candidate = git.candidate_at(s, row - 1, col)
      if not candidate then
        return false, terr
      end
      local here = still_here()
      git.object(s.root, candidate.path, function(obj)
        if not here() then
          return
        elseif not obj then
          return warn(terr)
        end
        git.object_buffer(s.root, obj, function(bufnr)
          if not here() then
            return
          end
          s.jump = nil
          if how then
            vim.cmd({ cmd = OPEN_CMDS[how], mods = mods })
          end
          vim.api.nvim_win_set_buf(0, bufnr)
        end)
      end)
      return true
    end
    target = { abs = skill.path, line = 1, type = "file" }
  end
  s.jump = { row = row - 1, col = col, abs = target.abs } -- for :Vergil send
  vim.cmd({ cmd = how and OPEN_CMDS[how] or "edit", args = { target.abs }, magic = { file = false }, mods = mods })
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
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local ref = require("vergil.reference.bare").ref_at(bufnr, row - 1, col, s.root)
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
  local edit, err = convert.toggle(ref, {
    attach = require("vergil.agents").for_buffer(bufnr).attach,
    mention_format = config.options.mention.format,
  })
  if not edit then
    return false, err
  end
  convert.apply(bufnr, edit)
  -- Keep the cursor inside the converted reference.
  vim.api.nvim_win_set_cursor(0, { row, math.min(col, edit.span.start_col + #edit.text - 1) })
  return true
end

return M
