--- Attaches the in-process server to prompt buffers, plus completion-engine
--- glue that can't live in the server.
local config = require("vergil.config")
local server = require("vergil.lsp.server")

local M = {}

local group = vim.api.nvim_create_augroup("vergil.lsp", { clear = true })

--- Reopens completion after Backspace inside a reference. Engines close the
--- menu when Backspace deletes a non-keyword character such as `.` or `/`
--- (blink: completion/trigger/init.lua; native never re-queries on
--- Backspace), and their settings can't be scoped to prompt buffers.
local function reopen_completion()
  local blink = package.loaded["blink.cmp"]
  if blink and blink.is_menu_visible then
    if not blink.is_menu_visible() then
      blink.show()
    end
    return
  end
  local cmp = package.loaded["cmp"]
  if cmp and cmp.visible then
    if not cmp.visible() then
      cmp.complete()
    end
    return
  end
  if vim.fn.pumvisible() == 0 and vim.lsp.completion and vim.lsp.completion.get then
    vim.lsp.completion.get()
  end
end

local function watch_backspace(bufnr)
  local last ---@type { row: integer, col: integer, len: integer }?
  local function snapshot()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    last = { row = row, col = col, len = #vim.api.nvim_get_current_line() }
  end
  vim.api.nvim_create_autocmd("InsertEnter", { group = group, buffer = bufnr, callback = snapshot })
  -- CursorMovedI fires before TextChangedI, so only record pure cursor moves.
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    buffer = bufnr,
    callback = function()
      if not last or #vim.api.nvim_get_current_line() == last.len then
        snapshot()
      end
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = bufnr,
    callback = function()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local was = last
      snapshot()
      local backspace = was and was.row == row and col < was.col and was.len - #line == was.col - col
      if not backspace or not config.options.completion.reopen_on_backspace then
        return
      end
      local completion = require("vergil.lsp.completion")
      local session = require("vergil.session").get(bufnr)
      if not session then
        return
      end
      if completion.typing_token(line, col) or completion.existing_token(bufnr, row - 1, col, session.root) then
        vim.schedule(reopen_completion) -- after the engine has hidden its menu
      end
    end,
  })
end

---@param bufnr integer
---@return integer? client_id
function M.attach(bufnr)
  local session = require("vergil.session").get(bufnr)
  if not session then
    return nil
  end
  require("vergil.files").prefetch(session.root)
  local client_id = vim.lsp.start({
    name = server.name,
    cmd = server.cmd,
    root_dir = session.root,
    -- One client per root; `reuse_client` defaults compare name and root_dir.
  }, { bufnr = bufnr })
  if not client_id then
    return nil
  end
  if config.options.completion.native then
    -- Idempotent per buffer and client, so a user's own LspAttach enabling
    -- native completion for every client doesn't register it twice.
    vim.lsp.completion.enable(true, client_id, bufnr, { autotrigger = true })
  end
  if not vim.b[bufnr].vergil_watching then
    vim.b[bufnr].vergil_watching = true
    watch_backspace(bufnr)
  end
  return client_id
end

---@param bufnr integer
function M.detach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = server.name })) do
    vim.lsp.buf_detach_client(bufnr, client.id)
  end
  vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  vim.b[bufnr].vergil_watching = nil
end

return M
