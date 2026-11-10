--- The `:Vergil` command. Subcommands are added as features are implemented.
local M = {}

local function notify(msg, level)
  vim.notify("vergil: " .. msg, level or vim.log.levels.INFO)
end

---@type table<string, fun(args: string[], opts: table)>
M.subcommands = {
  enable = function(args)
    local agents = require("vergil.agents")
    local key = args[1]
    if key and key ~= agents.plain.key and not agents.get(key) then
      return notify(("no agent %q under `agents` (see :help vergil-agents)"):format(key), vim.log.levels.WARN)
    end
    require("vergil.session").enable(0, key)
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
  open = function(args, opts)
    local ok, err = require("vergil").open(args[1], opts.smods)
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
  diff = function(args)
    local ok, err = require("vergil.diff").insert(args[1])
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

-- Revisions for `:Vergil diff <Tab>`, kept while the command line is open
-- so each Tab doesn't ask git again.
local cached ---@type { root: string, list: string[] }?

local function revisions()
  local session = require("vergil.session")
  local s = session.get(0)
  local root = s and s.root or session.root()
  if cached and cached.root == root then
    return cached.list
  end
  local list = require("vergil.git").revisions(root)
  if vim.fn.mode() == "c" then
    cached = { root = root, list = list }
    vim.api.nvim_create_autocmd("CmdlineLeave", {
      group = vim.api.nvim_create_augroup("vergil.complete", { clear = true }),
      once = true,
      callback = function()
        cached = nil
      end,
    })
  end
  return list
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
  if cmdline:match("^%s*%S+%s+enable%s+%S*$") then
    local agents = require("vergil.agents")
    local keys = vim.tbl_map(function(a)
      return a.key
    end, agents.list())
    keys[#keys + 1] = agents.plain.key
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, keys)
  end
  if cmdline:match("^%s*%S+%s+pick%s+%S*$") then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, require("vergil.picker.kinds"))
  end
  if cmdline:match("^%s*%S+%s+diff%s+%S*$") then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, revisions())
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
