--- Configuration. Only options that are implemented exist here.
local M = {}

---@class vergil.MentionTemplates
---@field single string template for one line, e.g. "{path}#L{start}"
---@field range string template for a range, e.g. "{path}#L{start}-L{end}"

---@class vergil.Config
---@field agent string adapter name under `vergil.adapters`
---@field root string? explicit session root; defaults to Neovim's startup cwd
---@field activation { filename_patterns: string[]? } nil patterns = adapter default
---@field mention { format: "github"|"colon"|vergil.MentionTemplates }
---@field triggers { attach: string, mention: string } completion triggers
---@field completion { native: boolean, reopen_on_backspace: boolean }
---@field files { command: string[]? } custom discovery command, run in the root

---@type vergil.Config
M.defaults = {
  agent = "claude",
  root = nil,
  activation = { filename_patterns = nil },
  mention = { format = "github" },
  triggers = { attach = "@", mention = "@@" },
  completion = {
    -- Enable Neovim's built-in LSP completion in prompt buffers. Leave off
    -- when a completion plugin (blink.cmp, nvim-cmp) is installed.
    native = false,
    -- Reopen the menu when Backspace inside a reference closed it.
    reopen_on_backspace = true,
  },
  files = { command = nil },
}

---@type vergil.Config
M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.set(opts)
  opts = opts or {}
  vim.validate("opts", opts, "table")
  vim.validate("agent", opts.agent, "string", true)
  vim.validate("root", opts.root, "string", true)
  vim.validate("activation", opts.activation, "table", true)
  vim.validate("mention", opts.mention, "table", true)
  vim.validate("triggers", opts.triggers, "table", true)
  vim.validate("completion", opts.completion, "table", true)
  vim.validate("files", opts.files, "table", true)
  if opts.files then
    vim.validate("files.command", opts.files.command, "table", true)
  end
  for _, k in ipairs({ "attach", "mention" }) do
    local t = opts.triggers and opts.triggers[k]
    vim.validate("triggers." .. k, t, "string", true)
    if t and (t == "" or t:find("%s")) then
      error(("vergil: triggers.%s must be non-empty without whitespace"):format(k), 0)
    end
  end
  if opts.activation then
    vim.validate("activation.filename_patterns", opts.activation.filename_patterns, "table", true)
  end
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Validates the format eagerly so a bad template fails at setup, not mid-prompt.
  require("vergil.reference.formatter").compile(merged.mention.format)
  M.options = merged
end

---@return vergil.Adapter
function M.adapter()
  return require("vergil.adapters." .. M.options.agent)
end

---@return string[]
function M.filename_patterns()
  return M.options.activation.filename_patterns or M.adapter().filename_patterns
end

return M
