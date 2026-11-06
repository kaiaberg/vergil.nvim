--- Sends lines from a file back to the prompt (`:Vergil send`): the other
--- direction of `gd`. Select lines in the file itself, with every motion and
--- text object, and they land in the prompt as a mention, a snippet or both,
--- exactly as the line selector would insert them.
---
--- The first send after `gd` or `:Vergil open` replaces the reference that was
--- opened, as `#` would. Otherwise the result goes after the prompt's cursor
--- (after a reference, never inside one), with spaces where needed.
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

---@alias vergil.SendAction "mention"|"snippet"|"both"

--- The path to write in the prompt: relative to the root when inside it.
local function prompt_path(abs, root)
  local rel = vim.fs.relpath(root, abs)
  if not rel then -- e.g. /tmp vs /private/tmp on macOS
    local real_root, real_abs = vim.uv.fs_realpath(root), vim.uv.fs_realpath(abs)
    rel = real_root and real_abs and vim.fs.relpath(real_root, real_abs)
  end
  return rel or vim.fn.fnamemodify(abs, ":~")
end

--- Whether two absolute paths name the same file, through symlinks too.
local function same_file(a, b)
  return a == b or (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

--- Shows the prompt: its window in this tab if there is one, else in the
--- current window, so `<C-^>` goes back to the file.
---@return integer win
local function show_prompt(prompt)
  local win = vim.fn.bufwinid(prompt)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    return win
  end
  vim.cmd.buffer(prompt)
  return vim.api.nvim_get_current_win()
end

--- The reference opened with `gd` or `:Vergil open`, if it still names `abs`.
--- Used once: later sends from the same file add to the prompt instead.
---@return vergil.Reference?
local function opened_ref(session, abs)
  local jump = session.jump
  session.jump = nil
  if not (jump and same_file(jump.abs, abs)) then
    return nil
  end
  local ref = parser.at(parser.parse_buffer(session.bufnr), jump.row, jump.col)
  if not ref or ref.resource or ref.unterminated or ref.in_fence then
    return nil
  end
  local target = resolver.resolve(ref, session.root)
  return target and target.abs and same_file(target.abs, abs) and ref or nil
end

--- The span to replace: the opened reference, or an empty span after the
--- cursor, padded with spaces for an inline mention.
---@return vergil.Reference ref
---@return vergil.Span span
local function target_span(session, win, abs, path, action)
  local prompt = session.bufnr
  local opened = opened_ref(session, abs)
  if opened then
    return opened, opened.span
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local ref = parser.at(parser.parse_buffer(prompt), row - 1, col)

  local line = vim.api.nvim_buf_get_lines(prompt, row - 1, row, false)[1] or ""
  local at = 0
  if ref and ref.span.end_row == row - 1 then
    at = ref.span.end_col -- after another reference, never inside it
  elseif line ~= "" then
    -- After the character under the cursor, as `a` would.
    at = math.min(col + 1 + vim.str_utf_end(line, col + 1), #line)
  end
  if action ~= "snippet" then
    local before = at > 0 and not line:sub(at, at):match("%s") and " " or ""
    local after = at < #line and not line:sub(at + 1, at + 1):match("%s") and " " or ""
    if before .. after ~= "" then
      vim.api.nvim_buf_set_text(prompt, row - 1, at, row - 1, at, { before .. after })
      at = at + #before
    end
  end
  local span = { start_row = row - 1, start_col = at, end_row = row - 1, end_col = at }
  return { mode = "mention", path = path, explicit = true, span = span }, span
end

--- Sends lines `line1`..`line2` of the current buffer to the prompt.
---@param action vergil.SendAction?
---@param line1 integer 1-based
---@param line2 integer 1-based, inclusive
---@return boolean ok
---@return string? err
function M.send(action, line1, line2)
  action = action or "mention"
  if action ~= "mention" and action ~= "snippet" and action ~= "both" then
    return false, ("unknown action %q; expected snippet or both"):format(action)
  end
  local session = require("vergil.session")
  local src = vim.api.nvim_get_current_buf()
  if session.is_enabled(src) then
    return false, "this is the prompt; send lines from a file, or use # here"
  end
  local name = vim.api.nvim_buf_get_name(src)
  if vim.bo[src].buftype ~= "" or name == "" or vim.fn.filereadable(name) == 0 then
    return false, "not a file on disk"
  end
  local prompt, err = session.find_prompt()
  if not prompt then
    return false, err
  end
  local s = session.get(prompt)
  local root = s.root
  local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  local path = prompt_path(abs, root)
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  local lines = vim.api.nvim_buf_get_lines(src, line1 - 1, line2, false)
  local modified = vim.bo[src].modified

  local win = show_prompt(prompt)
  local ref, span = target_span(s, win, abs, path, action)
  require("vergil.range").apply(
    { bufnr = prompt, win = win, ref = ref, span = span, from_insert = false },
    { action = action, start_line = line1, end_line = line2, lines = lines },
    abs
  )
  if modified then
    vim.notify(
      ("vergil: %s has unsaved changes; the agent reads the file on disk"):format(path),
      vim.log.levels.WARN
    )
  end
  return true
end

--- The lines of the Visual selection, or the cursor line outside Visual mode.
--- Leaves Visual mode.
---@return integer line1
---@return integer line2
function M.selected_lines()
  local mode = vim.fn.mode()
  local line1, line2 = vim.fn.line("v"), vim.fn.line(".")
  if mode:match("^[vV\22]") then
    vim.cmd.normal({ vim.keycode("<Esc>"), bang = true })
    return math.min(line1, line2), math.max(line1, line2)
  end
  return line2, line2
end

return M
