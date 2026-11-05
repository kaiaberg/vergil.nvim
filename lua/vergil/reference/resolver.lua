--- Resolves reference paths against the session root.
local M = {}

local uv = vim.uv

--- Absolute, normalized path. Handles `./a`, `a`, `~/a`, `../a` and absolute.
---@param path string
---@param root string
---@return string
function M.absolute(path, root)
  if path:sub(1, 1) == "~" then
    return vim.fs.normalize(path)
  end
  if path:sub(1, 1) == "/" then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(root, path))
end

--- Path relative to the root, or nil when outside it.
---@param path string
---@param root string
---@return string?
function M.relative(path, root)
  local abs = M.absolute(path, root)
  local norm_root = vim.fs.normalize(root)
  if abs == norm_root then
    return "."
  end
  return vim.fs.relpath(norm_root, abs)
end

--- Key for comparing references: equal keys mean the same target.
--- A trailing slash (directory) doesn't change the target.
---@param path string
---@param root string
---@return string
function M.key(path, root)
  return (M.absolute(path, root):gsub("(.)/$", "%1"))
end

---@class vergil.Target
---@field abs string
---@field rel string? relative to the root, nil when outside it
---@field exists boolean
---@field type "file"|"directory"|"other"|nil
---@field size integer? bytes, files only

--- Looks up a reference's target on disk. Resource attachments
--- (`@server:resource`) are not files and resolve to nil.
---@param ref vergil.Reference
---@param root string
---@return vergil.Target?
function M.resolve(ref, root)
  if ref.resource then
    return nil
  end
  local abs = M.absolute(ref.path, root)
  local st = uv.fs_stat(abs)
  local type = st and (st.type == "file" and "file" or st.type == "directory" and "directory" or "other") or nil
  return {
    abs = abs,
    rel = M.relative(ref.path, root),
    exists = st ~= nil,
    type = type,
    size = st and st.type == "file" and st.size or nil,
  }
end

--- Number of lines in a file, or nil if it can't be read.
--- Counts like Neovim: a final line without a newline still counts.
---@param abs string
---@return integer?
function M.line_count(abs)
  local fd = io.open(abs, "rb")
  if not fd then
    return nil
  end
  local count, last = 0, nil
  while true do
    local chunk = fd:read(65536)
    if not chunk then
      break
    end
    local _, n = chunk:gsub("\n", "")
    count = count + n
    last = chunk:sub(-1)
  end
  fd:close()
  if last and last ~= "\n" then
    count = count + 1
  end
  return count
end

return M
