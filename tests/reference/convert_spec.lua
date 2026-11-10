local h = require("helpers")
local parser = require("vergil.reference.parser")
local convert = require("vergil.reference.convert")

local function toggle_text(line, fmt)
  local ref = parser.parse({ line }, h.opts(fmt))[1]
  local edit, err = convert.toggle(ref, h.opts(fmt))
  if not edit then
    return nil, err
  end
  local s = edit.span
  return line:sub(1, s.start_col) .. edit.text .. line:sub(s.end_col + 1)
end

return {
  ["every direction in plan §6.5"] = function()
    h.eq(toggle_text("see @src/a.ts now"), "see `src/a.ts` now")
    h.eq(toggle_text("see `src/a.ts` now"), "see @src/a.ts now")
    h.eq(toggle_text("see `src/a.ts#L12-L35` now"), "see @src/a.ts `src/a.ts#L12-L35` now")
  end,
  ["attachment with ignored range becomes a ranged mention"] = function()
    h.eq(toggle_text("@a.ts#L3-L4"), "`a.ts#L3-L4`")
    h.eq(toggle_text("@a.ts#L3-L4", "colon"), "`a.ts:3-4`")
  end,
  ["punctuation and quoting survive"] = function()
    h.eq(toggle_text("(see @a.ts), ok"), "(see `a.ts`), ok")
    h.eq(toggle_text('@"my f.ts" x'), "`my f.ts` x")
    h.eq(toggle_text("`my f.ts` x"), '@"my f.ts" x')
  end,
  ["toggling twice restores the original"] = function()
    for _, line in ipairs({ "a @src/x.ts b", "a `src/x.ts` b", '@"q r.md"' }) do
      h.eq(toggle_text(toggle_text(line)), line)
    end
  end,
  ["to an attachment needs an agent with attachments"] = function()
    local ref = parser.parse({ "`a.ts`" }, h.opts())[1]
    h.eq({ convert.toggle(ref, { mention_format = "github" }) }, { nil, "this agent has no attachments" })
  end,
  ["refuses resources and unterminated quotes"] = function()
    h.eq({ toggle_text("@srv:res") }, { nil, "not a file reference" })
    h.eq({ toggle_text('@"half') }, { nil, "unterminated quoted path" })
  end,
  ["apply replaces exactly the span"] = function()
    local bufnr = h.buffer("convert-apply.md", { "keep  @a.ts\t trailing  ", "line two" })
    local ref = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), h.opts())[1]
    convert.apply(bufnr, assert(convert.toggle(ref, h.opts())))
    h.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "keep  `a.ts`\t trailing  ", "line two" })
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end,
}
