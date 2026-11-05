--- Safe submit and abort (plan §6.10).
---
--- `:wq` in the prompt leaves Neovim running when other windows are open,
--- which leaves the agent waiting, and quitting with modified buffers fails.
--- `:Vergil submit` writes the prompt, asks what to do about other modified
--- buffers (never discarding them silently) and exits. `:Vergil abort` does
--- the same check and exits with `:cquit`, so Claude Code restores the
--- prompt from before `Ctrl+G` (M0: any non-zero exit discards the edit).
local M = {}

--- Overridable for tests.
M.confirm = function(msg, choices, default)
  return vim.fn.confirm(msg, choices, default, "Question")
end
M.exit = function(cmd)
  vim.cmd(cmd)
end

--- The prompt buffer: the current buffer if it is one, else the alternate,
--- else the only enabled buffer.
---@return integer? bufnr
---@return string? err
local function prompt_buffer()
  local session = require("vergil.session")
  local cur = vim.api.nvim_get_current_buf()
  if session.is_enabled(cur) then
    return cur
  end
  local alt = vim.fn.bufnr("#")
  if alt > 0 and session.is_enabled(alt) then
    return alt
  end
  local found
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if session.is_enabled(bufnr) then
      if found then
        return nil, "several prompt buffers are open; run this from the one to submit"
      end
      found = bufnr
    end
  end
  if not found then
    return nil, "no prompt buffer (use :Vergil enable)"
  end
  return found
end

local function close_floats()
  require("vergil.ui.selector").cancel_active()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

---@param except integer?
---@return integer[]
function M.modified_buffers(except)
  return vim.tbl_filter(function(b)
    return b ~= except
      and vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buftype == ""
      and vim.bo[b].modified
  end, vim.api.nvim_list_bufs())
end

local function write(bufnr)
  return pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write")
  end)
end

--- Asks what to do with other modified buffers.
---@return "none"|"saved"|"discard"|nil decision nil means cancel
---@return string? err
local function settle_others(prompt, verb)
  local mods = M.modified_buffers(prompt)
  if #mods == 0 then
    return "none"
  end
  local names = vim.tbl_map(function(b)
    local name = vim.api.nvim_buf_get_name(b)
    return "  " .. (name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("[No Name] " .. b))
  end, mods)
  local msg = ("%d other modified buffer%s:\n%s\n\nSave before %s?"):format(
    #mods,
    #mods == 1 and "" or "s",
    table.concat(names, "\n"),
    verb
  )
  local choice = M.confirm(msg, "&Save all\n&Discard changes\n&Cancel", 1)
  if choice == 1 then
    for _, b in ipairs(mods) do
      local ok, err = write(b)
      if not ok then
        return nil, ("couldn't write %s: %s"):format(vim.api.nvim_buf_get_name(b), err)
      end
    end
    return "saved"
  elseif choice == 2 then
    return "discard"
  end
  return nil, "cancelled"
end

--- Writes the prompt and exits Neovim.
---@return boolean ok
---@return string? err
function M.submit()
  local bufnr, err = prompt_buffer()
  if not bufnr then
    return false, err
  end
  close_floats()
  local ok, werr = write(bufnr)
  if not ok then
    return false, ("couldn't write the prompt: %s"):format(werr)
  end
  local decision, serr = settle_others(bufnr, "submitting")
  if not decision then
    return false, serr
  end
  M.exit(decision == "discard" and "qall!" or "qall")
  return true
end

--- Exits so the agent restores the prompt from before `Ctrl+G`.
---@return boolean ok
---@return string? err
function M.abort()
  local bufnr, err = prompt_buffer()
  if not bufnr then
    return false, err
  end
  close_floats()
  local decision, serr = settle_others(bufnr, "aborting")
  if not decision then
    return false, serr
  end
  M.exit("cquit")
  return true
end

return M
