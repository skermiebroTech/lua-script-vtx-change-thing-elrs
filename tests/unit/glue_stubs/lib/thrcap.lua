-- Test stub (glue tests only): lib/thrcap.lua contract, records calls in GLUE_TRACE.
local M = { MIN = 20, MAX = 100 }
function M.new()
  local t = GLUE_TRACE
  t.thrNew = (t.thrNew or 0) + 1
  return { state = "ok", msg = "Cap 75%", cap = 75, custom = false, weight = 75, offset = -25,
           pending = nil, input = 2, rev = 0 }
end
function M.tick(T, now, allowWrite)
  local t = GLUE_TRACE
  t.thr = (t.thr or 0) + 1
  t.thrAllow = allowWrite
  t.seq[#t.seq + 1] = "thr"
end
function M.request(T, cap)
  T.pending = cap
  T.rev = T.rev + 1
end
return M
