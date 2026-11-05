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
---@field triggers { attach: string, mention: string, range: string, skills: string } completion and selector triggers
---@field skills { extra_items: { name: string, description: string?, argument_hint: string? }[] }
---@field selector { keys: { mention: string, snippet: string, both: string, cancel: string[] } }
---@field completion { native: boolean, reopen_on_backspace: boolean }
---@field files { command: string[]? } custom discovery command, run in the root
---@field keymaps { preset: boolean } opt-in buffer-local mappings in prompt buffers
---@field return_to_prompt boolean `:q` in a file opened from the prompt returns to the prompt

---@type vergil.Config
M.defaults = {
  agent = "claude",
  root = nil,
  activation = { filename_patterns = nil },
  mention = { format = "github" },
  triggers = { attach = "@", mention = "@@", range = "#", skills = "/" },
  -- Extra `/` items, e.g. built-in commands vergil doesn't discover:
  -- { { name = "compact", description = "Summarize the conversation" } }
  skills = { extra_items = {} },
  selector = {
    -- Buffer-local keys in the line selector. Motions are never remapped.
    keys = { mention = "<CR>", snippet = "gs", both = "gb", cancel = { "q", "<Esc>" } },
  },
  completion = {
    -- Enable Neovim's built-in LSP completion in prompt buffers. Leave off
    -- when a completion plugin (blink.cmp, nvim-cmp) is installed.
    native = false,
    -- Reopen the menu when Backspace inside a reference closed it.
    reopen_on_backspace = true,
  },
  files = { command = nil },
  -- No mappings by default. `preset = true` maps, in prompt buffers only:
  -- gs = :Vergil snippet, gb = :Vergil snippet both, <Esc> = close preview.
  keymaps = { preset = false },
  -- `:q` in the last window, showing a file opened from the prompt (e.g.
  -- with `gd`), returns to the prompt instead of exiting Neovim.
  return_to_prompt = true,
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
  vim.validate("selector", opts.selector, "table", true)
  vim.validate("keymaps", opts.keymaps, "table", true)
  vim.validate("return_to_prompt", opts.return_to_prompt, "boolean", true)
  if opts.triggers and opts.triggers.range ~= nil then
    vim.validate("triggers.range", opts.triggers.range, "string")
    if vim.fn.strchars(opts.triggers.range) ~= 1 or opts.triggers.range:find("%s") then
      error("vergil: triggers.range must be a single non-space character", 0)
    end
  end
  if opts.files then
    vim.validate("files.command", opts.files.command, "table", true)
  end
  vim.validate("skills", opts.skills, "table", true)
  if opts.skills then
    vim.validate("skills.extra_items", opts.skills.extra_items, "table", true)
    for i, it in ipairs(opts.skills.extra_items or {}) do
      if type(it) ~= "table" or type(it.name) ~= "string" or it.name == "" then
        error(("vergil: skills.extra_items[%d] needs a name"):format(i), 0)
      end
    end
  end
  for _, k in ipairs({ "attach", "mention", "skills" }) do
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
