--- `<Plug>` mappings, and the opt-in preset (`keymaps.preset = true`) that
--- maps them buffer-locally in prompt buffers. Vergil never maps keys
--- unless asked (plan §2, principle 7).
local M = {}

---@type { lhs: string, plug: string, desc: string }[]
M.preset = {
  { lhs = "gs", plug = "<Plug>(vergil-snippet)", desc = "Replace reference with its lines" },
  { lhs = "gb", plug = "<Plug>(vergil-snippet-both)", desc = "Add the reference's lines below" },
  { lhs = "<Esc>", plug = "<Plug>(vergil-close-preview)", desc = "Close the preview, or Esc" },
}

local group = vim.api.nvim_create_augroup("vergil.keymaps", { clear = true })

--- Focus ids of preview floats: LSP hover (`K`) and `:Vergil preview`.
local FOCUS_IDS = { "textDocument/hover", "vergil-preview" }

--- Closes the preview float opened from a buffer (`K` or `:Vergil preview`).
--- Neovim records it in `b:lsp_floating_preview`.
---@param bufnr integer?
---@return boolean closed
function M.close_preview(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local win = vim.b[bufnr].lsp_floating_preview
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
    return true
  end
  return false
end

--- Runs what `<Esc>` would have done without our buffer-local mapping:
--- a global `<Esc>` mapping if there is one, else a plain `<Esc>`.
local function fallback_esc()
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.lhs == "<Esc>" then
      if map.callback then
        map.callback()
      elseif map.rhs and map.rhs ~= "" then
        vim.api.nvim_feedkeys(vim.keycode(map.rhs), map.noremap == 1 and "n" or "m", false)
      end
      return
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
end

--- Defines the global `<Plug>` mappings. Called once from plugin/vergil.lua.
function M.define_plugs()
  local function run(sub)
    return function()
      require("vergil.commands").run({ fargs = sub })
    end
  end
  vim.keymap.set("n", "<Plug>(vergil-snippet)", run({ "snippet" }), { desc = "vergil: replace reference with its lines" })
  vim.keymap.set("n", "<Plug>(vergil-snippet-both)", run({ "snippet", "both" }), { desc = "vergil: add the reference's lines below" })
  vim.keymap.set("n", "<Plug>(vergil-close-preview)", function()
    if not M.close_preview() then
      fallback_esc()
    end
  end, { desc = "vergil: close the preview, or Esc" })
end

--- In a focused preview float (after pressing `K` twice), Neovim maps only
--- `q` to close it; map `<Esc>` there too.
local function on_win_enter(prompt_bufnr)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative == "" then
    return
  end
  for _, id in ipairs(FOCUS_IDS) do
    if vim.w[win][id] == prompt_bufnr then
      local float_buf = vim.api.nvim_win_get_buf(win)
      vim.keymap.set("n", "<Esc>", function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end, { buffer = float_buf, nowait = true, desc = "vergil: close the preview" })
      return
    end
  end
end

---@param bufnr integer
function M.attach(bufnr)
  if not require("vergil.config").options.keymaps.preset then
    return
  end
  for _, m in ipairs(M.preset) do
    vim.keymap.set("n", m.lhs, m.plug, { buffer = bufnr, remap = true, desc = "vergil: " .. m.desc })
  end
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return true -- remove the autocommand
      end
      on_win_enter(bufnr)
    end,
    desc = "vergil: Esc closes focused previews of buffer " .. bufnr,
  })
end

---@param bufnr integer
function M.detach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ours = {}
  for _, m in ipairs(M.preset) do
    ours[m.lhs] = m.plug
  end
  -- Only delete mappings vergil made; leave a user's own buffer mappings.
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if ours[map.lhs] and map.rhs == ours[map.lhs] then
      vim.keymap.del("n", map.lhs, { buffer = bufnr })
    end
  end
  for _, au in ipairs(vim.api.nvim_get_autocmds({ group = group, event = "WinEnter" })) do
    if au.desc == "vergil: Esc closes focused previews of buffer " .. bufnr then
      vim.api.nvim_del_autocmd(au.id)
    end
  end
end

return M
