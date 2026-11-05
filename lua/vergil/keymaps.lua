--- `<Plug>` mappings, and the opt-in preset (`keymaps.preset = true`) that
--- maps them buffer-locally in prompt buffers. Vergil never maps keys
--- unless asked (plan §2, principle 7).
local M = {}

---@type { lhs: string, plug: string, desc: string }[]
M.preset = {
  { lhs = "gs", plug = "<Plug>(vergil-snippet)", desc = "Replace reference with its lines" },
  { lhs = "gb", plug = "<Plug>(vergil-snippet-both)", desc = "Add the reference's lines below" },
}

--- Defines the global `<Plug>` mappings. Called once from plugin/vergil.lua.
function M.define_plugs()
  local function run(sub)
    return function()
      require("vergil.commands").run({ fargs = sub })
    end
  end
  vim.keymap.set("n", "<Plug>(vergil-snippet)", run({ "snippet" }), { desc = "vergil: replace reference with its lines" })
  vim.keymap.set("n", "<Plug>(vergil-snippet-both)", run({ "snippet", "both" }), { desc = "vergil: add the reference's lines below" })
end

---@param bufnr integer
function M.attach(bufnr)
  if not require("vergil.config").options.keymaps.preset then
    return
  end
  for _, m in ipairs(M.preset) do
    vim.keymap.set("n", m.lhs, m.plug, { buffer = bufnr, remap = true, desc = "vergil: " .. m.desc })
  end
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
end

return M
