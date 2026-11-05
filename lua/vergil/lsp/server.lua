--- In-process LSP server, started with `vim.lsp.start` and a Lua `cmd`.
---
--- The server reads prompt buffers directly instead of tracking document
--- sync: it runs inside the same Neovim, and the buffer is the source of
--- truth (plan §7.3). Positions are byte columns (`positionEncoding = utf-8`),
--- matching the parser's spans.
local M = {}

M.name = "vergil"

local ERR_METHOD_NOT_FOUND = -32601
local ERR_INTERNAL = -32603
local ERR_CANCELLED = -32800

local function session_for(params)
  local uri = params and params.textDocument and params.textDocument.uri
  if not uri then
    return nil
  end
  local bufnr = vim.uri_to_bufnr(uri)
  return require("vergil.session").get(bufnr)
end

--- Request handlers: `handler(params, session, respond)`. Synchronous
--- handlers return their result instead of calling `respond`.
local handlers = {
  ["textDocument/completion"] = function(params, session, respond)
    require("vergil.lsp.completion").handle(params, session, respond)
  end,
  ["textDocument/hover"] = function(params, session)
    return require("vergil.lsp.hover").handle(params, session)
  end,
  ["textDocument/definition"] = function(params, session)
    return require("vergil.lsp.definition").handle(params, session)
  end,
}

--- Handlers that answer through `respond` (possibly later) instead of returning.
local async = { ["textDocument/completion"] = true }

local function capabilities()
  return {
    positionEncoding = "utf-8",
    textDocumentSync = { openClose = false, change = 0 },
    completionProvider = { triggerCharacters = require("vergil.lsp.completion").trigger_characters() },
    hoverProvider = true,
    definitionProvider = true,
  }
end

--- The `cmd` function for `vim.lsp.start`.
---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.cmd(dispatchers)
  local closing = false
  local next_id = 0
  local pending = {} ---@type table<integer, fun(err: table?, result: any)>

  local srv = {}

  function srv.request(method, params, callback)
    next_id = next_id + 1
    local id = next_id
    if closing then
      return false
    end
    local done = false
    local function reply(err, result)
      if done then
        return
      end
      done = true
      pending[id] = nil
      callback(err, result)
    end
    pending[id] = reply

    if method == "initialize" then
      reply(nil, { capabilities = capabilities(), serverInfo = { name = M.name } })
    elseif method == "shutdown" then
      reply(nil, nil)
    elseif handlers[method] then
      local session = session_for(params)
      if not session then
        reply(nil, nil)
      else
        local ok, result = pcall(handlers[method], params, session, function(res)
          reply(nil, res)
        end)
        if not ok then
          reply({ code = ERR_INTERNAL, message = "vergil: " .. tostring(result) }, nil)
        elseif not async[method] then
          reply(nil, result)
        end
      end
    else
      reply({ code = ERR_METHOD_NOT_FOUND, message = "vergil: unsupported method " .. method }, nil)
    end
    return true, id
  end

  function srv.notify(method, params)
    if method == "$/cancelRequest" and params and pending[params.id] then
      pending[params.id]({ code = ERR_CANCELLED, message = "cancelled" }, nil)
    elseif method == "exit" then
      closing = true
      dispatchers.on_exit(0, 15)
    end
    return true
  end

  function srv.is_closing()
    return closing
  end

  function srv.terminate()
    closing = true
  end

  return srv
end

return M
