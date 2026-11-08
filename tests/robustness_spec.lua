-- Cancellation, performance and error handling (plan §9, Milestone 6).
local h = require("helpers")
local parser = require("vergil.reference.parser")

-- Shared CI machines are slower; VERGIL_PERF_FACTOR loosens the limits there.
local FACTOR = tonumber(vim.env.VERGIL_PERF_FACTOR) or 1

local function ms(fn)
  local t = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - t) / 1e6
end

local function big_repo(n)
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local list = {}
  for i = 1, n do
    list[#list + 1] = ("pkg%d/mod%d/file_%d.ts"):format(i % 200, i % 37, i)
  end
  -- A custom command lists the files without creating 50k of them on disk.
  local listing = root .. "/listing.txt"
  vim.fn.writefile(list, listing)
  return root, listing
end

return {
  -- Cancellation ------------------------------------------------------------
  ["a completion cancelled while discovery runs answers RequestCancelled"] = function()
    local root = h.tree({ ["a.ts"] = "" })
    local bufnr, client = h.prompt(root, { "@a" }, "robust")
    require("vergil.files").invalidate(root)
    local files = require("vergil.files")
    local orig = files.list
    local waiting
    files.list = function(_, cb)
      waiting = cb
    end -- discovery never finishes on its own
    local result
    local ok, id = client:request("textDocument/completion", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 2 },
    }, function(err, res)
      result = { err = err, res = res }
    end, bufnr)
    h.truthy(ok)
    client:cancel_request(id)
    vim.wait(500, function()
      return result ~= nil
    end)
    files.list = orig
    if waiting then
      waiting({ "a.ts" })
    end -- a late answer must not error
    vim.wait(50)
    h.eq(result and result.err and result.err.code, -32800)
  end,
  ["invalidating a root during a scan drops the late result"] = function()
    local files = require("vergil.files")
    local root = h.tree({ ["x"] = "" })
    local got = {}
    files.list(root, function(f)
      got[#got + 1] = f
    end)
    files.invalidate(root)
    vim.wait(300)
    h.eq(got, { {} })
  end,

  -- Performance -------------------------------------------------------------
  ["completion on 50k files stays fast after the first scan"] = function()
    local root, listing = big_repo(50000)
    require("vergil").setup({ root = root, files = { command = { "cat", listing } } })
    local bufnr, client = h.prompt(root, { "@" }, "perf")
    local function complete(text)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
      return h.request(client, bufnr, "textDocument/completion", 0, #text)
    end
    complete("@") -- first scan
    local worst = 0
    for _, q in ipairs({ "@f", "@fi", "@file_4", "@pkg1/mod2", "@@file_123" }) do
      worst = math.max(
        worst,
        ms(function()
          complete(q)
        end)
      )
    end
    require("vergil.files").invalidate(root)
    require("vergil").setup({})
    h.truthy(worst < 150 * FACTOR, ("slowest keystroke took %.1f ms"):format(worst))
  end,
  ["discovery never blocks: list() returns before the scan finishes"] = function()
    local root, listing = big_repo(20000)
    require("vergil").setup({ root = root, files = { command = { "sh", "-c", "sleep 0.3; cat " .. listing } } })
    local done = false
    local t = ms(function()
      require("vergil.files").list(root, function()
        done = true
      end)
    end)
    h.truthy(t < 20 * FACTOR, ("list() blocked for %.1f ms"):format(t))
    h.eq(done, false)
    vim.wait(3000, function()
      return done
    end)
    h.eq(done, true)
    require("vergil.files").invalidate(root)
    require("vergil").setup({})
  end,
  ["parsing a 5000-line prompt is fast"] = function()
    local lines = {}
    for i = 1, 5000 do
      lines[#lines + 1] = ("line %d with @src/f%d.ts and `src/g%d.ts#L1-L2` and prose"):format(i, i, i)
    end
    local refs
    local t = ms(function()
      refs = parser.parse(lines, h.opts())
    end)
    h.eq(#refs, 10000)
    h.truthy(t < 250 * FACTOR, ("parse took %.1f ms"):format(t))
  end,

  -- Error handling ----------------------------------------------------------
  ["unreadable, deleted and broken-symlink targets don't break hover or diagnostics"] = function()
    local root = h.tree({ ["secret.txt"] = "x\n", ["gone.txt"] = "x\n" })
    vim.uv.fs_chmod(root .. "/secret.txt", 0)
    vim.uv.fs_symlink(root .. "/nowhere", root .. "/broken.txt")
    local bufnr, client = h.prompt(root, { "@secret.txt @gone.txt @broken.txt" }, "err")
    os.remove(root .. "/gone.txt")
    for _, col in ipairs({ 2, 15, 26 }) do
      h.request(client, bufnr, "textDocument/hover", 0, col)
    end
    require("vergil.lsp.server").refresh(bufnr)
    vim.wait(200)
    local codes = vim.tbl_map(function(d)
      return d.code
    end, vim.diagnostic.get(bufnr))
    table.sort(codes)
    h.eq(codes, { "missing_attachment", "missing_attachment" })
    vim.uv.fs_chmod(root .. "/secret.txt", 420)
  end,
  ["invalid UTF-8 and very long lines parse without errors"] = function()
    local long = string.rep("word ", 20000) .. "@a.ts"
    local refs = parser.parse({ "bad \255\254 bytes @x.ts", long }, h.opts())
    h.eq(
      vim.tbl_map(function(r)
        return r.path
      end, refs),
      { "x.ts", "a.ts" }
    )
  end,
  ["a nonexistent root gives empty results, not errors"] = function()
    local root = vim.fn.tempname() .. "/missing-root"
    local got
    require("vergil.files").list(root, function(f)
      got = f
    end)
    vim.wait(3000, function()
      return got ~= nil
    end)
    h.eq(got, {})
    require("vergil.files").invalidate(root)
  end,
  ["an error inside a handler becomes an LSP error, and the server keeps working"] = function()
    local root = h.tree({ ["a.ts"] = "" })
    local bufnr, client = h.prompt(root, { "@a.ts" }, "err")
    local hover = require("vergil.lsp.hover")
    local orig = hover.handle
    hover.handle = function()
      error("boom")
    end
    local res = client:request_sync("textDocument/hover", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 2 },
    }, 1000, bufnr)
    hover.handle = orig
    h.truthy(res.err and res.err.message:find("boom", 1, true), vim.inspect(res))
    h.truthy(h.request(client, bufnr, "textDocument/hover", 0, 2).contents)
  end,
  ["an unreadable skills directory doesn't break / completion"] = function()
    local skills = require("vergil.adapters.claude.skills")
    local home = h.tree({
      [".claude/skills/ok/SKILL.md"] = "---\ndescription: fine\n---\n",
      [".claude/skills/locked/SKILL.md"] = "x",
    })
    vim.uv.fs_chmod(home .. "/.claude/skills/locked", 0)
    local old_home, old_managed = skills.home, skills.managed_dirs
    skills.home, skills.managed_dirs = home, {}
    local ok, items = pcall(skills.discover, h.tree({ x = "" }))
    skills.home, skills.managed_dirs = old_home, old_managed
    vim.uv.fs_chmod(home .. "/.claude/skills/locked", 493)
    h.truthy(ok, tostring(items))
    h.truthy(vim.tbl_contains(
      vim.tbl_map(function(i)
        return i.name
      end, items),
      "ok"
    ))
  end,
  ["the selector refuses binary and empty files gracefully"] = function()
    local root = h.tree({ ["empty.txt"] = "", ["bin.dat"] = "a\0b" })
    local bufnr = h.prompt(root, { "@empty.txt" }, "err")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    h.eq(require("vergil.range").select_at_cursor(), true, "empty files open")
    vim.wait(500, function()
      return vim.api.nvim_win_get_config(0).relative ~= ""
    end)
    vim.api.nvim_feedkeys("q", "xt", false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@bin.dat" })
    h.eq({ require("vergil.range").select_at_cursor() }, { false, "binary file: bin.dat" })
  end,
  ["startup loads only what activation needs"] = function()
    local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      ("vim.opt.rtp:prepend(%q)"):format(repo),
      'vim.cmd.runtime("plugin/vergil.lua")',
      "local mods = {}",
      "for name in pairs(package.loaded) do",
      '  if name:match("^vergil") then mods[#mods + 1] = name end',
      "end",
      "table.sort(mods)",
      'io.stdout:write(table.concat(mods, " "))',
    }, script)
    local res = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script }, { text = true }):wait(10000)
    h.eq(res.code, 0, res.stderr)
    h.eq(res.stdout, "vergil.config vergil.keymaps vergil.picker.kinds vergil.session")
  end,
}
