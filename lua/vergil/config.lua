--- Configuration. Only options that are implemented exist here.
local M = {}

---@class vergil.MentionTemplates
---@field single string template for one line, e.g. "{path}#L{start}"
---@field range string template for a range, e.g. "{path}#L{start}-L{end}"

---@class vergil.Config
---@field agent string adapter name under `vergil.adapters`
---@field root string? explicit session root; defaults to Neovim's startup cwd
---@field activation { filename_patterns: string[]? } nil patterns = adapter default
---@field mention { format: "github"|"colon"|vergil.MentionTemplates, symbols: boolean }
---@field triggers { attach: string, mention: string, range: string, skills: string } completion and selector triggers
---@field skills { extra_items: { name: string, description: string?, argument_hint: string? }[] }
---@field selector { keys: { mention: string, snippet: string, both: string, symbols: string, cancel: string[] } }
---@field completion { native: boolean, reopen_on_backspace: boolean }
---@field files { command: string[]? } custom discovery command, run in the root
---@field keymaps { preset: boolean } opt-in buffer-local mappings in prompt buffers
---@field picker { on_trigger: boolean, keys: table<string, string[]>, tabs: string[] }
---@field preview { on_repeat: "close"|"focus" }
---@field return_to_prompt boolean `:q` in a file opened from the prompt returns to the prompt
---@field diagnostics { attachment_token_warning: integer, severity: table<string, "error"|"warn"|"info"|"hint"|false> }

---@type vergil.Config
M.defaults = {
  agent = "claude",
  root = nil,
  activation = { filename_patterns = nil },
  -- symbols: add the function or class name after a range that covers
  -- exactly one, e.g. `a.lua#L3-L9` (`M.apply`), so drift can be flagged.
  mention = { format = "github", symbols = true },
  triggers = { attach = "@", mention = "@@", range = "#", skills = "/" },
  -- Extra `/` items, e.g. built-in commands vergil doesn't discover:
  -- { { name = "compact", description = "Summarize the conversation" } }
  skills = { extra_items = {} },
  selector = {
    -- Buffer-local keys in the line selector. Motions are never remapped.
    -- `symbols` lists the file's functions and classes to select from.
    keys = { mention = "<CR>", snippet = "gs", both = "gb", symbols = "gO", cancel = { "q", "<Esc>" } },
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
  -- gs/gb = snippet (replace/add below), <Esc> = close preview,
  -- gf/<C-w>f/<C-w>gf = open reference (here/split/tab, else the native key),
  -- ZZ = :Vergil submit, ZQ = :Vergil abort.
  keymaps = { preset = false },
  -- `:q` in the last window, showing a file opened from the prompt (e.g.
  -- with `gd`), returns to the prompt instead of exiting Neovim.
  return_to_prompt = true,
  -- The picker (`:Vergil pick`, `<C-g>` from inline completion).
  -- on_trigger: typing `@` or `/` opens the picker instead of inline
  -- completion. keys: override the picker's keys, e.g.
  -- { next_tab = { "<C-l>" }, prev_tab = { "<C-h>" } }.
  -- tabs: which tabs the picker has, in this order; leave one out to drop it
  -- (from All too).
  picker = {
    on_trigger = false,
    keys = {},
    tabs = { "all", "files", "changed", "branches", "commits", "skills" },
  },
  -- `K` (preset) or `:Vergil preview` while the preview is open: "close" it,
  -- or "focus" it (move into it, as Neovim's own `K` does).
  preview = { on_repeat = "close" },
  diagnostics = {
    -- Flag attachments above this many estimated tokens (bytes / 3). Agents
    -- may skip or cut large files; see "Observed behaviour" in the README.
    attachment_token_warning = 20000,
    -- "error", "warn", "info", "hint", or false to turn a check off.
    severity = {
      duplicate = "warn", -- same file attached twice
      large = "info", -- attachment above the token threshold
      range = "warn", -- mention range past the end of the file
      ignored_range = "hint", -- @file#range: the range may be ignored
      missing_mention = "warn",
      missing_attachment = "info", -- pasted text may contain @words
      fenced = "hint", -- @file inside fenced code may still be attached
      symbol = "warn", -- `a.lua#L3-L9` (`M.apply`): the range no longer matches
    },
  },
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
  if opts.mention then
    vim.validate("mention.symbols", opts.mention.symbols, "boolean", true)
  end
  vim.validate("triggers", opts.triggers, "table", true)
  vim.validate("completion", opts.completion, "table", true)
  vim.validate("files", opts.files, "table", true)
  vim.validate("selector", opts.selector, "table", true)
  vim.validate("keymaps", opts.keymaps, "table", true)
  vim.validate("return_to_prompt", opts.return_to_prompt, "boolean", true)
  vim.validate("picker", opts.picker, "table", true)
  if opts.picker then
    vim.validate("picker.on_trigger", opts.picker.on_trigger, "boolean", true)
    vim.validate("picker.keys", opts.picker.keys, "table", true)
    vim.validate("picker.tabs", opts.picker.tabs, "table", true)
    local known = { all = true, files = true, changed = true, branches = true, commits = true, skills = true }
    local seen = {}
    for _, name in ipairs(opts.picker.tabs or {}) do
      if not known[name] then
        error(
          ("vergil: unknown picker tab %q; expected all, files, changed, branches, commits or skills"):format(
            tostring(name)
          ),
          0
        )
      elseif seen[name] then
        error(("vergil: picker tab %q is listed twice"):format(name), 0)
      end
      seen[name] = true
    end
    if opts.picker.tabs and #opts.picker.tabs == 0 then
      error("vergil: picker.tabs needs at least one tab", 0)
    end
  end
  vim.validate("preview", opts.preview, "table", true)
  if opts.preview and opts.preview.on_repeat ~= nil then
    vim.validate("preview.on_repeat", opts.preview.on_repeat, function(v)
      return v == "close" or v == "focus"
    end, '"close" or "focus"')
  end
  vim.validate("diagnostics", opts.diagnostics, "table", true)
  if opts.diagnostics then
    vim.validate("diagnostics.attachment_token_warning", opts.diagnostics.attachment_token_warning, "number", true)
    vim.validate("diagnostics.severity", opts.diagnostics.severity, "table", true)
    for kind, sev in pairs(opts.diagnostics.severity or {}) do
      if not (sev == false or sev == "error" or sev == "warn" or sev == "info" or sev == "hint") then
        error(("vergil: diagnostics.severity.%s must be error, warn, info, hint or false"):format(kind), 0)
      end
    end
  end
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
