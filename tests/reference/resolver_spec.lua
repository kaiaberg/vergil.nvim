local h = require("helpers")
local resolver = require("vergil.reference.resolver")

return {
  ["normalizes relative, dot, home and absolute forms"] = function()
    h.eq(resolver.absolute("a.ts", "/r"), "/r/a.ts")
    h.eq(resolver.absolute("./a.ts", "/r"), "/r/a.ts")
    h.eq(resolver.absolute("x/../a.ts", "/r"), "/r/a.ts")
    h.eq(resolver.absolute("/abs/a.ts", "/r"), "/abs/a.ts")
    h.eq(resolver.absolute("~/a.ts", "/r"), vim.fs.normalize("~/a.ts"))
  end,
  ["equal keys for the same target"] = function()
    local k = resolver.key("a.ts", "/r")
    h.eq(resolver.key("./a.ts", "/r"), k)
    h.eq(resolver.key("/r/a.ts", "/r"), k)
    h.eq(resolver.key("src/", "/r"), resolver.key("src", "/r"))
  end,
  ["relative path, or nil outside the root"] = function()
    h.eq(resolver.relative("/r/a/b.ts", "/r"), "a/b.ts")
    h.eq(resolver.relative("../x.ts", "/r/sub"), nil)
  end,
  ["resolve reports existence, type and size"] = function()
    local root = h.tree({ ["a.ts"] = "12345", ["dir/x"] = "" })
    local function res(path, extra) return resolver.resolve(vim.tbl_extend("force", { path = path }, extra or {}), root) end
    local f = res("a.ts")
    h.eq({ f.exists, f.type, f.size, f.rel }, { true, "file", 5, "a.ts" })
    local d = res("dir/")
    h.eq({ d.exists, d.type, d.size }, { true, "directory", nil })
    h.eq(res("missing.ts").exists, false)
    h.eq(res("srv:x", { resource = true }), nil)
  end,
  ["line_count matches Neovim's view"] = function()
    local root = h.tree({ a = "1\n2\n3\n", b = "1\n2", c = "" })
    h.eq(resolver.line_count(root .. "/a"), 3)
    h.eq(resolver.line_count(root .. "/b"), 2)
    h.eq(resolver.line_count(root .. "/c"), 0)
    h.eq(resolver.line_count(root .. "/missing"), nil)
  end,
}
