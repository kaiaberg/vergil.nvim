local h = require("helpers")
local sources = require("vergil.skill_sources")
local claude = h.recipe("claude").skills

--- Discovery with the README's Claude Code sources.
local skills = {
  discover = function(root)
    return sources.discover(root, claude)
  end,
}

local function by_name(list)
  local out = {}
  for _, it in ipairs(list) do
    out[it.name] = it
  end
  return out
end

local function with_home(home_files, fn)
  local home = h.tree(home_files)
  local old_home = sources.home
  sources.home = home
  local ok, err = pcall(fn, home)
  sources.home = old_home
  if not ok then
    error(err, 0)
  end
end

return {
  ["project skills and commands: names, descriptions, fallbacks"] = function()
    with_home({ ["x"] = "" }, function()
      local root = h.tree({
        [".claude/skills/review/SKILL.md"] = '---\ndescription: Review code\nargument-hint: "[file]"\n---\n',
        [".claude/skills/dirname/SKILL.md"] = "---\nname: renamed\ndescription: d\n---\n",
        [".claude/skills/nodesc/SKILL.md"] = "---\nname: nodesc\n---\n\n# Heading\n\nbody\n",
        [".claude/commands/plain.md"] = "Plain command. Second sentence.\n",
        [".claude/commands/sub/deep.md"] = "---\ndescription: nested\n---\n",
        [".claude/skills/broken/SKILL.md"] = "---\n: : :\n---\n",
      })
      local s = by_name(skills.discover(root))
      h.eq(
        { s.review.description, s.review.argument_hint, s.review.kind, s.review.origin },
        { "Review code", "[file]", "skill", "project" }
      )
      h.eq(s.renamed.description, "d")
      h.eq(s.dirname, nil)
      h.eq(s.nodesc.description, "Heading")
      h.eq(s.plain.description, "Plain command. Second sentence.")
      h.eq(s["sub:deep"].kind, "command")
      h.truthy(s.broken, "unparseable frontmatter still yields an item")
    end)
  end,
  ["user-invocable: false is listed (as in Claude Code's menu), with the flag"] = function()
    with_home({}, function()
      local root = h.tree({ [".claude/skills/hid/SKILL.md"] = "---\ndescription: h\nuser-invocable: false\n---\n" })
      h.eq(by_name(skills.discover(root)).hid.user_invocable, false)
    end)
  end,
  ["precedence: skill beats command, personal beats project"] = function()
    with_home({
      [".claude/skills/both/SKILL.md"] = "---\ndescription: personal skill\n---\n",
      [".claude/commands/cmdonly.md"] = "---\ndescription: personal command\n---\n",
    }, function()
      local root = h.tree({
        [".claude/skills/both/SKILL.md"] = "---\ndescription: project skill\n---\n",
        [".claude/skills/cmdonly/SKILL.md"] = "---\ndescription: project skill wins over personal command\n---\n",
        [".claude/commands/clash.md"] = "---\ndescription: command\n---\n",
        [".claude/skills/clash/SKILL.md"] = "---\ndescription: skill\n---\n",
      })
      local s = by_name(skills.discover(root))
      h.eq(s.both.description, "personal skill")
      h.eq(s.both.shadows[1].origin, "project")
      h.eq(s.cmdonly.description, "project skill wins over personal command")
      h.eq(s.clash.description, "skill")
      h.eq(s.clash.shadows[1].kind, "command")
    end)
  end,
  ["project skills from parent directories up to the repository root"] = function()
    with_home({}, function()
      local repo = h.tree({
        [".git/HEAD"] = "",
        [".claude/skills/rootskill/SKILL.md"] = "---\ndescription: from repo root\n---\n",
        ["packages/web/.claude/skills/webskill/SKILL.md"] = "---\ndescription: local\n---\n",
      })
      local s = by_name(skills.discover(repo .. "/packages/web"))
      h.truthy(s.rootskill and s.webskill)
    end)
  end,
  ["synced skills: bare unless the name is taken"] = function()
    with_home({
      [".claude/skills/girl-dinner/SKILL.md"] = "---\ndescription: personal\n---\n",
      [".claude/skills/synced/bucket/girl-dinner/SKILL.md"] = "---\nname: girl-dinner\ndescription: synced\n---\n",
      [".claude/skills/synced/bucket/xlsx/SKILL.md"] = "---\nname: xlsx\ndescription: sheets\n---\n",
    }, function()
      local s = by_name(skills.discover(h.tree({ x = "" })))
      h.eq(s["girl-dinner"].description, "personal")
      h.eq(s["anthropic-skills:girl-dinner"].description, "synced")
      h.eq({ s.xlsx.description, s.xlsx.origin }, { "sheets", "synced" })
    end)
  end,
  ["installed plugins are namespaced, disabled ones too (documented)"] = function()
    with_home({
      [".claude/plugins/cache/mkt/tools/1.0.0/skills/lint/SKILL.md"] = "---\ndescription: lint it\n---\n",
      [".claude/plugins/cache/mkt/tools/1.0.0/commands/fmt.md"] = "Format.\n",
      [".claude/plugins/cache/mkt/tools/1.0.0/commands/sub/deep.md"] = "Deep.\n",
      [".claude/plugins/cache/mkt/off/1.0.0/skills/nope/SKILL.md"] = "x\n",
    }, function()
      local s = by_name(skills.discover(h.tree({ x = "" })))
      h.eq({ s["tools:lint"].description, s["tools:lint"].origin }, { "lint it", "plugin" })
      h.eq(s["tools:fmt"].kind, "command")
      h.truthy(s["tools:sub:deep"], vim.inspect(vim.tbl_keys(s)))
      h.truthy(s["off:nope"], "the cache doesn't say which plugins are enabled")
    end)
  end,
  ["a name repeated in one source keeps the newest file"] = function()
    with_home({
      [".claude/plugins/cache/mkt/tools/1.0.0/skills/lint/SKILL.md"] = "---\ndescription: old\n---\n",
      [".claude/plugins/cache/mkt/tools/1.1.0/skills/lint/SKILL.md"] = "---\ndescription: new\n---\n",
    }, function(home)
      local old = home .. "/.claude/plugins/cache/mkt/tools/1.0.0/skills/lint/SKILL.md"
      vim.uv.fs_utime(old, 1000, 1000)
      h.eq(by_name(skills.discover(h.tree({ x = "" })))["tools:lint"].description, "new")
    end)
  end,
  ["other sources: path names from the file name, prefixes, origins"] = function()
    local root = h.tree({
      ["prompts/review.md"] = "---\ndescription: r\n---\n",
      ["prompts/nested/skip.md"] = "x\n",
      ["kit/a/SKILL.md"] = "---\nname: alpha\n---\n",
    })
    local s = by_name(sources.discover(root, {
      { glob = "prompts/*.md", name = "path", prefix = "prompts:" },
      { glob = "kit/*/SKILL.md", name = "dir", prefix = "{1}-", origin = "kit", kind = "tool" },
    }))
    h.eq(
      { s["prompts:review"].description, s["prompts:review"].origin, s["prompts:review"].kind },
      { "r", "project", "command" }
    )
    h.eq(s["prompts:nested:skip"], nil, "no ** in the glob")
    h.eq({ s["a-alpha"].origin, s["a-alpha"].kind }, { "kit", "tool" })
  end,
  ["edited files are re-read"] = function()
    with_home({}, function()
      local root = h.tree({ [".claude/commands/c.md"] = "---\ndescription: old\n---\n" })
      h.eq(by_name(skills.discover(root)).c.description, "old")
      vim.fn.writefile({ "---", "description: new and longer", "---" }, root .. "/.claude/commands/c.md")
      h.eq(by_name(skills.discover(root)).c.description, "new and longer")
    end)
  end,
}
