local h = require("helpers")
local bare = require("vergil.reference.bare")

local function at(line, col)
  local c = bare.candidate(line, col, "github")
  return c and { c.path, c.start_line, c.end_line, c.text }
end

return {
  ["the path under the cursor, with its lines"] = function()
    h.eq(at("see src/a.ts:12 now", 6), { "src/a.ts", 12, 12, "src/a.ts:12" })
    h.eq(at("see src/a.ts:3-9 now", 14), { "src/a.ts", 3, 9, "src/a.ts:3-9" })
    h.eq(at("at src/a.ts:40:7", 4), { "src/a.ts", 40, 40, "src/a.ts:40:7" })
    h.eq(at("src/a.ts#L5-L6", 0), { "src/a.ts", 5, 6, "src/a.ts#L5-L6" })
  end,
  ["brackets, quotes and sentence punctuation aren't part of it"] = function()
    h.eq(at("(see src/a.ts).", 6), { "src/a.ts", nil, nil, "src/a.ts" })
    h.eq(at('"src/a.ts", then', 3), { "src/a.ts", nil, nil, "src/a.ts" })
    h.eq(at("in src/a.ts:12:", 5), { "src/a.ts", 12, 12, "src/a.ts:12" })
    h.eq(at("open ~/notes/x.md!", 7), { "~/notes/x.md", nil, nil, "~/notes/x.md" })
  end,
  ["the span covers exactly the path"] = function()
    local c = bare.candidate("(src/a.ts:12).", 3, "github")
    h.eq({ c.start_col, c.end_col }, { 1, 12 })
  end,
  ["a cursor just after it still finds it"] = function()
    h.eq(at("src/a.ts", 8), { "src/a.ts", nil, nil, "src/a.ts" })
    h.eq(at("src/a.ts here", 8), { "src/a.ts", nil, nil, "src/a.ts" })
  end,
  ["nothing on blanks, punctuation or attachments"] = function()
    h.eq(at("a  b", 2), nil)
    h.eq(at("...", 1), nil)
    h.eq(at("", 0), nil)
    h.eq(at("@src/a.ts", 3), nil)
  end,
}
