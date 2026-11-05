local h = require("helpers")

return {
  [":checkhealth vergil runs and reports each section"] = function()
    h.load_plugin()
    vim.cmd("checkhealth vergil")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    for _, section in ipairs({ "Neovim", "Configuration", "File discovery", "Completion", "Picker", "Prompt safety", "Claude Code" }) do
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
}
