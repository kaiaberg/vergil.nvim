--- Diagnostics for prompt references (plan §6.6). Validation never touches
--- the buffer; fixes are offered as code actions.
---
--- Rules:
--- - Paths are compared after normalization (`./a`, `a`, `~`, absolute).
--- - Mentions of attached files are never flagged: attach once, then mention.
--- - Fenced code is skipped, except for a hint when a fenced `@token` names a
---   real file, because Claude Code attaches it anyway.
--- - Ordinary inline code that merely might be a path is never flagged.
--- - Attachment size is estimated in tokens (bytes / 3): Claude Code's limit
---   is token-based and files above it are silently dropped (M0 findings).
local config = require("vergil.config")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

M.source = "vergil"

local SEVERITY = { error = 1, warn = 2, info = 3, hint = 4 }

--- Diagnostic kinds that "Convert to mention" fixes.
M.fixable = { duplicate = true, large = true, ignored_range = true }

local function human_size(n)
  if n < 1024 * 1024 then
    return ("%.0f KB"):format(n / 1024)
  end
  return ("%.1f MB"):format(n / 1024 / 1024)
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
        add("fenced", ref, ("Claude Code will attach %s, even inside a code block."):format(name))
      end
    elseif ref.mode == "attach" then
      local key = resolver.key(ref.path, session.root)
      if first_attach[key] then
        add("duplicate", ref, ("%s is already attached on line %d."):format(name, first_attach[key]))
      else
        first_attach[key] = ref.span.start_row + 1
      end
      if ref.ignored_range then
        add("ignored_range", ref, "The range doesn't limit an attachment: Claude Code attaches the whole file.")
      end
      if not target.exists then
        add("missing_attachment", ref, ("Not found: %s"):format(target.abs))
      elseif target.type == "file" and target.size then
        local tokens = math.floor(target.size / 3)
        if tokens > opts.attachment_token_warning then
          add(
            "large",
            ref,
            ("Large attachment (~%dk tokens, %s): Claude Code may silently drop it. Mention it instead?"):format(
              math.floor(tokens / 1000),
              human_size(target.size)
            )
          )
        end
      end
    elseif ref.explicit or (target and target.exists) then -- mention
      if not target.exists then
        add("missing_mention", ref, ("Not found: %s"):format(target.abs))
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
