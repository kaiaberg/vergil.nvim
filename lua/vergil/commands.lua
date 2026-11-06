--- The `:Vergil` command. Subcommands are added as features are implemented.
local M = {}

local function notify(msg, level)
  vim.notify("vergil: " .. msg, level or vim.log.levels.INFO)
end

---@type table<string, fun(args: string[], opts: table)>
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
  range = function()
    local ok, err = require("vergil.range").select_at_cursor()
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  snippet = function(args)
    local ok, err = require("vergil.range").snippet_at_cursor(args[1])
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  submit = function()
    local ok, err = require("vergil.submit").submit()
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  abort = function()
    local ok, err = require("vergil.submit").abort()
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  pick = function(args)
    local ok, err = require("vergil.picker").pick(args[1])
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end,
  send = function(args, opts)
    local ok, err = require("vergil.send").send(args[1], opts.line1, opts.line2)
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

---@param opts { fargs: string[], line1: integer, line2: integer }
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
  sub(vim.list_slice(opts.fargs, 2), opts)
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
  if cmdline:match("^%s*%S+%s+pick%s+%S*$") then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, { "attach", "mention", "skills" })
  end
  if cmdline:match("^%s*%S+%s+send%s+%S*$") then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, { "snippet", "both" })
  end
  if cmdline:match("^%s*%S+%s+snippet%s+%S*$") then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, { "both" })
  end
  if cmdline:match("^%s*%S+%s+%S+%s") then
    return {}
  end
  return vim.tbl_filter(function(n)
    return vim.startswith(n, arglead)
  end, M.names())
end

return M
