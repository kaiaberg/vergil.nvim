--- The picker: one window with tabs for everything that can go into a
--- prompt. `:Vergil pick [tab]` opens it on a tab; `<C-g>` (preset) expands
--- the inline `@`/`@@`/`/` completion into it, keeping what you typed.
---
--- Outside the project, Files browses a directory at a time when the query
--- starts with `~` or `/` (All: `~` only, as `/` searches skills there).
--- Enter on a directory opens it.
---
--- Tabs: All, Files, Changed (git), Commits (git), Skills. The git tabs are
--- left out outside a repository. Files are inserted as attachments or
--- mentions (`<C-t>` switches; a marked file keeps the mode it was marked
--- with), skills as `/name`, commits as `` `abc1234` (subject) ``. `<Tab>`
--- marks several items, from any tab; `<C-o>` switches how they're joined:
--- spaces, commas, or one per line.
local config = require("vergil.config")
local files = require("vergil.files")
local formatter = require("vergil.reference.formatter")

local M = {}

--- `:Vergil pick` arguments: a tab, or `attach`/`mention` for Files in that
--- mode.
M.kinds = require("vergil.picker.kinds")

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
  all = "all",
  attach = "files",
  mention = "files",
  files = "files",
  skills = "skills",
  changed = "changed",
  branches = "branches",
  commits = "commits",
}

---@class vergil.PickContext
---@field bufnr integer
---@field win integer
---@field row integer 0-based
---@field col integer 0-based insertion column
---@field end_col integer? replace up to here (an expanded `@query`)
---@field root string
---@field from_insert boolean
---@field cursor integer[] where the picker was opened: 1-based row, 0-based col

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
  -- The cursor goes to the end of the inserted text (before the padding).
  local last = vim.split(text, "\n", { plain = true })
  M.restore(ctx, ctx.row + #parts, (#parts == 1 and col or 0) + #last[#last])
end

--- Returns to the window and mode the picker was opened from: the cursor
--- after column `end_col` (0-based, exclusive) of 1-based `row`, in Insert
--- mode if that's where the picker came from. Deferred: closing the picker
--- leaves its Insert mode only once the current key is handled, which would
--- cancel a `startinsert` issued now.
---@param ctx vergil.PickContext
---@param row integer?
---@param end_col integer?
function M.restore(ctx, row, end_col)
  local function go()
    if not vim.api.nvim_win_is_valid(ctx.win) then
      return
    end
    vim.api.nvim_set_current_win(ctx.win)
    if row and vim.api.nvim_buf_is_valid(ctx.bufnr) then
      local len = #(vim.api.nvim_buf_get_lines(ctx.bufnr, row - 1, row, false)[1] or "")
      vim.api.nvim_win_set_cursor(ctx.win, { row, ctx.from_insert and end_col or math.max(0, end_col - 1) })
      if ctx.from_insert then
        vim.cmd(end_col >= len and "startinsert!" or "startinsert")
      end
    elseif ctx.cursor and vim.api.nvim_buf_is_valid(ctx.bufnr) then
      -- Back where the picker was opened.
      pcall(vim.api.nvim_win_set_cursor, ctx.win, ctx.cursor)
      if ctx.from_insert then
        local len = #(vim.api.nvim_get_current_line())
        vim.cmd(ctx.cursor[2] >= len and "startinsert!" or "startinsert")
      end
    end
  end
  go()
  vim.schedule(function()
    -- Unless a new picker opened, or you moved on, in the meantime.
    if not require("vergil.ui.picker").current() and vim.api.nvim_get_current_win() == ctx.win then
      go()
    end
  end)
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
  -- Git data loads in the background, once per picker and only when a tab
  -- needs it, so opening the picker never waits on git. Whether the root is
  -- in a repository is known without running git.
  local in_repo, git_err = git.in_repo(root)
  local sources = {} ---@type table<string, { value: any, err: string?, done: boolean, waiters: function[] }>
  local fetchers = {
    changed = function(cb)
      git.changed(root, function(list, err)
        cb(list and vim.tbl_filter(function(f)
          return keep(f.path)
        end, list), err)
      end)
    end,
    commits = function(cb)
      git.commits(root, nil, cb)
    end,
    branches = function(cb)
      git.branches(root, cb)
    end,
  }
  --- Calls `cb(value, err)` once the source is in (right away if it is).
  local function source(name, cb)
    local src = sources[name]
    if not src then
      src = { done = false, waiters = {} }
      sources[name] = src
      fetchers[name](function(value, err)
        src.value, src.err, src.done = value, err, true
        for _, w in ipairs(src.waiters) do
          w(value, err)
        end
        src.waiters = {}
      end)
    end
    if src.done then
      cb(src.value, src.err)
    else
      table.insert(src.waiters, cb)
    end
  end
  local function status_of()
    local status = {}
    local src = sources.changed
    for _, f in ipairs((src and src.value) or {}) do
      status[f.path] = f.status
    end
    return status
  end

  local function to_file_items(list)
    local status, items = status_of(), {}
    for _, path in ipairs(list or {}) do
      if keep(path) then
        items[#items + 1] = { id = "file:" .. path, text = path, label = status[path], kind = "file", value = path }
      end
    end
    return items
  end
  --- Files as soon as they're listed; again with git's status labels once
  --- those are in (the picker keeps the selection).
  local function file_items(cb)
    require("vergil.files").list(root, function(list)
      cb(to_file_items(list))
      if in_repo then
        source("changed", function(changed)
          if changed and #changed > 0 then
            cb(to_file_items(list))
          end
        end)
      end
    end)
  end
  local function changed_items(changed)
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
  local function commit_items(commits)
    return vim.tbl_map(function(c)
      return {
        id = "commit:" .. c.hash,
        text = c.hash .. "  " .. c.subject,
        label = ("%s, %s"):format(c.author, c.date),
        kind = "commits",
        value = c,
      }
    end, commits or {})
  end
  local function branch_items(branches)
    return vim.tbl_map(function(b)
      local label = table.concat(
        vim.tbl_filter(function(x)
          return x ~= ""
        end, {
          b.current and "checked out" or "",
          b.track,
          b.date,
        }),
        " · "
      )
      return {
        id = "branch:" .. b.name,
        text = b.name .. "  " .. b.subject,
        label = label,
        kind = "branches",
        value = b,
      }
    end, branches or {})
  end
  local function git_tab(name, to_items)
    return function(cb)
      source(name, function(value, err)
        if value then
          cb(to_items(value))
        else
          cb(nil, err)
        end
      end)
    end
  end

  local specs = {
    files = { key = "files", name = "Files", load = file_items },
    skills = {
      key = "skills",
      name = "Skills",
      load = function(cb)
        cb(skill_items())
      end,
    },
  }
  if in_repo then
    specs.changed = { key = "changed", name = "Changed", load = git_tab("changed", changed_items) }
    specs.branches = { key = "branches", name = "Branches", load = git_tab("branches", branch_items) }
    specs.commits = { key = "commits", name = "Commits", load = git_tab("commits", commit_items) }
  end
  specs.all = {
    key = "all",
    name = "All",
    load = function(cb)
      -- Changed files first, then skills, branches, the other files and
      -- commits; only from tabs that are turned on. Shown as soon as the
      -- files are listed, and again as each git source comes in.
      local files
      local function build()
        local items, seen = {}, {}
        local function add(list, label)
          for _, item in ipairs(list) do
            if not seen[item.id] then
              seen[item.id] = true
              items[#items + 1] = (label and not item.label) and vim.tbl_extend("force", item, { label = label })
                or item
            end
          end
        end
        local function relabel(list, label)
          return vim.tbl_map(function(i)
            return vim.tbl_extend("force", i, { label = label })
          end, list)
        end
        local function got(name)
          return sources[name] and sources[name].value
        end
        if enabled.changed and in_repo then
          add(changed_items(got("changed")))
        end
        if enabled.skills then
          add(skill_items())
        end
        if enabled.branches and in_repo then
          add(relabel(branch_items(got("branches")), "branch"))
        end
        add(to_file_items(files), "file")
        if enabled.commits and in_repo then
          add(relabel(commit_items(got("commits")), "commit"))
        end
        cb(items)
      end
      local function start_git()
        if not in_repo then
          return
        end
        for _, name in ipairs({ "changed", "branches", "commits" }) do
          -- The Files tab's labels need the status even without Changed.
          if enabled[name] or (name == "changed" and enabled.files) then
            source(name, function(value)
              if value and #value > 0 then
                build()
              end
            end)
          end
        end
      end
      if enabled.files then
        require("vergil.files").list(root, function(list)
          files = list
          build()
          start_git()
        end)
      else
        files = {}
        build()
        start_git()
      end
    end,
  }

  local tabs = {}
  for _, name in ipairs(config.options.picker.tabs) do
    if specs[name] then
      tabs[#tabs + 1] = specs[name]
    end
  end
  return tabs, git_err
end

--- Directory items for a query outside the project (`~/co`, `/etc/`), for
--- the Files and All tabs; nil for anything the tab filters itself.
---@param tab vergil.PickerTab
---@param query string
---@return vergil.PickerItem[]?
---@return integer[][]?
function M.search(tab, query)
  if not (tab.key == "files" or (tab.key == "all" and query:sub(1, 1) == "~")) then
    return nil
  end
  local dir, name = files.outside_query(query)
  if not dir then
    return nil
  end
  local paths, positions = files.list_dir(dir, name)
  local items = vim.tbl_map(function(path)
    local is_dir = path:sub(-1) == "/"
    return {
      id = "file:" .. path,
      text = path,
      label = is_dir and "dir" or nil,
      kind = "file",
      value = path,
      query = is_dir and path or nil,
    }
  end, paths)
  return items, positions
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
  -- In Normal mode, insert after the word under the cursor, so it isn't
  -- split; on whitespace, after the cursor character, like `a`.
  local insert_col = col
  if not from_insert and line ~= "" then
    local word_end = line:find("%s", col + 1)
    insert_col = line:sub(col + 1, col + 1):match("%s") and col + 1 or (word_end and word_end - 1 or #line)
  end
  ---@type vergil.PickContext
  local ctx = {
    bufnr = bufnr,
    win = win,
    row = row - 1,
    col = insert_col,
    root = session.root,
    from_insert = from_insert,
    cursor = { row, col },
  }
  if opts.replace then
    ctx.row, ctx.col, ctx.end_col = opts.replace.row, opts.replace.start_col, opts.replace.end_col
  end

  local state = { mode = kind == "mention" and "mention" or "attach", sep = 1 }
  local keys = vim.tbl_extend("force", M.default_keys, config.options.picker.keys or {})
  local function has_files(t)
    return t.key == "all" or t.key == "files" or t.key == "changed"
  end
  local function resume()
    M.restore(ctx)
  end

  -- Commit and branch previews come from git in the background; "Loading"
  -- until then, kept per item for this picker.
  local previews = {}
  local function git_preview(item)
    local cached = previews[item.id]
    if cached then
      return cached ~= true and { lines = cached, ft = "git" } or { lines = { "Loading…" } }
    end
    previews[item.id] = true
    local git = require("vergil.git")
    local function done(lines)
      previews[item.id] = lines
      local p = require("vergil.ui.picker").current()
      local now = p and p.current_item and p.current_item()
      if now and now.id == item.id then
        p.refresh_preview()
      end
    end
    if item.kind == "commits" then
      git.show(session.root, item.value.hash, done)
    else
      git.object_lines(session.root, { type = "branch", name = item.value.name }, done)
    end
    return { lines = { "Loading…" } }
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
    local label = (
      { attach = "attach", mention = "mention", skills = "skill", commits = "commit", branches = "branch" }
    )[mode]
    return { sign = sign, text = text, label = label, data = { text = text, kind = item.kind } }
  end

  require("vergil.ui.picker").open({
    tabs = tabs,
    search = M.search,
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
        local abs = require("vergil.reference.resolver").absolute(item.value, session.root)
        if item.value:sub(-1) == "/" then
          local names = vim.tbl_map(function(p)
            return p:sub(#item.value + 1)
          end, files.list_dir(item.value, ""))
          return { lines = #names > 0 and names or { "(empty)" } }
        end
        return { lines = read_head(abs, 400), ft = vim.filetype.match({ filename = abs }) }
      elseif item.kind == "skills" then
        return { lines = require("vergil.skills").contents(item.value, session.root), ft = "markdown" }
      elseif item.kind == "commits" or item.kind == "branches" then
        return git_preview(item)
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
            bufnr = ctx.bufnr,
            win = ctx.win,
            row = ctx.row,
            col = ctx.col,
            path = item.value,
            from_insert = ctx.from_insert,
          })
          if not ok then
            vim.notify("vergil: " .. err, vim.log.levels.WARN)
          end
        end,
      },
      {
        keys = keys.diff,
        desc = "diff",
        when = function(t)
          return t.key == "commits" or t.key == "branches" or t.key == "all"
        end,
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

--- Opens the picker on what's at the cursor (`<C-g>`).
--- Insert mode: the inline completion being typed (`@query`, `@@query` or
--- `/query`) opens on its tab with that query; any other word before the
--- cursor opens the All tab with the word as query. Either is replaced by
--- what's chosen. Normal mode: a reference under the cursor opens with its
--- path as query and is replaced; otherwise the All tab opens empty and
--- inserts after the cursor.
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
  local completion = require("vergil.lsp.completion")
  local session = require("vergil.session").get(bufnr)
  local function open(kind, query, start_col, end_col)
    return M.pick(kind, { query = query, replace = { row = row - 1, start_col = start_col, end_col = end_col } })
  end
  local insert_mode = at ~= nil or vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  -- Where the word ends that the cursor is in (0-based, exclusive). Not for
  -- `picker.on_trigger` (`at`): an `@` just typed before a word starts a
  -- new reference rather than taking the word over.
  local stop = col
  if not at then
    local space = line:find("%s", col + 1)
    stop = space and space - 1 or #line
  end

  if not insert_mode then
    local ref = completion.existing_token(bufnr, row - 1, col, session.root, true)
    if ref then
      return open(ref.mode, ref.query, ref.start_col, ref.end_col)
    end
    local skill = require("vergil.skills").token_at(line, col)
    if skill then
      -- Up to the name: `token_at` leaves out trailing punctuation.
      return open(
        "skills",
        skill.name,
        skill.start_col,
        skill.start_col + #config.options.triggers.skills + #skill.name
      )
    end
    local s, e = M.word_at(line, col, stop)
    if s then
      return open("all", line:sub(s + 1, e), s, e)
    end
    return M.pick("all")
  end

  -- Insert mode: search for what's before the cursor, replace the whole
  -- word (or reference), so no fragment of it is left behind.
  local ref = not at and completion.existing_token(bufnr, row - 1, col, session.root)
  if ref and ref.start_col < col then
    return open(ref.mode, ref.query, ref.start_col, math.max(ref.end_col, col))
  end
  local token = completion.typing_token(line, col)
  if token then
    return open(token.mode, token.query, token.start_col, stop)
  end
  local skill = require("vergil.skills").typing_token(line, col)
  if skill then
    return open("skills", skill.query, skill.start_col, stop)
  end
  if col > 0 and not line:sub(col, col):match("%s") then
    local s, e = M.word_at(line, col - 1, stop)
    if s and s < col then
      return open("all", line:sub(s + 1, col), s, math.max(e, col))
    end
  end
  return M.pick("all")
end

--- The word around 0-based column `col` (up to `stop`), without the
--- punctuation around it in prose: `(parser),` gives `parser`.
---@param line string
---@param col integer
---@param stop integer 0-based exclusive end of the whitespace-separated word
---@return integer? start 0-based
---@return integer? end_col 0-based, exclusive
function M.word_at(line, col, stop)
  if line:sub(col + 1, col + 1):match("^%s?$") then
    return nil
  end
  local s = line:sub(1, col + 1):match("()%S+$") - 1
  local word = line:sub(s + 1, stop)
  local lead = #word:match("^[%(%[{\"'<]*")
  local trail = #word:match("[%)%]}\"'>%.,;:!?]*$")
  if lead + trail >= #word then
    return nil
  end
  return s + lead, stop - trail
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
