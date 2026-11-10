local h = require("helpers")
local fmt = require("vergil.reference.formatter")

return {
  ["github preset"] = function()
    h.eq(fmt.mention("src/a.ts", nil, nil, "github"), "`src/a.ts`")
    h.eq(fmt.mention("src/a.ts", 12, 12, "github"), "`src/a.ts#L12`")
    h.eq(fmt.mention("src/a.ts", 12, 35, "github"), "`src/a.ts#L12-L35`")
  end,
  ["colon preset"] = function()
    h.eq(fmt.mention("a.ts", 12, 35, "colon"), "`a.ts:12-35`")
    h.eq(fmt.mention("a.ts", 7, 7, "colon"), "`a.ts:7`")
  end,
  ["custom template"] = function()
    local t = { single = "{path} line {start}", range = "{path} lines {start} to {end}" }
    h.eq(fmt.mention("a.ts", 3, 9, t), "`a.ts lines 3 to 9`")
    h.eq({ fmt.parse_mention("a.ts lines 3 to 9", t) }, { "a.ts", 3, 9 })
  end,
  ["every preset round-trips"] = function()
    for name in pairs(fmt.presets) do
      for _, p in ipairs({ "a.ts", "src/my file.ts", "a#b/c.ts", "x:y/z.lua", "100%.md" }) do
        for _, r in ipairs({ { nil, nil }, { 4, 4 }, { 4, 90 } }) do
          local text = fmt.mention(p, r[1], r[2], name)
          h.eq({ fmt.parse_mention(text:sub(2, -2), name) }, { p, r[1], r[2] }, name .. " " .. text)
        end
      end
    end
  end,
  ["other presets' ranges are read too"] = function()
    h.eq({ fmt.parse_mention("src/a.ts:12", "github") }, { "src/a.ts", 12, 12 })
    h.eq({ fmt.parse_mention("src/a.ts:12-30", "github") }, { "src/a.ts", 12, 30 })
    h.eq({ fmt.parse_mention("src/a.ts#L12-L30", "colon") }, { "src/a.ts", 12, 30 })
    local t = { single = "{path} line {start}", range = "{path} lines {start} to {end}" }
    h.eq({ fmt.parse_mention("a.ts:4", t) }, { "a.ts", 4, 4 })
  end,
  ["line and column read as the line"] = function()
    h.eq({ fmt.parse_mention("src/a.ts:12:5", "github") }, { "src/a.ts", 12, 12 })
    h.eq({ fmt.parse_mention("src/a.ts:12:5", "colon") }, { "src/a.ts", 12, 12 })
  end,
  ["the configured format wins"] = function()
    -- `#L4` is a literal part of the path in a format that doesn't use it,
    -- only when the configured format itself matches first.
    local t = { single = "{path}@{start}", range = "{path}@{start}-{end}" }
    h.eq({ fmt.parse_mention("a#L4.ts@7", t) }, { "a#L4.ts", 7, 7 })
  end,
  ["plain content parses as path without range"] = function()
    h.eq({ fmt.parse_mention("src/a.ts", "github") }, { "src/a.ts" })
  end,
  ["path with a backtick can't be a mention"] = function()
    h.eq({ fmt.mention("a`b", nil, nil, "github") }, { nil, "path contains a backtick" })
  end,
  ["invalid templates are rejected"] = function()
    h.errors(function()
      fmt.compile("nope")
    end, "mention.format")
    h.errors(function()
      fmt.compile({ single = "{path}", range = "{path}-{end}" })
    end, "needs {start}")
    h.errors(function()
      fmt.compile({ single = "{start}:{path}", range = "{path}:{start}-{end}" })
    end, "start with {path}")
    h.errors(function()
      fmt.compile({ single = "{path}{start}", range = "{path}:{start}-{end}" })
    end, "separator")
    h.errors(function()
      fmt.compile({ single = "{path}:{line}", range = "{path}:{start}-{end}" })
    end, "unknown field")
    h.errors(function()
      fmt.compile({ single = "{path}:{start}", range = "{path}:{end}-{start}" })
    end, "before {end}")
  end,
  ["attachment uses the agent's syntax"] = function()
    h.eq(fmt.attachment("my file", h.opts().attach), '@"my file"')
    h.eq(fmt.attachment("my file", { prefix = "+", strip = "" }), nil, "needs a quote it doesn't have")
  end,
}
