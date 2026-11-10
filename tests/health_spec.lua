local h = require("helpers")

--- Runs vergil's health check with vim.health stubbed, so the report doesn't
--- depend on how :checkhealth renders it (Neovim 0.13 renders asynchronously).
--- Lines look like "## Section", "OK msg", "INFO msg", "WARN msg", "ERROR msg".
local function report()
  h.load_plugin()
  local out, saved = {}, {}
  for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
    saved[kind] = vim.health[kind]
    vim.health[kind] = function(msg)
      out[#out + 1] = (kind == "start" and "## " or kind:upper() .. " ") .. msg
    end
  end
  local ok, err = pcall(require("vergil.health").check)
  for kind, fn in pairs(saved) do
    vim.health[kind] = fn
  end
  assert(ok, err)
  return table.concat(out, "\n")
end

--- Runs `fn` with a fake `claude` on PATH printing `version`, or with no
--- `claude` at all when `version` is nil.
local function with_agent(version, fn)
  local bin = vim.fn.tempname()
  vim.fn.mkdir(bin, "p")
  local path = vim.env.PATH
  if version then
    vim.fn.writefile({ "#!/bin/sh", "echo '" .. version .. " (Claude Code)'" }, bin .. "/claude")
    vim.fn.setfperm(bin .. "/claude", "rwxr-xr-x")
    vim.env.PATH = bin .. ":" .. path
  else
    vim.env.PATH = bin
  end
  local ok, res = pcall(fn)
  vim.env.PATH = path
  vim.fn.delete(bin, "rf")
  assert(ok, res)
  return res
end

return {
  [":checkhealth vergil renders"] = function()
    h.load_plugin()
    vim.cmd("checkhealth vergil")
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end
    vim.wait(5000, function()
      return text():find("Prompt safety", 1, true) ~= nil
    end)
    h.truthy(text():find("Prompt safety", 1, true), text())
    vim.cmd("bwipeout!")
  end,
  ["reports each section without errors"] = function()
    local text = report()
    for _, section in ipairs({ "Neovim", "Configuration", "File discovery", "Completion", "Picker", "Prompt safety" }) do
      h.truthy(text:find("## " .. section, 1, true), section .. " missing:\n" .. text)
    end
    h.eq(text:find("\nERROR", 1, true), nil, text)
  end,
  ["warns about unknown options"] = function()
    local config = require("vergil.config")
    local notify = vim.notify
    vim.notify = function() end
    config.set({ keymap = { preset = true } })
    vim.notify = notify
    local text = report()
    config.set({})
    h.truthy(text:find("WARN Unknown options: keymap", 1, true), text)
    h.truthy(text:find("OK Options are valid", 1, true), text)
  end,
  ["warns about whitespace stripping on save"] = function()
    vim.g.strip_whitespace_on_save = 1
    local text = report()
    vim.g.strip_whitespace_on_save = nil
    h.truthy(text:find("WARN vim-better-whitespace strips trailing whitespace on save", 1, true), text)
  end,
  ["lists each agent, with its version when installed"] = function()
    h.load_plugin()
    local text = with_agent("2.1.400", report)
    h.truthy(text:find("## Agent: Claude Code", 1, true), text)
    h.truthy(text:find("INFO Activates on: claude-prompt-*.md", 1, true), text)
    h.truthy(text:find('INFO Attachments: @path, @"path with spaces"', 1, true), text)
    h.truthy(text:find("OK `claude` is on PATH (2.1.400)", 1, true), text)
  end,
  ["an agent that isn't installed is fine"] = function()
    local text = with_agent(nil, report)
    h.truthy(text:find("INFO `claude` is not on PATH", 1, true), text)
    h.eq(text:find("\nERROR", 1, true), nil, text)
  end,
  ["warns without agents, and says what a mentions-only agent does"] = function()
    local config = require("vergil.config")
    config.set({ agents = {} })
    local none = report()
    config.set({ agents = { x = { match = { "x-*.md" } } } })
    local plain = report()
    config.set({})
    h.truthy(none:find("WARN No agents configured", 1, true), none)
    h.truthy(plain:find("INFO No attachments: files are inserted as mentions", 1, true), plain)
  end,
}
