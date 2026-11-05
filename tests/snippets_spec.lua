local h = require("helpers")
local snippets = require("vergil.snippets")

return {
  ["block: header mention, language and verbatim lines"] = function()
    local block = snippets.block("src/a.ts", 12, 15, { "if (!token) {", "\tthrow x;  ", "}" }, { mention_format = "github", language = "typescript" })
    h.eq(block, { "From `src/a.ts#L12-L15`:", "", "```typescript", "if (!token) {", "\tthrow x;  ", "}", "```" })
  end,
  ["single line uses the single-line format"] = function()
    h.eq(snippets.block("a.lua", 3, 3, { "x" }, { mention_format = "colon", language = "lua" })[1], "From `a.lua:3`:")
  end,
  ["fence grows past backtick runs in the content"] = function()
    h.eq(snippets.fence({ "plain" }), "```")
    h.eq(snippets.fence({ "```lua", "x", "```" }), "````")
    h.eq(snippets.fence({ "a ````` b" }), "``````")
  end,
  ["language from the file name"] = function()
    h.eq(snippets.language("/x/a.py"), "python")
    h.eq(snippets.language("/x/unknown.zzz"), "")
  end,
  ["never an @ reference in the block"] = function()
    for _, line in ipairs(snippets.block("src/a.ts", 1, 2, { "a", "b" }, { mention_format = "github", language = "" })) do
      h.eq(line:find("^@") or line:find("%s@"), nil)
    end
  end,
}
