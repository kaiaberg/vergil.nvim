--- `textDocument/codeAction` (`gra` by default): conversions (plan §6.5),
--- fixes for diagnostics (§6.6), and snippet/line-selection actions.
---
--- Conversions are plain text edits. Snippet and selection actions run
--- client-side commands (registered in lsp/client.lua), because they open UI
--- or depend on the file's current contents.
local config = require("vergil.config")
local convert = require("vergil.reference.convert")
local formatter = require("vergil.reference.formatter")
local diagnostics = require("vergil.lsp.diagnostics")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

M.commands = {
  snippet = "vergil.snippet",
  select = "vergil.select",
}

local function overlaps(span, range)
  local srow, erow = range.start.line, range["end"].line
  if span.start_row < srow or span.start_row > erow then
    return false
  end
  if srow == erow then
    local scol, ecol = range.start.character, range["end"].character
    return span.start_col <= ecol and span.end_col >= scol
  end
  return true
end

local function text_edit(uri, edit)
  local s = edit.span
  return {
    changes = {
      [uri] = {
        {
          range = {
            start = { line = s.start_row, character = s.start_col },
            ["end"] = { line = s.end_row, character = s.end_col },
          },
          newText = edit.text,
        },
      },
    },
  }
end

---@param params table LSP CodeActionParams
---@param session vergil.Session
---@return table[]
function M.handle(params, session)
  local uri = params.textDocument.uri
  local ctx = { adapter = config.adapter(), mention_format = config.options.mention.format }
  local fixable = {}
  for _, d in ipairs(params.context and params.context.diagnostics or {}) do
    if d.source == diagnostics.source and diagnostics.fixable[d.code] then
      fixable[#fixable + 1] = d
    end
  end

  local actions = {}
  for _, ref in ipairs(parser.parse_buffer(session.bufnr)) do
    if overlaps(ref.span, params.range) and not ref.in_fence then
      local target = resolver.resolve(ref, session.root)
      local is_file_ref = ref.mode == "attach" or ref.explicit or (target and target.exists)
      if is_file_ref then
        local edit = convert.toggle(ref, ctx)
        if edit then
          local fixes = vim.tbl_filter(function(d)
            return d.range.start.line == ref.span.start_row and d.range.start.character == ref.span.start_col
          end, fixable)
          local to_mention = ref.mode == "attach"
          actions[#actions + 1] = {
            title = to_mention and "Convert to mention" or "Convert to attachment",
            kind = #fixes > 0 and "quickfix" or "refactor.rewrite",
            diagnostics = #fixes > 0 and fixes or nil,
            isPreferred = #fixes > 0 or nil,
            edit = text_edit(uri, edit),
          }
        end
        local drift = diagnostics.symbol_drift(session.bufnr, ref, target)
        if drift and not drift.missing then
          local mention = formatter.mention(ref.path, drift.start_line, drift.end_line, config.options.mention.format)
          if mention then
            local where = drift.start_line == drift.end_line and ("L%d"):format(drift.start_line)
              or ("L%d-L%d"):format(drift.start_line, drift.end_line)
            local fixes = vim.tbl_filter(function(d)
              return d.code == "symbol" and d.range.start.line == ref.span.start_row and d.range.start.character == ref.span.start_col
            end, params.context and params.context.diagnostics or {})
            actions[#actions + 1] = {
              title = ("Update range to %s"):format(where),
              kind = "quickfix",
              diagnostics = #fixes > 0 and fixes or nil,
              isPreferred = true,
              edit = text_edit(uri, { span = ref.span, text = mention }),
            }
          end
        end
        if target and target.exists and target.type == "file" then
          local pos = { uri, ref.span.start_row, ref.span.start_col }
          local ranged = ref.start_line or ref.ignored_range
          if ranged then
            actions[#actions + 1] = {
              title = "Replace with snippet",
              kind = "refactor.rewrite",
              command = { title = "Replace with snippet", command = M.commands.snippet, arguments = { pos[1], pos[2], pos[3], "snippet" } },
            }
            actions[#actions + 1] = {
              title = "Add snippet below",
              kind = "refactor.rewrite",
              command = { title = "Add snippet below", command = M.commands.snippet, arguments = { pos[1], pos[2], pos[3], "both" } },
            }
          end
          actions[#actions + 1] = {
            title = "Select lines…",
            kind = "refactor.rewrite",
            command = { title = "Select lines…", command = M.commands.select, arguments = pos },
          }
        end
      end
    end
  end
  return actions
end

return M
