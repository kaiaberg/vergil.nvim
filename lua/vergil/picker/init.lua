--- Full-size picker (`:Vergil pick [attach|mention|skills]`).
---
--- `Enter` inserts the type you started with, `<C-t>` switches between
--- attachment and mention, `<C-r>` opens line selection for the file.
--- Backends: telescope.nvim when available (or `picker.backend`), else
--- `vim.ui.select`, which supports `Enter` only.
local config = require("vergil.config")
local formatter = require("vergil.reference.formatter")

local M = {}

M.kinds = { "attach", "mention", "skills" }

---@class vergil.PickContext
---@field bufnr integer
---@field win integer
---@field row integer 0-based
---@field col integer 0-based insertion column
---@field root string
---@field from_insert boolean

---@class vergil.PickApi
---@field ctx vergil.PickContext
---@field choose fun(kind: string, value: string|vergil.Skill)
---@field select_lines fun(path: string)

local function backend()
  local name = config.options.picker.backend
  if name == "select" then
    return require("vergil.picker.select")
  end
  if name == "telescope" or name == "auto" then
    local ok = pcall(require, "telescope")
    if ok then
      return require("vergil.picker.telescope")
    elseif name == "telescope" then
      vim.notify("vergil: telescope.nvim is not available; using vim.ui.select", vim.log.levels.WARN)
    end
  end
  return require("vergil.picker.select")
end

--- Inserts text at the context's position. Adds a space before it when
--- needed, because Claude Code only treats `@` and `/` after whitespace as
--- references.
---@param ctx vergil.PickContext
---@param text string
function M.insert(ctx, text)
  if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.row, ctx.row + 1, false)[1] or ""
  local col = math.min(ctx.col, #line)
  local before = line:sub(col, col)
  if col > 0 and not before:match("%s") then
    text = " " .. text
  end
  vim.api.nvim_buf_set_text(ctx.bufnr, ctx.row, col, ctx.row, col, { text })
  if vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_set_current_win(ctx.win)
    local end_col = col + #text
    vim.api.nvim_win_set_cursor(ctx.win, { ctx.row + 1, ctx.from_insert and end_col or math.max(0, end_col - 1) })
    if ctx.from_insert then
      vim.cmd(end_col >= #line + #text and "startinsert!" or "startinsert")
    end
  end
end

--- Text to insert for a chosen item.
---@param kind string
---@param value string|vergil.Skill
---@return string?
function M.text_for(kind, value)
  if kind == "skills" then
    return config.options.triggers.skills .. value.name .. " "
  elseif kind == "mention" then
    return formatter.mention(value, nil, nil, config.options.mention.format)
  end
  return formatter.attachment(value, config.adapter())
end

---@param kind? "attach"|"mention"|"skills"
---@return boolean ok
---@return string? err
function M.pick(kind)
  kind = kind or "attach"
  if not vim.tbl_contains(M.kinds, kind) then
    return false, ("unknown picker %q; expected attach, mention or skills"):format(kind)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local session = require("vergil.session").get(bufnr)
  if not session then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local win = vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local from_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  local line = vim.api.nvim_get_current_line()
  -- In Normal mode, insert after the cursor character, like `a`.
  local insert_col = (from_insert or line == "") and col or math.min(col + 1, #line)
  ---@type vergil.PickContext
  local ctx = { bufnr = bufnr, win = win, row = row - 1, col = insert_col, root = session.root, from_insert = from_insert }
  if from_insert then
    vim.cmd.stopinsert()
  end

  ---@type vergil.PickApi
  local api = {
    ctx = ctx,
    choose = function(k, value)
      local text = M.text_for(k, value)
      if text then
        M.insert(ctx, text)
      end
    end,
    select_lines = function(path)
      local ok, err = require("vergil.range").select_for_path({
        bufnr = ctx.bufnr,
        win = ctx.win,
        row = ctx.row,
        col = ctx.col,
        path = path,
        from_insert = ctx.from_insert,
      })
      if not ok then
        vim.notify("vergil: " .. err, vim.log.levels.WARN)
      end
    end,
  }

  local b = backend()
  if kind == "skills" then
    b.pick_skills(require("vergil.skills").items(session.root), api)
  else
    require("vergil.files").list(session.root, function(files)
      b.pick_files(files, kind, api)
    end)
  end
  return true
end

return M
