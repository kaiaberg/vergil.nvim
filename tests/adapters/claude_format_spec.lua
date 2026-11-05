local h = require("helpers")
local f = require("vergil.adapters.claude.format")

local function paths(line)
  return vim.tbl_map(function(a) return a.path end, f.find_attachments(line))
end

return {
  ["plain attachment with exact span"] = function()
    h.eq(f.find_attachments("see @src/a.ts now"), { { start_col = 4, end_col = 13, path = "src/a.ts", quoted = false } })
  end,
  ["boundary: only line start or whitespace (contract-tested)"] = function()
    h.eq(paths("@a.ts\t@b.ts"), { "a.ts", "b.ts" })
    h.eq(paths('(@a.ts) "@b.ts" `@c.ts` me@d.ts'), {})
  end,
  ["trailing punctuation is stripped from the span"] = function()
    local a = f.find_attachments("x @a.ts), y")[1]
    h.eq({ a.path, a.end_col }, { "a.ts", 7 })
    h.eq(paths("@a.ts... @b.ts; @c.ts! @d.ts? @e.ts] @f.ts} @g.ts> @h.ts' @i.ts\" @j.ts`"), { "a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts", "g.ts", "h.ts", "i.ts", "j.ts" })
  end,
  ["quoted path with spaces"] = function()
    h.eq(f.find_attachments('@"my file.ts" ok'), { { start_col = 0, end_col = 13, path = "my file.ts", quoted = true } })
  end,
  ["unterminated quote runs to end of line"] = function()
    h.eq(f.find_attachments('x @"my fi'), { { start_col = 2, end_col = 9, path = "my fi", quoted = true, unterminated = true } })
  end,
  ["bare @, @@ and empty quotes are not references"] = function()
    h.eq(paths('@ x @@foo @""'), {})
  end,
  ["directory, dot-slash and home paths"] = function()
    h.eq(paths("@src/ @./a.ts @~/notes.md @../up.ts"), { "src/", "./a.ts", "~/notes.md", "../up.ts" })
  end,
  ["#range is split off and reported as ignored"] = function()
    h.eq(f.find_attachments("@a.ts#L12-L35")[1].ignored_range, { 12, 35 })
    h.eq(f.find_attachments("@a.ts#1-10")[1].ignored_range, { 1, 10 })
    h.eq(f.find_attachments("@a.ts#L5")[1].ignored_range, { 5, 5 })
    h.eq(f.find_attachments("@a.ts#L5")[1].path, "a.ts")
    h.eq(f.find_attachments("@a#b.ts")[1].path, "a#b.ts")
  end,
  ["server:resource is flagged; paths with colons later are not"] = function()
    h.eq(f.find_attachments("@github:repos/x")[1].resource, true)
    h.eq(f.find_attachments("@src/a.ts:12")[1].resource, nil)
  end,
  ["unicode paths keep byte spans"] = function()
    local a = f.find_attachments("ä @dörp/ü.ts")[1]
    h.eq({ a.path, a.start_col, a.end_col }, { "dörp/ü.ts", 3, 15 })
  end,
  ["format quotes only when needed"] = function()
    h.eq(f.attachment("src/a.ts"), "@src/a.ts")
    h.eq(f.attachment("src/my file.ts"), '@"src/my file.ts"')
    h.eq(f.attachment("weird."), '@"weird."')
  end,
  ["format round-trips through find"] = function()
    for _, p in ipairs({ "a.ts", "src/my file.ts", "dir/", "x/y z/ä.md", "end." }) do
      h.eq(paths(f.attachment(p)), { p }, p)
    end
  end,
}
