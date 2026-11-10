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
          agents = { x = { match = { "*.md" } } },
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
  ["the removed agent and activation options fail with a pointer"] = function()
    h.errors(function()
      config.set({ agent = "claude" })
    end, "`agent` was removed in 0.4; define your agents under `agents`")
    h.errors(function()
      config.set({ activation = { filename_patterns = { "x" } } })
    end, "`activation` was removed")
    reset()
  end,
  ["agent definitions are checked field by field"] = function()
    local function bad(spec, pattern)
      h.errors(function()
        config.set({ agents = { a = spec } })
      end, pattern)
    end
    bad({}, "agents.a.match must be a list of globs")
    bad({ match = { "x" }, attch = {} }, "agents.a.attch is unknown")
    bad({ match = { "x" }, attach = { quote = '"' } }, "agents.a.attach.prefix must be")
    bad({ match = { "x" }, attach = { prefix = "@", quote = "''" } }, "attach.quote must be one character")
    bad({ match = { "x" }, attach = { prefix = "@", ranges = "kept" } }, 'attach.ranges must be "ignored"')
    bad({ match = { "x" }, skills = { { glob = "x" } } }, 'agents.a.skills%[1%].name must be "dir" or "path"')
    h.errors(function()
      config.set({ agents = { plain = { match = { "x" } } } })
    end, "reserved")
    config.set({ agents = { a = { match = { "x" } }, b = false } })
    h.eq(
      vim.tbl_map(function(a)
        return a.key
      end, require("vergil.agents").list()),
      { "a" },
      "false turns one off"
    )
    reset()
  end,
  ["the README recipes pass setup"] = function()
    config.set({ agents = { claude = h.recipe("claude"), codex = h.recipe("codex") } })
    h.eq(#require("vergil.agents").list(), 2)
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
  ["no agents: a notice once per user, never headless"] = function()
    local file = vim.fn.tempname()
    local old_file, uis = config.notice_file, vim.api.nvim_list_uis
    config.notice_file = file
    local shown = {}
    local notify = vim.notify
    vim.notify = function(msg)
      shown[#shown + 1] = msg
    end
    config.set({ agents = {} })
    config.notice_no_agents()
    h.eq(#shown, 0, "headless")
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    config.notice_no_agents()
    config.notice_no_agents()
    config.set({})
    config.notice_no_agents()
    vim.api.nvim_list_uis, vim.notify, config.notice_file = uis, notify, old_file
    h.eq(#shown, 1, vim.inspect(shown))
    h.truthy(shown[1]:find("no agents are configured", 1, true), shown[1])
    h.truthy(vim.uv.fs_stat(file), "remembered")
  end,
}
