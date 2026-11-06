local h = require("helpers")

return {
  [":checkhealth vergil runs and reports each section"] = function()
    h.load_plugin()
    vim.cmd("checkhealth vergil")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    for _, section in ipairs({ "Neovim", "Configuration", "File discovery", "Completion", "Picker", "Prompt safety" }) do
      h.truthy(text:find(section, 1, true), section .. " missing:\n" .. text)
    end
    h.eq(text:find("ERROR", 1, true), nil, text)
    vim.cmd("bwipeout!")
  end,
  ["warns about whitespace stripping on save"] = function()
    vim.g.strip_whitespace_on_save = 1
    vim.cmd("checkhealth vergil")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.g.strip_whitespace_on_save = nil
    vim.cmd("bwipeout!")
    h.truthy(text:find("strips trailing whitespace on save", 1, true), text)
  end,
  ["compares the agent's version with the verified one"] = function()
    h.load_plugin()
    local verified = require("vergil.config").adapter().verified_version
    local bin = vim.fn.tempname()
    vim.fn.mkdir(bin, "p")
    local path = vim.env.PATH
    local function run(version)
      vim.fn.writefile({ "#!/bin/sh", "echo '" .. version .. " (Claude Code)'" }, bin .. "/claude")
      vim.fn.setfperm(bin .. "/claude", "rwxr-xr-x")
      vim.env.PATH = bin .. ":" .. path
      vim.cmd("checkhealth vergil")
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      vim.env.PATH = path
      vim.cmd("bwipeout!")
      return text
    end
    local same = run(verified)
    h.truthy(same:find("Agent: Claude Code", 1, true), same)
    h.truthy(same:find("were checked with this version", 1, true), same)
    local other = run("9.9.9")
    h.truthy(other:find("last checked with " .. verified .. "; you have 9.9.9", 1, true), other)
    local line = other:match("[^\n]*last checked[^\n]*")
    h.eq(line:find("WARNING", 1, true), nil, line) -- informational, not a warning
    vim.fn.delete(bin, "rf")
  end,
  ["says nothing about the agent when it isn't installed"] = function()
    h.load_plugin()
    local path = vim.env.PATH
    vim.env.PATH = vim.fn.tempname() -- an empty, missing directory
    vim.cmd("checkhealth vergil")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.env.PATH = path
    vim.cmd("bwipeout!")
    h.eq(text:find("Agent: Claude Code", 1, true), nil, text)
    h.eq(text:find("ERROR", 1, true), nil, text)
  end,
}
