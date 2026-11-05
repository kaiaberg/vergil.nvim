local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

return {
  [":helptags succeeds and :help finds every documented tag"] = function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/doc", "p")
    vim.fn.writefile(vim.fn.readfile(root .. "/doc/vergil.txt"), tmp .. "/doc/vergil.txt")
    vim.cmd.helptags(tmp .. "/doc")
    vim.opt.rtp:prepend(tmp)
    for _, tag in ipairs({ "vergil.txt", ":Vergil", ":Vergil-submit", "vergil-#", "vergil-config", "VergilEnable", "vergil-keymap-preset", "vergil.setup()" }) do
      vim.cmd.help(tag)
      h.eq(vim.bo.filetype, "help", tag)
      vim.cmd.helpclose()
    end
  end,
  ["every |link| in the help file resolves"] = function()
    local text = table.concat(vim.fn.readfile(root .. "/doc/vergil.txt"), "\n")
    local defined = {}
    for tag in text:gmatch("%*([^%s*]+)%*") do defined[tag] = true end
    for link in text:gmatch("|([^%s|]+)|") do
      local builtin = vim.fn.taglist("^" .. vim.fn.escape(link, "\\[]*.~^$") .. "$")
      h.truthy(defined[link] or #builtin > 0 or pcall(vim.cmd.help, link), "unresolved |" .. link .. "|")
      pcall(vim.cmd.helpclose)
    end
  end,
  ["every command and <Plug> mapping is documented"] = function()
    h.load_plugin()
    local text = table.concat(vim.fn.readfile(root .. "/doc/vergil.txt"), "\n") .. table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
    for _, name in ipairs(require("vergil.commands").names()) do
      h.truthy(text:find(":Vergil " .. name, 1, true), ":Vergil " .. name .. " undocumented")
    end
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      local plug = map.lhs:match("^<Plug>%((vergil%-[^)]+)%)$")
      if plug then
        h.truthy(text:find("<Plug>(" .. plug .. ")", 1, true), plug .. " undocumented")
      end
    end
  end,
}
