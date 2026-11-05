-- Covers the M0 prototype's trigger detection. Delete with prototype/.
local token_at = require("server").token_at
local eq = function(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local at = function(line) return token_at(line, #line) end
local ref = require("server").reference_at

return {
  ["@ at line start is an attachment"] = function() eq(at("@src"), { kind = "attach", start = 0, query = "src" }) end,
  ["@@ is a mention covering both @"] = function() eq(at("see @@ses"), { kind = "mention", start = 4, query = "ses" }) end,
  ["email does not trigger"] = function() eq(at("mail me@ex"), nil) end,
  ["quoted path may contain spaces"] = function() eq(at('@"my fi'), { kind = "attach", start = 0, query = "my fi" }) end,
  ["unquoted space ends the token"] = function() eq(at("@my fi"), nil) end,
  ["slash after whitespace is a skill"] = function() eq(at("then /rev"), { kind = "skill", start = 5, query = "rev" }) end,
  ["slash inside a path is not a skill"] = function() eq(at("src/auth"), nil) end,
  ["second slash closes skill completion"] = function() eq(at("/a/b"), nil) end,

  ["reference_at: attachment, cursor at end"] = function() eq(ref("see @src/a.ts", 13), { kind = "attach", start = 4, finish = 13, query = "src/a.ts" }) end,
  ["reference_at: cursor mid-path keeps the prefix as query"] = function() eq(ref("@src/a.ts x", 4), { kind = "attach", start = 0, finish = 9, query = "src" }) end,
  ["reference_at: quoted attachment"] = function() eq(ref('@"my f.ts" x', 10), { kind = "attach", start = 0, finish = 10, query = "my f.ts" }) end,
  ["reference_at: mention"] = function() eq(ref("in `src/a.ts` ok", 13), { kind = "mention", start = 3, finish = 13, query = "src/a.ts" }) end,
  ["reference_at: nothing under cursor"] = function() eq(ref("plain text", 5), nil) end,
  ["reference_at: email is not a reference"] = function() eq(ref("me@ex.com", 9), nil) end,
}
