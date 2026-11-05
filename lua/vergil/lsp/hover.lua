--- Hover previews for references (`K`, or `:Vergil preview`).
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

M.preview_lines = 20
M.max_range_lines = 60
M.max_dir_entries = 40

local function human_size(n)
  if n < 1024 then
    return n .. " B"
  elseif n < 1024 * 1024 then
    return ("%.1f KB"):format(n / 1024)
  end
  return ("%.1f MB"):format(n / 1024 / 1024)
end

--- Reads lines `first..last` (1-based, inclusive), stopping at `last`.
local function read_lines(abs, first, last)
  local out, n = {}, 0
  local fd = io.open(abs, "rb")
  if not fd then
    return nil
  end
  -- Check raw bytes: LuaJIT's lines() cuts a line at a NUL byte.
  local head = fd:read(8192) or ""
  if head:find("\0", 1, true) then
    fd:close()
    return nil, "binary"
  end
  fd:seek("set", 0)
  for line in fd:lines() do
    n = n + 1
    if n >= first then
      out[#out + 1] = line
    end
    if n >= last then
      break
    end
  end
  fd:close()
  return out
end

local function fence_for(lines)
  local longest = 2
  for _, l in ipairs(lines) do
    for run in l:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return string.rep("`", longest + 1)
end

--- Whether a mention should be treated as a file reference.
---@param ref vergil.Reference
---@param target vergil.Target?
function M.is_file_ref(ref, target)
  return ref.mode == "attach" or ref.explicit or (target ~= nil and target.exists)
end

--- Markdown lines describing a reference, or nil when there's nothing to show.
---@param ref vergil.Reference
---@param root string
---@return string[]?
function M.contents(ref, root)
  if ref.resource then
    return { ("**%s**"):format(ref.path), "", "Resource reference; vergil doesn't resolve these." }
  end
  local target = resolver.resolve(ref, root)
  if not target or not M.is_file_ref(ref, target) then
    return nil
  end
  local name = target.rel or target.abs
  local kind = ref.mode == "attach" and "attachment" or "mention"
  if not target.exists then
    return { ("**%s**"):format(name), "", ("Not found: `%s` (%s)"):format(target.abs, kind) }
  end
  if target.type == "directory" then
    local entries = {}
    for entry, type in vim.fs.dir(target.abs) do
      entries[#entries + 1] = entry .. (type == "directory" and "/" or "")
    end
    table.sort(entries)
    local out = { ("**%s/** · directory · %d entries · %s"):format(name:gsub("/$", ""), #entries, kind), "" }
    for i = 1, math.min(#entries, M.max_dir_entries) do
      out[#out + 1] = "- `" .. entries[i] .. "`"
    end
    if #entries > M.max_dir_entries then
      out[#out + 1] = ("- … %d more"):format(#entries - M.max_dir_entries)
    end
    return out
  end

  local total = resolver.line_count(target.abs) or 0
  local header = ("**%s** · %s · %d %s · %s"):format(name, human_size(target.size or 0), total, total == 1 and "line" or "lines", kind)
  local first, last = 1, M.preview_lines
  local note
  if ref.start_line then
    first, last = ref.start_line, ref.end_line or ref.start_line
    if first > total then
      return { header, "", ("Line %d is past the end of the file (%d lines)."):format(first, total) }
    end
    if last > total then
      note = ("Range ends past the file (%d lines)."):format(total)
      last = total
    end
    if last - first + 1 > M.max_range_lines then
      note = ("Showing the first %d of %d lines."):format(M.max_range_lines, last - first + 1)
      last = first + M.max_range_lines - 1
    end
    header = header .. (first == last and (" · line %d"):format(first) or (" · lines %d–%d"):format(first, last))
  end
  local lines, err = read_lines(target.abs, first, last)
  if not lines then
    return { header, "", err == "binary" and "Binary file." or "Can't read the file." }
  end
  local lang = vim.filetype.match({ filename = target.abs }) or ""
  local fence = fence_for(lines)
  local out = { header, "", fence .. lang }
  vim.list_extend(out, lines)
  out[#out + 1] = fence
  if note then
    out[#out + 1] = ""
    out[#out + 1] = "_" .. note .. "_"
  elseif not ref.start_line and total > last then
    out[#out + 1] = ""
    out[#out + 1] = ("_… %d more lines_"):format(total - last)
  end
  return out
end

--- The skill token at a position and its definition, if known and not in
--- fenced code.
---@return { name: string, start_col: integer, end_col: integer }? token
---@return vergil.Skill? skill
function M.skill_at(session, row, col)
  local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  if parser.fenced_lines(lines)[row + 1] then
    return nil
  end
  local skills = require("vergil.skills")
  local tok = skills.token_at(lines[row + 1] or "", col)
  if not tok then
    return nil
  end
  local skill = skills.find(session.root, tok.name)
  if not skill then
    return nil
  end
  return tok, skill
end

function M.skill_hover(session, row, col)
  local tok, skill = M.skill_at(session, row, col)
  if not tok or not skill then
    return nil
  end
  return {
    contents = { kind = "markdown", value = table.concat(require("vergil.skills").contents(skill, session.root), "\n") },
    range = { start = { line = row, character = tok.start_col }, ["end"] = { line = row, character = tok.end_col } },
  }
end

--- `textDocument/hover` result for a position, or nil.
---@param params table LSP HoverParams
---@param session vergil.Session
function M.handle(params, session)
  local row, col = params.position.line, params.position.character
  local ref = parser.at(parser.parse_buffer(session.bufnr), row, col)
  if not ref then
    return M.skill_hover(session, row, col)
  end
  local contents = M.contents(ref, session.root)
  if not contents then
    return nil
  end
  local s = ref.span
  return {
    contents = { kind = "markdown", value = table.concat(contents, "\n") },
    range = { start = { line = s.start_row, character = s.start_col }, ["end"] = { line = s.end_row, character = s.end_col } },
  }
end

return M
