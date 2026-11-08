--- Centered floating windows.
local M = {}

-- 'winborder' values without a top edge, which can't carry a title.
local NO_TITLE = { [""] = true, none = true, shadow = true }

--- The border for vergil's floats: nil, so the user's 'winborder' applies,
--- unless it has no top edge to put a title on; then "rounded".
---@return string?
function M.border()
  return NO_TITLE[vim.o.winborder] and "rounded" or nil
end

---@class vergil.FloatOpts
---@field width number fraction of the editor width (0-1)
---@field height number fraction of the editor height (0-1)
---@field title string?
---@field footer string?

--- Opens a centered, focused float for a buffer.
---@param bufnr integer
---@param opts vergil.FloatOpts
---@return integer win
function M.open(bufnr, opts)
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(20, math.floor(cols * opts.width))
  local height = math.max(5, math.floor(lines * opts.height))
  local config = {
    relative = "editor",
    width = math.min(width, cols - 2),
    height = math.min(height, lines - 3),
    row = math.max(0, math.floor((lines - height) / 2) - 1),
    col = math.max(0, math.floor((cols - width) / 2)),
    style = "minimal",
    border = M.border(),
    title = opts.title,
    title_pos = opts.title and "center" or nil,
    footer = opts.footer,
    footer_pos = opts.footer and "center" or nil,
  }
  return vim.api.nvim_open_win(bufnr, true, config)
end

return M
