--- A small tabbed fuzzy picker: a search line, a list and a preview, in
--- floats. It knows nothing about vergil; `vergil.picker` supplies the tabs.
---
--- Typing filters the current tab with `matchfuzzypos`. Tabs cycle, and the
--- query is kept when switching. Items can be marked to confirm several.
local M = {}

---@class vergil.PickerItem
---@field text string searched and shown
---@field label string? shown right-aligned, e.g. "modified" or "skill"
---@field kind string? what the item is, for the caller
---@field value any

---@class vergil.PickerTab
---@field key string
---@field name string
---@field load fun(cb: fun(items: vergil.PickerItem[]?, err: string?)) may call back later
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
---@field status (fun(): string)? text in the search line's title
---@field preview (fun(item: vergil.PickerItem): { lines: string[], ft: string?, line: integer? }?)?
---@field actions vergil.PickerAction[]?
---@field keys table<string, string[]>?
---@field on_confirm fun(items: vergil.PickerItem[], tab: vergil.PickerTab)
---@field on_cancel fun()?

---@class vergil.PickerState
---@field opts vergil.PickerOpts
---@field tab integer
---@field query string
---@field matches vergil.PickerItem[]
---@field positions integer[][]
---@field selected integer
---@field marked vergil.PickerItem[]
---@field closed boolean

M.limit = 500
--- The preview shows when the picker is at least this wide.
M.preview_min_width = 80

local ns = vim.api.nvim_create_namespace("vergil.picker")
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

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].completion = false -- blink.cmp
  return buf
end

local function key_label(lhs)
  return (lhs:gsub("^<", ""):gsub(">$", ""):gsub("CR", "Enter"):gsub("^C%-", "C-"))
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

  -- Layout: list with the tab bar on top, search line below, preview right.
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.min(cols - 4, math.max(40, math.floor(cols * 0.9)))
  local height = math.min(lines - 4, math.max(10, math.floor(lines * 0.8)))
  local row = math.max(0, math.floor((lines - height) / 2) - 1)
  local col = math.max(0, math.floor((cols - width) / 2))
  local with_preview = opts.preview and width >= M.preview_min_width
  local list_w = with_preview and math.floor(width * 0.5) or width
  local list_h = height - 3

  local list_buf, prompt_buf = scratch(), scratch()
  local preview_buf = with_preview and scratch() or nil
  local base = { relative = "editor", style = "minimal", border = "rounded", zindex = 60 }
  local list_win = vim.api.nvim_open_win(list_buf, false, vim.tbl_extend("force", base, {
    row = row, col = col, width = list_w, height = list_h, title = " ", title_pos = "left", focusable = false,
  }))
  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, vim.tbl_extend("force", base, {
    row = row + list_h + 2, col = col, width = list_w, height = 1, title = " ", title_pos = "left",
    footer = " ", footer_pos = "left",
  }))
  local preview_win
  if preview_buf then
    preview_win = vim.api.nvim_open_win(preview_buf, false, vim.tbl_extend("force", base, {
      row = row, col = col + list_w + 2, width = width - list_w - 2, height = height,
      title = " Preview ", title_pos = "center", focusable = false,
    }))
    vim.wo[preview_win].number = true
    vim.wo[preview_win].wrap = false
  end
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].wrap = false
  P.wins = { list = list_win, prompt = prompt_win, preview = preview_win }
  P.bufs = { list = list_buf, prompt = prompt_buf, preview = preview_buf }

  local function tab()
    return opts.tabs[P.tab]
  end

  local function current_item()
    return P.matches[P.selected]
  end

  local function is_marked(item)
    for _, m in ipairs(P.marked) do
      if m == item then
        return true
      end
    end
    return false
  end

  local function render_tabs()
    local chunks = { { " ", "FloatBorder" } }
    for i, t in ipairs(opts.tabs) do
      chunks[#chunks + 1] = { (" %d %s "):format(i, t.name), i == P.tab and "VergilPickerTabActive" or "VergilPickerTab" }
      chunks[#chunks + 1] = { " ", "FloatBorder" }
    end
    vim.api.nvim_win_set_config(list_win, { title = chunks, title_pos = "left" })
  end

  local function render_status()
    local status = opts.status and opts.status() or nil
    local marked = #P.marked > 0 and (" %d marked "):format(#P.marked) or ""
    vim.api.nvim_win_set_config(prompt_win, {
      title = { { (" %s "):format(status or "Search"), "FloatTitle" }, { marked, "VergilPickerMark" } },
      title_pos = "left",
    })
    -- Key hints, fitted to the width: action hints go first, then "mark".
    local prev, next = key_label(keys.prev_tab[1]), key_label(keys.next_tab[1])
    local common = prev:match("^(%a%-)") == next:match("^(%a%-)") and prev:match("^(%a%-)") or nil
    local tabs_hint = (common and (prev .. "/" .. next:sub(#common + 1)) or (prev .. "/" .. next)) .. " tabs"
    local actions = {}
    for _, a in ipairs(opts.actions or {}) do
      if a.desc and (not a.when or a.when(tab())) then
        actions[#actions + 1] = key_label(a.keys[1]) .. " " .. a.desc
      end
    end
    local mark = { "Tab mark" }
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
    local res = item and opts.preview(item) or { lines = {} }
    res = res or { lines = {} }
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
    -- (inside a command, entering Insert mode) crashes Neovim 0.12.
    local last = math.max(1, #(res.lines or {}))
    local target = math.min(res.line or 1, last)
    local top = res.line and math.max(1, target - math.floor(height / 2)) or 1
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
    if t.err then
      out = { "  " .. t.err }
    elseif not t.items then
      out = { "  Loading…" }
    elseif #t.items == 0 then
      out = { "  Nothing here" }
    elseif #P.matches == 0 then
      out = { "  No matches" }
    else
      local inner = list_w - 1
      for i, item in ipairs(P.matches) do
        local prefix = is_marked(item) and "● " or "  "
        local label = item.label or ""
        local avail = inner - #prefix - (label ~= "" and vim.fn.strdisplaywidth(label) + 2 or 0)
        local text = item.text
        if vim.fn.strdisplaywidth(text) > avail then
          text = vim.fn.strcharpart(text, 0, math.max(1, avail - 1)) .. "…"
        end
        local pad = math.max(1, inner - #prefix - vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(label))
        out[i] = prefix .. text .. (label ~= "" and (string.rep(" ", pad) .. label) or "")
        hls[i] = { prefix = #prefix, text_len = #text, label_start = label ~= "" and (#out[i] - #label) or nil, marked = prefix ~= "  " }
      end
    end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, out)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for i, h in pairs(hls) do
      if h.marked then
        vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, 0, { end_col = 1, hl_group = "VergilPickerMark" })
      end
      for _, pos in ipairs(P.positions[i] or {}) do
        -- matchfuzzypos gives character indexes into the text.
        local byte = vim.str_byteindex(P.matches[i].text, "utf-32", pos, false)
        if byte < h.text_len then
          local stop = vim.str_byteindex(P.matches[i].text, "utf-32", pos + 1, false)
          vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, h.prefix + byte, {
            end_col = h.prefix + math.min(stop, h.text_len), hl_group = "VergilPickerMatch",
          })
        end
      end
      if h.label_start then
        vim.api.nvim_buf_set_extmark(list_buf, ns, i - 1, h.label_start, { end_col = #out[i], hl_group = "VergilPickerLabel" })
      end
    end
    P.selected = math.max(1, math.min(P.selected, #P.matches))
    pcall(vim.api.nvim_win_set_cursor, list_win, { P.selected, 0 })
    render_status()
    schedule_preview()
  end

  local function refilter()
    local items = tab().items or {}
    if P.query == "" then
      P.matches = vim.list_slice(items, 1, M.limit)
      P.positions = {}
    else
      local res = vim.fn.matchfuzzypos(items, P.query, { key = "text", limit = M.limit })
      P.matches, P.positions = res[1], res[2]
    end
    P.selected = 1
    render_list()
  end

  local function ensure_loaded(t)
    if t.items or t.loading or t.err then
      return
    end
    t.loading = true
    t.load(function(items, err)
      t.loading = false
      t.items, t.err = items, (not items) and (err or "nothing to show") or nil
      if not P.closed and tab() == t then
        refilter()
      end
    end)
  end

  --- Picks up what was typed since the last TextChangedI (which only fires
  --- when typing pauses), so actions always see the current query.
  local function sync()
    local q = vim.api.nvim_buf_is_valid(prompt_buf) and vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or P.query
    if q ~= P.query then
      P.query = q
      refilter()
    end
  end

  local function switch(i)
    sync()
    local n = #opts.tabs
    P.tab = ((i - 1) % n) + 1 -- cyclic
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
    -- Only when in Insert mode: a pending :stopinsert would cancel the next
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
    local chosen = #P.marked > 0 and vim.list_slice(P.marked) or { current_item() }
    if #chosen == 0 then
      return
    end
    local t = tab()
    P.close_windows()
    opts.on_confirm(chosen, t)
  end
  P.confirm = confirm
  P.cancel = cancel
  P.current = current_item
  P.tab_spec = tab

  local function toggle_mark(on)
    sync()
    local item = current_item()
    if not item then
      return
    end
    for i, m in ipairs(P.marked) do
      if m == item then
        if on ~= true then
          table.remove(P.marked, i)
        end
        render_list()
        return
      end
    end
    if on ~= false then
      P.marked[#P.marked + 1] = item
    end
  end

  local map = function(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = prompt_buf, nowait = true })
  end
  for _, lhs in ipairs(keys.confirm) do map(lhs, confirm) end
  for _, lhs in ipairs(keys.close) do map(lhs, cancel) end
  for _, lhs in ipairs(keys.down) do map(lhs, function() move(1) end) end
  for _, lhs in ipairs(keys.up) do map(lhs, function() move(-1) end) end
  for _, lhs in ipairs(keys.mark) do
    map(lhs, function()
      toggle_mark()
      move(1)
      render_list()
    end)
  end
  for _, lhs in ipairs(keys.unmark) do
    map(lhs, function()
      move(-1)
      toggle_mark(false)
      render_list()
    end)
  end
  for _, lhs in ipairs(keys.next_tab) do map(lhs, function() switch(P.tab + 1) end) end
  for _, lhs in ipairs(keys.prev_tab) do map(lhs, function() switch(P.tab - 1) end) end
  for i = 1, math.min(9, #opts.tabs) do
    map(("<M-%d>"):format(i), function() switch(i) end)
    map(("<C-%d>"):format(i), function() switch(i) end) -- terminals with CSI u
  end
  local function scroll(dir)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_call(preview_win, function()
        local view = vim.fn.winsaveview()
        local count = vim.api.nvim_buf_line_count(preview_buf)
        local top = math.max(1, math.min(view.topline + dir * math.max(1, math.floor(height / 2)), count))
        vim.fn.winrestview({ topline = top, lnum = math.max(top, math.min(view.lnum, count)) })
      end)
    end
  end
  for _, lhs in ipairs(keys.scroll_down) do map(lhs, function() scroll(1) end) end
  for _, lhs in ipairs(keys.scroll_up) do map(lhs, function() scroll(-1) end) end
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

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "InsertLeave" }, { buffer = prompt_buf, callback = sync })
  -- Leaving the search line any other way (e.g. a mouse click) cancels.
  vim.api.nvim_create_autocmd("WinLeave", {
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

  --- Re-renders after the caller changed something shown (e.g. the status).
  function P.refresh()
    render_list()
  end

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
