--- `textDocument/completion` for file references.
---
--- Lessons from the M0 prototype (docs/m0-findings.md):
--- - Filter and rank here, and set `filterText` to the typed token so engines
---   that prefix-filter keep every item.
--- - Always return `isIncomplete = true`: native completion ignores the second
---   `@` of `@@` otherwise, and refilters mention items (inserted as
---   `` `path` ``) against their inserted word until the menu closes.
--- - Report the size in `labelDetails` only; blink shows `detail` as well.
--- - Native completion on 0.11 truncates inserted text at the first space
---   unless the item is a snippet, so such items are sent as escaped snippets.
local config = require("vergil.config")
local files = require("vergil.files")
local formatter = require("vergil.reference.formatter")
local parser = require("vergil.reference.parser")
local resolver = require("vergil.reference.resolver")

local M = {}

M.max_items = 100

local KIND_FILE = 17
local INVOKED = 1
local SNIPPET = 2

local snippet_fix = vim.fn.has("nvim-0.12") == 0

--- Native completion on 0.11: no completion plugin loaded.
local function native_011()
  return snippet_fix and not package.loaded["blink.cmp"] and not package.loaded["cmp"]
end

---@class vergil.CompletionToken
---@field mode "attach"|"mention"
---@field start_col integer 0-based column where the replaced text starts
---@field end_col integer 0-based exclusive column where it ends
---@field query string

--- Characters that should (re)trigger completion. `.`, `/`, `~` and `"`
--- keep engines like blink from closing the menu on non-keyword characters.
---@return string[]
function M.trigger_characters()
  local chars = { ".", "/", "~", '"' }
  for _, k in ipairs({ "attach", "mention", "skills" }) do
    local c = config.options.triggers[k]:sub(-1)
    if not vim.tbl_contains(chars, c) then
      chars[#chars + 1] = c
    end
  end
  return chars
end

--- The reference being typed before the cursor: a trigger at line start or
--- after whitespace, then a query without whitespace (or a quoted query).
---@param line string
---@param col integer 0-based cursor column
---@return vergil.CompletionToken?
function M.typing_token(line, col)
  local before = line:sub(1, col)
  local triggers = config.options.triggers
  -- Longest trigger first, so "@@" wins over "@".
  local order = { { triggers.mention, "mention" }, { triggers.attach, "attach" } }
  table.sort(order, function(a, b)
    return #a[1] > #b[1]
  end)
  for _, t in ipairs(order) do
    local trigger, mode = t[1], t[2]
    local init, found = 1, nil
    while true do
      local s = before:find(trigger, init, true)
      if not s then
        break
      end
      found = s
      init = s + 1
    end
    if found then
      local boundary = found == 1 or before:sub(found - 1, found - 1):match("%s") ~= nil
      local query = before:sub(found + #trigger)
      local ok = (query:sub(1, 1) == '"' and not query:sub(2):find('"')) or not query:find("%s")
      if boundary and ok then
        return { mode = mode, start_col = found - 1, end_col = col, query = (query:gsub('^"', "")) }
      end
    end
  end
end

--- An existing reference under the cursor, for re-searching it in place on
--- manual completion. The query is its path up to the cursor.
---@param bufnr integer
---@param row integer
---@param col integer
---@param root string
---@param whole boolean? the query is the whole path, not just up to the cursor
---@return vergil.CompletionToken?
function M.existing_token(bufnr, row, col, root, whole)
  local ref = parser.at(parser.parse_buffer(bufnr), row, col)
  if not ref or ref.resource or ref.in_fence then
    return nil
  end
  if ref.mode == "mention" and not ref.explicit then
    local target = resolver.resolve(ref, root)
    if not (target and target.exists) then
      return nil
    end
  end
  local path_start = ref.span.start_col + ((ref.mode == "attach" and ref.quoted) and 2 or 1)
  local upto = whole and #ref.path or math.max(0, math.min(col - path_start, #ref.path))
  return { mode = ref.mode, start_col = ref.span.start_col, end_col = ref.span.end_col, query = ref.path:sub(1, upto) }
end

local function escape_snippet(text)
  return (text:gsub("[\\%$}]", "\\%0"))
end

local function human_size(n)
  if n < 1024 then
    return n .. " B"
  elseif n < 1024 * 1024 then
    return ("%.1f KB"):format(n / 1024)
  end
  return ("%.1f MB"):format(n / 1024 / 1024)
end

local function rank(list, query)
  if query == "" then
    return vim.list_slice(list, 1, M.max_items)
  end
  return vim.fn.matchfuzzy(list, query, { limit = M.max_items })
end

local function attached_keys(bufnr, root, token, row)
  local keys = {}
  for _, ref in ipairs(parser.parse_buffer(bufnr)) do
    local own = ref.span.start_row == row and ref.span.start_col == token.start_col
    if ref.mode == "attach" and not ref.resource and not ref.in_fence and not own then
      keys[resolver.key(ref.path, root)] = true
    end
  end
  return keys
end

--- Completion items for paths already ranked.
local function build(ranked, token, ctx)
  local items = {}
  local attached = attached_keys(ctx.bufnr, ctx.root, token, ctx.row)
  local fmt = config.options.mention.format
  local adapter = config.adapter()
  local range = {
    start = { line = ctx.row, character = token.start_col },
    ["end"] = { line = ctx.row, character = token.end_col },
  }
  for i, path in ipairs(ranked) do
    local text = token.mode == "mention" and formatter.mention(path, nil, nil, fmt) or formatter.attachment(path, adapter)
    if text then
      local st = path:sub(-1) ~= "/" and vim.uv.fs_stat(resolver.absolute(path, ctx.root))
      local detail = st and human_size(st.size) or ""
      if attached[resolver.key(path, ctx.root)] then
        detail = detail .. " · attached"
      end
      local item = {
        label = path,
        kind = KIND_FILE,
        labelDetails = { description = detail },
        filterText = ctx.typed,
        sortText = ("%05d"):format(i),
        textEdit = { range = range, newText = text },
        data = { vergil = true },
      }
      if native_011() then
        -- 0.11's native menu shows `detail` and ignores `labelDetails`.
        -- Engines like blink show both, so only set it here.
        item.detail = detail
      end
      if snippet_fix and text:find("%s") then
        item.insertTextFormat = SNIPPET
        item.textEdit.newText = escape_snippet(text)
      end
      items[#items + 1] = item
    end
  end
  return items
end

-- Keyword, not Function: engines add "()" to Function items (blink's
-- auto_brackets, nvim-cmp autopairs integrations).
local KIND_KEYWORD = 14

local function skill_items(token, ctx)
  local skills = require("vergil.skills")
  local trigger = config.options.triggers.skills
  local all = skills.items(ctx.root)
  local by_name = {}
  local names = {}
  for _, it in ipairs(all) do
    by_name[it.name] = it
    names[#names + 1] = it.name
  end
  if token.query == "" then
    table.sort(names)
  end
  local ranked = rank(names, token.query)
  local range = {
    start = { line = ctx.row, character = token.start_col },
    ["end"] = { line = ctx.row, character = token.end_col },
  }
  local items = {}
  for i, name in ipairs(ranked) do
    local it = by_name[name]
    local where = it.origin .. " " .. it.kind
    local item = {
      label = trigger .. name,
      kind = KIND_KEYWORD,
      labelDetails = { detail = it.argument_hint and (" " .. it.argument_hint) or nil, description = where },
      documentation = { kind = "markdown", value = table.concat(skills.contents(it, ctx.root), "\n") },
      filterText = ctx.typed,
      sortText = ("%05d"):format(i),
      -- Inserts the command only; whether it runs is Claude Code's concern.
      textEdit = { range = range, newText = trigger .. name .. " " },
    }
    if native_011() then
      item.detail = where
    end
    items[#items + 1] = item
  end
  return items
end

local EMPTY = { isIncomplete = false, items = {} }

--- Handles a completion request. Calls `respond(result)` once, possibly
--- after file discovery finishes.
---@param params table LSP CompletionParams
---@param session vergil.Session
---@param respond fun(result: table)
function M.handle(params, session, respond)
  local bufnr = session.bufnr
  local row, col = params.position.line, params.position.character
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[row + 1] or ""
  if parser.fenced_lines(lines)[row + 1] then
    return respond(EMPTY)
  end
  if config.options.picker.on_trigger and not (params.context and params.context.triggerKind == INVOKED) then
    return respond(EMPTY) -- the picker opens instead
  end
  local token = M.typing_token(line, col)
  if params.context and params.context.triggerKind == INVOKED then
    token = M.existing_token(bufnr, row, col, session.root) or token
  end
  if not token then
    local skill_token = require("vergil.skills").typing_token(line, col)
    if not skill_token then
      return respond(EMPTY)
    end
    local ctx = { root = session.root, row = row, typed = line:sub(skill_token.start_col + 1, col) }
    return respond({ isIncomplete = true, items = skill_items(skill_token, ctx) })
  end
  local ctx = { bufnr = bufnr, root = session.root, row = row, typed = line:sub(token.start_col + 1, col) }
  local dir, name = files.outside_query(token.query)
  if dir then
    local paths = files.list_dir(dir, name)
    return respond({ isIncomplete = true, items = build(vim.list_slice(paths, 1, M.max_items), token, ctx) })
  end
  files.list(session.root, function(file_list)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return respond(EMPTY)
    end
    respond({ isIncomplete = true, items = build(rank(file_list, token.query), token, ctx) })
  end)
end

return M
