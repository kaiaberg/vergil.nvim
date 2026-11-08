local h = require("helpers")
local symbols = require("vergil.symbols")

-- Lua and C parsers ship with Neovim, so these run everywhere.
local LUA = {
  "local M = {}", --  1
  "", --  2
  "local function helper(x)", --  3
  "  return x", --  4
  "end", --  5
  "", --  6
  "function M.apply(ctx)", --  7
  "  vim.schedule(function() end)", --  8
  "  return helper(ctx)", --  9
  "end", -- 10
  "", -- 11
  "M.cancel = function()", -- 12
  "  local t = { on_done = function() end }", -- 13
  "end", -- 14
  "", -- 15
  "return M", -- 16
}
local C = {
  "struct point { int x; };",
  "struct point origin;",
  "static int *add(int a, int b) {",
  "  return 0;",
  "}",
}

local root = h.tree({
  ["src/a.lua"] = table.concat(LUA, "\n") .. "\n",
  ["notes.unknownext"] = "plain\n",
})

local function names(list)
  return vim.tbl_map(function(s)
    return ("%s L%d-L%d"):format(s.name, s.start_line, s.end_line)
  end, list)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function text(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function selector_open()
  vim.wait(1000, function()
    return vim.api.nvim_win_get_config(0).relative ~= ""
  end)
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

--- Opens the selector for the reference on the prompt's only line.
local function trigger(line, name)
  vim.cmd("silent! %bwipeout!")
  local b = h.prompt(root, { line }, name or "sym")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("A#")
  h.truthy(selector_open(), "selector did not open")
  return b
end

--- Stubs vim.ui.select to pick the item whose name is `choose` (nil: cancel).
local function picking(choose, fn)
  local shown
  local select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    shown = vim.tbl_map(opts.format_item, items)
    local choice
    for _, item in ipairs(items) do
      if item.name == choose then
        choice = item
      end
    end
    on_choice(choice)
  end
  local ok, err = pcall(fn)
  vim.ui.select = select
  assert(ok, err)
  return shown
end

local function set_file(lines)
  vim.fn.writefile(lines, root .. "/src/a.lua")
  vim.uv.fs_utime(root .. "/src/a.lua", os.time() + 5, os.time() + 5) -- a new mtime
end

return {
  ["Lua: named, local and assigned functions and table fields; callbacks skipped"] = function()
    h.eq(
      names(symbols.list(LUA, "/x/a.lua")),
      { "helper L3-L5", "M.apply L7-L10", "M.cancel L12-L14", "M.cancel.on_done L13-L13" }
    )
  end,
  ["C: functions through declarators, structs with a body only"] = function()
    h.eq(names(symbols.list(C, "/x/a.c")), { "point L1-L1", "add L3-L5" })
  end,
  ["nested symbols are qualified"] = function()
    local list =
      symbols.list({ "local M = {}", "function M.outer()", "  local function inner() end", "end" }, "/x/a.lua")
    h.eq(names(list), { "M.outer L2-L4", "M.outer.inner L3-L3" })
    h.eq(list[2].depth, 1)
  end,
  ["no parser: no symbols, with a reason"] = function()
    h.eq({ symbols.list({ "x" }, "/x/notes.unknownext") }, { nil, "no treesitter parser for notes.unknownext" })
  end,
  ["exact and find"] = function()
    local list = symbols.list(LUA, "/x/a.lua")
    h.eq(symbols.exact(list, 7, 10).name, "M.apply")
    h.eq(symbols.exact(list, 7, 9), nil)
    h.eq(symbols.find(list, "M.cancel").start_line, 12)
  end,

  ["selector: gO selects a symbol's lines, then Enter adds the name"] = function()
    set_file(LUA)
    local b = trigger("look at @src/a.lua")
    local shown = picking("M.apply", function()
      feed("gO")
    end)
    h.eq(shown, {
      "helper              L3-L5",
      "M.apply             L7-L10",
      "M.cancel            L12-L14",
      "  M.cancel.on_done  L13-L13",
    })
    h.eq(vim.api.nvim_get_mode().mode, "V", "lines selected")
    feed("<CR>")
    h.eq(text(b), { "look at `src/a.lua#L7-L10` (`M.apply`)" })
  end,
  ["selector: lines selected by hand get the name too, other ranges don't"] = function()
    local b = trigger("@src/a.lua", "sym-hand")
    feed("3GV2j<CR>")
    h.eq(text(b), { "`src/a.lua#L3-L5` (`helper`)" })
    b = trigger("@src/a.lua", "sym-other")
    feed("3GVj<CR>")
    h.eq(text(b), { "`src/a.lua#L3-L4`" })
  end,
  ["selector: snippets carry the name in their header"] = function()
    local b = trigger("@src/a.lua", "sym-snip")
    picking("helper", function()
      feed("gO")
    end)
    feed("gs")
    h.truthy(vim.tbl_contains(text(b), "From `src/a.lua#L3-L5` (`helper`):"), vim.inspect(text(b)))
  end,
  ["selector: cancelling the list keeps the selector open"] = function()
    trigger("@src/a.lua", "sym-cancel")
    picking(nil, function()
      feed("gO")
    end)
    h.truthy(vim.api.nvim_win_get_config(0).relative ~= "", "still in the selector")
    feed("q")
  end,
  ["selector: mention.symbols = false leaves names out"] = function()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(root, { "@src/a.lua" }, "sym-off")
    require("vergil").setup({ root = root, mention = { symbols = false } })
    feed("A#")
    selector_open()
    feed("7GV3j<CR>")
    h.eq(text(b), { "`src/a.lua#L7-L10`" })
    require("vergil").setup({ root = root })
  end,
  ["selector: gO without a parser says so"] = function()
    vim.cmd("silent! %bwipeout!")
    h.prompt(root, { "@notes.unknownext" }, "sym-none")
    feed("A#")
    selector_open()
    local said
    local notify = vim.notify
    vim.notify = function(msg)
      said = msg
    end
    feed("gO")
    vim.notify = notify
    h.eq(said, "vergil: no treesitter parser for notes.unknownext")
    feed("q")
  end,
  [":Vergil send names a whole function"] = function()
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(root, { "" }, "sym-send")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/a.lua"))
    require("vergil.send").send("mention", 12, 14)
    h.eq(text(b), { "`src/a.lua#L12-L14` (`M.cancel`)" })
  end,

  ["diagnostics: a moved symbol is flagged, and the range can be updated"] = function()
    set_file(LUA)
    vim.cmd("silent! %bwipeout!")
    local b, client =
      h.prompt(root, { "fix `src/a.lua#L7-L10` (`M.apply`) and `src/a.lua#L3-L5` (`helper`)" }, "sym-diag")
    h.eq(vim.diagnostic.get(b), {}, "matching ranges are fine")
    local moved = vim.list_extend({ "-- a new first line", "" }, LUA)
    set_file(moved)
    require("vergil.lsp.server").refresh(b)
    vim.wait(2000, function()
      return #vim.diagnostic.get(b) == 2
    end)
    local d = vim.diagnostic.get(b)
    table.sort(d, function(x, y)
      return x.col < y.col
    end)
    h.eq(
      { d[1].code, d[1].message, d[2].message },
      { "symbol", "`M.apply` is now at L9-L12.", "`helper` is now at L5-L7." }
    )
    h.eq(d[1].severity, vim.diagnostic.severity.WARN)

    local params = {
      textDocument = { uri = vim.uri_from_bufnr(b) },
      range = { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 6 } },
      context = { diagnostics = { d[1].user_data and d[1].user_data.lsp or d[1] } },
    }
    local actions = client:request_sync("textDocument/codeAction", params, 2000, b).result
    local update = vim.tbl_filter(function(a)
      return a.title == "Update range to L9-L12"
    end, actions)[1]
    h.truthy(
      update,
      vim.inspect(vim.tbl_map(function(a)
        return a.title
      end, actions))
    )
    h.eq({ update.kind, update.isPreferred }, { "quickfix", true })
    vim.lsp.util.apply_workspace_edit(update.edit, client.offset_encoding)
    h.eq(text(b)[1], "fix `src/a.lua#L9-L12` (`M.apply`) and `src/a.lua#L3-L5` (`helper`)")
    set_file(LUA)
  end,
  ["diagnostics: a removed symbol is flagged; unnamed mentions are not checked"] = function()
    set_file(LUA)
    vim.cmd("silent! %bwipeout!")
    local b = h.prompt(root, { "`src/a.lua#L1-L2` (`M.gone`) `src/a.lua#L7-L8`" }, "sym-gone")
    vim.wait(2000, function()
      return #vim.diagnostic.get(b) > 0
    end)
    local d = vim.diagnostic.get(b)
    h.eq(#d, 1)
    h.eq(d[1].message, "`M.gone` is no longer in src/a.lua.")
  end,
}
