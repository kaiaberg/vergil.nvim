--- `vim.ui.select` picker backend: `Enter` only (no type switch or line
--- selection), but works everywhere and with any `vim.ui.select` provider.
local M = {}

---@param files string[]
---@param kind "attach"|"mention"
---@param api vergil.PickApi
---@param opts vergil.PickFilesOpts?
function M.pick_files(files, kind, api, opts)
  opts = opts or {}
  local labels = opts.labels or {}
  vim.ui.select(files, {
    prompt = opts.title or (kind == "mention" and "Mention file" or "Attach file"),
    format_item = function(path)
      return labels[path] and ("%s  (%s)"):format(path, labels[path]) or path
    end,
  }, function(choice)
    if choice then
      api.choose(kind, choice)
    end
  end)
end

---@param skills vergil.Skill[]
---@param api vergil.PickApi
function M.pick_skills(skills, api)
  vim.ui.select(skills, {
    prompt = "Skills and commands",
    format_item = function(s)
      return "/" .. s.name .. (s.description and ("  " .. s.description) or "")
    end,
  }, function(choice)
    if choice then
      api.choose("skills", choice)
    end
  end)
end

return M
