--- `<Plug>` mappings, and the opt-in preset (`keymaps.preset = true`) that
--- maps them buffer-locally in prompt buffers. Vergil never maps keys
--- unless asked (plan §2, principle 7).
local M = {}

---@type { lhs: string, plug: string, desc: string, mode: string? }[]
M.preset = {
  { lhs = "K", plug = "<Plug>(vergil-hover)", desc = "Preview; again closes it (preview.on_repeat)" },
  { lhs = "gs", plug = "<Plug>(vergil-snippet)", desc = "Replace reference with its lines" },
  { lhs = "gb", plug = "<Plug>(vergil-snippet-both)", desc = "Add the reference's lines below" },
  { lhs = "<Esc>", plug = "<Plug>(vergil-close-preview)", desc = "Close the preview, or Esc" },
  { lhs = "gf", plug = "<Plug>(vergil-open)", desc = "Open the reference, or gf" },
  { lhs = "<C-w>f", plug = "<Plug>(vergil-open-split)", desc = "Open the reference in a split, or <C-w>f" },
  { lhs = "<C-w>gf", plug = "<Plug>(vergil-open-tab)", desc = "Open the reference in a tab, or <C-w>gf" },
  { lhs = "ZZ", plug = "<Plug>(vergil-submit)", desc = "Submit the prompt" },
  { lhs = "ZQ", plug = "<Plug>(vergil-abort)", desc = "Abort: restore the prompt from before Ctrl+G" },
  { lhs = "<C-g>", plug = "<Plug>(vergil-pick-expand)", desc = "Open the picker on what you're typing", mode = "i" },
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

local function notify(err)
  vim.notify("vergil: " .. err, vim.log.levels.WARN)
end

--- An action reporting `(ok, err)`; `fallback` runs native keys when there
--- is no reference under the cursor.
local function act(fn, fallback)
  return function()
    local ok, err = fn()
    if ok then
      return
    end
    if fallback and err == "no reference under the cursor" then
      vim.cmd.normal({ vim.keycode(fallback), bang = true })
    elseif err then
      notify(err)
    end
  end
end

--- Defines the global `<Plug>` mappings. Called once from plugin/vergil.lua.
function M.define_plugs()
  local vergil = function()
    return require("vergil")
  end
  local range = function()
    return require("vergil.range")
  end
  local plugs = {
    ["snippet"] = { act(function() return range().snippet_at_cursor("snippet") end), "replace reference with its lines" },
    ["snippet-both"] = { act(function() return range().snippet_at_cursor("both") end), "add the reference's lines below" },
    ["range"] = { act(function() return range().select_at_cursor() end), "select lines for the reference" },
    ["toggle"] = { act(function() return vergil().toggle() end), "convert between attachment and mention" },
    ["preview"] = { act(function() return vergil().preview() end), "preview the reference" },
    ["open"] = { act(function() return vergil().open() end, "gf"), "open the reference" },
    ["open-split"] = { act(function() return vergil().open("split") end, "<C-w>f"), "open the reference in a split" },
    ["open-vsplit"] = { act(function() return vergil().open("vsplit") end), "open the reference in a vsplit" },
    ["open-tab"] = { act(function() return vergil().open("tab") end, "<C-w>gf"), "open the reference in a tab" },
    ["submit"] = { act(function() return require("vergil.submit").submit() end), "submit the prompt" },
    ["abort"] = { act(function() return require("vergil.submit").abort() end), "abort and restore the prompt" },
    ["hover"] = {
      function()
        local win = vim.b.lsp_floating_preview
        if win and vim.api.nvim_win_is_valid(win) and require("vergil.config").options.preview.on_repeat == "close" then
          vim.api.nvim_win_close(win, true)
        else
          vim.lsp.buf.hover() -- opens it, or moves into an open one
        end
      end,
      "preview (LSP hover); again closes or focuses it",
    },
    ["close-preview"] = {
      function()
        if not M.close_preview() then
          fallback_esc()
        end
      end,
      "close the preview, or Esc",
    },
  }
  for name, p in pairs(plugs) do
    vim.keymap.set("n", ("<Plug>(vergil-%s)"):format(name), p[1], { desc = "vergil: " .. p[2] })
  end
  -- Send lines from a file to the prompt: the Visual selection, or the
  -- cursor line in Normal mode.
  for suffix, action in pairs({ [""] = "mention", ["-snippet"] = "snippet", ["-both"] = "both" }) do
    vim.keymap.set({ "n", "x" }, "<Plug>(vergil-send" .. suffix .. ")", function()
      local send = require("vergil.send")
      local line1, line2 = send.selected_lines()
      local ok, err = send.send(action, line1, line2)
      if not ok then
        notify(err)
      end
    end, { desc = "vergil: send lines to the prompt (" .. action .. ")" })
  end
  for _, kind in ipairs(require("vergil.picker").kinds) do
    local lhs = kind == "all" and "<Plug>(vergil-pick)" or ("<Plug>(vergil-pick-%s)"):format(kind)
    vim.keymap.set({ "n", "i" }, lhs, function()
      local ok, err = require("vergil.picker").pick(kind)
      if not ok then
        notify(err)
      end
    end, { desc = "vergil: pick (" .. kind .. ")" })
  end
  vim.keymap.set({ "n", "i" }, "<Plug>(vergil-pick-expand)", function()
    local ok, err = require("vergil.picker").expand()
    if not ok then
      notify(err)
    end
  end, { desc = "vergil: open the picker on what you're typing" })
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

--- With the preset, Visual-mode keys in file buffers (not prompts) send the
--- selection to the prompt. They are the line selector's keys, and are only
--- mapped in a Neovim that has a prompt open.
---@param bufnr integer
function M.attach_source(bufnr)
  local config = require("vergil.config")
  if not config.options.keymaps.preset or vim.b[bufnr].vergil_send_keys then
    return
  end
  local session = require("vergil.session")
  if session.is_enabled(bufnr) or vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then
    return
  end
  vim.b[bufnr].vergil_send_keys = true
  local keys = config.options.selector.keys
  for action, plug in pairs({ mention = "<Plug>(vergil-send)", snippet = "<Plug>(vergil-send-snippet)", both = "<Plug>(vergil-send-both)" }) do
    vim.keymap.set("x", keys[action], plug, { buffer = bufnr, remap = true, desc = "vergil: send the selection to the prompt (" .. action .. ")" })
  end
end

local watching_sources = false

--- Starts mapping the send keys in file buffers once the first prompt opens.
function M.watch_sources()
  if watching_sources then
    return
  end
  watching_sources = true
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      M.attach_source(ev.buf)
    end,
    desc = "vergil: send keys in files opened from the prompt",
  })
end

---@param bufnr integer
function M.attach(bufnr)
  if not require("vergil.config").options.keymaps.preset then
    return
  end
  for _, m in ipairs(M.preset) do
    vim.keymap.set(m.mode or "n", m.lhs, m.plug, { buffer = bufnr, remap = true, desc = "vergil: " .. m.desc })
  end
  M.watch_sources()
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
  -- Only delete mappings vergil made; leave a user's own buffer mappings.
  for _, mode in ipairs({ "n", "i" }) do
    local ours = {}
    for _, m in ipairs(M.preset) do
      if (m.mode or "n") == mode then
        ours[vim.keycode(m.lhs)] = m.plug
      end
    end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      if ours[vim.keycode(map.lhs)] and map.rhs == ours[vim.keycode(map.lhs)] then
        vim.keymap.del(mode, map.lhs, { buffer = bufnr })
      end
    end
  end
  for _, au in ipairs(vim.api.nvim_get_autocmds({ group = group, event = "WinEnter" })) do
    if au.desc == "vergil: Esc closes focused previews of buffer " .. bufnr then
      vim.api.nvim_del_autocmd(au.id)
    end
  end
end

return M
