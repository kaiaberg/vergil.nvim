--- Line selection (plan §6.3): `#` typed directly after a reference, or
--- `:Vergil range`, opens the selector; the result replaces the reference.
---
--- A selected range always produces a mention: selecting lines from an `@`
--- attachment removes the `@`, because an attachment always loads the whole
--- file. Cancelling removes only the typed `#`, so the prompt is exactly as
--- it was before.
local config = require("vergil.config")
local formatter = require("vergil.reference.formatter")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")
local snippets = require("vergil.snippets")

local M = {}

local group = vim.api.nvim_create_augroup("vergil.range", { clear = true })

---@class vergil.RangeContext
---@field bufnr integer
---@field win integer the prompt window
---@field ref vergil.Reference
---@field span vergil.Span the text to replace: the reference, plus `#` if typed
---@field from_insert boolean resume Insert mode afterwards

--- A reference that can take a range, or nil with a reason.
---@param ref vergil.Reference
---@param root string
---@return vergil.Target?
---@return string? err
local function selectable(ref, root)
  if ref.resource or ref.unterminated or ref.in_fence then
    return nil, "not a file reference"
  end
  local target = resolver.resolve(ref, root)
  if ref.mode == "mention" and not ref.explicit and not (target and target.exists) then
    return nil, "not a file reference"
  end
  if not target or not target.exists then
    return nil, ("not found: %s"):format(target and target.abs or ref.path)
  end
  if target.type ~= "file" then
    return nil, ("not a file: %s"):format(target.rel or target.abs)
  end
  return target
end

local function is_blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

local function resume(ctx, row, col)
  if not vim.api.nvim_win_is_valid(ctx.win) then
    return
  end
  vim.api.nvim_set_current_win(ctx.win)
  local last = vim.api.nvim_buf_line_count(ctx.bufnr)
  row = math.min(row, last)
  local len = #(vim.api.nvim_buf_get_lines(ctx.bufnr, row - 1, row, false)[1] or "")
  vim.api.nvim_win_set_cursor(ctx.win, { row, math.min(col, len) })
  if ctx.from_insert then
    -- `startinsert` with the cursor past the end of the line needs `!`.
    if col >= len then
      vim.cmd("startinsert!")
    else
      vim.cmd("startinsert")
    end
  end
end

--- Inserts a block of lines after `row` (1-based; 0 = top), padded with one
--- blank line on each side unless there already is one. At the end of the
--- buffer a blank line is added after it, so there is somewhere to type.
---@return integer after 1-based row of the line right after the block
function M.insert_block(bufnr, row, block)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  if row > 0 and not is_blank(lines[row]) then
    out[#out + 1] = ""
  end
  vim.list_extend(out, block)
  if row >= #lines or not is_blank(lines[row + 1]) then
    out[#out + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, out)
  return row + #out - (out[#out] == "" and 0 or -1)
end

local function undojoin()
  pcall(vim.cmd.undojoin)
end

--- Applies a selector result to the prompt.
---@param ctx vergil.RangeContext
---@param result vergil.SelectorResult
---@param abs string
function M.apply(ctx, result, abs)
  local bufnr, span = ctx.bufnr, ctx.span
  local fmt = config.options.mention.format
  local mention, err = formatter.mention(ctx.ref.path, result.start_line, result.end_line, fmt)
  if not mention then
    vim.notify("vergil: " .. err, vim.log.levels.WARN)
    return M.cancel(ctx)
  end
  mention = formatter.with_symbol(mention, result.symbol)
  local row = span.start_row + 1

  if result.action == "mention" then
    vim.api.nvim_buf_set_text(bufnr, span.start_row, span.start_col, span.end_row, span.end_col, { mention })
    return resume(ctx, row, span.start_col + #mention)
  end

  local block = assert(snippets.block(ctx.ref.path, result.start_line, result.end_line, result.lines, {
    mention_format = fmt,
    language = snippets.language(abs),
    symbol = result.symbol,
  }))

  if result.action == "both" then
    vim.api.nvim_buf_set_text(bufnr, span.start_row, span.start_col, span.end_row, span.end_col, { mention })
    undojoin()
    M.insert_block(bufnr, row, block)
    return resume(ctx, row, span.start_col + #mention)
  end

  -- Snippet only: the reference becomes the snippet's header, so remove it
  -- from the line. If that empties the line, the block takes its place.
  vim.api.nvim_buf_set_text(bufnr, span.start_row, span.start_col, span.end_row, span.end_col, { "" })
  local line = vim.api.nvim_buf_get_lines(bufnr, span.start_row, row, false)[1]
  undojoin()
  if is_blank(line) then
    vim.api.nvim_buf_set_lines(bufnr, span.start_row, row, false, {})
    local after = M.insert_block(bufnr, row - 1, block)
    return resume(ctx, after, 0)
  end
  M.insert_block(bufnr, row, block)
  return resume(ctx, row, span.start_col)
end

--- Restores the prompt: removes a typed `#` and nothing else.
---@param ctx vergil.RangeContext
function M.cancel(ctx)
  local span, ref = ctx.span, ctx.ref
  if span.end_col > ref.span.end_col and vim.api.nvim_buf_is_valid(ctx.bufnr) then
    local line = vim.api.nvim_buf_get_lines(ctx.bufnr, span.start_row, span.start_row + 1, false)[1] or ""
    if line:sub(ref.span.end_col + 1, span.end_col) == config.options.triggers.range then
      vim.api.nvim_buf_set_text(ctx.bufnr, span.start_row, ref.span.end_col, span.end_row, span.end_col, { "" })
    end
  end
  resume(ctx, span.start_row + 1, ref.span.end_col)
end

--- Opens the selector for a context.
---@param ctx vergil.RangeContext
---@param target vergil.Target
---@return boolean ok
---@return string? err
local function read_text(target)
  local ok, lines = pcall(vim.fn.readfile, target.abs)
  if not ok then
    return nil, ("can't read %s"):format(target.abs)
  end
  for i = 1, math.min(#lines, 200) do
    if lines[i]:find("\n", 1, true) then -- readfile turns NUL into NL
      return nil, ("binary file: %s"):format(target.rel or target.abs)
    end
  end
  return lines
end

local function open(ctx, target)
  local lines, err = read_text(target)
  if not lines then
    return false, err
  end
  local r = ctx.ref
  local range = r.start_line and { r.start_line, r.end_line } or r.ignored_range
  require("vergil.ui.selector").open({
    abs = target.abs,
    title = target.rel or target.abs,
    lines = lines,
    range = range,
    on_done = function(result)
      M.apply(ctx, result, target.abs)
    end,
    on_cancel = function()
      M.cancel(ctx)
    end,
  })
  return true
end

--- `:Vergil range`: selects lines for the reference under the cursor.
---@return boolean ok
---@return string? err
function M.select_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return M.select_at(vim.api.nvim_get_current_buf(), row - 1, col)
end

--- The reference at a position in a prompt buffer, its target, and a context.
local function context_at(bufnr, row, col)
  local session = require("vergil.session").get(bufnr)
  if not session then
    return nil, "not enabled in this buffer (use :Vergil enable)"
  end
  local ref = parser.at(parser.parse_buffer(bufnr), row, col)
  if not ref then
    return nil, "no reference under the cursor"
  end
  local target, err = selectable(ref, session.root)
  if not target then
    return nil, err
  end
  local win = vim.fn.bufwinid(bufnr)
  return { bufnr = bufnr, win = win ~= -1 and win or vim.api.nvim_get_current_win(), ref = ref, span = ref.span, from_insert = false },
    target
end

--- Opens the selector for a file and inserts the result at a position
--- (used by the picker's `<C-r>`): there is no reference to replace yet.
---@param opts { bufnr: integer, win: integer, row: integer, col: integer, path: string, from_insert: boolean }
---@return boolean ok
---@return string? err
function M.select_for_path(opts)
  local session = require("vergil.session").get(opts.bufnr)
  if not session then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local span = { start_row = opts.row, start_col = opts.col, end_row = opts.row, end_col = opts.col }
  local ref = { mode = "mention", path = opts.path, explicit = true, span = span }
  local target, err = selectable(ref, session.root)
  if not target then
    return false, err
  end
  return open({ bufnr = opts.bufnr, win = opts.win, ref = ref, span = span, from_insert = opts.from_insert }, target)
end

--- Opens the selector for the reference at a 0-based position.
---@return boolean ok
---@return string? err
function M.select_at(bufnr, row, col)
  local ctx, target = context_at(bufnr, row, col)
  if not ctx then
    return false, target
  end
  return open(ctx, target)
end

--- `:Vergil snippet [both]`: replaces the ranged reference under the cursor
--- with its lines (like `gs` in the selector), or keeps the mention and adds
--- the lines below (`both`, like `gb`). Without a range, opens the selector.
---@param action? "snippet"|"both"
---@return boolean ok
---@return string? err
function M.snippet_at_cursor(action)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return M.snippet_at(vim.api.nvim_get_current_buf(), row - 1, col, action)
end

--- `snippet_at_cursor` for a 0-based position.
---@return boolean ok
---@return string? err
function M.snippet_at(bufnr, row, col, action)
  action = action or "snippet"
  if action ~= "snippet" and action ~= "both" then
    return false, ("unknown snippet mode %q; expected both or nothing"):format(action)
  end
  local ctx, target = context_at(bufnr, row, col)
  if not ctx then
    return false, target
  end
  local ref = ctx.ref
  local range = ref.start_line and { ref.start_line, ref.end_line } or ref.ignored_range
  if not range then
    return open(ctx, target)
  end
  local lines, rerr = read_text(target)
  if not lines then
    return false, rerr
  end
  if range[2] > #lines then
    return false, ("lines %d-%d are past the end of %s (%d lines)"):format(range[1], range[2], target.rel or target.abs, #lines)
  end
  M.apply(ctx, {
    action = action,
    start_line = range[1],
    end_line = range[2],
    lines = vim.list_slice(lines, range[1], range[2]),
  }, target.abs)
  return true
end

--- Handles the trigger character typed in Insert mode.
local function on_insert_char(bufnr)
  if vim.v.char ~= config.options.triggers.range then
    return
  end
  local session = require("vergil.session").get(bufnr)
  if not session then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local ref
  for _, r in ipairs(parser.parse_buffer(bufnr)) do
    if r.span.start_row == row - 1 and r.span.end_col == col then
      ref = r
    end
  end
  if not ref then
    return
  end
  local target = selectable(ref, session.root)
  if not target then
    return
  end
  local win = vim.api.nvim_get_current_win()
  vim.schedule(function()
    -- The trigger must actually have been inserted right after the reference.
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local trigger = config.options.triggers.range
    if line:sub(col + 1, col + #trigger) ~= trigger or vim.api.nvim_get_current_win() ~= win then
      return
    end
    local span = vim.deepcopy(ref.span)
    span.end_col = col + #trigger
    vim.cmd.stopinsert()
    local ctx = { bufnr = bufnr, win = win, ref = ref, span = span, from_insert = true }
    local ok, err = open(ctx, target)
    if not ok then
      vim.notify("vergil: " .. err, vim.log.levels.WARN)
      resume(ctx, row, span.end_col)
    end
  end)
end

---@param bufnr integer
function M.attach(bufnr)
  vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    buffer = bufnr,
    callback = function()
      on_insert_char(bufnr)
    end,
  })
end

---@param bufnr integer
function M.detach(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  end
end

return M
