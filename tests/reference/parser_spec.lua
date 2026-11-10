local h = require("helpers")
local parser = require("vergil.reference.parser")

local function parse(text, fmt)
  return parser.parse(vim.split(text, "\n"), h.opts(fmt))
end

local function summary(refs)
  return vim.tbl_map(function(r)
    return r.mode .. ":" .. r.path
  end, refs)
end

return {
  ["the plan's example prompt"] = function()
    local refs = parse(table.concat({
      "Why does this fail when the token expires?",
      "",
      "@src/auth/session.ts",
      "",
      "The check in `src/auth/session.ts#L12-L35` looks wrong to me, and it may be related to:",
      "",
      "From `src/auth/token.ts#L4-L6`:",
      "",
      "```typescript",
      "if (!token) {",
      "```",
    }, "\n"))
    h.eq(summary(refs), { "attach:src/auth/session.ts", "mention:src/auth/session.ts", "mention:src/auth/token.ts" })
    h.eq({ refs[2].start_line, refs[2].end_line, refs[2].text }, { 12, 35, "`src/auth/session.ts#L12-L35`" })
    h.eq(refs[2].span, { start_row = 4, start_col = 13, end_row = 4, end_col = 42 })
  end,
  ["pasted colon and line:column ranges keep their lines"] = function()
    local refs = parse("see `src/a.ts:12`, `src/a.ts:3-9` and `src/a.ts:40:7`", "github")
    h.eq(summary(refs), { "mention:src/a.ts", "mention:src/a.ts", "mention:src/a.ts" })
    h.eq(
      vim.tbl_map(function(r)
        return { r.start_line, r.end_line }
      end, refs),
      { { 12, 12 }, { 3, 9 }, { 40, 40 } }
    )
  end,
  ["a name after a ranged mention belongs to it"] = function()
    h.eq(
      summary(parse("see `a.lua#L3-L9` (`M.apply`) and `b.lua` (`c.lua`)")),
      { "mention:a.lua", "mention:b.lua", "mention:c.lua" }
    )
    h.eq(
      summary(parse("`a.lua#L3` (`x.lua`) `a.lua#L4` `y.lua`")),
      { "mention:a.lua", "mention:a.lua", "mention:y.lua" }
    )
  end,
  ["`name` (branch) is a git branch, not a file"] = function()
    local refs = parse("merge `feature/login` (branch) into `src/a.lua`")
    h.eq({ refs[1].git, refs[1].explicit, refs[2].git }, { "branch", false, nil })
  end,
  ["spans match the source text exactly"] = function()
    local lines = { 'a @x.ts, `y/z.md#L3` @"q r.md" `c.lua` end' }
    for _, r in ipairs(parser.parse(lines, h.opts())) do
      h.eq(lines[1]:sub(r.span.start_col + 1, r.span.end_col), r.text)
    end
  end,
  ["fenced code: attachments flagged, mentions ignored"] = function()
    local refs = parse("```java\n@Override\n`a/b.ts`\n```\n@after.ts")
    h.eq(summary(refs), { "attach:Override", "attach:after.ts" })
    h.eq({ refs[1].in_fence, refs[2].in_fence }, { true, nil })
  end,
  ["fences: tildes, longer closers, indentation"] = function()
    h.eq(parser.fenced_lines({ "~~~", "x", "```", "~~~~", "y" }), { true, true, true, true, false })
    h.eq(parser.fenced_lines({ "````", "```", "````", "z" }), { true, true, true, false })
    h.eq(parser.fenced_lines({ "    ```", "x" }), { false, false })
    h.eq(parser.fenced_lines({ "``` a`b", "x" }), { false, false })
  end,
  ["unclosed fence runs to the end"] = function()
    h.eq(summary(parse("```\n`a/b.ts`")), {})
  end,
  ["mentions: explicit vs maybe-inline-code"] = function()
    local refs = parse("`src/a.ts` `a.ts` `README` `x#L2` `foo()` `a = b` `@x.ts` `` `a/b` ``")
    h.eq(summary(refs), { "mention:src/a.ts", "mention:a.ts", "mention:README", "mention:x" })
    h.eq(
      vim.tbl_map(function(r)
        return r.explicit
      end, refs),
      { true, true, false, true }
    )
  end,
  ["mention with spaces in the path"] = function()
    h.eq(summary(parse("see `src/my file.ts#L1-L2`")), { "mention:src/my file.ts" })
  end,
  ["reversed range is not a mention"] = function()
    h.eq(summary(parse("`a.ts#L9-L3`")), {})
  end,
  ["colon format"] = function()
    local r = parse("`a.ts:4-6`", "colon")[1]
    h.eq({ r.path, r.start_line, r.end_line }, { "a.ts", 4, 6 })
  end,
  ["attachment inside an inline code span is flagged"] = function()
    local refs = parse("`see @a.ts`")
    h.eq(summary(refs), { "attach:a.ts" })
    h.eq(refs[1].in_code, true)
  end,
  ["emails, image placeholders and plain prose produce nothing"] = function()
    h.eq(parse("mail me@example.com about [Image #1] and/or this"), {})
  end,
  ["attachment variants carry their flags"] = function()
    local refs = parse('@a.ts#L1-L2 @srv:res @"half')
    h.eq(refs[1].ignored_range, { 1, 2 })
    h.eq(refs[2].resource, true)
    h.eq(refs[3].unterminated, true)
  end,
  ["at finds the reference under or just after the cursor"] = function()
    local refs = parse("ab @x.ts cd")
    h.eq(parser.at(refs, 0, 3).path, "x.ts")
    h.eq(parser.at(refs, 0, 8).path, "x.ts")
    h.eq(parser.at(refs, 0, 10), nil)
  end,
}
