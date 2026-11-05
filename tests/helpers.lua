local M = {}

function M.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error((msg and (msg .. ": ") or "") .. vim.inspect(actual) .. "\n  ~= expected " .. vim.inspect(expected), 2)
  end
end

function M.truthy(v, msg)
  if not v then
    error(msg or "expected a truthy value", 2)
  end
end

function M.errors(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("expected an error", 2)
  end
  if pattern and not tostring(err):find(pattern) then
    error(("error %q doesn't match %q"):format(tostring(err), pattern), 2)
  end
end

--- Parse options with the Claude adapter and a given mention format.
function M.opts(fmt)
  return { adapter = require("vergil.adapters.claude"), mention_format = fmt or "github" }
end

--- A temporary directory tree: files = { ["a/b.ts"] = "content" }.
function M.tree(files)
  local root = vim.fs.normalize(vim.fn.tempname())
  for rel, content in pairs(files) do
    local abs = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(abs), "p")
    if rel:sub(-1) ~= "/" then
      local fd = assert(io.open(abs, "wb"))
      fd:write(content)
      fd:close()
    end
  end
  return root
end

--- A fresh scratch buffer with a name and lines, made current.
function M.buffer(name, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

return M
