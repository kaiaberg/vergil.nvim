local h = require("helpers")
local fm = require("vergil.frontmatter")

local function parse(text)
  return fm.parse(vim.split(text, "\n"))
end

local function fields(text)
  return (parse(text))
end

return {
  ["plain, quoted and boolean values"] = function()
    local f, body = parse(
      "---\nname: x\ndescription: \"Say \\\"hi\\\"\\nnow\"\nother: 'it''s'\nuser-invocable: false\ndisable-model-invocation: true\n---\nbody"
    )
    h.eq(f, {
      name = "x",
      description = 'Say "hi"\nnow',
      other = "it's",
      ["user-invocable"] = false,
      ["disable-model-invocation"] = true,
    })
    h.eq(body, { "body" })
  end,
  ["folded and literal block scalars with chomping"] = function()
    h.eq(
      fields("---\nd: >\n  Folded block\n  scalar text.\n\n  New para.\n---").d,
      "Folded block scalar text.\nNew para.\n"
    )
    h.eq(fields("---\nd: >-\n  a\n  b\n---").d, "a b")
    h.eq(fields("---\nd: |\n  line 1\n    indented\n---").d, "line 1\n  indented\n")
    h.eq(fields("---\nd: |-\n  x\nnext: y\n---"), { d = "x", next = "y" })
  end,
  ["multi-line plain values fold into one line"] = function()
    h.eq(
      fields("---\ndescription: first part\n  second part\nname: n\n---"),
      { description = "first part second part", name = "n" }
    )
  end,
  ["lists, comments and unknown lines don't break other keys"] = function()
    local f = parse("---\n# comment\nallowed-tools:\n  - Read\n  - Bash\ndescription: kept # trailing comment\n---")
    h.eq(f.description, "kept")
  end,
  ["no frontmatter or an unclosed one: everything is body"] = function()
    local f, body = parse("Just text\nmore")
    h.eq({ f, body }, { {}, { "Just text", "more" } })
    f, body = parse("---\nname: x\nno close")
    h.eq({ f, #body }, { {}, 3 })
  end,
  ["first_line fallback strips heading markers"] = function()
    h.eq(fm.first_line({ "", "# Heading", "text" }), "Heading")
    h.eq(fm.first_line({ "Plain command. Second sentence.", "", "Next" }), "Plain command. Second sentence.")
    h.eq(fm.first_line({ "", "  " }), nil)
  end,
}
