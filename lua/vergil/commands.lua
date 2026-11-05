--- The `:Vergil` command. Subcommands are added as features are implemented.
local M = {}

local function notify(msg, level)
  vim.notify("vergil: " .. msg, level or vim.log.levels.INFO)
end

---@type table<string, fun(args: string[])>
M.subcommands = {
  enable = function()
    require("vergil.session").enable(0)
  end,
  disable = function()
    require("vergil.session").disable(0)
  end,
  preview = function()
    local ok, err = require("vergil").preview()
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  open = function(args)
    local ok, err = require("vergil").open(args[1])
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  toggle = function()
    local ok, err = require("vergil").toggle()
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
}

---@param opts { fargs: string[] }
function M.run(opts)
  local name = opts.fargs[1]
  local sub = name and M.subcommands[name]
  if not sub then
    notify(
      ("unknown subcommand %q; expected one of: %s"):format(name or "", table.concat(M.names(), ", ")),
      vim.log.levels.ERROR
    )
    return
  end
  sub(vim.list_slice(opts.fargs, 2))
end

---@return string[]
function M.names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  if cmdline:match("^%s*%S+%s+open%s+%S*$") then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, { "split", "vsplit", "tab" })
  end
  if cmdline:match("^%s*%S+%s+%S+%s") then
    return {}
  end
  return vim.tbl_filter(function(n)
    return vim.startswith(n, arglead)
  end, M.names())
end

return M
