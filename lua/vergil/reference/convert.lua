--- Converts between attachments and mentions (plan §6.5).
---
--- Conversions return text edits and never touch the buffer themselves;
--- `apply` replaces exactly the reference's span and nothing else.
local formatter = require("vergil.reference.formatter")

local M = {}

---@class vergil.Edit
---@field span vergil.Span
---@field text string

---@class vergil.ConvertCtx
---@field adapter vergil.Adapter
---@field mention_format string|vergil.MentionTemplates

local function refuse(ref)
  if ref.mode == "attach" and ref.resource then
    return "not a file reference"
  end
  if ref.unterminated then
    return "unterminated quoted path"
  end
end

--- `@file` → `` `file` ``; `@file#L12-L35` → `` `file#L12-L35` ``.
---@param ref vergil.Reference
---@param ctx vergil.ConvertCtx
---@return vergil.Edit?
---@return string? err
function M.to_mention(ref, ctx)
  if ref.mode ~= "attach" then
    return nil, "already a mention"
  end
  local err = refuse(ref)
  if err then
    return nil, err
  end
  local r = ref.ignored_range
  local text, ferr = formatter.mention(ref.path, r and r[1], r and r[2], ctx.mention_format)
  if not text then
    return nil, ferr
  end
  return { span = ref.span, text = text }
end

--- `` `file` `` → `@file`; `` `file#L12-L35` `` → `@file` `` `file#L12-L35` ``,
--- keeping the mention so the range isn't lost.
---@param ref vergil.Reference
---@param ctx vergil.ConvertCtx
---@return vergil.Edit?
---@return string? err
function M.to_attachment(ref, ctx)
  if ref.mode ~= "mention" then
    return nil, "already an attachment"
  end
  local attach = formatter.attachment(ref.path, ctx.adapter)
  if ref.start_line then
    return { span = ref.span, text = attach .. " " .. ref.text }
  end
  return { span = ref.span, text = attach }
end

--- Converts to the other reference type.
---@param ref vergil.Reference
---@param ctx vergil.ConvertCtx
---@return vergil.Edit?
---@return string? err
function M.toggle(ref, ctx)
  if ref.mode == "attach" then
    return M.to_mention(ref, ctx)
  end
  return M.to_attachment(ref, ctx)
end

--- Applies an edit to a buffer, replacing exactly its span.
---@param bufnr integer
---@param edit vergil.Edit
function M.apply(bufnr, edit)
  local s = edit.span
  vim.api.nvim_buf_set_text(bufnr, s.start_row, s.start_col, s.end_row, s.end_col, vim.split(edit.text, "\n"))
end

return M
