--- Functions, classes and methods of a file, found with Neovim's treesitter
--- parser for its language. No queries, no LSP: node types are matched by
--- shape (`*_definition`, `*_declaration`, `*_item`, or `*_specifier` with a
--- body, with a function, class, method, struct, ... in the name), which
--- covers most grammars well enough to name a range. Callbacks passed as
--- arguments are skipped. Files without a parser simply have no symbols.
local M = {}

---@class vergil.Symbol
---@field name string qualified with enclosing symbols, e.g. `Session.enable`
---@field kind string the node type, e.g. `function_declaration`
---@field start_line integer 1-based
---@field end_line integer 1-based, inclusive
---@field depth integer nesting level, 0 for top level

local KEYWORDS = { "function", "method", "class", "struct", "interface", "trait", "enum", "impl", "module", "mod" }
local SHAPES = { "_definition$", "_declaration$", "_item$" }
local BARE = { method = true, class = true, module = true, singleton_method = true, ["function"] = false }

local function definition_like(node)
  local type = node:type()
  if BARE[type] then
    return true
  end
  local shaped = type:find("_specifier$") ~= nil and node:field("body")[1] ~= nil -- C `struct x { }`
  for _, s in ipairs(SHAPES) do
    if type:find(s) then
      shaped = true
      break
    end
  end
  if not shaped then
    return false
  end
  for _, k in ipairs(KEYWORDS) do
    if type:find(k, 1, true) then
      return true
    end
  end
  return false
end

local function text(node, source)
  return (vim.treesitter.get_node_text(node, source):gsub("%s+", " "))
end

--- The identifier in a C-style declarator chain: `int *f(void)` -> `f`.
local function declarator_name(node, source)
  local seen = 0
  while node and seen < 8 do
    local inner = node:field("declarator")[1]
    if not inner then
      return text(node, source)
    end
    node, seen = inner, seen + 1
  end
end

--- The name of an unnamed function from what it's assigned to:
--- `M.f = function() end`, `const f = () => {}`, `f: function() {}`.
local function assigned_name(node, source)
  -- A callback (also in a table passed as an argument) is not a definition.
  local up = node:parent()
  for _ = 1, 4 do
    if not up then
      break
    end
    if up:type():find("argument") then
      return nil
    end
    up = up:parent()
  end
  local p = node:parent()
  for _ = 1, 3 do
    if not p then
      return nil
    end
    local named = p:field("name")[1] or p:field("left")[1] or p:field("key")[1]
    if named then
      return text(named, source)
    end
    if p:type():find("assignment") then
      local first = p:named_child(0)
      return first and first ~= node and text(first, source) or nil
    end
    p = p:parent()
  end
end

---@return string?
local function symbol_name(node, source)
  local named = node:field("name")[1]
  if named then
    return text(named, source)
  end
  local decl = node:field("declarator")[1]
  if decl then
    return declarator_name(decl, source)
  end
  local type_field = node:field("type")[1] -- Rust `impl Foo`
  if type_field and node:type():find("impl", 1, true) then
    return text(type_field, source)
  end
  if node:type():find("function", 1, true) then
    return assigned_name(node, source)
  end
end

--- The treesitter language for a file name, if a parser is installed.
---@param abs string
---@return string? lang
function M.language(abs)
  local ft = vim.filetype.match({ filename = abs })
  if not ft then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ok, added = pcall(vim.treesitter.language.add, lang)
  if not ok or not added then
    return nil
  end
  return lang
end

--- The symbols of a file's text, in order.
---@param lines string[]
---@param abs string the file name, for the language
---@return vergil.Symbol[]? symbols
---@return string? err
function M.list(lines, abs)
  local lang = M.language(abs)
  if not lang then
    return nil, ("no treesitter parser for %s"):format(vim.fs.basename(abs))
  end
  local source = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok then
    return nil, ("no treesitter parser for %s"):format(vim.fs.basename(abs))
  end
  local tree = parser:parse()[1]
  local out = {}
  local function walk(node, scope, depth)
    for child in node:iter_children() do
      if child:named() then
        local name = definition_like(child) and symbol_name(child, source)
        if name and name ~= "" then
          local sr, _, er, ec = child:range()
          if ec == 0 and er > sr then
            er = er - 1 -- ends at the start of the next line
          end
          local qualified = (#scope > 0 and not name:find("[.:]")) and (scope[#scope] .. "." .. name) or name
          out[#out + 1] = { name = qualified, kind = child:type(), start_line = sr + 1, end_line = er + 1, depth = depth }
          scope[#scope + 1] = qualified
          walk(child, scope, depth + 1)
          scope[#scope] = nil
        else
          walk(child, scope, depth)
        end
      end
    end
  end
  walk(tree:root(), {}, 0)
  return out
end

--- The symbol whose lines are exactly `start_line`..`end_line`, if any.
---@param symbols vergil.Symbol[]?
---@return vergil.Symbol?
function M.exact(symbols, start_line, end_line)
  for _, s in ipairs(symbols or {}) do
    if s.start_line == start_line and s.end_line == end_line then
      return s
    end
  end
end

--- The first symbol with a given name.
---@param symbols vergil.Symbol[]?
---@return vergil.Symbol?
function M.find(symbols, name)
  for _, s in ipairs(symbols or {}) do
    if s.name == name then
      return s
    end
  end
end

return M
