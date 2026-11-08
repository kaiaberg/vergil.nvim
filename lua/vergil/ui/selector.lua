--- The line selector: a float showing a read-only scratch copy of a file,
--- navigated with ordinary Vim motions, search and Visual mode.
---
--- It never loads the real file into a buffer, so no swapfile, no LSP client
--- and no buffer-local mappings leak onto it. Its filetype is
--- `vergil-selector`, not the file's, which would start the language's
--- ftplugins and `vim.lsp.enable` configs; highlighting goes through
--- treesitter or 'syntax' directly.
local config = require("vergil.config")
local float = require("vergil.ui.float")

local M = {}

-- Buffer-local autocmds; they go when the selector's buffer is wiped.
local group = vim.api.nvim_create_augroup("vergil.selector", { clear = true })

local active_cancel ---@type fun()?

--- Cancels an open selector right away (not on the next tick), e.g. before
--- submitting, so a typed `#` is removed before the prompt is written.
function M.cancel_active()
  if active_cancel then
    active_cancel()
  end
end

---@alias vergil.SelectorAction "mention"|"snippet"|"both"

---@class vergil.SelectorResult
---@field action vergil.SelectorAction
---@field start_line integer
---@field end_line integer
---@field lines string[] the selected source lines, verbatim
---@field symbol string? the function or class the lines cover exactly

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
  vim.bo[bufnr].filetype = "vergil-selector" -- before highlighting: FileType resets 'syntax'
  highlight(bufnr, opts.abs)

  local footer = (" %s mention · %s snippet · %s both · %s symbols · %s cancel "):format(
    key_label(keys.mention),
    key_label(keys.snippet),
    key_label(keys.both),
    key_label(keys.symbols),
    table.concat(vim.tbl_map(key_label, keys.cancel), "/")
  )
  local win = float.open(bufnr, { width = 0.85, height = 0.8, title = " " .. opts.title .. " ", footer = footer })
  vim.wo[win].number = true
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local finished = false
  local picking = false -- a symbol list is open; leaving the window is fine
  local symbol_list ---@type vergil.Symbol[]|false|nil
  local symbol_err ---@type string?
  local function file_symbols()
    if symbol_list == nil then
      symbol_list, symbol_err = require("vergil.symbols").list(opts.lines, opts.abs)
      symbol_list = symbol_list or false
    end
    return symbol_list or nil, symbol_err
  end
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
    active_cancel = nil
    close()
    opts.on_cancel()
  end
  local function done(action, s, e)
    if finished then
      return
    end
    finished = true
    active_cancel = nil
    if s > e then
      s, e = e, s
    end
    local lines = vim.list_slice(opts.lines, s, e)
    local symbol
    if config.options.mention.symbols then
      symbol = require("vergil.symbols").exact(file_symbols(), s, e)
    end
    close()
    opts.on_done({ action = action, start_line = s, end_line = e, lines = lines, symbol = symbol and symbol.name })
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

  --- Selects a symbol's lines, ready for mention, snippet or both.
  local function select_lines(s, e)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_set_current_win(win)
    if vim.api.nvim_get_mode().mode:match("^[vV\22]") then
      vim.cmd.normal({ vim.keycode("<Esc>"), bang = true })
    end
    vim.api.nvim_win_set_cursor(win, { s, 0 })
    vim.cmd("normal! V" .. (e > s and (e - s) .. "j" or ""))
  end
  map({ "n", "x" }, keys.symbols, function()
    local list, err = file_symbols()
    if not list or #list == 0 then
      vim.notify("vergil: " .. (err or "no functions or classes found"), vim.log.levels.INFO)
      return
    end
    local width = 0
    for _, sym in ipairs(list) do
      width = math.max(width, sym.depth * 2 + #sym.name)
    end
    picking = true
    vim.ui.select(list, {
      prompt = "Symbols",
      kind = "vergil.symbols",
      format_item = function(sym)
        local label = ("  "):rep(sym.depth) .. sym.name
        return ("%s%s  L%d-L%d"):format(label, (" "):rep(width - #label), sym.start_line, sym.end_line)
      end,
    }, function(choice)
      picking = false
      if finished then
        return
      end
      if choice then
        select_lines(choice.start_line, choice.end_line)
      elseif vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
    end)
  end, "list functions and classes")

  active_cancel = cancel

  -- Closing or leaving the window any other way counts as cancelling,
  -- except leaving it for the symbol list.
  vim.api.nvim_create_autocmd({ "WinClosed", "WinLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      if ev.event == "WinLeave" and picking then
        return
      end
      vim.schedule(cancel)
      return true
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
