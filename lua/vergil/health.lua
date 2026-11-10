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
  local ok, err = pcall(config.set, config.options, true)
  if ok then
    health.ok("Options are valid")
  else
    health.error("Invalid options: " .. tostring(err))
  end
  local unknown = config.unknown(config.options)
  if #unknown > 0 then
    health.warn("Unknown options: " .. table.concat(unknown, ", "), "Check for typos; see :help vergil-config")
  end
  local session = require("vergil.session")
  health.info("Session root: " .. session.root() .. (config.options.root and " (configured)" or " (startup directory)"))
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
    health.ok("Available: " .. table.concat(found, ", ") .. " (first one that runs wins)")
  else
    health.warn(
      "No rg, fd or git: using the built-in scan, which ignores .gitignore",
      "Install ripgrep for faster discovery that respects .gitignore"
    )
  end
  local root = require("vergil.session").root()
  local files = require("vergil.files")
  local backend = files.backend(root)
  if backend then
    health.info("Used for the session root: " .. backend)
    local cached = files.cached(root)
    if cached and #cached == 0 and backend ~= "command" then
      health.info(
        "No files found in the root: .gitignore may ignore all of it",
        "To list ignored files too, set files.command, e.g. "
          .. '{ "rg", "--files", "--hidden", "--no-ignore", "--glob", "!.git" }'
      )
    end
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
    health.info("'fixendofline' adds a final newline on save; usually harmless for agents")
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

--- One section per configured agent: what activates it, what it supports,
--- and its version when the executable is installed. vergil works without
--- the agent installed, e.g. to write prompts ahead of time.
local function check_agents()
  local agents = require("vergil.agents").list()
  if #agents == 0 then
    health.start("Agents")
    health.warn(
      "No agents configured: no prompt file activates vergil (only :Vergil enable)",
      "Add your agents under `agents` in setup(); see :help vergil-agents and the README's recipes"
    )
    return
  end
  for _, a in ipairs(agents) do
    health.start("Agent: " .. a.name)
    health.info("Activates on: " .. table.concat(a.match, ", "))
    local at = a.attach
    if at then
      local quoted = at.quote and (", %s%spath with spaces%s"):format(at.prefix, at.quote, at.quote) or ""
      health.info(("Attachments: %spath%s"):format(at.prefix, quoted))
    else
      health.info("No attachments: files are inserted as mentions")
    end
    if a.skills then
      local n = #require("vergil.skills").items(require("vergil.session").root(), a)
      health.info(("Skills: %d from %d source%s"):format(n, #a.skills, #a.skills == 1 and "" or "s"))
    end
    if a.executable then
      if vim.fn.executable(a.executable) == 1 then
        local installed = M.agent_version(a.executable)
        health.ok(("`%s` is on PATH%s"):format(a.executable, installed and (" (" .. installed .. ")") or ""))
      else
        health.info(("`%s` is not on PATH"):format(a.executable))
      end
    end
  end
  local visual, editor = vim.env.VISUAL, vim.env.EDITOR
  local used = (visual and visual ~= "") and ("$VISUAL=" .. visual)
    or (editor and editor ~= "") and ("$EDITOR=" .. editor)
  health.start("Editor")
  if used then
    health.info("Agents open " .. used .. " (most prefer $VISUAL over $EDITOR)")
  else
    health.warn("Neither $VISUAL nor $EDITOR is set", "Set VISUAL=nvim so your agent opens Neovim for prompts")
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
  check_agents()
end

return M
