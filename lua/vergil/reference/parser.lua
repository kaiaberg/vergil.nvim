--- Finds references in prompt text and returns their exact spans.
---
--- Grammar:
--- - Attachments use the adapter's syntax and are found everywhere, because
---   the agent doesn't parse Markdown: Claude Code expands `@Override` inside
---   fenced code. They are flagged `in_fence` / `in_code` so callers can skip them.
--- - Mentions are single-backtick code spans outside fenced code whose content
---   parses with the configured mention format. `explicit` is true when the
---   content clearly is a path (has a range, a `/`, or a file extension);
---   otherwise it may be ordinary inline code, and callers should only treat it
---   as a mention when the target exists.
---
--- The parser is pure: it never touches the file system.
local formatter = require("vergil.reference.formatter")

local M = {}

---@class vergil.Span
---@field start_row integer 0-based
---@field start_col integer 0-based byte column
---@field end_row integer 0-based
---@field end_col integer 0-based exclusive byte column

---@class vergil.Reference
---@field mode "attach"|"mention"
---@field path string as written (relative, `./`, `~` or absolute)
---@field start_line integer? mention only
---@field end_line integer? mention only
---@field span vergil.Span
---@field text string the exact source text of the span
---@field in_fence boolean? inside fenced code (attachments only)
---@field in_code boolean? inside an inline code span (attachments only)
---@field quoted boolean? attachment written as `@"path"`
---@field unterminated boolean? quoted attachment missing its closing quote
---@field resource boolean? non-file attachment such as `@server:resource`
---@field ignored_range integer[]? attachment `#range` that doesn't limit it
---@field explicit boolean? mention content clearly is a path

---@class vergil.ParseOpts
---@field adapter vergil.Adapter
---@field mention_format string|vergil.MentionTemplates

--- Marks which lines are fenced code. Fence delimiters count as fenced.
--- CommonMark-style: up to 3 spaces of indent, 3+ backticks or tildes, closed
--- by the same character at least as long with nothing else on the line.
---@param lines string[]
---@return boolean[]
function M.fenced_lines(lines)
  local fenced, open = {}, nil
  for i, line in ipairs(lines) do
    local indent, run = line:match("^( *)(```+)")
    if not run then
      indent, run = line:match("^( *)(~~~+)")
    end
    if run and #indent > 3 then
      run = nil
    end
    if open then
      fenced[i] = true
      if run and run:sub(1, 1) == open:sub(1, 1) and #run >= #open and line:sub(#indent + #run + 1):match("^%s*$") then
        open = nil
      end
    elseif run and not (run:sub(1, 1) == "`" and line:sub(#indent + #run + 1):find("`", 1, true)) then
      -- A backtick fence's info string may not contain backticks.
      fenced[i] = true
      open = run
    else
      fenced[i] = false
    end
  end
  return fenced
end

--- Single-line code spans: { start = 1-based index of opening run, finish =
--- 1-based index of closing run's last backtick, ticks = run length }.
local function code_spans(line)
  local spans, pos = {}, 1
  while true do
    local s, e = line:find("`+", pos)
    if not s then
      break
    end
    local n = e - s + 1
    local search, close_s, close_e = e + 1, nil, nil
    while true do
      local cs, ce = line:find("`+", search)
      if not cs then
        break
      end
      if ce - cs + 1 == n then
        close_s, close_e = cs, ce
        break
      end
      search = ce + 1
    end
    if close_s then
      spans[#spans + 1] = { start = s, finish = close_e, ticks = n, content = line:sub(e + 1, close_s - 1) }
      pos = close_e + 1
    else
      pos = e + 1 -- unmatched run is literal text
    end
  end
  return spans
end

local NOT_PATH = "[%(%)=;{}<>|%*%$\"'`]"

local function mention_from(span, row, content, fmt)
  if content == "" or content:match("^%s") or content:match("%s$") or content:sub(1, 1) == "@" then
    return nil
  end
  -- Prose inside inline code, e.g. `see @a.ts`: the attachment is real
  -- (Claude Code ignores Markdown), so the span isn't also a mention.
  if content:find(NOT_PATH) or content:find("%s@") then
    return nil
  end
  local path, s, e = formatter.parse_mention(content, fmt)
  if path == "" or (s and e and e < s) then
    return nil
  end
  local explicit = s ~= nil or path:find("/", 1, true) ~= nil or path:match("%.[%w]+$") ~= nil
  return {
    mode = "mention",
    path = path,
    start_line = s,
    end_line = e,
    span = { start_row = row, start_col = span.start - 1, end_row = row, end_col = span.finish },
    explicit = explicit,
  }
end

--- Parses lines of prompt text.
---@param lines string[]
---@param opts vergil.ParseOpts
---@return vergil.Reference[] refs ordered by position
function M.parse(lines, opts)
  local refs = {}
  local fenced = M.fenced_lines(lines)
  for i, line in ipairs(lines) do
    local row = i - 1
    local spans = fenced[i] and {} or code_spans(line)
    if not fenced[i] then
      for _, span in ipairs(spans) do
        if span.ticks == 1 then
          local ref = mention_from(span, row, span.content, opts.mention_format)
          if ref then
            ref.text = line:sub(span.start, span.finish)
            refs[#refs + 1] = ref
          end
        end
      end
    end
    for _, a in ipairs(opts.adapter.find_attachments(line)) do
      local in_code = false
      for _, span in ipairs(spans) do
        if a.start_col >= span.start and a.start_col < span.finish then
          in_code = true
          break
        end
      end
      refs[#refs + 1] = {
        mode = "attach",
        path = a.path,
        span = { start_row = row, start_col = a.start_col, end_row = row, end_col = a.end_col },
        text = line:sub(a.start_col + 1, a.end_col),
        in_fence = fenced[i] or nil,
        in_code = in_code or nil,
        quoted = a.quoted or nil,
        unterminated = a.unterminated,
        resource = a.resource,
        ignored_range = a.ignored_range,
      }
    end
  end
  table.sort(refs, function(a, b)
    if a.span.start_row ~= b.span.start_row then
      return a.span.start_row < b.span.start_row
    end
    return a.span.start_col < b.span.start_col
  end)
  return refs
end

--- Parses a buffer with the current configuration.
---@param bufnr integer
---@return vergil.Reference[]
function M.parse_buffer(bufnr)
  local config = require("vergil.config")
  return M.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    adapter = config.adapter(),
    mention_format = config.options.mention.format,
  })
end

--- The reference containing a position (end column inclusive, so a cursor
--- just after a reference still finds it).
---@param refs vergil.Reference[]
---@param row integer 0-based
---@param col integer 0-based byte column
---@return vergil.Reference?
function M.at(refs, row, col)
  for _, ref in ipairs(refs) do
    local s = ref.span
    if s.start_row == row and col >= s.start_col and col <= s.end_col then
      return ref
    end
  end
end

return M
