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

--- Opens `claude-prompt-<name>.md` under `root` as the session root, with
--- the plugin loaded, and returns its buffer and vergil LSP client.
local prompt_count = 0
function M.prompt(root, lines, name)
  M.load_plugin()
  require("vergil").setup({ root = root })
  prompt_count = prompt_count + 1
  vim.cmd.edit(vim.fn.fnameescape(("%s/claude-prompt-%s%d.md"):format(root, name or "t", prompt_count)))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  local client
  vim.wait(2000, function()
    client = vim.lsp.get_clients({ bufnr = bufnr, name = "vergil" })[1]
    return client ~= nil and client.initialized
  end)
  assert(client, "vergil client did not attach")
  return bufnr, client
end

function M.load_plugin()
  if not vim.g.loaded_vergil then
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    vim.cmd.source(root .. "/plugin/vergil.lua")
  end
end

--- Sends a request and waits for its result.
function M.request(client, bufnr, method, row, col, context)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = col },
    context = context,
  }
  local res = client:request_sync(method, params, 3000, bufnr)
  assert(res, method .. " timed out")
  assert(not res.err, vim.inspect(res.err))
  return res.result
end

--- Labels of a completion result.
function M.labels(result)
  return vim.tbl_map(function(i)
    return i.label
  end, result.items)
end

return M
