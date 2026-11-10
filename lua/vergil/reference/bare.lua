--- Bare paths: a file or directory written without `@` or backticks, such
--- as `src/a.ts:12` pasted from a log. Like `gf`, vergil looks for one only
--- under the cursor, never across the buffer, and only takes it when it
--- exists on disk, so ordinary words aren't mistaken for paths.
local formatter = require("vergil.reference.formatter")
local resolver = require("vergil.reference.resolver")

local M = {}

--- Characters that end a bare path: whitespace, brackets, quotes and list
--- punctuation, so `(src/a.ts)` and `"a.ts",` give the path alone.
local DELIM = "[%s%(%)%[%]{}<>\"'`,;|]"

--- A run of characters between delimiters, with its 1-based start.
local WORD = "()[^%s%(%)%[%]{}<>\"'`,;|]+"

--- Trailing characters that end a sentence rather than belong to the path.
local TRAILING = "[%.:!?]+$"

---@class vergil.BareCandidate
---@field path string
---@field start_line integer?
---@field end_line integer?
---@field start_col integer 0-based byte column
---@field end_col integer 0-based exclusive byte column
---@field text string

--- The bare path candidate around a byte column of a line. Pure: it never
--- touches the file system.
---@param line string
---@param col integer 0-based byte column
---@param fmt string|vergil.MentionTemplates
---@return vergil.BareCandidate?
function M.candidate(line, col, fmt)
  local i = col + 1 -- 1-based
  if i > #line + 1 then
    return nil
  end
  -- A cursor just after the path (on its delimiter or past the end) still
  -- finds it, as references do.
  if i > #line or line:sub(i, i):match(DELIM) then
    i = i - 1
  end
  if i < 1 or line:sub(i, i):match(DELIM) then
    return nil
  end
  local s, e = i, i
  while s > 1 and not line:sub(s - 1, s - 1):match(DELIM) do
    s = s - 1
  end
  while e < #line and not line:sub(e + 1, e + 1):match(DELIM) do
    e = e + 1
  end
  local text = line:sub(s, e):gsub(TRAILING, "")
  if text == "" or text:sub(1, 1) == "@" then
    return nil -- `@` belongs to an attachment, whatever the agent writes
  end
  e = s + #text - 1
  local path, first, last = formatter.parse_mention(text, fmt)
  if path == "" or (first and last and last < first) then
    return nil
  end
  return { path = path, start_line = first, end_line = last, start_col = s - 1, end_col = e, text = text }
end

--- Every candidate on a line that starts in a byte range, outside inline
--- code. Pure, like `candidate`.
---@param line string
---@param first integer 0-based byte column, inclusive
---@param last integer 0-based byte column, exclusive
---@param fmt string|vergil.MentionTemplates
---@return vergil.BareCandidate[]
function M.candidates(line, first, last, fmt)
  local code = require("vergil.reference.parser").code_spans(line)
  local out = {}
  for s in line:gmatch(WORD) do
    local col = s - 1
    local in_code = false
    for _, span in ipairs(code) do
      if s > span.start and s < span.finish then
        in_code = true
        break
      end
    end
    if col >= first and col < last and not in_code then
      out[#out + 1] = M.candidate(line, col, fmt)
    end
  end
  return out
end

--- A candidate on a row as a mention reference (`bare = true`).
---@param c vergil.BareCandidate
---@param row integer 0-based
---@return vergil.Reference
function M.reference(c, row)
  return {
    mode = "mention",
    bare = true,
    explicit = true,
    path = c.path,
    start_line = c.start_line,
    end_line = c.end_line,
    span = { start_row = row, start_col = c.start_col, end_row = row, end_col = c.end_col },
    text = c.text,
  }
end

--- A bare path at a position that exists on disk, as a mention reference
--- (`bare = true`), or nil.
---@param bufnr integer
---@param row integer 0-based
---@param col integer 0-based byte column
---@param root string
---@return vergil.Reference?
function M.at(bufnr, row, col, root)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return nil
  end
  local c = M.candidate(line, col, require("vergil.config").options.mention.format)
  if not c then
    return nil
  end
  local ref = M.reference(c, row)
  local target = resolver.resolve(ref, root)
  if not (target and target.exists) then
    return nil
  end
  return ref
end

--- The reference at a position: a parsed one, else a bare path that exists.
---@param bufnr integer
---@param row integer 0-based
---@param col integer 0-based byte column
---@param root string
---@return vergil.Reference?
function M.ref_at(bufnr, row, col, root)
  local parser = require("vergil.reference.parser")
  return parser.at(parser.parse_buffer(bufnr), row, col) or M.at(bufnr, row, col, root)
end

return M
