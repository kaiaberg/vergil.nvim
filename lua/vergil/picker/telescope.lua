--- telescope.nvim picker backend, with file previews.
---
--- Keys: `Enter` inserts the current type, `<C-t>` switches between
--- attachment and mention, `<C-r>` opens line selection for the file.
local M = {}

local TITLES = { attach = "Attach file  (<C-t> mention · <C-r> lines)", mention = "Mention file  (<C-t> attach · <C-r> lines)" }

---@param files string[]
---@param kind "attach"|"mention"
---@param api vergil.PickApi
function M.pick_files(files, kind, api)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values
  local finders = require("telescope.finders")
  local pickers = require("telescope.pickers")
  local state = { kind = kind }

  pickers
    .new({}, {
      prompt_title = TITLES[kind],
      finder = finders.new_table({
        results = files,
        entry_maker = function(path)
          return { value = path, display = path, ordinal = path, path = api.ctx.root .. "/" .. path }
        end,
      }),
      sorter = conf.file_sorter({}),
      previewer = conf.file_previewer({}),
      attach_mappings = function(prompt_bufnr, map)
        local function selected()
          local entry = action_state.get_selected_entry()
          return entry and entry.value
        end
        actions.select_default:replace(function()
          local path = selected()
          actions.close(prompt_bufnr)
          if path then
            vim.schedule(function()
              api.choose(state.kind, path)
            end)
          end
        end)
        map({ "i", "n" }, "<C-t>", function()
          state.kind = state.kind == "attach" and "mention" or "attach"
          local picker = action_state.get_current_picker(prompt_bufnr)
          pcall(function()
            picker.prompt_border:change_title(TITLES[state.kind])
          end)
        end)
        map({ "i", "n" }, "<C-r>", function()
          local path = selected()
          actions.close(prompt_bufnr)
          if path then
            vim.schedule(function()
              api.select_lines(path)
            end)
          end
        end)
        return true
      end,
    })
    :find()
end

---@param skills vergil.Skill[]
---@param api vergil.PickApi
function M.pick_skills(skills, api)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values
  local finders = require("telescope.finders")
  local pickers = require("telescope.pickers")
  local previewers = require("telescope.previewers")
  local contents = require("vergil.skills").contents

  pickers
    .new({}, {
      prompt_title = "Skills and commands",
      finder = finders.new_table({
        results = skills,
        entry_maker = function(s)
          local text = "/" .. s.name .. (s.description and ("  " .. s.description) or "")
          return { value = s, display = text, ordinal = s.name .. " " .. (s.description or "") }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Skill",
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, contents(entry.value, api.ctx.root))
          vim.bo[self.state.bufnr].filetype = "markdown"
          vim.wo[self.state.winid].wrap = true
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            vim.schedule(function()
              api.choose("skills", entry.value)
            end)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
