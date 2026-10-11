-- Test stub (glue tests only).
local M = {}
function M.resolve(o)
  GLUE_TRACE.theme = GLUE_TRACE.theme + 1
  return { dark = (o.darkTheme or 1) ~= 0, text = WHITE }
end
return M
