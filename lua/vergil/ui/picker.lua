--- A small tabbed fuzzy picker: a search line, a list, a preview and a list
--- of marked items, in floats. It knows nothing about vergil;
--- `vergil.picker` supplies the tabs and what marks mean.
---
--- Typing filters the current tab with `matchfuzzypos`. Tabs cycle, and the
--- query is kept when switching. Marks belong to what an item is (its `id`),
--- not to a tab, so an item marked in one tab is marked in all of them. Each
--- mark keeps a snapshot (`mark_info`) taken when it was marked.
local M = {}

---@class vergil.PickerItem
---@field id string identity across tabs, e.g. "file:src/a.lua"
---@field text string searched and shown
---@field label string? shown right-aligned, e.g. "modified" or "skill"
---@field kind string? what the item is, for the caller
---@field value any
---@field query string? Enter searches for this instead of choosing the item (e.g. a directory to browse into), unless items are marked

---@class vergil.PickerMarkInfo
---@field sign string one or two characters shown before a marked item
---@field text string shown in the marked list, e.g. what will be inserted
---@field label string? shown right-aligned in the marked list
---@field data any for the caller, e.g. the text to insert

---@class vergil.PickerMark
---@field item vergil.PickerItem
---@field info vergil.PickerMarkInfo

---@class vergil.PickerTab
---@field key string
---@field name string
---@field load fun(cb: fun(items: vergil.PickerItem[]?, err: string?)) may call back later, and again with updated items
---@field items vergil.PickerItem[]? filled once loaded
---@field err string?
---@field loading boolean?

---@class vergil.PickerAction
---@field keys string[]
---@field desc string? shown in the footer when given
---@field when (fun(tab: vergil.PickerTab): boolean)? default: every tab
---@field fn fun(picker: vergil.PickerState)

---@class vergil.PickerOpts
---@field tabs vergil.PickerTab[]
---@field tab integer? 1-based tab to start on
---@field query string?
---@field status (fun(tab: vergil.PickerTab): string)? text in the search line's title
---@field search (fun(tab: vergil.PickerTab, query: string): vergil.PickerItem[]?, integer[][]?)? items for a query the tab doesn't filter itself, already ranked, with match positions; nil to filter the tab's items
---@field preview (fun(item: vergil.PickerItem): { lines: string[], ft: string?, line: integer? }?)?
---@field mark_info fun(item: vergil.PickerItem): vergil.PickerMarkInfo snapshot when marking (and for an unmarked choice)
---@field actions vergil.PickerAction[]?
---@field keys table<string, string[]>?
---@field on_confirm fun(marks: vergil.PickerMark[], tab: vergil.PickerTab)
---@field on_cancel fun()?

---@class vergil.PickerState
---@field opts vergil.PickerOpts
---@field tab integer
---@field query string
---@field matches vergil.PickerItem[]
---@field positions integer[][]
---@field selected integer
---@field marked vergil.PickerMark[] in the order they were marked
---@field closed boolean
---@field searched boolean? the matches came from `opts.search`

M.limit = 500
--- The preview (and marked list) show when the picker is at least this wide.
M.preview_min_width = 80

local ns = vim.api.nvim_create_namespace("vergil.picker")
-- The search line's autocmds are buffer-local and go when it's wiped.
local group = vim.api.nvim_create_augroup("vergil.picker", { clear = true })
local active ---@type vergil.PickerState?

local function set_hl()
  local links = {
    VergilPickerTab = "Comment",
    VergilPickerTabActive = "PmenuSel",
    VergilPickerMatch = "Special",
    VergilPickerLabel = "Comment",
    VergilPickerMark = "Special",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

M.default_keys = {
  confirm = { "<CR>" },
  close = { "<Esc>", "<C-c>" },
  down = { "<Down>", "<C-n>", "<C-j>" },
  up = { "<Up>", "<C-p>", "<C-k>" },
  mark = { "<Tab>" },
  unmark = { "<S-Tab>" },
  next_tab = { "<C-Right>", "<C-l>", "<M-l>" },
  prev_tab = { "<C-Left>", "<C-h>", "<M-h>" },
  scroll_down = { "<C-f>" },
  scroll_up = { "<C-b>" },
}

--- The state of the open picker, for tests and callers.
---@return vergil.PickerState?
function M.current()
  return active
end

--- A scratch buffer with its own filetype, so users can target it with
--- FileType autocommands (e.g. to turn off indent guides).
local function scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].completion = false -- blink.cmp
  vim.bo[buf].filetype = ft
  return buf
end

local function key_label(lhs)
  return (lhs:gsub("^<", ""):gsub(">$", ""):gsub("CR", "Enter"))
end

--- `text` cut to `width` display cells, with an ellipsis.
local function fit(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

--- A line with `left` and a right-aligned `label`, `width` cells wide.
---@return string line
---@return integer left_len bytes of the (fitted) left part
---@return integer? label_start byte column of the label
local function columns(left, label, width)
  -- The name matters more: a label takes at most about 40% of the width.
  label = fit(label or "", math.max(8, math.floor(width * 0.4)))
  local room = width - (label ~= "" and vim.fn.strdisplaywidth(label) + 2 or 0)
  left = fit(left, math.max(1, room))
  if label == "" then
    return left, #left, nil
  end
  local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(label))
  local line = left .. string.rep(" ", pad) .. label
  return line, #left, #line - #label
end

---@param opts vergil.PickerOpts
---@return vergil.PickerState
function M.open(opts)
  if active and not active.closed then
    M.close()
  end
  set_hl()
  local keys = vim.tbl_extend("force", M.default_keys, opts.keys or {})
  ---@type vergil.PickerState
  local P = {
    opts = opts,
    tab = math.max(1, math.min(opts.tab or 1, #opts.tabs)),
    query = opts.query or "",
    matches = {},
    positions = {},
    selected = 1,
    marked = {},
    closed = false,
  }
  active = P
  local origin = vim.api.nvim_get_current_win()

  -- Layout: list with the tab bar on top and the search line below it; on
  -- the right, the preview above the marked list.
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.min(cols - 4, math.max(40, math.floor(cols * 0.9)))
  local height = math.min(lines - 4, math.max(10, math.floor(lines * 0.8)))
  local row = math.max(0, math.floor((lines - height) / 2) - 1)
  local col = math.max(0, math.floor((cols - width) / 2))
  local wide = width >= M.preview_min_width
  local list_w = wide and math.floor(width * 0.5) or width
  local list_h = height - 3
  local right_w = width - list_w - 2
  local marks_h = wide and math.max(3, math.min(8, math.floor(height / 3))) or 0
  local preview_h = height - marks_h - 2

  local list_buf, prompt_buf = scratch("vergil-picker-list"), scratch("vergil-picker")
  local preview_buf = wide and opts.preview and scratch("vergil-picker-preview") or nil
  local marks_buf = wide and scratch("vergil-picker-marks") or nil
  local base = { relative = "editor", style = "minimal", border = require("vergil.ui.float").border(), zindex = 60 }
  local list_win = vim.api.nvim_open_win(
    list_buf,
    false,
    vim.tbl_extend("force", base, {
      row = row,
      col = col,
      width = list_w,
      height = list_h,
      title = " ",
      title_pos = "left",
      focusable = false,
    })
  )
  local prompt_win = vim.api.nvim_open_win(
    prompt_buf,
    true,
    vim.tbl_extend("force", base, {
      row = row + list_h + 2,
      col = col,
      width = list_w,
      height = 1,
      title = " ",
      title_pos = "left",
      footer = " ",
      footer_pos = "left",
    })
  )
  local preview_win, marks_win
  if preview_buf then
    preview_win = vim.api.nvim_open_win(
      preview_buf,
      false,
      vim.tbl_extend("force", base, {
        row = row,
        col = col + list_w + 2,
        width = right_w,
        height = preview_h,
        title = " Preview ",
        title_pos = "center",
        focusable = false,
      })
    )
    vim.wo[preview_win].number = true
    vim.wo[preview_win].wrap = false
  end
  if marks_buf then
    marks_win = vim.api.nvim_open_win(
      marks_buf,
      false,
      vim.tbl_extend("force", base, {
        row = row + (preview_win and preview_h + 2 or 0),
        col = col + list_w + 2,
        width = right_w,
        height = preview_win and marks_h or height,
        title = " Marked ",
        title_pos = "left",
        focusable = false,
      })
    )
    vim.wo[marks_win].wrap = false
  end
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].wrap = false
  P.wins = { list = list_win, prompt = prompt_win, preview = preview_win, marks = marks_win }
  P.bufs = { list = list_buf, prompt = prompt_buf, preview = preview_buf, marks = marks_buf }

  local function tab()
    return opts.tabs[P.tab]
  end

  local function current_item()
    return P.matches[P.selected]
  end

  ---@return vergil.PickerMark?, integer?
  local function mark_of(item)
    for i, m in ipairs(P.marked) do
      if m.item.id == item.id then
        return m, i
      end
    end
  end

  local function render_tabs()
    local chunks = { { " ", "FloatBorder" } }
    for i, t in ipairs(opts.tabs) do
      chunks[#chunks + 1] =
        { (" %d %s "):format(i, t.name), i == P.tab and "VergilPickerTabActive" or "VergilPickerTab" }
      chunks[#chunks + 1] = { " ", "FloatBorder" }
    end
    vim.api.nvim_win_set_config(list_win, { title = chunks, title_pos = "left" })
  end

  local function render_marks()
    if not marks_buf or not vim.api.nvim_buf_is_valid(marks_buf) then
      return
    end
    local out, hls = {}, {}
    if #P.marked == 0 then
      out = { "  " .. key_label(keys.mark[1]) .. " marks items to insert together" }
    else
      for i, m in ipairs(P.marked) do
        local line, _, label_start = columns(m.info.sign .. " " .. m.info.text, m.info.label, right_w - 1)
        out[i] = line
        hls[i] = { sign = #m.info.sign, label = label_start }
      end
    end
    vim.bo[marks_buf].modifiable = true
    vim.api.nvim_buf_set_lines(marks_buf, 0, -1, false, out)
    vim.bo[marks_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(marks_buf, ns, 0, -1)
    for i, h in pairs(hls) do
      vim.api.nvim_buf_set_extmark(marks_buf, ns, i - 1, 0, { end_col = h.sign, hl_group = "VergilPickerMark" })
      if h.label then
        vim.api.nvim_buf_set_extmark(
          marks_buf,
          ns,
          i - 1,
          h.label,
          { end_col = #out[i], hl_group = "VergilPickerLabel" }
        )
      end
    end
    vim.api.nvim_win_set_config(marks_win, {
      title = #P.marked > 0 and (" Marked (%d) "):format(#P.marked) or " Marked ",
      title_pos = "left",
    })
  end

  local function render_status()
    local status = opts.status and opts.status(tab()) or "Search"
    local marked = (#P.marked > 0 and not marks_win) and (" %d marked "):format(#P.marked) or ""
    vim.api.nvim_win_set_config(prompt_win, {
      title = { { (" %s "):format(status), "FloatTitle" }, { marked, "VergilPickerMark" } },
      title_pos = "left",
    })
    -- Key hints, fitted to the width: action hints go first, then "mark".
    local prev, next = key_label(keys.prev_tab[1]), key_label(keys.next_tab[1])
    local common = prev:match("^(%a%-)")
    local tabs_hint = (
      (common and next:match("^(%a%-)") == common) and (prev .. "/" .. next:sub(#common + 1)) or (prev .. "/" .. next)
    ) .. " tabs"
    local actions = {}
    for _, a in ipairs(opts.actions or {}) do
      if a.desc and a.keys[1] and (not a.when or a.when(tab())) then
        actions[#actions + 1] = key_label(a.keys[1]) .. " " .. a.desc
      end
    end
    local mark = { key_label(keys.mark[1]) .. " mark" }
    local function build()
      local hints = { "Enter insert" }
      vim.list_extend(hints, mark)
      vim.list_extend(hints, actions)
      vim.list_extend(hints, { tabs_hint, "Esc close" })
      return " " .. table.concat(hints, " · ") .. " "
    end
    local footer = build()
    while vim.fn.strdisplaywidth(footer) > list_w - 2 and (#actions > 0 or #mark > 0) do
      if #actions > 0 then
        table.remove(actions)
      else
        mark = {}
      end
      footer = build()
    end
    vim.api.nvim_win_set_config(prompt_win, { footer = footer, footer_pos = "left" })
  end

  local preview_pending = false
  local function render_preview()
    preview_pending = false
    if P.closed or not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
      return
    end
    local item = current_item()
    local res = (item and opts.preview(item)) or { lines = {} }
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, res.lines or {})
    vim.bo[preview_buf].modifiable = false
    pcall(vim.treesitter.stop, preview_buf)
    vim.bo[preview_buf].syntax = ""
    if res.ft and res.ft ~= "" then
      local lang = vim.treesitter.language.get_lang(res.ft) or res.ft
      if not pcall(vim.treesitter.start, preview_buf, lang) then
        vim.bo[preview_buf].syntax = res.ft
      end
    end
    -- No :normal here: running Normal-mode commands while the picker opens
    -- (inside a command, entering Insert mode) is fragile.
    local last = math.max(1, #(res.lines or {}))
    local target = math.min(res.line or 1, last)
    local top = res.line and math.max(1, target - math.floor(preview_h / 2)) or 1
    pcall(vim.api.nvim_win_set_cursor, preview_win, { target, 0 })
    vim.api.nvim_win_call(preview_win, function()
      vim.fn.winrestview({ topline = top, lnum = target })
    end)
  end
  local function schedule_preview()
    if preview_buf and not preview_pending then
      preview_pending = true
      vim.schedule(render_preview)
    end
  end

  local function render_list()
    if P.closed then
      return
    end
    local t = tab()
    local out, hls = {}, {}
    local message
    if P.searched then
      message = #P.matches == 0 and "No matches" or nil
    elseif t.err then
      message = t.err
    elseif not t.items then
      message = "Loading…"
    elseif #t.items == 0 then
      message = "Nothing here"
    elseif #P.matches == 0 then
      message = "No matches"
    end
    if message then
      out = { "  " .. message }
    else
      for i, item in ipairs(P.matches) do
        local m = mark_of(item)
        local sign = m and m.info.sign or ""
        local prefix = sign .. string.rep(" ", math.max(1, 2 - vim.fn.strdisplaywidth(sign)))
        local line, left_len, label_start = columns(prefix .. item.text, item.label, list_w - 1)
        out[i] = line
        hls[i] = { prefix = #prefix, sign = #sign, text_len = left_len - #prefix, label_start = label_start }
      end
    end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, out)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for i, h in pairs(hls) do
      if h.sign > 0 then
        vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, 0, { end_col = h.sign, hl_group = "VergilPickerMark" })
      end
      for _, pos in ipairs(P.positions[i] or {}) do
        -- matchfuzzypos gives character indexes into the text.
        local text = P.matches[i].text
        local byte = vim.str_byteindex(text, "utf-32", pos, false)
        if byte < h.text_len then
          local stop = vim.str_byteindex(text, "utf-32", pos + 1, false)
          vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, h.prefix + byte, {
            end_col = h.prefix + math.min(stop, h.text_len),
            hl_group = "VergilPickerMatch",
          })
        end
      end
      if h.label_start then
        vim.api.nvim_buf_set_extmark(
          list_buf,
          ns,
          i - 1,
          h.label_start,
          { end_col = #out[i], hl_group = "VergilPickerLabel" }
        )
      end
    end
    P.selected = math.max(1, math.min(P.selected, #P.matches))
    pcall(vim.api.nvim_win_set_cursor, list_win, { P.selected, 0 })
    render_status()
    render_marks()
    schedule_preview()
  end

  local function refilter()
    local items = tab().items or {}
    local own, own_pos
    if opts.search then
      own, own_pos = opts.search(tab(), P.query)
    end
    P.searched = own ~= nil
    if own then
      P.matches, P.positions = vim.list_slice(own, 1, M.limit), own_pos or {}
    elseif P.query == "" then
      P.matches = vim.list_slice(items, 1, M.limit)
      P.positions = {}
    else
      local res = vim.fn.matchfuzzypos(items, P.query, { key = "text", limit = M.limit })
      P.matches, P.positions = res[1], res[2]
    end
    P.selected = 1
    render_list()
  end

  --- Picks up what was typed since the last TextChangedI (which only fires
  --- when typing pauses), so actions always see the current query.
  local function sync()
    local q = vim.api.nvim_buf_is_valid(prompt_buf) and vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1]
      or P.query
    if q ~= P.query then
      P.query = q
      refilter()
    end
  end

  local function ensure_loaded(t)
    if t.items or t.loading or t.err then
      return
    end
    t.loading = true
    t.load(function(items, err)
      local update = t.items ~= nil
      t.loading = false
      t.items, t.err = items, (not items) and (err or "nothing to show") or nil
      if P.closed or tab() ~= t then
        return
      end
      -- An update (e.g. git's data arriving) keeps the selected item.
      local keep = update and P.matches[P.selected]
      refilter()
      if keep then
        for i, m in ipairs(P.matches) do
          if m.id == keep.id then
            P.selected = i
            pcall(vim.api.nvim_win_set_cursor, list_win, { i, 0 })
            break
          end
        end
      end
      schedule_preview()
    end)
  end

  local function switch(i)
    sync()
    P.tab = ((i - 1) % #opts.tabs) + 1 -- cyclic
    render_tabs()
    ensure_loaded(tab())
    refilter()
  end
  P.switch = switch

  local function move(delta)
    sync()
    if #P.matches == 0 then
      return
    end
    P.selected = ((P.selected - 1 + delta) % #P.matches) + 1
    pcall(vim.api.nvim_win_set_cursor, list_win, { P.selected, 0 })
    schedule_preview()
  end

  function P.close_windows()
    if P.closed then
      return
    end
    P.closed = true
    if active == P then
      active = nil
    end
    -- Only in Insert mode: a pending :stopinsert would cancel the next
    -- startinsert (e.g. of the next picker).
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.cmd.stopinsert()
    end
    for _, w in pairs(P.wins) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end

  local function cancel()
    P.close_windows()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function confirm()
    sync()
    local chosen = vim.list_slice(P.marked)
    if #chosen == 0 then
      local item = current_item()
      if not item then
        return
      end
      if item.query then
        return P.set_query(item.query)
      end
      chosen = { { item = item, info = opts.mark_info(item) } }
    end
    local t = tab()
    P.close_windows()
    opts.on_confirm(chosen, t)
  end

  --- Marks (`on` true), unmarks (false) or toggles (nil) the current item.
  local function set_mark(on)
    sync()
    local item = current_item()
    if not item then
      return
    end
    local _, i = mark_of(item)
    if i and on ~= true then
      table.remove(P.marked, i)
    elseif not i and on ~= false then
      P.marked[#P.marked + 1] = { item = item, info = opts.mark_info(item) }
    end
  end

  P.confirm, P.cancel, P.current, P.tab_spec, P.sync = confirm, cancel, current_item, tab, sync
  --- Replaces the search line and searches for it.
  function P.set_query(q)
    if vim.api.nvim_buf_is_valid(prompt_buf) then
      vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { q })
      pcall(vim.api.nvim_win_set_cursor, prompt_win, { 1, #q })
    end
    sync()
  end
  --- Re-renders after the caller changed something shown (e.g. the status).
  function P.refresh()
    render_list()
  end
  --- Renders the preview again, e.g. once its content has loaded.
  P.refresh_preview = function()
    schedule_preview()
  end
  P.current_item = function()
    return current_item()
  end

  local map = function(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = prompt_buf, nowait = true })
  end
  for _, lhs in ipairs(keys.confirm) do
    map(lhs, confirm)
  end
  for _, lhs in ipairs(keys.close) do
    map(lhs, cancel)
  end
  for _, lhs in ipairs(keys.down) do
    map(lhs, function()
      move(1)
    end)
  end
  for _, lhs in ipairs(keys.up) do
    map(lhs, function()
      move(-1)
    end)
  end
  for _, lhs in ipairs(keys.mark) do
    map(lhs, function()
      set_mark()
      move(1)
      render_list()
    end)
  end
  for _, lhs in ipairs(keys.unmark) do
    map(lhs, function()
      move(-1)
      set_mark(false)
      render_list()
    end)
  end
  for _, lhs in ipairs(keys.next_tab) do
    map(lhs, function()
      switch(P.tab + 1)
    end)
  end
  for _, lhs in ipairs(keys.prev_tab) do
    map(lhs, function()
      switch(P.tab - 1)
    end)
  end
  for i = 1, math.min(9, #opts.tabs) do
    map(("<M-%d>"):format(i), function()
      switch(i)
    end)
    map(("<C-%d>"):format(i), function()
      switch(i)
    end) -- terminals with CSI u
  end
  local function scroll(dir)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_call(preview_win, function()
        local view = vim.fn.winsaveview()
        local count = vim.api.nvim_buf_line_count(preview_buf)
        local top = math.max(1, math.min(view.topline + dir * math.max(1, math.floor(preview_h / 2)), count))
        vim.fn.winrestview({ topline = top, lnum = math.max(top, math.min(view.lnum, count)) })
      end)
    end
  end
  for _, lhs in ipairs(keys.scroll_down) do
    map(lhs, function()
      scroll(1)
    end)
  end
  for _, lhs in ipairs(keys.scroll_up) do
    map(lhs, function()
      scroll(-1)
    end)
  end
  for _, a in ipairs(opts.actions or {}) do
    for _, lhs in ipairs(a.keys) do
      map(lhs, function()
        sync()
        if not a.when or a.when(tab()) then
          a.fn(P)
        end
      end)
    end
  end

  vim.api.nvim_create_autocmd(
    { "TextChangedI", "TextChanged", "InsertLeave" },
    { group = group, buffer = prompt_buf, callback = sync }
  )
  -- Leaving the search line any other way (e.g. a mouse click) cancels.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = prompt_buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if not P.closed then
          cancel()
        end
      end)
    end,
  })

  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { P.query })
  render_tabs()
  ensure_loaded(tab())
  refilter()
  vim.api.nvim_win_set_cursor(prompt_win, { 1, #P.query })
  vim.cmd("startinsert!")
  return P
end

--- Closes the open picker without choosing anything.
function M.close()
  if active and not active.closed then
    active.cancel()
  end
end

return M
