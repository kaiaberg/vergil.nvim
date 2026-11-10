local h = require("helpers")

local root = h.tree({
  ["src/a.lua"] = table.concat(
    vim.tbl_map(function(i)
      return "line " .. i
    end, vim.fn.range(1, 30)),
    "\n"
  ) .. "\n",
  ["src/tick.md"] = "has ``` fences\n",
  ["bin.dat"] = "ab\0cd\n",
  ["dir/x.txt"] = "",
  ["dir/sub/y.txt"] = "",
})

local function hover(line, col)
  local bufnr, client = h.prompt(root, { line })
  return h.request(client, bufnr, "textDocument/hover", 0, col)
end

local function value(line, col)
  local r = hover(line, col)
  return r and r.contents.value
end

return {
  ["bare path: previewed like a mention, labelled path"] = function()
    local v = value("look at src/a.lua:3 please", 9)
    h.truthy(v:find("· path", 1, true), v)
    h.truthy(v:find("line 3", 1, true), v)
    h.eq(value("look at nothing.lua please", 9), nil)
    h.eq(value("look at it please", 5), nil)
  end,
  ["attachment: header and first lines in a fenced block"] = function()
    local v = value("@src/a.lua", 2)
    h.truthy(v:find("**src/a.lua** · 231 B · 30 lines · attachment", 1, true), v)
    h.truthy(v:find("```lua\nline 1\n", 1, true), v)
    h.truthy(v:find("line 20\n```", 1, true), v)
    h.truthy(v:find("… 10 more lines", 1, true), v)
  end,
  ["mention range shows exactly those lines"] = function()
    local v = value("`src/a.lua#L5-L7`", 3)
    h.truthy(v:find("lines 5–7", 1, true), v)
    h.truthy(v:find("```lua\nline 5\nline 6\nline 7\n```", 1, true), v)
  end,
  ["range past the end is reported"] = function()
    h.truthy(value("`src/a.lua#L40`", 3):find("past the end", 1, true))
    h.truthy(value("`src/a.lua#L29-L35`", 3):find("Range ends past the file", 1, true))
  end,
  ["hover range covers the reference"] = function()
    h.eq(
      hover("see @src/a.lua.", 6).range,
      { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 14 } }
    )
  end,
  ["longer fence when the file contains backticks"] = function()
    h.truthy(value("@src/tick.md", 2):find("````markdown\nhas ``` fences\n````", 1, true))
  end,
  ["missing, binary, directory and resource"] = function()
    h.truthy(value("@nope.ts", 2):find("Not found", 1, true))
    h.truthy(value("@bin.dat", 2):find("Binary file.", 1, true))
    local d = value("@dir/", 2)
    h.truthy(d:find("directory · 2 entries", 1, true), d)
    h.truthy(d:find("- `sub/`\n- `x.txt`", 1, true), d)
    h.truthy(value("@srv:res", 2):find("Resource reference", 1, true))
  end,
  ["no hover on prose or ordinary inline code"] = function()
    h.eq(hover("just words", 2), nil)
    h.eq(hover("call `refresh`", 7), nil)
  end,
}
