-- Test stub (glue tests only).
local M = {}
function M.new()
  return { state = "off", msg = "", ready = false, bandLabels = {}, band = 0, bandLetter = "",
           channel = 0, powerLabels = {}, power = 0, pitLabels = {}, pit = 0, freq = 0,
           send = "idle", sendMsg = "", rev = 0 }
end
function M.tick(V, C, E, now, allow, pageOpen)
  local t = GLUE_TRACE
  t.vtx = t.vtx + 1
  t.vtxAllow = allow
  t.pageOpen = pageOpen
  t.seq[#t.seq + 1] = "vtx"
end
-- request API of lib/vtx.lua (the real ui/vtxpage.lua calls it); records nothing
function M.apply(V, sel, send) end
function M.reload(V) end
function M.freqOf(letter, ch)
  if letter == "" or ch < 1 or ch > 8 then return 0 end
  return 5700 + 20 * ch
end
return M
