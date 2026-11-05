local h = require("helpers")
local adapter_skills = require("vergil.adapters.claude.skills")

local home = h.tree({ [".claude/skills/girl-dinner/SKILL.md"] = "---\ndescription: Dinner helper\n---\n" })
local root = h.tree({
  [".claude/skills/review-auth/SKILL.md"] = "---\ndescription: Review auth code\nargument-hint: \"[file]\"\n---\nbody\n",
  [".claude/commands/diffsum.md"] = "---\ndescription: Summarise the diff\n---\n",
  ["src/a.ts"] = "",
})

local function with_env(fn)
  local old_home, old_managed = adapter_skills.home, adapter_skills.managed_dirs
  adapter_skills.home, adapter_skills.managed_dirs = home, {}
  local ok, err = pcall(fn)
  adapter_skills.home, adapter_skills.managed_dirs = old_home, old_managed
  if not ok then error(err, 0) end
end

local function complete(line, col)
  local bufnr, client = h.prompt(root, { line }, "skills")
  return h.request(client, bufnr, "textDocument/completion", 0, col or #line)
end

return {
  ["/ lists skills and commands with origin, hint and description"] = function()
    with_env(function()
      local res = complete("/")
      h.eq(h.labels(res), { "/diffsum", "/girl-dinner", "/review-auth" })
      local item = res.items[3]
      h.eq(item.labelDetails, { detail = " [file]", description = "project skill" })
      h.eq(item.textEdit.newText, "/review-auth ")
      h.eq(item.kind, 14, "Keyword: Function would get auto-brackets")
      h.truthy(item.documentation.value:find("Review auth code", 1, true))
    end)
  end,
  ["/ mid-prompt after whitespace, fuzzy"] = function()
    with_env(function()
      h.eq(complete("then run /rev").items[1].label, "/review-auth")
    end)
  end,
  ["no skill completion in paths, after a second / or in fences"] = function()
    with_env(function()
      h.eq(complete("and/or").items, {})
      h.eq(complete("/usr/").items, {})
      local bufnr, client = h.prompt(root, { "```", "/" }, "skills")
      h.eq(h.request(client, bufnr, "textDocument/completion", 1, 1).items, {})
    end)
  end,
  ["@ still completes files"] = function()
    with_env(function()
      h.eq(complete("@src/").items[1].label, "src/a.ts")
    end)
  end,
  ["extra items from config, without overriding discovered names"] = function()
    with_env(function()
      require("vergil").setup({ root = root, skills = { extra_items = { { name = "/compact", description = "Summarize" }, { name = "diffsum", description = "ignored" } } } })
      local bufnr, client = h.prompt(root, { "/" }, "skills")
      require("vergil").setup({ root = root, skills = { extra_items = { { name = "/compact", description = "Summarize" }, { name = "diffsum", description = "ignored" } } } })
      local res = h.request(client, bufnr, "textDocument/completion", 0, 1)
      local labels = h.labels(res)
      h.truthy(vim.tbl_contains(labels, "/compact"))
      h.eq(#vim.tbl_filter(function(l) return l == "/diffsum" end, labels), 1)
      require("vergil").setup({ root = root })
    end)
  end,
  ["hover and definition on a /skill in the text"] = function()
    with_env(function()
      local bufnr, client = h.prompt(root, { "please /review-auth src/a.ts" }, "skills")
      local hv = h.request(client, bufnr, "textDocument/hover", 0, 10)
      h.truthy(hv.contents.value:find("**/review-auth** `[file]`", 1, true), hv.contents.value)
      h.truthy(hv.contents.value:find("_project skill_ · `.claude/skills/review-auth/SKILL.md`", 1, true), hv.contents.value)
      h.eq(hv.range.start.character, 7)
      local loc = h.request(client, bufnr, "textDocument/definition", 0, 10)
      h.eq(loc.uri, vim.uri_from_fname(root .. "/.claude/skills/review-auth/SKILL.md"))
      h.eq(h.request(client, bufnr, "textDocument/hover", 0, 2), nil)
    end)
  end,
  ["unknown /words and paths get no hover"] = function()
    with_env(function()
      local bufnr, client = h.prompt(root, { "/nothing and /usr/bin" }, "skills")
      h.eq(h.request(client, bufnr, "textDocument/hover", 0, 3), nil)
      h.eq(h.request(client, bufnr, "textDocument/hover", 0, 16), nil)
    end)
  end,
  [":Vergil open on a skill opens its definition"] = function()
    with_env(function()
      h.prompt(root, { "/diffsum" }, "skills")
      vim.api.nvim_win_set_cursor(0, { 1, 2 })
      h.eq(require("vergil").open("split"), true)
      h.eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.uv.fs_realpath(root .. "/.claude/commands/diffsum.md"))
      vim.cmd("close")
    end)
  end,
}
