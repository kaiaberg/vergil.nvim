--- Converts every path in a range to mentions or attachments: bare paths
--- that exist, and references of the other kind. Backs the
--- `<Plug>(vergil-mention)` and `<Plug>(vergil-attach)` operators (repeat
--- with `.`) and `:[range]Vergil mention|attach`.
local bare = require("vergil.reference.bare")
local convert = require("vergil.reference.convert")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

---@alias vergil.ConvertTo "mention"|"attach"

---@class vergil.Region
---@field row integer 0-based
---@field first integer 0-based byte column, inclusive
---@field last integer 0-based byte column, exclusive

--- Bare path candidates on a line starting in [first, last) that don't
--- overlap a parsed reference. Existence is checked by the caller.
---@param line string
---@param row integer 0-based
---@param refs vergil.Reference[] parsed references on the row
---@param first integer
---@param last integer
---@param fmt string|vergil.MentionTemplates
---@return vergil.Reference[]
local function bare_refs(line, row, refs, first, last, fmt)
  local out = {}
  for _, c in ipairs(bare.candidates(line, first, last, fmt)) do
    local overlaps = false
    for _, ref in ipairs(refs) do
      if c.start_col < ref.span.end_col and c.end_col > ref.span.start_col then
        overlaps = true
        break
      end
    end
    if not overlaps then
      out[#out + 1] = bare.reference(c, row)
    end
  end
  return out
end

--- Parsed references by row, and which lines are fenced.
---@param lines string[]
---@param attach vergil.AttachSpec?
---@param fmt string|vergil.MentionTemplates
---@return table<integer, vergil.Reference[]> by_row 0-based rows
---@return boolean[] fenced 1-based
local function index(lines, attach, fmt)
  local by_row = {}
  for _, ref in ipairs(parser.parse(lines, { attach = attach, mention_format = fmt })) do
    local row = ref.span.start_row
    by_row[row] = by_row[row] or {}
    table.insert(by_row[row], ref)
  end
  return by_row, parser.fenced_lines(lines)
end

--- The edit turning one reference into `to`, or nil to leave it.
---@param ref vergil.Reference
---@param to vergil.ConvertTo
---@param ctx vergil.ConvertCtx
---@param root string
---@return vergil.Edit?
local function edit_for(ref, to, ctx, root)
  if ref.resource or ref.unterminated or ref.in_fence or ref.in_code or ref.git then
    return nil
  end
  local target = resolver.resolve(ref, root)
  if not (target and target.exists) then
    return nil
  end
  if ref.bare then
    -- Paths under the root are written relative to it, as the picker does.
    if target.rel and target.rel ~= "." and ref.path:match("^[~/]") then
      ref.path = target.rel
    end
    local mention = convert.to_mention(ref, ctx)
    if to == "mention" or not mention then
      return mention
    end
    return convert.to_attachment(
      vim.tbl_extend("force", ref, { bare = false, text = mention.text, span = ref.span }),
      ctx
    )
  end
  if to == "mention" and ref.mode == "attach" then
    return (convert.to_mention(ref, ctx))
  end
  if to == "attach" and ref.mode == "mention" then
    return (convert.to_attachment(ref, ctx))
  end
end

--- Converts the paths that start inside the regions, in one undo step.
---@param bufnr integer
---@param to vergil.ConvertTo
---@param regions vergil.Region[]
---@return integer? count converted, nil on error
---@return string? err
function M.convert(bufnr, to, regions)
  local session = require("vergil.session").get(bufnr)
  if not session then
    return nil, "not enabled in this buffer (use :Vergil enable)"
  end
  local attach = require("vergil.agents").for_buffer(bufnr).attach
  if to == "attach" and not attach then
    return nil, "this agent has no attachments"
  end
  local ctx = { attach = attach, mention_format = require("vergil.config").options.mention.format }
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local by_row, fenced = index(lines, attach, ctx.mention_format)
  local edits = {} ---@type vergil.Edit[]
  for _, region in ipairs(regions) do
    local row, line = region.row, lines[region.row + 1]
    if line and not fenced[region.row + 1] then
      local refs = by_row[row] or {}
      local function inside(col)
        return col >= region.first and col < region.last
      end
      for _, ref in ipairs(refs) do
        if inside(ref.span.start_col) then
          edits[#edits + 1] = edit_for(ref, to, ctx, session.root)
        end
      end
      for _, ref in ipairs(bare_refs(line, row, refs, region.first, region.last, ctx.mention_format)) do
        edits[#edits + 1] = edit_for(ref, to, ctx, session.root)
      end
    end
  end
  -- Last first, so earlier spans stay valid.
  table.sort(edits, function(a, b)
    if a.span.start_row ~= b.span.start_row then
      return a.span.start_row > b.span.start_row
    end
    return a.span.start_col > b.span.start_col
  end)
  for _, e in ipairs(edits) do
    convert.apply(bufnr, e)
  end
  return #edits
end

--- Regions for whole lines (1-based, inclusive).
---@param bufnr integer
---@param line1 integer
---@param line2 integer
---@return vergil.Region[]
function M.line_regions(bufnr, line1, line2)
  local regions = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)) do
    regions[#regions + 1] = { row = line1 + i - 2, first = 0, last = #line }
  end
  return regions
end

--- Regions between the `[` and `]` marks, as an operator gets them.
---@param bufnr integer
---@param type "line"|"char"|"block"
---@return vergil.Region[]
local function mark_regions(bufnr, type)
  local s = vim.api.nvim_buf_get_mark(bufnr, "[")
  local e = vim.api.nvim_buf_get_mark(bufnr, "]")
  if type == "line" then
    return M.line_regions(bufnr, s[1], e[1])
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, s[1] - 1, e[1], false)
  local regions = {}
  for i, line in ipairs(lines) do
    local row = s[1] + i - 2
    local first, last = 0, #line
    if type == "block" then
      first, last = math.min(s[2], e[2]), math.max(s[2], e[2]) + 1
    else
      if i == 1 then
        first = s[2]
      end
      if i == #lines then
        last = math.min(e[2] + 1, #line)
      end
    end
    regions[#regions + 1] = { row = row, first = first, last = last }
  end
  return regions
end

local function run(to, regions)
  local count, err = M.convert(vim.api.nvim_get_current_buf(), to, regions)
  if not count then
    vim.notify("vergil: " .. err, vim.log.levels.WARN)
  elseif count == 0 then
    vim.notify("vergil: no paths to convert", vim.log.levels.WARN)
  end
end

--- `operatorfunc` targets.
function M.op_mention(type)
  run("mention", mark_regions(vim.api.nvim_get_current_buf(), type))
end
function M.op_attach(type)
  run("attach", mark_regions(vim.api.nvim_get_current_buf(), type))
end

--- Starts the operator: map an expr mapping to this.
---@param to vergil.ConvertTo
---@return string keys
function M.expr(to)
  vim.o.operatorfunc = ("v:lua.require'vergil.operator'.op_%s"):format(to)
  return "g@"
end

--- Moves the cursor to the [count]th next (`dir` 1) or previous (-1) bare
--- path that exists, outside code and references: what the operators would
--- convert.
---@param dir 1|-1
---@param count integer?
---@return boolean ok
---@return string? err
function M.jump(dir, count)
  local bufnr = vim.api.nvim_get_current_buf()
  local session = require("vergil.session").get(bufnr)
  if not session then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local fmt = require("vergil.config").options.mention.format
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local by_row, fenced = index(lines, require("vergil.agents").for_buffer(bufnr).attach, fmt)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local found
  for _ = 1, math.max(count or 1, 1) do
    found = nil
    local r = row
    while r >= 0 and r < #lines and not found do
      if not fenced[r + 1] then
        local refs = bare_refs(lines[r + 1], r, by_row[r] or {}, 0, #lines[r + 1], fmt)
        local from, to, step = 1, #refs, 1
        if dir < 0 then
          from, to, step = #refs, 1, -1
        end
        for i = from, to, step do
          local ref = refs[i]
          local c = ref.span.start_col
          local ahead = r ~= row or (dir > 0 and c > col) or (dir < 0 and c < col)
          if ahead then
            local target = resolver.resolve(ref, session.root)
            if target and target.exists then
              found = ref
              break
            end
          end
        end
      end
      r = r + dir
    end
    if not found then
      break
    end
    row, col = found.span.start_row, found.span.start_col
  end
  if not found then
    return false, dir > 0 and "no path below" or "no path above"
  end
  vim.cmd("normal! m'") -- like other jumps, `` returns
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
  return true
end

--- `:[range]Vergil mention|attach`.
---@param to vergil.ConvertTo
---@param line1 integer
---@param line2 integer
---@return boolean ok
---@return string? err
function M.lines(to, line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local count, err = M.convert(bufnr, to, M.line_regions(bufnr, line1, line2))
  if not count then
    return false, err
  end
  if count == 0 then
    return false, "no paths to convert"
  end
  return true
end

return M
