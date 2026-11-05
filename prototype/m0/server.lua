-- M0 prototype: in-process LSP server offering `@`, `@@` and `/` completion.
--
-- Throwaway code for the prototype gate (plan §7.1). It deliberately takes
-- shortcuts the real implementation must not: it reads the buffer directly
-- instead of tracking didChange, discovers files synchronously-on-first-use,
-- and parses frontmatter naively. Do not build on this file; port the lessons.

local M = {}

M.opts = {
  -- "client": return every file and let the completion engine filter.
  -- "server": fuzzy-filter here, return isIncomplete = true.
  filter = "server",
  max_items = 5000,
  -- Reopen the completion menu when Backspace inside a reference closed it.
  reopen_on_backspace = true,
}

local uv = vim.uv or vim.loop

-- File discovery ------------------------------------------------------------

local file_cache = {} ---@type table<string, string[]>
local stat_cache = {} ---@type table<string, table|false>

local function run(cmd, cwd)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil
  end
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait(2000)
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  local lines = vim.split(res.stdout, "\n", { trimempty = true })
  -- Empty output is not success: a root inside a repo that ignores it
  -- (e.g. Homebrew's Cellar) makes `git ls-files` exit 0 with nothing.
  return #lines > 0 and lines or nil
end

local function discover(root)
  if file_cache[root] then
    return file_cache[root]
  end
  local files = run({ "rg", "--files", "--hidden", "--glob", "!.git" }, root)
    or run({ "fd", "--type", "f", "--hidden", "--exclude", ".git" }, root)
    or run({ "git", "ls-files", "--cached", "--others", "--exclude-standard" }, root)
  if not files then
    files = {}
    for name, type in vim.fs.dir(root, { depth = 8 }) do
      if type == "file" and not name:match("^%.git/") then
        files[#files + 1] = name
      end
    end
  end
  table.sort(files)
  file_cache[root] = files
  return files
end

-- Skill discovery (Claude adapter territory in the real plugin) -------------

local function read_frontmatter(path)
  local fd = io.open(path, "r")
  if not fd then
    return {}
  end
  local meta, first = {}, true
  for line in fd:lines() do
    if first then
      first = false
      if line ~= "---" then
        break
      end
    elseif line == "---" then
      break
    else
      local k, v = line:match("^([%w_-]+):%s*(.-)%s*$")
      if k then
        v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        meta[k] = v
      end
    end
  end
  fd:close()
  return meta
end

local function discover_skills(root)
  local items, seen = {}, {}
  local function add(name, path, kind, origin)
    if seen[name] then
      return
    end
    local meta = read_frontmatter(path)
    if meta["user-invocable"] == "false" then
      return
    end
    seen[name] = true
    items[#items + 1] = {
      name = meta.name ~= nil and meta.name ~= "" and meta.name or name,
      description = meta.description,
      hint = meta["argument-hint"],
      path = path,
      kind = kind,
      origin = origin,
    }
  end
  -- Personal before project: plan §4.2 says personal overrides project.
  local bases = { { vim.fn.expand("~/.claude"), "personal" }, { root .. "/.claude", "project" } }
  for _, b in ipairs(bases) do
    for _, p in ipairs(vim.fn.glob(b[1] .. "/skills/*/SKILL.md", false, true)) do
      add(vim.fn.fnamemodify(p, ":h:t"), p, "skill", b[2])
    end
  end
  for _, b in ipairs(bases) do
    for _, p in ipairs(vim.fn.glob(b[1] .. "/commands/*.md", false, true)) do
      add(vim.fn.fnamemodify(p, ":t:r"), p, "command", b[2])
    end
  end
  return items
end

-- Token detection -----------------------------------------------------------

local function in_fence(lines, row)
  local fence
  for i = 1, row do
    local f = lines[i]:match("^%s*(```+)") or lines[i]:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f
      elseif f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then
        fence = nil
      end
    end
  end
  return fence ~= nil
end

local function boundary_ok(before, idx)
  if idx == 1 then
    return true
  end
  return before:sub(idx - 1, idx - 1):match("[%s%(%[{\"'`]") ~= nil
end

--- Returns { kind = "attach"|"mention"|"skill", start = byte col (0-based), query }
function M.token_at(line, col)
  local before = line:sub(1, col)
  local at = before:match(".*()@")
  if at then
    local start, kind = at, "attach"
    if at > 1 and before:sub(at - 1, at - 1) == "@" then
      start, kind = at - 1, "mention"
    end
    local query = before:sub(at + 1)
    local ok = query:sub(1, 1) == '"' and not query:sub(2):find('"') or not query:find("%s")
    if ok and boundary_ok(before, start) then
      return { kind = kind, start = start - 1, query = query:gsub('^"', "") }
    end
  end
  local slash = before:match("^()/[^%s/]*$") or before:match("%s()/[^%s/]*$")
  if slash then
    return { kind = "skill", start = slash - 1, query = before:sub(slash + 1) }
  end
end

--- For manual invocation (<C-Space>): the existing reference under the cursor,
--- so a wrong pick can be re-searched in place. Returns the token with
--- `finish` (0-based, exclusive) so the whole reference gets replaced; the
--- query is the path text up to the cursor.
function M.reference_at(line, col)
  local patterns = {
    { '()@"([^"]*)"?()', "attach" },
    { "()@([^%s\"@`]+)()", "attach" },
    { "()`([^`]+)`()", "mention" },
  }
  for _, p in ipairs(patterns) do
    local init = 1
    while true do
      local s, path, e = line:match(p[1], init)
      if not s then
        break
      end
      local start, finish = s - 1, e - 1
      local path_start = finish - #path - ((p[2] == "mention" or line:sub(finish, finish) == '"') and 1 or 0)
      if col >= start and col <= finish and boundary_ok(line, s) then
        local q = line:sub(path_start + 1, math.max(path_start, math.min(col, path_start + #path)))
        return { kind = p[2], start = start, finish = finish, query = q }
      end
      init = e
    end
  end
end

-- Fuzzy scoring (server filter mode only) -----------------------------------

local function score(str, query)
  if query == "" then
    return 0
  end
  local s, q = str:lower(), query:lower()
  local pos, total, last = 1, 0, 0
  for i = 1, #q do
    local found = s:find(q:sub(i, i), pos, true)
    if not found then
      return nil
    end
    total = total + (found == last + 1 and 5 or 1)
    if found == 1 or s:sub(found - 1, found - 1):match("[/%._-]") then
      total = total + 3
    end
    last, pos = found, found + 1
  end
  return total - #str * 0.01
end

-- Completion ----------------------------------------------------------------

local function human_size(n)
  if n < 1024 then
    return n .. " B"
  elseif n < 1024 * 1024 then
    return ("%.1f KB"):format(n / 1024)
  end
  return ("%.1f MB"):format(n / 1024 / 1024)
end

local function attach_text(path)
  return path:find("%s") and ('@"' .. path .. '"') or ("@" .. path)
end

local function complete(params, root)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row, col = params.position.line, params.position.character
  local line = lines[row + 1] or ""
  if in_fence(lines, row + 1) then
    return { isIncomplete = false, items = {} }
  end
  local tok = M.token_at(line, col)
  local invoked = params.context and params.context.triggerKind == 1
  if invoked then
    -- Manual trigger on an existing reference: re-search it in place.
    tok = M.reference_at(line, col) or tok
  end
  if not tok then
    return { isIncomplete = false, items = {} }
  end
  local typed = line:sub(tok.start + 1, col)
  local range = {
    start = { line = row, character = tok.start },
    ["end"] = { line = row, character = tok.finish or col },
  }
  local items = {}

  if tok.kind == "skill" then
    for _, s in ipairs(discover_skills(root)) do
      local doc = { ("**/%s**%s"):format(s.name, s.hint and (" `" .. s.hint .. "`") or "") }
      if s.description then
        doc[#doc + 1] = "\n" .. s.description
      end
      doc[#doc + 1] = ("\n_%s %s_ · `%s`"):format(s.origin, s.kind, vim.fn.fnamemodify(s.path, ":~"))
      items[#items + 1] = {
        label = "/" .. s.name,
        kind = 3, -- Function
        labelDetails = { detail = s.hint and (" " .. s.hint) or nil, description = s.origin .. " " .. s.kind },
        documentation = { kind = "markdown", value = table.concat(doc, "\n") },
        filterText = "/" .. s.name,
        textEdit = { range = range, newText = "/" .. s.name .. " " },
      }
    end
    return { isIncomplete = false, items = items }
  end

  local attached = {}
  for i, l in ipairs(lines) do
    for _, pat in ipairs({ '()@"([^"]+)"', "()@([^%s\"@`]+)" }) do
      for s, p in l:gmatch(pat) do
        -- Don't count the reference being completed or re-searched.
        local own = i == row + 1 and (s - 1 == tok.start or s - 2 == tok.start)
        if not own then
          attached[p] = true
        end
      end
    end
  end

  local files = discover(root)
  local prefix = tok.kind == "mention" and "@@" or "@"
  local candidates = {}
  for _, f in ipairs(files) do
    if M.opts.filter == "client" then
      candidates[#candidates + 1] = { f, 0 }
    else
      local sc = score(f, tok.query)
      if sc then
        candidates[#candidates + 1] = { f, sc }
      end
    end
    if M.opts.filter == "client" and #candidates >= M.opts.max_items then
      break
    end
  end
  if M.opts.filter == "server" then
    table.sort(candidates, function(a, b)
      return a[2] > b[2]
    end)
  end

  local limit = M.opts.filter == "server" and 100 or M.opts.max_items
  for i = 1, math.min(#candidates, limit) do
    local f = candidates[i][1]
    local st = stat_cache[f]
    if st == nil then
      st = uv.fs_stat(root .. "/" .. f) or false
      stat_cache[f] = st
    end
    local detail = st and human_size(st.size) or ""
    if attached[f] then
      detail = detail .. " · attached"
    end
    items[#items + 1] = {
      label = f,
      kind = 17, -- File
      labelDetails = { description = detail }, -- not also `detail`: blink shows both
      -- Server mode: echo what was typed so engines that prefix-filter keep the item.
      filterText = M.opts.filter == "server" and typed or (prefix .. f),
      sortText = ("%05d"):format(i),
      textEdit = {
        range = range,
        newText = tok.kind == "mention" and ("`" .. f .. "`") or attach_text(f),
      },
    }
  end
  -- A bare `@` result must be incomplete: native completion ignores the second
  -- `@` trigger while the menu is open unless the previous result was
  -- incomplete (runtime/lua/vim/lsp/completion.lua, `trigger()`), so `@@`
  -- would otherwise filter mention-less attach items down to nothing.
  --
  -- Mention results must be incomplete too: once a result is complete, Vim
  -- refilters the open menu itself against each item's inserted *word*
  -- (ignoring filterText). A mention inserts "`path`", which never matches the
  -- typed "@@que", so the menu would close on the first keystroke. The same
  -- applies to quoted attachments. Simplest correct rule: file results are
  -- always incomplete, so every keystroke re-queries and filterText is used.
  return { isIncomplete = true, items = items }
end

-- Server ----------------------------------------------------------------------

function M.cmd(root)
  return function(dispatchers)
    local closing, id = false, 0
    local srv = {}
    function srv.request(method, params, callback)
      id = id + 1
      if method == "initialize" then
        callback(nil, {
          capabilities = {
            positionEncoding = "utf-8",
            textDocumentSync = 0,
            completionProvider = { triggerCharacters = { "@", "/", '"', "." } }, -- ".": blink closes the menu on non-keyword chars
          },
          serverInfo = { name = "vergil-m0" },
        })
      elseif method == "textDocument/completion" then
        local ok, res = pcall(complete, params, root)
        if ok then
          callback(nil, res)
        else
          callback({ code = -32603, message = tostring(res) }, nil)
        end
      elseif method == "shutdown" then
        callback(nil, nil)
      else
        callback({ code = -32601, message = "unsupported: " .. method }, nil)
      end
      return true, id
    end
    function srv.notify(method)
      if method == "exit" then
        dispatchers.on_exit(0, 15)
      end
      return true
    end
    function srv.is_closing()
      return closing
    end
    function srv.terminate()
      closing = true
    end
    return srv
  end
end

M.root = nil

-- Reopen completion after Backspace inside a reference. Engines close the menu
-- when Backspace deletes a non-keyword character such as `.` or `/` (blink:
-- completion/trigger/init.lua; native: Backspace never re-queries), and blink's
-- trigger options are global booleans, so this can't be fixed in engine config
-- for prompt buffers only.
local function reopen_completion()
  local blink = package.loaded["blink.cmp"]
  if blink then
    if not blink.is_menu_visible() then
      blink.show()
    end
    return
  end
  local cmp = package.loaded["cmp"]
  if cmp then
    if not cmp.visible() then
      cmp.complete()
    end
    return
  end
  if vim.fn.pumvisible() == 0 then
    vim.lsp.completion.get()
  end
end

local function watch_backspace(bufnr)
  local last ---@type { row: integer, col: integer, len: integer }?
  local function snapshot()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    last = { row = row, col = col, len = #vim.api.nvim_get_current_line() }
  end
  vim.api.nvim_create_autocmd("InsertEnter", { buffer = bufnr, callback = snapshot })
  -- CursorMovedI fires before TextChangedI, so only record pure cursor moves.
  vim.api.nvim_create_autocmd("CursorMovedI", {
    buffer = bufnr,
    callback = function()
      if not last or #vim.api.nvim_get_current_line() == last.len then
        snapshot()
      end
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = bufnr,
    callback = function()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local was = last
      snapshot()
      -- Backspace: same row, cursor moved left, line got shorter by as much.
      if not (was and was.row == row and col < was.col and was.len - #line == was.col - col) then
        return
      end
      if not (M.token_at(line, col) or M.reference_at(line, col)) then
        return
      end
      vim.schedule(reopen_completion) -- after the engine has hidden its menu
    end,
  })
end

function M.attach(bufnr)
  M.root = M.root or vim.fn.getcwd()
  local id = vim.lsp.start({ name = "vergil-m0", cmd = M.cmd(M.root), root_dir = M.root }, { bufnr = bufnr })
  if M.opts.reopen_on_backspace and not vim.b[bufnr].vergil_m0_watch then
    vim.b[bufnr].vergil_m0_watch = true
    watch_backspace(bufnr)
  end
  return id
end

function M.setup(opts)
  M.opts = vim.tbl_extend("force", M.opts, opts or {})
  M.root = vim.fn.getcwd() -- captured once, at startup (plan §6.9)
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    pattern = "claude-prompt-*.md",
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
end

return M
