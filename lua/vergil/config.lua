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

---@type vergil.Config
M.defaults = {
  agent = "claude",
  root = nil,
  activation = { filename_patterns = nil },
  mention = { format = "github" },
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
