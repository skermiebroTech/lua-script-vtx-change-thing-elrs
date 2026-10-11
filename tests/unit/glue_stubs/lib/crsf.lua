-- Test stub (glue tests only): records calls in the global GLUE_TRACE.
local M = {}
function M.new() return { stub = "C" } end
function M.beginTick(C, now)
  local t = GLUE_TRACE
  t.crsf = t.crsf + 1
  t.seq[#t.seq + 1] = "crsf"
end
return M
