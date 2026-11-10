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
  local fenced = parser.fenced_lines(lines)
  local by_row = {} ---@type table<integer, vergil.Reference[]>
  for _, ref in ipairs(parser.parse(lines, { attach = attach, mention_format = ctx.mention_format })) do
    local row = ref.span.start_row
    by_row[row] = by_row[row] or {}
    table.insert(by_row[row], ref)
  end
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
      for _, c in ipairs(bare.candidates(line, region.first, region.last, ctx.mention_format)) do
        local overlaps = false
        for _, ref in ipairs(refs) do
          if c.start_col < ref.span.end_col and c.end_col > ref.span.start_col then
            overlaps = true
            break
          end
        end
        if not overlaps then
          edits[#edits + 1] = edit_for(bare.reference(c, row), to, ctx, session.root)
        end
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
