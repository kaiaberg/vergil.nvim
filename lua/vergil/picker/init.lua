--- The picker: one window with tabs for everything that can go into a
--- prompt. `:Vergil pick [tab]` opens it on a tab; `<C-g>` (preset) expands
--- the inline `@`/`@@`/`/` completion into it, keeping what you typed.
---
--- Tabs: All, Files, Changed (git), Commits (git), Skills. The git tabs are
--- left out outside a repository. Files are inserted as attachments or
--- mentions (`<C-t>` switches; a marked file keeps the mode it was marked
--- with), skills as `/name`, commits as `` `abc1234` (subject) ``. `<Tab>`
--- marks several items, from any tab; `<C-o>` switches how they're joined:
--- spaces, commas, or one per line.
local config = require("vergil.config")
local formatter = require("vergil.reference.formatter")

local M = {}

--- `:Vergil pick` arguments: a tab, or `attach`/`mention` for Files in that
--- mode.
M.kinds = { "all", "attach", "mention", "skills", "changed", "branches", "commits" }

--- Keys for vergil's own picker actions; `picker.keys` overrides them, like
--- the generic ones in `vergil.ui.picker`.
M.default_keys = {
  toggle_mode = { "<C-t>" },
  select_lines = { "<C-r>" },
  diff = { "<C-d>" },
  separator = { "<C-o>" },
}

--- How several items are joined, in the order `<C-o>` cycles through them.
M.separators = {
  { key = "space", sep = " ", label = "spaces" },
  { key = "comma", sep = ", ", label = "commas" },
  { key = "lines", sep = "\n", label = "one per line" },
}

local TAB_FOR = {
  all = "all", attach = "files", mention = "files", files = "files", skills = "skills",
  changed = "changed", branches = "branches", commits = "commits",
}

---@class vergil.PickContext
---@field bufnr integer
---@field win integer
---@field row integer 0-based
---@field col integer 0-based insertion column
---@field end_col integer? replace up to here (an expanded `@query`)
---@field root string
---@field from_insert boolean

--- Inserts text at the context's position (replacing `col..end_col` when
--- set), with a space before it when needed, because agents only treat `@`
--- and `/` after whitespace as references, and after it, so it doesn't run
--- into the following text.
---@param ctx vergil.PickContext
---@param text string
function M.insert(ctx, text)
  if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.row, ctx.row + 1, false)[1] or ""
  local col = math.min(ctx.col, #line)
  local stop = math.min(ctx.end_col or col, #line)
  local before, after = line:sub(col, col), line:sub(stop + 1, stop + 1)
  if col > 0 and not before:match("%s") then
    text = " " .. text
  end
  local pad = (after ~= "" and not after:match("%s") and not text:match("%s$")) and " " or ""
  local parts = vim.split(text .. pad, "\n", { plain = true })
  vim.api.nvim_buf_set_text(ctx.bufnr, ctx.row, col, ctx.row, stop, parts)
  if vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_set_current_win(ctx.win)
    -- The cursor goes to the end of the inserted text (before the padding).
    local last_row = ctx.row + #parts
    local last = vim.split(text, "\n", { plain = true })
    local end_col = (#parts == 1 and col or 0) + #last[#last]
    local new_len = #(vim.api.nvim_buf_get_lines(ctx.bufnr, last_row - 1, last_row, false)[1] or "")
    vim.api.nvim_win_set_cursor(ctx.win, { last_row, ctx.from_insert and end_col or math.max(0, end_col - 1) })
    if ctx.from_insert then
      vim.cmd(end_col >= new_len and "startinsert!" or "startinsert")
    end
  end
end

--- Text to insert for a chosen item.
---@param kind "attach"|"mention"|"skills"|"commits"
---@param value any
---@return string?
function M.text_for(kind, value)
  if kind == "skills" then
    return config.options.triggers.skills .. value.name .. " "
  elseif kind == "commits" then
    return require("vergil.git").reference(value)
  elseif kind == "branches" then
    return require("vergil.git").branch_reference(value)
  elseif kind == "mention" then
    return formatter.mention(value, nil, nil, config.options.mention.format)
  end
  return formatter.attachment(value, config.adapter())
end

local function read_head(abs, max)
  local fd = io.open(abs, "rb")
  if not fd then
    return { "(can't read " .. abs .. ")" }
  end
  local data = fd:read(64 * 1024) or ""
  fd:close()
  if data:find("\0", 1, true) then
    return { "(binary file)" }
  end
  local lines = vim.split(data, "\n", { plain = true })
  return vim.list_slice(lines, 1, max)
end

--- The prompt file itself, so it's never offered.
local function self_filter(bufnr, root)
  local self = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(bufnr))
  return function(path)
    local abs = path:sub(1, 1) == "/" and path or (root .. "/" .. path)
    return not self or vim.uv.fs_realpath(abs) ~= self
  end
end

--- Builds the tabs for a session, in `picker.tabs` order.
---@return vergil.PickerTab[] tabs
---@return string? git_err why the git tabs are missing
local function build_tabs(session)
  local root = session.root
  local keep = self_filter(session.bufnr, root)
  local git = require("vergil.git")
  local enabled = {}
  for _, name in ipairs(config.options.picker.tabs) do
    enabled[name] = true
  end
  local changed, git_err = git.changed(root)
  local status = {}
  if changed then
    changed = vim.tbl_filter(function(f) return keep(f.path) end, changed)
    for _, f in ipairs(changed) do
      status[f.path] = f.status
    end
  end

  local function file_items(cb)
    require("vergil.files").list(root, function(list)
      local items = {}
      for _, path in ipairs(list or {}) do
        if keep(path) then
          items[#items + 1] = { id = "file:" .. path, text = path, label = status[path], kind = "file", value = path }
        end
      end
      cb(items)
    end)
  end
  local function changed_items()
    return vim.tbl_map(function(f)
      return { id = "file:" .. f.path, text = f.path, label = f.status, kind = "file", value = f.path }
    end, changed or {})
  end
  local function skill_items()
    local trigger = config.options.triggers.skills
    return vim.tbl_map(function(s)
      local text = trigger .. s.name .. (s.description and ("  " .. s.description) or "")
      return { id = "skill:" .. s.name, text = text, label = s.kind, kind = "skills", value = s }
    end, require("vergil.skills").items(root))
  end
  local commits_cache, branches_cache
  local function commit_items()
    if not commits_cache then
      commits_cache = vim.tbl_map(function(c)
        return { id = "commit:" .. c.hash, text = c.hash .. "  " .. c.subject, label = ("%s, %s"):format(c.author, c.date), kind = "commits", value = c }
      end, git.commits(root) or {})
    end
    return commits_cache
  end
  local function branch_items()
    if not branches_cache then
      branches_cache = vim.tbl_map(function(b)
        local label = table.concat(vim.tbl_filter(function(x) return x ~= "" end, {
          b.current and "checked out" or "", b.track, b.date,
        }), " · ")
        return { id = "branch:" .. b.name, text = b.name .. "  " .. b.subject, label = label, kind = "branches", value = b }
      end, git.branches(root) or {})
    end
    return branches_cache
  end

  local in_repo = changed ~= nil
  local specs = {
    files = { key = "files", name = "Files", load = file_items },
    skills = { key = "skills", name = "Skills", load = function(cb) cb(skill_items()) end },
  }
  if in_repo then
    specs.changed = { key = "changed", name = "Changed", load = function(cb) cb(changed_items()) end }
    specs.branches = { key = "branches", name = "Branches", load = function(cb) cb(branch_items()) end }
    specs.commits = { key = "commits", name = "Commits", load = function(cb) cb(commit_items()) end }
  end
  specs.all = {
    key = "all",
    name = "All",
    load = function(cb)
      -- Changed files first, then skills, branches, the other files and
      -- commits; only from tabs that are turned on.
      local function finish(files)
        local items, seen = {}, {}
        local function add(list, label)
          for _, item in ipairs(list) do
            if not seen[item.id] then
              seen[item.id] = true
              items[#items + 1] = (label and not item.label) and vim.tbl_extend("force", item, { label = label }) or item
            end
          end
        end
        local function relabel(list, label)
          return vim.tbl_map(function(i) return vim.tbl_extend("force", i, { label = label }) end, list)
        end
        if enabled.changed and in_repo then add(changed_items()) end
        if enabled.skills then add(skill_items()) end
        if enabled.branches and in_repo then add(relabel(branch_items(), "branch")) end
        add(files, "file")
        if enabled.commits and in_repo then add(relabel(commit_items(), "commit")) end
        cb(items)
      end
      if enabled.files then
        file_items(finish)
      else
        finish({})
      end
    end,
  }

  local tabs = {}
  for _, name in ipairs(config.options.picker.tabs) do
    if specs[name] then
      tabs[#tabs + 1] = specs[name]
    end
  end
  return tabs, (not in_repo) and git_err or nil
end

---@class vergil.PickOpts
---@field query string? initial search
---@field replace { row: integer, start_col: integer, end_col: integer }? text to replace (an expanded `@query`)

--- Opens the picker on a tab.
---@param kind? string one of `M.kinds` (default "all")
---@param opts vergil.PickOpts?
---@return boolean ok
---@return string? err
function M.pick(kind, opts)
  opts = opts or {}
  kind = kind or "all"
  local tab_key = TAB_FOR[kind]
  if not tab_key then
    return false, ("unknown picker %q; expected %s"):format(kind, table.concat(M.kinds, ", "))
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local session = require("vergil.session").get(bufnr)
  if not session then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local tabs, git_err = build_tabs(session)
  local start
  for i, t in ipairs(tabs) do
    if t.key == tab_key then
      start = i
    end
  end
  if not start and kind == "all" and #tabs > 0 then
    start = 1 -- no All tab: open the first one
  end
  if not start then
    if not vim.tbl_contains(config.options.picker.tabs, tab_key) then
      return false, ("the %s tab is turned off (picker.tabs)"):format(tab_key)
    end
    return false, git_err or ("no %s tab"):format(tab_key)
  end

  local win = vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local from_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  local line = vim.api.nvim_get_current_line()
  -- In Normal mode, insert after the cursor character, like `a`.
  local insert_col = (from_insert or line == "") and col or math.min(col + 1, #line)
  ---@type vergil.PickContext
  local ctx = { bufnr = bufnr, win = win, row = row - 1, col = insert_col, root = session.root, from_insert = from_insert }
  if opts.replace then
    ctx.row, ctx.col, ctx.end_col = opts.replace.row, opts.replace.start_col, opts.replace.end_col
  end

  local state = { mode = kind == "mention" and "mention" or "attach", sep = 1 }
  local keys = vim.tbl_extend("force", M.default_keys, config.options.picker.keys or {})
  local function has_files(t)
    return t.key == "all" or t.key == "files" or t.key == "changed"
  end
  local function resume()
    if vim.api.nvim_win_is_valid(ctx.win) then
      vim.api.nvim_set_current_win(ctx.win)
      if ctx.from_insert then
        vim.cmd("startinsert")
      end
    end
  end

  local function key_hint(name)
    local lhs = keys[name] and keys[name][1]
    return lhs and (lhs:gsub("^<", ""):gsub(">$", "")) or nil
  end

  --- What a chosen item becomes: its sign in the list, the text it
  --- inserts, and its kind. Files take the current attach/mention mode;
  --- skills and commits are the same either way.
  ---@return vergil.PickerMarkInfo
  local function mark_info(item)
    local mode = item.kind == "file" and state.mode or item.kind
    local text = vim.trim(M.text_for(mode, item.value) or "")
    local sign = ({ attach = "@", mention = "`", skills = "/", commits = "◆", branches = "⎇" })[mode] or "•"
    local label = ({ attach = "attach", mention = "mention", skills = "skill", commits = "commit", branches = "branch" })[mode]
    return { sign = sign, text = text, label = label, data = { text = text, kind = item.kind } }
  end

  require("vergil.ui.picker").open({
    tabs = tabs,
    tab = start,
    query = opts.query,
    keys = keys,
    mark_info = mark_info,
    status = function(current)
      local join = M.separators[state.sep].label
      local join_hint = key_hint("separator")
      local parts = {}
      if has_files(current) then
        local switch = key_hint("toggle_mode")
        parts[#parts + 1] = (state.mode == "mention" and "Mention" or "Attach")
          .. (switch and (" (%s: %s)"):format(switch, state.mode == "mention" and "attach" or "mention") or "")
      else
        parts[#parts + 1] = current.name
      end
      parts[#parts + 1] = "joined by " .. join .. (join_hint and (" (%s)"):format(join_hint) or "")
      return table.concat(parts, " · ")
    end,
    preview = function(item)
      if item.kind == "file" then
        local abs = item.value:sub(1, 1) == "/" and item.value or (session.root .. "/" .. item.value)
        return { lines = read_head(abs, 400), ft = vim.filetype.match({ filename = abs }) }
      elseif item.kind == "skills" then
        return { lines = require("vergil.skills").contents(item.value, session.root), ft = "markdown" }
      elseif item.kind == "commits" then
        return { lines = require("vergil.git").show(session.root, item.value.hash), ft = "git" }
      elseif item.kind == "branches" then
        local git = require("vergil.git")
        return { lines = git.object_lines(session.root, { type = "branch", name = item.value.name }), ft = "git" }
      end
    end,
    actions = {
      {
        keys = keys.toggle_mode,
        desc = "attach/mention",
        when = has_files,
        fn = function(p)
          state.mode = state.mode == "attach" and "mention" or "attach"
          p.refresh()
        end,
      },
      {
        keys = keys.separator,
        desc = "join",
        fn = function(p)
          state.sep = state.sep % #M.separators + 1
          p.refresh()
        end,
      },
      {
        keys = keys.select_lines,
        desc = "lines",
        when = has_files,
        fn = function(p)
          local item = p.current()
          if not item or item.kind ~= "file" then
            return
          end
          p.close_windows()
          local ok, err = require("vergil.range").select_for_path({
            bufnr = ctx.bufnr, win = ctx.win, row = ctx.row, col = ctx.col, path = item.value, from_insert = ctx.from_insert,
          })
          if not ok then
            vim.notify("vergil: " .. err, vim.log.levels.WARN)
          end
        end,
      },
      {
        keys = keys.diff,
        desc = "diff",
        when = function(t) return t.key == "commits" or t.key == "branches" or t.key == "all" end,
        fn = function(p)
          local item = p.current()
          if not item or (item.kind ~= "commits" and item.kind ~= "branches") then
            return
          end
          -- A commit's own changes; a branch's changes since it split off.
          local rev = item.kind == "commits" and (item.value.hash .. "^!")
            or ((require("vergil.git").current_branch(session.root) or "HEAD") .. "..." .. item.value.name)
          p.close_windows()
          if vim.api.nvim_win_is_valid(ctx.win) then
            vim.api.nvim_set_current_win(ctx.win)
            vim.api.nvim_win_set_cursor(ctx.win, { ctx.row + 1, 0 })
          end
          local ok, err = require("vergil.diff").insert(rev)
          if not ok then
            vim.notify("vergil: " .. err, vim.log.levels.WARN)
          end
        end,
      },
    },
    on_confirm = function(marks)
      local texts = {}
      for _, m in ipairs(marks) do
        if m.info.data.text ~= "" then
          texts[#texts + 1] = m.info.data.text
        end
      end
      if #texts == 0 then
        return resume()
      end
      local sep = M.separators[state.sep]
      local text = table.concat(texts, sep.sep)
      -- Ready for a skill's arguments, unless each item has its own line.
      if marks[#marks].info.data.kind == "skills" and sep.key ~= "lines" then
        text = text .. " "
      end
      M.insert(ctx, text)
    end,
    on_cancel = resume,
  })
  return true
end

--- Expands the inline completion being typed (`@query`, `@@query` or
--- `/query`) into the picker, on the matching tab, keeping the query. With
--- nothing being typed, opens the All tab.
---@param at { row: integer, col: integer }? 1-based row and the column the
---   typed text ends at; default: the cursor
---@return boolean ok
---@return string? err
function M.expand(at)
  local bufnr = vim.api.nvim_get_current_buf()
  if not require("vergil.session").get(bufnr) then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if at then
    row, col = at.row, at.col
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local blink = package.loaded["blink.cmp"]
  if blink and blink.hide then
    pcall(blink.hide)
  end
  local cmp = package.loaded["cmp"]
  if cmp and cmp.close then
    pcall(cmp.close)
  end
  local token = require("vergil.lsp.completion").typing_token(line, col)
  if token then
    return M.pick(token.mode, {
      query = token.query,
      replace = { row = row - 1, start_col = token.start_col, end_col = token.end_col },
    })
  end
  local skill = require("vergil.skills").typing_token(line, col)
  if skill then
    return M.pick("skills", {
      query = skill.query,
      replace = { row = row - 1, start_col = skill.start_col, end_col = skill.end_col },
    })
  end
  return M.pick("all")
end

--- With `picker.on_trigger`, typing `@` or `/` where a reference may start
--- opens the picker instead of inline completion.
---@param bufnr integer
function M.attach_trigger(bufnr)
  if vim.b[bufnr].vergil_picker_trigger then
    return
  end
  vim.b[bufnr].vergil_picker_trigger = true
  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("vergil.picker.trigger." .. bufnr, { clear = true }),
    callback = function()
      if not config.options.picker.on_trigger then
        return
      end
      local triggers = config.options.triggers
      local char = vim.v.char
      if char ~= triggers.attach:sub(1, 1) and char ~= triggers.skills then
        return
      end
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local before = vim.api.nvim_get_current_line():sub(col, col)
      if col > 0 and not before:match("%s") then
        return
      end
      -- After the character is in: open if it's still there, as typed.
      vim.schedule(function()
        local line = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
        if vim.api.nvim_get_current_buf() == bufnr and line and line:sub(col + 1, col + 1) == char then
          M.expand({ row = row, col = col + 1 })
        end
      end)
    end,
  })
end

return M
