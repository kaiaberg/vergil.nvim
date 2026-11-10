local h = require("helpers")
local f = require("vergil.reference.attachments")
local claude = require("vergil.agents").normalize("claude", h.recipe("claude")).attach

local function paths(line)
  return vim.tbl_map(function(a)
    return a.path
  end, f.find(line, claude))
end

return {
  ["plain attachment with exact span"] = function()
    h.eq(f.find("see @src/a.ts now", claude), { { start_col = 4, end_col = 13, path = "src/a.ts", quoted = false } })
  end,
  ["boundary: only line start or whitespace (contract-tested)"] = function()
    h.eq(paths("@a.ts\t@b.ts"), { "a.ts", "b.ts" })
    h.eq(paths('(@a.ts) "@b.ts" `@c.ts` me@d.ts'), {})
  end,
  ["trailing punctuation is stripped from the span"] = function()
    local a = f.find("x @a.ts), y", claude)[1]
    h.eq({ a.path, a.end_col }, { "a.ts", 7 })
    h.eq(
      paths("@a.ts... @b.ts; @c.ts! @d.ts? @e.ts] @f.ts} @g.ts> @h.ts' @i.ts\" @j.ts`"),
      { "a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts", "g.ts", "h.ts", "i.ts", "j.ts" }
    )
  end,
  ["quoted path with spaces"] = function()
    h.eq(f.find('@"my file.ts" ok', claude), { { start_col = 0, end_col = 13, path = "my file.ts", quoted = true } })
  end,
  ["unterminated quote runs to end of line"] = function()
    h.eq(
      f.find('x @"my fi', claude),
      { { start_col = 2, end_col = 9, path = "my fi", quoted = true, unterminated = true } }
    )
  end,
  ["bare @, @@ and empty quotes are not references"] = function()
    h.eq(paths('@ x @@foo @""'), {})
  end,
  ["directory, dot-slash and home paths"] = function()
    h.eq(paths("@src/ @./a.ts @~/notes.md @../up.ts"), { "src/", "./a.ts", "~/notes.md", "../up.ts" })
  end,
  ["#range is split off and reported as ignored"] = function()
    h.eq(f.find("@a.ts#L12-L35", claude)[1].ignored_range, { 12, 35 })
    h.eq(f.find("@a.ts#1-10", claude)[1].ignored_range, { 1, 10 })
    h.eq(f.find("@a.ts#L5", claude)[1].ignored_range, { 5, 5 })
    h.eq(f.find("@a.ts#L5", claude)[1].path, "a.ts")
    h.eq(f.find("@a#b.ts", claude)[1].path, "a#b.ts")
  end,
  ["server:resource is flagged; paths with colons later are not"] = function()
    h.eq(f.find("@github:repos/x", claude)[1].resource, true)
    h.eq(f.find("@src/a.ts:12", claude)[1].resource, nil)
  end,
  ["unicode paths keep byte spans"] = function()
    local a = f.find("ä @dörp/ü.ts", claude)[1]
    h.eq({ a.path, a.start_col, a.end_col }, { "dörp/ü.ts", 3, 15 })
  end,
  ["format quotes only when needed"] = function()
    h.eq(f.format("src/a.ts", claude), "@src/a.ts")
    h.eq(f.format("src/my file.ts", claude), '@"src/my file.ts"')
    h.eq(f.format("weird.", claude), '@"weird."')
  end,
  ["format round-trips through find"] = function()
    for _, p in ipairs({ "a.ts", "src/my file.ts", "dir/", "x/y z/ä.md", "end." }) do
      h.eq(paths(f.format(p, claude)), { p }, p)
    end
  end,
  ["another agent's syntax: prefix, no quote, nothing stripped, ranges kept"] = function()
    local spec = { prefix = "+", strip = "" }
    h.eq(
      vim.tbl_map(function(a)
        return a.path
      end, f.find("+a.ts, +b.ts++ x+c ++d @e", spec)),
      { "a.ts,", "b.ts++" }
    )
    h.eq(f.find("+a.ts#L5", spec)[1].ignored_range, nil, 'not hinted without ranges = "ignored"')
    h.eq(f.find('+"a b"', spec)[1].path, '"a', "no quote: quotes are part of the path")
    h.eq(f.format("my file", spec), nil)
    h.eq(f.format("a.ts", spec), "+a.ts")
  end,
}
