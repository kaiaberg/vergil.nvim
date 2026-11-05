--- In-process LSP server, started with `vim.lsp.start` and a Lua `cmd`.
---
--- The server reads prompt buffers directly: it runs inside the same Neovim,
--- and the buffer is the source of truth (plan §7.3). Document sync is only
--- used as a signal to revalidate. Positions are byte columns
--- (`positionEncoding = utf-8`), matching the parser's spans.
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
  ["textDocument/codeAction"] = function(params, session)
    return require("vergil.lsp.code_actions").handle(params, session)
  end,
}

--- Running server instances, for pushing diagnostics outside of requests,
--- with the documents each one has open: publishing through an instance that
--- doesn't own a document would duplicate its diagnostics under another client.
local instances = {} ---@type table<table, { dispatchers: vim.lsp.rpc.Dispatchers, uris: table<string, boolean> }>

local function publish(dispatchers, uri)
  local session = require("vergil.session").get(vim.uri_to_bufnr(uri))
  local diags = {}
  if session then
    local ok, res = pcall(require("vergil.lsp.diagnostics").compute, session)
    diags = ok and res or {}
  end
  dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diags })
end

--- Revalidates a prompt buffer, e.g. after returning to it.
---@param bufnr integer
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local uri = vim.uri_from_bufnr(bufnr)
  for _, inst in pairs(instances) do
    if inst.uris[uri] then
      publish(inst.dispatchers, uri)
    end
  end
end

--- Handlers that answer through `respond` (possibly later) instead of returning.
local async = { ["textDocument/completion"] = true }

local function capabilities()
  return {
    positionEncoding = "utf-8",
    textDocumentSync = { openClose = true, change = 1 },
    completionProvider = { triggerCharacters = require("vergil.lsp.completion").trigger_characters() },
    hoverProvider = true,
    definitionProvider = true,
    codeActionProvider = { codeActionKinds = { "quickfix", "refactor.rewrite" } },
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
  local open_uris = {}
  instances[srv] = { dispatchers = dispatchers, uris = open_uris }

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
    elseif method == "textDocument/didOpen" or method == "textDocument/didChange" then
      local uri = params.textDocument.uri
      open_uris[uri] = true
      vim.schedule(function()
        if not closing then
          publish(dispatchers, uri)
        end
      end)
    elseif method == "textDocument/didClose" then
      open_uris[params.textDocument.uri] = nil
      dispatchers.notification("textDocument/publishDiagnostics", { uri = params.textDocument.uri, diagnostics = {} })
    elseif method == "exit" then
      closing = true
      instances[srv] = nil
      dispatchers.on_exit(0, 15)
    end
    return true
  end

  function srv.is_closing()
    return closing
  end

  function srv.terminate()
    closing = true
    instances[srv] = nil
  end

  return srv
end

return M
