local h = require("helpers")
local op = require("vergil.operator")

local root = h.tree({
  ["src/a.lua"] = table.concat(vim.fn.range(1, 50), "\n") .. "\n",
  ["src/b.lua"] = "b\n",
  ["dir/x.txt"] = "",
})

local function text(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

--- A prompt with the operators on `gm` and `ga`, as the preset maps them.
local function prompt(lines)
  local b = h.prompt(root, lines, "op")
  for lhs, plug in pairs({ gm = "mention", ga = "attach" }) do
    vim.keymap.set({ "n", "x" }, lhs, ("<Plug>(vergil-%s)"):format(plug), { buffer = b, remap = true })
    vim.keymap.set("n", lhs .. lhs:sub(2), ("<Plug>(vergil-%s-line)"):format(plug), { buffer = b, remap = true })
  end
  return b
end

return {
  ["gm on a paragraph: every existing path becomes a mention, ranges kept"] = function()
    local b = prompt({
      "Error in src/a.lua:12, called from src/b.lua.",
      "Also see (dir/x.txt) and dir/, not missing/file.lua or e.g. this.",
      "",
      "src/a.lua stays outside the paragraph",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("gmip")
    h.eq(text(b), {
      "Error in `src/a.lua#L12`, called from `src/b.lua`.",
      "Also see (`dir/x.txt`) and `dir/`, not missing/file.lua or e.g. this.",
      "",
      "src/a.lua stays outside the paragraph",
    })
    feed("u")
    h.eq(text(b)[1], "Error in src/a.lua:12, called from src/b.lua.", "one undo step")
  end,
  ["a charwise motion converts only what starts inside it; . repeats"] = function()
    local b = prompt({ "src/a.lua src/b.lua src/a.lua:3" })
    vim.api.nvim_win_set_cursor(0, { 1, 10 })
    feed("gmiW")
    h.eq(text(b), { "src/a.lua `src/b.lua` src/a.lua:3" })
    vim.api.nvim_win_set_cursor(0, { 1, 24 })
    feed(".")
    h.eq(text(b), { "src/a.lua `src/b.lua` `src/a.lua#L3`" })
  end,
  ["ga attaches bare paths and mentions, keeping ranges as a mention"] = function()
    local b = prompt({ "fix src/a.lua:3-4 and `src/b.lua`" })
    feed("gaa")
    h.eq(text(b), { "fix @src/a.lua `src/a.lua#L3-L4` and @src/b.lua" })
  end,
  ["gm turns attachments into mentions too"] = function()
    local b = prompt({ "@src/a.lua and @dir/x.txt" })
    feed("gmm")
    h.eq(text(b), { "`src/a.lua` and `dir/x.txt`" })
  end,
  ["fenced and inline code are left alone"] = function()
    local b = prompt({ "```", "src/a.lua:3", "```", "run `lua src/a.lua` then src/b.lua" })
    feed("gmG")
    h.eq(text(b), { "```", "src/a.lua:3", "```", "run `lua src/a.lua` then `src/b.lua`" })
  end,
  ["absolute paths under the root become relative"] = function()
    local b = prompt({ "at " .. root .. "/src/a.lua:7" })
    feed("gmm")
    h.eq(text(b), { "at `src/a.lua#L7`" })
  end,
  ["Visual gm and :Vergil mention/attach"] = function()
    local b = prompt({ "src/a.lua", "src/b.lua", "dir/x.txt" })
    feed("Vjgm")
    h.eq(text(b), { "`src/a.lua`", "`src/b.lua`", "dir/x.txt" })
    vim.cmd("3Vergil attach")
    h.eq(text(b), { "`src/a.lua`", "`src/b.lua`", "@dir/x.txt" })
  end,
  ["nothing to convert, and agents without attachments"] = function()
    local b = prompt({ "no paths here" })
    h.eq({ op.lines("mention", 1, 1) }, { false, "no paths to convert" })
    h.eq(text(b), { "no paths here" })
    require("vergil").setup({ root = root, agents = {} })
    local p = h.prompt(root, { "src/a.lua" }, "op-plain")
    vim.cmd("Vergil enable plain")
    h.eq({ op.convert(p, "attach", op.line_regions(p, 1, 1)) }, { nil, "this agent has no attachments" })
    require("vergil").setup({ root = root })
  end,
}
