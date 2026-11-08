local h = require("helpers")
local config = require("vergil.config")

--- Runs `fn` and returns the warnings it sent through vim.notify.
local function warnings(fn)
  local out, notify = {}, vim.notify
  vim.notify = function(msg, level)
    if level == vim.log.levels.WARN then
      out[#out + 1] = msg
    end
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return out
end

local function reset()
  config.set({})
end

return {
  ["unknown options are reported, known and nil-default ones aren't"] = function()
    h.eq(
      warnings(function()
        config.set({
          root = "/tmp",
          files = { command = { "fd" } },
          activation = { filename_patterns = { "*.md" } },
          picker = { keys = { anything = { "<C-x>" } }, tabs = { "files" } },
          diagnostics = { severity = { large = false } },
        })
      end),
      {}
    )
    h.eq(
      warnings(function()
        config.set({ keymap = { preset = true }, picker = { tab = {} }, diagnostics = { severity = { lage = "info" } } })
      end),
      {
        "vergil: unknown options diagnostics.severity.lage, keymap, picker.tab (see :help vergil-config)",
      }
    )
    h.eq(config.unknown({ selector = { keys = { mentoin = "x" } } }), { "selector.keys.mentoin" })
    h.eq(
      warnings(function()
        config.set({ keymap = {} }, true)
      end),
      {},
      "quiet"
    )
    reset()
  end,
  ["an unknown agent fails at setup"] = function()
    h.eq(vim.tbl_contains(config.agents(), "claude"), true)
    h.errors(function()
      config.set({ agent = "nope" })
    end, 'unknown agent "nope"; expected claude')
    reset()
  end,
  ["booleans and selector keys are type-checked"] = function()
    for _, opts in ipairs({
      { completion = { native = "yes" } },
      { completion = { reopen_on_backspace = 1 } },
      { keymaps = { preset = "true" } },
    }) do
      h.errors(function()
        config.set(opts)
      end)
    end
    h.errors(function()
      config.set({ selector = { keys = { mention = 1 } } })
    end, "selector.keys.mention must be a key")
    h.errors(function()
      config.set({ selector = { keys = { cancel = "q" } } })
    end, "selector.keys.cancel must be a list")
    h.errors(function()
      config.set({ selector = { keys = { cancel = {} } } })
    end, "selector.keys.cancel must be a list")
    config.set({ selector = { keys = { mention = "<Tab>", cancel = { "q" } } } })
    reset()
  end,
}
