--- Reads an agent recipe from the README (`<!-- recipe:<name> -->` before a
--- Lua block holding `name = { ... },`), so tests run what users copy.
--- `dofile("tests/recipe.lua")(name)`; also used by the contract tests.
local readme = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/README.md"

---@param name string
---@return table
return function(name)
  local text = table.concat(vim.fn.readfile(readme), "\n")
  local block = text:match("<!%-%- recipe:" .. name .. " %-%->\n```lua\n(.-)\n```")
  assert(block, "no recipe:" .. name .. " in the README")
  local chunk = assert(load("return {\n" .. block .. "\n}", "recipe:" .. name, "t", {}))
  return assert(chunk()[name], "the recipe doesn't define " .. name)
end
