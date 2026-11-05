--- Claude Code adapter. Everything Claude-specific lives under this directory.

---@class vergil.Adapter
---@field name string
---@field filename_patterns string[] default activation patterns (file name only)
---@field find_attachments fun(line: string): vergil.RawAttachment[]
---@field attachment fun(path: string): string formats an attachment

local format = require("vergil.adapters.claude.format")
local session = require("vergil.adapters.claude.session")

---@type vergil.Adapter
return {
  name = "claude",
  filename_patterns = session.filename_patterns,
  find_attachments = format.find_attachments,
  attachment = format.attachment,
}
