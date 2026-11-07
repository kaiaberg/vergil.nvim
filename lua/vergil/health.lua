--- `:checkhealth vergil`
local M = {}

local health = vim.health

local function check_neovim()
  health.start("Neovim")
  local v = vim.version()
  local version = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. version)
  else
    health.error("Neovim " .. version .. " is too old", "vergil.nvim needs Neovim 0.11 or newer")
  end
end

local function check_config()
  health.start("Configuration")
  local config = require("vergil.config")
  local ok, err = pcall(config.set, config.options)
  if ok then
    health.ok("Options are valid")
  else
    health.error("Invalid options: " .. tostring(err))
  end
  local session = require("vergil.session")
  health.info("Agent: " .. config.options.agent)
  health.info("Session root: " .. session.root() .. (config.options.root and " (configured)" or " (startup directory)"))
  health.info("Activates on: " .. table.concat(config.filename_patterns(), ", "))
  local enabled = vim.tbl_filter(session.is_enabled, vim.api.nvim_list_bufs())
  health.info(("Enabled in %d buffer%s"):format(#enabled, #enabled == 1 and "" or "s"))
end

local function check_files()
  health.start("File discovery")
  local config = require("vergil.config")
  local found = {}
  if config.options.files.command then
    local cmd = config.options.files.command[1]
    if vim.fn.executable(cmd) == 1 then
      found[#found + 1] = "custom command (" .. cmd .. ")"
    else
      health.warn("files.command is set, but `" .. cmd .. "` is not executable")
    end
  end
  for _, exe in ipairs({ "rg", "fd", "git" }) do
    if vim.fn.executable(exe) == 1 then
      found[#found + 1] = exe
    end
  end
  if #found > 0 then
    health.ok("Available: " .. table.concat(found, ", ") .. " (first one that returns files wins)")
  else
    health.warn(
      "No rg, fd or git: using the built-in scan, which ignores .gitignore",
      "Install ripgrep for faster discovery that respects .gitignore"
    )
  end
  local backend = require("vergil.files").backend(require("vergil.session").root())
  if backend then
    health.info("Used for the session root: " .. backend)
  end
end

local function check_completion()
  health.start("Completion")
  local config = require("vergil.config")
  local engines = {}
  if package.loaded["blink.cmp"] then
    engines[#engines + 1] = "blink.cmp"
  end
  if package.loaded["cmp"] then
    engines[#engines + 1] = "nvim-cmp"
  end
  if config.options.completion.native then
    engines[#engines + 1] = "native (completion.native)"
  end
  if #engines == 0 then
    health.warn(
      "No completion engine detected: @, @@ and / won't pop up",
      "Install blink.cmp or nvim-cmp, or set completion.native = true"
    )
  elseif #engines > 1 and config.options.completion.native then
    health.warn(
      "completion.native is on while " .. engines[1] .. " is loaded: two menus may open",
      "Set completion.native = false"
    )
  else
    health.ok("Engine: " .. table.concat(engines, ", "))
  end
  if package.loaded["blink.cmp"] then
    health.info(
      "Tip: limit blink to the LSP source in prompt buffers, so snippets and paths don't pop up while typing prose: "
        .. "sources.default = function() return vim.b.vergil_enabled and { 'lsp' } or { ... } end"
    )
  end
  if vim.fn.has("nvim-0.12") == 0 and config.options.completion.native then
    health.info("Neovim 0.11 native completion: vergil works around inserted paths being cut at spaces")
  end
end

--- Things that rewrite the prompt on save break Claude Code's re-collapsing
--- of unchanged pasted text (plan §6.11).
local function check_prompt_safety()
  health.start("Prompt safety")
  local problems = 0
  if vim.g.strip_whitespace_on_save == 1 then
    problems = problems + 1
    health.warn(
      "vim-better-whitespace strips trailing whitespace on save",
      "Exclude prompt buffers, e.g. vim.g.better_whitespace_filetypes_blacklist, or keep strip_whitespace_on_save off"
    )
  end
  for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "BufWritePre" })) do
    local pattern = au.pattern or ""
    if au.buffer == nil and (pattern == "*" or pattern:find("%*%.md") or pattern:find("markdown")) then
      problems = problems + 1
      health.warn(
        ("A BufWritePre autocommand for %q may rewrite prompts: %s"):format(
          pattern,
          au.desc or (au.group_name and ("group " .. au.group_name)) or "no description"
        ),
        "Make sure format-on-save and whitespace trimming skip claude-prompt-*.md"
      )
    end
  end
  if vim.o.fixendofline and not vim.o.endofline then
    health.info("'fixendofline' adds a final newline on save; harmless for Claude Code")
  end
  if problems == 0 then
    health.ok("No format-on-save or whitespace trimming found")
  end
end

--- The version an agent's `--version` prints, if it answers within 3 seconds
--- (agents written in Node can be slow to start).
---@param exe string
---@return string?
function M.agent_version(exe)
  local ok, res = pcall(function()
    return vim.system({ exe, "--version" }, { text = true }):wait(3000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return (res.stdout or ""):match("%d+%.%d+%.%d+")
end

--- Agents change faster than vergil; say which version its assumptions
--- (syntax, size limits, exit codes) were last checked against.
local function check_agent_version(adapter)
  local exe = adapter.executable
  local name = adapter.display_name or adapter.name
  local installed = M.agent_version(exe)
  health.ok(("`%s` is on PATH%s"):format(exe, installed and (" (" .. installed .. ")") or ""))
  local verified = adapter.verified_version
  if not (verified and installed) then
    return
  end
  if installed == verified then
    health.ok(("vergil's assumptions about %s were checked with this version"):format(name))
  else
    health.info(
      ("vergil's assumptions about %s were last checked with %s; you have %s. "):format(name, verified, installed)
        .. "Usually nothing changes; if references or diagnostics look off, see \"Observed behaviour\" in the README."
    )
  end
end

--- Only when the agent is installed: vergil works without it, for example
--- to write prompts or plans ahead of time.
local function check_agent()
  local adapter = require("vergil.config").adapter()
  if not (adapter.executable and vim.fn.executable(adapter.executable) == 1) then
    return
  end
  health.start("Agent: " .. (adapter.display_name or adapter.name))
  check_agent_version(adapter)
  local visual, editor = vim.env.VISUAL, vim.env.EDITOR
  local used = (visual and visual ~= "") and ("$VISUAL=" .. visual) or (editor and editor ~= "") and ("$EDITOR=" .. editor)
  if used then
    health.info("Ctrl+G opens " .. used .. " (Claude Code prefers $VISUAL over $EDITOR)")
  else
    health.warn("Neither $VISUAL nor $EDITOR is set", "Set VISUAL=nvim so Claude Code's Ctrl+G opens Neovim")
  end
end

local function check_picker()
  health.start("Picker")
  local picker = require("vergil.config").options.picker
  health.ok("Built-in picker" .. (picker.on_trigger and " (opens on @ and /)" or ""))
  if picker.backend ~= nil then
    health.warn("picker.backend is no longer used: vergil has its own picker", "Remove picker.backend from your setup")
  end
end

function M.check()
  check_neovim()
  check_config()
  check_files()
  check_completion()
  check_picker()
  check_prompt_safety()
  check_agent()
end

return M
