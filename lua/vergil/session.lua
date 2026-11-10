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
---@field agent string key of the buffer's agent under `agents`, or "plain"
---@field jump { row: integer, col: integer, abs: string }? reference last opened with `gd` or `:Vergil open` (0-based)
---@field status vergil.Status? the latest prompt status (`vergil.status`)

local sessions = {} ---@type table<integer, vergil.Session>
--- The prompt file's bytes when vergil first saw it, for `:Vergil abort`.
--- Kept across disable/enable, so only the very first read counts.
local originals = {} ---@type table<integer, string[]|false>
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

--- The agent whose `match` rules cover a buffer name, if any.
---@param name string
---@return vergil.Agent?
function M.matches(name)
  return require("vergil.agents").match(name)
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

--- The prompt buffer: the current buffer if it is one, else the alternate,
--- else the only enabled buffer.
---@return integer? bufnr
---@return string? err
function M.find_prompt()
  local cur = vim.api.nvim_get_current_buf()
  if M.is_enabled(cur) then
    return cur
  end
  local alt = vim.fn.bufnr("#")
  if alt > 0 and M.is_enabled(alt) then
    return alt
  end
  local found
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if M.is_enabled(bufnr) then
      if found then
        return nil, "several prompt buffers are open; run this from the one you mean"
      end
      found = bufnr
    end
  end
  if not found then
    return nil, "no prompt buffer (use :Vergil enable)"
  end
  return found
end

--- Enables vergil in a buffer. Idempotent. The agent is `agent` (a key
--- under `agents`), else the one matching the buffer's name, else "plain".
---@param bufnr integer
---@param agent string?
---@return vergil.Session
function M.enable(bufnr, agent)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if sessions[bufnr] then
    if agent then
      sessions[bufnr].agent = agent
    end
    return sessions[bufnr]
  end
  if not agent then
    local matched = M.matches(vim.api.nvim_buf_get_name(bufnr))
    agent = matched and matched.key or require("vergil.agents").plain.key
  end
  local session = { bufnr = bufnr, root = M.root(), agent = agent }
  sessions[bufnr] = session
  if originals[bufnr] == nil then
    local name = vim.api.nvim_buf_get_name(bufnr)
    originals[bufnr] = vim.fn.filereadable(name) == 1 and vim.fn.readfile(name, "b") or false
  end
  vim.b[bufnr].vergil_enabled = true
  require("vergil.lsp.client").attach(bufnr)
  require("vergil.range").attach(bufnr)
  require("vergil.keymaps").attach(bufnr)
  require("vergil.picker").attach_trigger(bufnr)
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
    require("vergil.status").clear(bufnr)
    require("vergil.lsp.client").detach(bufnr)
    require("vergil.range").detach(bufnr)
    require("vergil.keymaps").detach(bufnr)
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "VergilDisable", data = { bufnr = bufnr }, modeline = false })
end

--- Enables vergil when an agent's `match` covers the buffer's name. Used by
--- autocommands.
---@param bufnr integer
function M.maybe_enable(bufnr)
  local agent = vim.bo[bufnr].buftype == "" and M.matches(vim.api.nvim_buf_get_name(bufnr))
  if agent then
    M.enable(bufnr, agent.key)
  end
end

local function is_normal_win(win)
  return vim.api.nvim_win_get_config(win).relative == ""
end

--- On `:q` in the last window, when it shows something other than a prompt
--- (e.g. a file opened with `gd`), reopens the prompt in a new window without
--- moving focus. `:q` then closes only the current window and lands back in
--- the prompt, instead of exiting Neovim and returning to the agent.
--- Called from a QuitPre autocommand in plugin/vergil.lua.
function M.on_quit_pre()
  if not config.options.return_to_prompt then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if sessions[vim.api.nvim_win_get_buf(win)] or #vim.api.nvim_list_tabpages() > 1 then
    return
  end
  if #vim.tbl_filter(is_normal_win, vim.api.nvim_tabpage_list_wins(0)) > 1 then
    return
  end
  -- Prefer the alternate buffer (where the jump came from), else any prompt.
  local alt = vim.fn.bufnr("#")
  local target = sessions[alt] and alt or nil
  if not target then
    for bufnr in pairs(sessions) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        target = bufnr
        break
      end
    end
  end
  if target then
    vim.api.nvim_open_win(target, false, { split = "above", win = win })
  end
end

--- Forgets a buffer that is being deleted, without firing events on it.
---@param bufnr integer
function M.forget(bufnr)
  sessions[bufnr] = nil
  originals[bufnr] = nil
end

--- The prompt file as it was when vergil first enabled the buffer, or nil
--- when the file didn't exist yet.
---@param bufnr integer
---@return string[]?
function M.original(bufnr)
  return originals[bufnr] or nil
end

return M
