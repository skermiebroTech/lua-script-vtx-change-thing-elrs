-- Test stub (glue tests only).
local M = {}
function M.new()
  GLUE_TRACE.elrsNew = GLUE_TRACE.elrsNew + 1
  return { found = false, label = "ELRS", version = nil, armed = false }
end
function M.tick(E, C, now, allow)
  local t = GLUE_TRACE
  t.elrs = t.elrs + 1
  t.elrsAllow = allow
  t.seq[#t.seq + 1] = "elrs"
end
function M.rateHz(E, rfmd)
  if rfmd == 7 then return 250 end
  return nil
end
return M
