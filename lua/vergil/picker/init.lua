--- Full-size picker (`:Vergil pick [attach|mention|skills|changed]`).
---
--- `Enter` inserts the type you started with, `<C-t>` switches between
--- attachment and mention, `<C-r>` opens line selection for the file, and
--- telescope's `<Tab>` marks several files to insert at once. `changed`
--- lists files changed in git, to attach.
--- Backends: telescope.nvim when available (or `picker.backend`), else
--- `vim.ui.select`, which supports `Enter` only.
local config = require("vergil.config")
local formatter = require("vergil.reference.formatter")

local M = {}

M.kinds = { "attach", "mention", "skills", "changed" }

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
---@field choose_many fun(kind: string, values: string[]) several files, inserted space-separated
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
--- references, and after it, so it doesn't run into the following text.
---@param ctx vergil.PickContext
---@param text string
function M.insert(ctx, text)
  if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.row, ctx.row + 1, false)[1] or ""
  local col = math.min(ctx.col, #line)
  local before, after = line:sub(col, col), line:sub(col + 1, col + 1)
  if col > 0 and not before:match("%s") then
    text = " " .. text
  end
  local pad = (after ~= "" and not after:match("%s") and not text:match("%s$")) and " " or ""
  vim.api.nvim_buf_set_text(ctx.bufnr, ctx.row, col, ctx.row, col, { text .. pad })
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

---@class vergil.PickFilesOpts
---@field title string?
---@field labels table<string, string>? text shown after each path, e.g. a git status

---@param kind? "attach"|"mention"|"skills"|"changed"
---@return boolean ok
---@return string? err
function M.pick(kind)
  kind = kind or "attach"
  if not vim.tbl_contains(M.kinds, kind) then
    return false, ("unknown picker %q; expected attach, mention, skills or changed"):format(kind)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local session = require("vergil.session").get(bufnr)
  if not session then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local changed
  if kind == "changed" then
    local err
    changed, err = require("vergil.git").changed(session.root)
    if not changed then
      return false, err
    end
    -- Not the prompt itself, when it's drafted inside the repository.
    local self = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(bufnr))
    changed = vim.tbl_filter(function(f)
      local abs = f.path:sub(1, 1) == "/" and f.path or (session.root .. "/" .. f.path)
      return not self or vim.uv.fs_realpath(abs) ~= self
    end, changed)
    if #changed == 0 then
      return false, "no changed files"
    end
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
    choose_many = function(k, values)
      local parts = {}
      for _, value in ipairs(values) do
        parts[#parts + 1] = M.text_for(k, value)
      end
      if #parts > 0 then
        M.insert(ctx, table.concat(parts, " "))
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
  elseif kind == "changed" then
    local paths, labels = {}, {}
    for _, f in ipairs(changed) do
      paths[#paths + 1] = f.path
      labels[f.path] = f.status
    end
    b.pick_files(paths, "attach", api, { title = "Changed files", labels = labels })
  else
    require("vergil.files").list(session.root, function(files)
      b.pick_files(files, kind, api)
    end)
  end
  return true
end

return M
