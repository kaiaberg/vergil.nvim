--- Prompt status data for status lines: vergil draws nothing itself. After
--- each change it stores a table in `b:vergil_status` and fires
--- `User VergilStatus`, so lualine, heirline or a plain 'statusline' can
--- show what they like. Computed with the diagnostics, never on redraw.
local resolver = require("vergil.reference.resolver")
local size = require("vergil.size")

local M = {}

---@class vergil.Status
---@field agent string the buffer's agent, by its name under `agents` ("plain" for none)
---@field attachments integer distinct attached files and directories that exist
---@field attachment_bytes integer their total size (directories count 0)
---@field attachment_tokens integer rough estimate: a third of `attachment_bytes`
---@field mentions integer mentions of files or directories (every occurrence)
---@field missing integer references whose target doesn't exist
---@field to_convert integer bare paths `]f` would visit
---@field outside_root integer references to existing targets outside the root
---@field prompt_tokens integer rough estimate for the prompt text itself
---@field tokens integer `prompt_tokens + attachment_tokens`

--- Computes the status of a session's prompt buffer.
---@param session vergil.Session
---@return vergil.Status
function M.compute(session)
  local bufnr, root = session.bufnr, session.root
  local operator = require("vergil.operator")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fmt = require("vergil.config").options.mention.format
  local by_row, fenced = operator.index(lines, require("vergil.agents").for_buffer(bufnr).attach, fmt)

  -- One stat per distinct path as written, however often it appears.
  local targets = {} ---@type table<string, vergil.Target|false>
  local function resolve(ref)
    if targets[ref.path] == nil then
      targets[ref.path] = resolver.resolve(ref, root) or false
    end
    return targets[ref.path] or nil
  end

  local st = {
    agent = session.agent,
    attachments = 0,
    attachment_bytes = 0,
    attachment_tokens = 0,
    mentions = 0,
    missing = 0,
    to_convert = 0,
    outside_root = 0,
  }
  local attached = {} ---@type table<string, true>
  local bytes = 0
  for row = 0, #lines - 1 do
    local refs = by_row[row] or {}
    for _, ref in ipairs(refs) do
      if not (ref.resource or ref.unterminated or ref.git) then
        local target = resolve(ref)
        -- The same rules as the diagnostics: a fenced attachment counts only
        -- if it exists (`@Override` in code isn't a missing file), and an
        -- inline code span only when it clearly is a path or exists.
        local is_file = ref.mode == "attach" and (not ref.in_fence or target.exists)
          or ref.mode == "mention" and (ref.explicit or target.exists)
        if is_file then
          if not target.exists then
            st.missing = st.missing + 1
          else
            if not target.rel then
              st.outside_root = st.outside_root + 1
            end
            if ref.mode == "mention" then
              st.mentions = st.mentions + 1
            elseif not attached[target.abs] then
              attached[target.abs] = true
              st.attachments = st.attachments + 1
              st.attachment_bytes = st.attachment_bytes + (target.size or 0)
            end
          end
        end
      end
    end
    if not fenced[row + 1] then
      for _, ref in ipairs(operator.bare_refs(lines[row + 1], row, refs, 0, #lines[row + 1], fmt)) do
        -- Most words in prose aren't files: a plain stat rules them out
        -- before the full (normalizing) resolve.
        local p = ref.path
        local plain = p:sub(1, 1) ~= "~" and (p:sub(1, 1) == "/" and p or root .. "/" .. p)
        if not plain or vim.uv.fs_stat(plain) then
          local target = resolve(ref)
          if target and target.exists then
            st.to_convert = st.to_convert + 1
          end
        end
      end
    end
    bytes = bytes + #lines[row + 1] + 1
  end
  st.attachment_tokens = size.tokens(st.attachment_bytes)
  st.prompt_tokens = size.tokens(math.max(bytes - 1, 0))
  st.tokens = st.prompt_tokens + st.attachment_tokens
  return st
end

--- Recomputes a session's status, stores it in `b:vergil_status` and fires
--- `User VergilStatus` (`ev.data = { bufnr, status }`).
---@param session vergil.Session
function M.update(session)
  local bufnr = session.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local st = M.compute(session)
  session.status = st
  vim.b[bufnr].vergil_status = st
  vim.api.nvim_exec_autocmds("User", {
    pattern = "VergilStatus",
    data = { bufnr = bufnr, status = st },
    modeline = false,
  })
end

--- Removes the status from a buffer vergil turned off in.
---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].vergil_status = nil
  end
end

return M
