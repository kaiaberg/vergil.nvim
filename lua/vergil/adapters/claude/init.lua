--- Claude Code adapter. Everything Claude-specific lives under this directory.

---@class vergil.Adapter
---@field name string
---@field display_name string? shown in :checkhealth
---@field executable string? the agent's command, for :checkhealth
---@field verified_version string? agent version vergil's assumptions were last checked against
---@field filename_patterns string[] default activation patterns (file name only)
---@field find_attachments fun(line: string): vergil.RawAttachment[]
---@field attachment fun(path: string): string formats an attachment
---@field discover_skills? fun(root: string): vergil.Skill[]

local format = require("vergil.adapters.claude.format")
local session = require("vergil.adapters.claude.session")
local skills = require("vergil.adapters.claude.skills")

---@type vergil.Adapter
return {
  name = "claude",
  display_name = "Claude Code",
  executable = "claude",
  verified_version = require("vergil.adapters.claude.verified"),
  filename_patterns = session.filename_patterns,
  find_attachments = format.find_attachments,
  attachment = format.attachment,
  discover_skills = skills.discover,
}
