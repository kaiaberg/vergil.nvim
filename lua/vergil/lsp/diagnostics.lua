--- Diagnostics for prompt references (plan §6.6). Validation never touches
--- the buffer; fixes are offered as code actions.
---
--- Rules:
--- - Paths are compared after normalization (`./a`, `a`, `~`, absolute).
--- - Mentions of attached files are never flagged: attach once, then mention.
--- - Messages state what vergil knows (sizes, ranges, code blocks) and hedge
---   what the agent might do with it: agents change faster than vergil.
--- - Fenced code is skipped, except for a hint when a fenced `@token` names a
---   real file, because the agent may attach it anyway (Claude Code does).
--- - Ordinary inline code that merely might be a path is never flagged.
--- - Attachment size is estimated in tokens (bytes / 3); agents tend to limit
---   tokens, not bytes.
--- - A ranged mention followed by `` (`name`) `` is checked against the
---   file's symbols, so a range that drifted from its function is flagged.
local config = require("vergil.config")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")
local symbols = require("vergil.symbols")

local M = {}

M.source = "vergil"

local SEVERITY = { error = 1, warn = 2, info = 3, hint = 4 }

--- Diagnostic kinds that "Convert to mention" fixes.
M.fixable = { duplicate = true, large = true, ignored_range = true }

local human_size = require("vergil.size").format

local symbol_cache = {} ---@type table<string, { stamp: string, list: vergil.Symbol[]|false }>

--- A file's symbols, re-parsed only when its modification time or size changes.
---@param abs string
---@return vergil.Symbol[]?
local function file_symbols(abs)
  local stat = vim.uv.fs_stat(abs)
  if not stat or stat.type ~= "file" or stat.size > 1024 * 1024 then
    return nil
  end
  local stamp = ("%d:%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
  local cached = symbol_cache[abs]
  if cached and cached.stamp == stamp then
    return cached.list or nil
  end
  local ok, lines = pcall(vim.fn.readfile, abs)
  local list = ok and symbols.list(lines, abs) or nil
  symbol_cache[abs] = { stamp = stamp, list = list or false }
  return list
end

--- The name in `` (`name`) `` right after a reference, if any.
---@param bufnr integer
---@param ref vergil.Reference
---@return string?
function M.symbol_after(bufnr, ref)
  local line = vim.api.nvim_buf_get_lines(bufnr, ref.span.end_row, ref.span.end_row + 1, false)[1] or ""
  return line:sub(ref.span.end_col + 1):match("^ %(`([^`]+)`%)")
end

---@class vergil.SymbolDrift
---@field name string
---@field missing boolean? the file no longer has a symbol of that name
---@field start_line integer? where the symbol is now
---@field end_line integer?

--- Whether a named ranged mention no longer matches its symbol.
---@param bufnr integer
---@param ref vergil.Reference
---@param target vergil.Target
---@return vergil.SymbolDrift?
function M.symbol_drift(bufnr, ref, target)
  if ref.mode ~= "mention" or not ref.start_line or not target or not target.exists or target.type ~= "file" then
    return nil
  end
  local name = M.symbol_after(bufnr, ref)
  local list = name and file_symbols(target.abs)
  if not list then
    return nil -- no name, or no parser for the language
  end
  local sym = symbols.find(list, name)
  if not sym then
    return { name = name, missing = true }
  end
  if sym.start_line == ref.start_line and sym.end_line == ref.end_line then
    return nil
  end
  return { name = name, start_line = sym.start_line, end_line = sym.end_line }
end

local function lsp_range(span)
  return {
    start = { line = span.start_row, character = span.start_col },
    ["end"] = { line = span.end_row, character = span.end_col },
  }
end

--- Diagnostics for a session's prompt buffer, in LSP form.
---@param session vergil.Session
---@return table[]
function M.compute(session)
  local opts = config.options.diagnostics
  local out = {}
  local function add(kind, ref, message)
    local sev = opts.severity[kind]
    if not sev then
      return
    end
    out[#out + 1] = {
      range = lsp_range(ref.span),
      severity = SEVERITY[sev],
      source = M.source,
      code = kind,
      message = message,
    }
  end

  local line_counts = {}
  local function line_count(abs)
    if line_counts[abs] == nil then
      line_counts[abs] = resolver.line_count(abs) or false
    end
    return line_counts[abs] or nil
  end

  local first_attach = {} ---@type table<string, integer>
  local function check(ref)
    local target = resolver.resolve(ref, session.root)
    local name = target and (target.rel or target.abs) or ref.path

    if ref.mode == "attach" and ref.in_fence then
      if target and target.exists then
        add("fenced", ref, ("Inside a code block, but may still attach %s."):format(name))
      end
    elseif ref.mode == "attach" then
      local key = resolver.key(ref.path, session.root)
      if first_attach[key] then
        add("duplicate", ref, ("%s is already attached on line %d."):format(name, first_attach[key]))
      else
        first_attach[key] = ref.span.start_row + 1
      end
      if ref.ignored_range then
        add("ignored_range", ref, "Attachments are usually whole files, so the range may be ignored.")
      end
      if not target.exists then
        add("missing_attachment", ref, ("Not found: %s"):format(target.abs))
      elseif target.type == "file" and target.size then
        local tokens = require("vergil.size").tokens(target.size)
        if tokens > opts.attachment_token_warning then
          add(
            "large",
            ref,
            ("Large attachment (~%dk tokens, %s): the agent may skip or cut it. Mention it instead?"):format(
              math.floor(tokens / 1000),
              human_size(target.size)
            )
          )
        end
      end
    elseif ref.explicit or (target and target.exists) then -- mention
      local drift = target.exists and M.symbol_drift(session.bufnr, ref, target)
      if not target.exists then
        add("missing_mention", ref, ("Not found: %s"):format(target.abs))
      elseif drift then
        if drift.missing then
          add("symbol", ref, ("`%s` is no longer in %s."):format(drift.name, name))
        else
          local where = drift.start_line == drift.end_line and ("L%d"):format(drift.start_line)
            or ("L%d-L%d"):format(drift.start_line, drift.end_line)
          add("symbol", ref, ("`%s` is now at %s."):format(drift.name, where))
        end
      elseif ref.start_line and target.type == "file" then
        local total = line_count(target.abs)
        if total and (ref.start_line > total or ref.end_line > total) then
          local range = ref.start_line == ref.end_line and ("Line %d is"):format(ref.start_line)
            or ("Lines %d-%d are"):format(ref.start_line, ref.end_line)
          add("range", ref, ("%s past the end of %s (%d lines)."):format(range, name, total))
        end
      end
    end
  end

  for _, ref in ipairs(parser.parse_buffer(session.bufnr)) do
    if not (ref.resource or ref.unterminated) then
      check(ref)
    end
  end
  return out
end

return M
