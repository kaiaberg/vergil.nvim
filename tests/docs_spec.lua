local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

return {
  [":helptags succeeds and :help finds every documented tag"] = function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/doc", "p")
    vim.fn.writefile(vim.fn.readfile(root .. "/doc/vergil.txt"), tmp .. "/doc/vergil.txt")
    vim.cmd.helptags(tmp .. "/doc")
    vim.opt.rtp:prepend(tmp)
    for _, tag in ipairs({
      "vergil.txt",
      ":Vergil",
      ":Vergil-submit",
      "vergil-#",
      "vergil-config",
      "VergilEnable",
      "vergil-keymap-preset",
      "vergil.setup()",
    }) do
      vim.cmd.help(tag)
      h.eq(vim.bo.filetype, "help", tag)
      vim.cmd.helpclose()
    end
  end,
  ["every |link| in the help file resolves"] = function()
    local text = table.concat(vim.fn.readfile(root .. "/doc/vergil.txt"), "\n")
    local defined = {}
    for tag in text:gmatch("%*([^%s*]+)%*") do
      defined[tag] = true
    end
    for link in text:gmatch("|([^%s|]+)|") do
      -- An exact help tag: `:help` itself would also accept a partial match.
      local builtin = vim.tbl_contains(vim.fn.getcompletion(link, "help"), link)
      h.truthy(defined[link] or builtin, "unresolved |" .. link .. "|")
    end
  end,
  ["every command and <Plug> mapping is documented"] = function()
    h.load_plugin()
    local text = table.concat(vim.fn.readfile(root .. "/doc/vergil.txt"), "\n")
      .. table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
    for _, name in ipairs(require("vergil.commands").names()) do
      h.truthy(text:find(":Vergil " .. name, 1, true), ":Vergil " .. name .. " undocumented")
    end
    -- Highlight groups: every Vergil* name in the code, besides the events.
    for _, file in ipairs(vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)) do
      for group in table.concat(vim.fn.readfile(file), "\n"):gmatch("Vergil%u%w*") do
        h.truthy(text:find(group, 1, true), group .. " undocumented")
      end
    end
    local help = table.concat(vim.fn.readfile(root .. "/doc/vergil.txt"), "\n")
    local pick = help:match("%*:Vergil%-pick%*(.-)\n\n")
    for _, kind in ipairs(require("vergil.picker").kinds) do
      h.truthy(pick:find("`" .. kind .. "`", 1, true), ":Vergil pick " .. kind .. " undocumented in :help")
    end
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      local plug = map.lhs:match("^<Plug>%((vergil%-[^)]+)%)$")
      if plug then
        h.truthy(text:find("<Plug>(" .. plug .. ")", 1, true), plug .. " undocumented")
      end
    end
  end,
}
