--- `:Vergil diff [staged|<rev>]`: inserts `git diff` below the cursor line
--- as a fenced `diff` block, headed by the command that produced it.
local M = {}

--- Inserts the diff into the current prompt buffer.
---@param what string? nil: all uncommitted changes; "staged"; or a revision or range
---@return boolean ok
---@return string? err
function M.insert(what)
  local bufnr = vim.api.nvim_get_current_buf()
  local session = require("vergil.session").get(bufnr)
  if not session then
    return false, "not enabled in this buffer (use :Vergil enable)"
  end
  local lines, err, command = require("vergil.git").diff(session.root, what)
  if not lines then
    return false, err
  end
  if #lines == 0 then
    return false, ("no changes (%s)"):format(command)
  end
  local fence = require("vergil.snippets").fence(lines)
  local block = { ("Output of `%s`:"):format(command), "", fence .. "diff" }
  vim.list_extend(block, lines)
  block[#block + 1] = fence

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local after = require("vergil.range").insert_block(bufnr, row, block)
  vim.api.nvim_win_set_cursor(0, { math.min(after, vim.api.nvim_buf_line_count(bufnr)), 0 })

  local bytes = #table.concat(lines, "\n")
  local tokens = math.floor(bytes / 3)
  if tokens > require("vergil.config").options.diagnostics.attachment_token_warning then
    vim.notify(
      ("vergil: inserted a large diff (~%dk tokens); consider attaching or mentioning the files instead"):format(
        math.floor(tokens / 1000)
      ),
      vim.log.levels.WARN
    )
  end
  return true
end

return M
