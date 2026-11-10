local h = require("helpers")
local status = require("vergil.status")
local size = require("vergil.size")

local root = h.tree({
  ["src/a.lua"] = string.rep("x", 300) .. "\n", -- 301 bytes
  ["src/b.lua"] = string.rep("y", 899) .. "\n", -- 900 bytes
  ["dir/x.txt"] = "",
})
local outside = h.tree({ ["o.txt"] = "out\n" })

local function compute(lines)
  local b = h.prompt(root, lines, "status")
  return status.compute(require("vergil.session").get(b)), b
end

return {
  ["counts attachments once, with their size and tokens"] = function()
    local st = compute({ "@src/a.lua @src/b.lua and @src/a.lua again, @dir/" })
    h.eq({ st.attachments, st.attachment_bytes, st.attachment_tokens }, { 3, 1201, 400 })
  end,
  ["mentions, missing files, outside the root"] = function()
    local st = compute({
      "`src/a.lua#L1` and `src/a.lua` and `refresh`",
      "@missing.lua `gone/file.lua` @" .. outside .. "/o.txt",
    })
    h.eq({ st.mentions, st.missing, st.outside_root }, { 2, 2, 1 })
  end,
  ["fenced attachments count only when the file exists"] = function()
    local st = compute({ "```java", "@Override", "@src/a.lua", "```" })
    h.eq({ st.attachments, st.missing }, { 1, 0 })
  end,
  ["to_convert counts the bare paths ]f would visit"] = function()
    local st = compute({ "see src/a.lua:1 and nope.lua, `src/b.lua`", "```", "src/b.lua", "```", "dir/x.txt" })
    h.eq(st.to_convert, 2)
  end,
  ["prompt and total tokens"] = function()
    local st = compute({ string.rep("w", 29), string.rep("v", 29) }) -- 59 bytes
    h.eq({ st.prompt_tokens, st.attachment_tokens, st.tokens }, { 19, 0, 19 })
    st = compute({ "@src/b.lua" }) -- 10 bytes
    h.eq({ st.prompt_tokens, st.tokens }, { 3, 303 })
  end,
  ["the agent's name"] = function()
    h.eq(compute({ "" }).agent, "claude")
  end,
  ["b:vergil_status and User VergilStatus follow edits; cleared on disable"] = function()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "VergilStatus",
      callback = function(ev)
        seen[#seen + 1] = ev.data.status.attachments
      end,
    })
    local b = h.prompt(root, { "@src/a.lua" }, "status-live")
    h.truthy(
      vim.wait(2000, function()
        return vim.b[b].vergil_status and vim.b[b].vergil_status.attachments == 1
      end),
      "set after open"
    )
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "@src/a.lua @src/b.lua" })
    h.truthy(
      vim.wait(2000, function()
        return vim.b[b].vergil_status.attachments == 2
      end),
      "updated after a change"
    )
    h.eq(require("vergil").status(b).attachments, 2)
    h.eq(seen[#seen], 2)
    vim.api.nvim_del_autocmd(id)
    require("vergil").disable(b)
    h.eq(vim.b[b].vergil_status, nil)
    h.eq(require("vergil").status(b), nil)
  end,
  ["format_size"] = function()
    local f = require("vergil").format_size
    h.eq({ f(0), f(1023), f(1024), f(1536), f(1024 * 1024 * 3), f(1024 ^ 3 * 2) }, {
      "0 B",
      "1023 B",
      "1.0 KB",
      "1.5 KB",
      "3.0 MB",
      "2.0 GB",
    })
    h.eq(size.tokens(10), 3)
  end,
}
