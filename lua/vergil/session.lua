--- Prompt sessions: which buffers vergil is enabled in, and the session root.
---
--- The root is captured once, when the plugin loads, so `:cd` during the
--- session doesn't move it: the agent resolves `@` paths against the directory
--- it was started in, which is Neovim's working directory at startup.
local config = require("vergil.config")

local M = {}

---@class vergil.Session
---@field bufnr integer
---@field root string
---@field agent string

local sessions = {} ---@type table<integer, vergil.Session>
local startup_root ---@type string?

--- Records Neovim's working directory as the root. Only the first call counts.
function M.capture_root()
  startup_root = startup_root or vim.fn.getcwd()
end

--- The session root: explicit configuration, then the captured startup cwd.
---@return string
function M.root()
  M.capture_root()
  return vim.fs.normalize(config.options.root or startup_root)
end

--- Whether a buffer name's file name (not its directory) matches the
--- activation patterns.
---@param name string
---@return boolean
function M.matches(name)
  local tail = vim.fs.basename(name)
  if tail == "" then
    return false
  end
  for _, pattern in ipairs(config.filename_patterns()) do
    if vim.regex(vim.fn.glob2regpat(pattern)):match_str(tail) then
      return true
    end
  end
  return false
end

---@param bufnr integer
---@return vergil.Session?
function M.get(bufnr)
  return sessions[bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr]
end

---@param bufnr integer
---@return boolean
function M.is_enabled(bufnr)
  return M.get(bufnr) ~= nil
end

--- Enables vergil in a buffer. Idempotent.
---@param bufnr integer
---@return vergil.Session
function M.enable(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if sessions[bufnr] then
    return sessions[bufnr]
  end
  local session = { bufnr = bufnr, root = M.root(), agent = config.options.agent }
  sessions[bufnr] = session
  vim.b[bufnr].vergil_enabled = true
  require("vergil.lsp.client").attach(bufnr)
  vim.api.nvim_exec_autocmds("User", { pattern = "VergilEnable", data = { bufnr = bufnr }, modeline = false })
  return session
end

--- Disables vergil in a buffer. Idempotent.
---@param bufnr integer
function M.disable(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not sessions[bufnr] then
    return
  end
  sessions[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].vergil_enabled = nil
    require("vergil.lsp.client").detach(bufnr)
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "VergilDisable", data = { bufnr = bufnr }, modeline = false })
end

--- Enables vergil when a buffer's file name matches. Used by autocommands.
---@param bufnr integer
function M.maybe_enable(bufnr)
  if vim.bo[bufnr].buftype == "" and M.matches(vim.api.nvim_buf_get_name(bufnr)) then
    M.enable(bufnr)
  end
end

--- Forgets a buffer that is being deleted, without firing events on it.
---@param bufnr integer
function M.forget(bufnr)
  sessions[bufnr] = nil
end

return M
