--- The line selector: a float showing a read-only scratch copy of a file,
--- navigated with ordinary Vim motions, search and Visual mode.
---
--- It never loads the real file into a buffer, so no swapfile, no LSP client
--- and no buffer-local mappings leak onto it. Highlighting goes through
--- treesitter or 'syntax' directly instead of 'filetype', which would fire
--- FileType autocommands (and with them `vim.lsp.enable` configs).
local config = require("vergil.config")
local float = require("vergil.ui.float")

local M = {}

---@alias vergil.SelectorAction "mention"|"snippet"|"both"

---@class vergil.SelectorResult
---@field action vergil.SelectorAction
---@field start_line integer
---@field end_line integer
---@field lines string[] the selected source lines, verbatim

---@class vergil.SelectorOpts
---@field abs string absolute path of the file
---@field title string shown in the border
---@field lines string[] file contents
---@field cursor integer? 1-based line to start on
---@field range integer[]? { start, end } to preselect
---@field on_done fun(result: vergil.SelectorResult)
---@field on_cancel fun()

local function highlight(bufnr, abs)
  local ft = vim.filetype.match({ filename = abs, buf = bufnr })
  if not ft then
    return
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.start, bufnr, lang) then
    vim.bo[bufnr].syntax = ft
  end
end

local function key_label(lhs)
  return (lhs:gsub("<CR>", "Enter"):gsub("<Esc>", "Esc"))
end

--- Opens the selector. Exactly one of `on_done` / `on_cancel` is called.
---@param opts vergil.SelectorOpts
---@return integer win
function M.open(opts)
  local keys = config.options.selector.keys
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  highlight(bufnr, opts.abs)

  local footer = (" %s mention · %s snippet · %s both · %s cancel "):format(
    key_label(keys.mention),
    key_label(keys.snippet),
    key_label(keys.both),
    table.concat(vim.tbl_map(key_label, keys.cancel), "/")
  )
  local win = float.open(bufnr, { width = 0.85, height = 0.8, title = " " .. opts.title .. " ", footer = footer })
  vim.wo[win].number = true
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local finished = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function cancel()
    if finished then
      return
    end
    finished = true
    close()
    opts.on_cancel()
  end
  local function done(action, s, e)
    if finished then
      return
    end
    finished = true
    if s > e then
      s, e = e, s
    end
    local lines = vim.list_slice(opts.lines, s, e)
    close()
    opts.on_done({ action = action, start_line = s, end_line = e, lines = lines })
  end

  local function act(action)
    return function()
      local mode = vim.api.nvim_get_mode().mode
      if mode == "V" or mode == "v" or mode == "\22" then
        local s, e = vim.fn.line("v"), vim.fn.line(".")
        vim.cmd.normal({ vim.keycode("<Esc>"), bang = true })
        done(action, s, e)
      else
        local s = vim.fn.line(".")
        done(action, s, math.min(s + vim.v.count1 - 1, #opts.lines))
      end
    end
  end

  local map = function(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = bufnr, nowait = true, desc = "vergil: " .. desc })
  end
  map({ "n", "x" }, keys.mention, act("mention"), "insert mention")
  map({ "n", "x" }, keys.snippet, act("snippet"), "insert snippet")
  map({ "n", "x" }, keys.both, act("both"), "insert mention and snippet")
  for _, lhs in ipairs(keys.cancel) do
    -- Normal mode only: Esc in Visual mode keeps its usual meaning.
    map("n", lhs, cancel, "cancel")
  end

  -- Closing or leaving the window any other way counts as cancelling.
  vim.api.nvim_create_autocmd({ "WinClosed", "WinLeave" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(cancel)
    end,
  })

  local last = math.max(1, #opts.lines)
  local start = math.min(math.max(opts.cursor or (opts.range and opts.range[1]) or 1, 1), last)
  vim.api.nvim_win_set_cursor(win, { start, 0 })
  if opts.range and opts.range[2] and opts.range[2] > opts.range[1] then
    vim.cmd("normal! V" .. (math.min(opts.range[2], last) - start) .. "j")
  end
  vim.cmd("normal! zz")
  return win
end

return M
