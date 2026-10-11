-- Test stub (glue tests only): one label whose text reads a field set by update.
local M = {}
function M.build(wgt, root)
  local t = GLUE_TRACE
  if t.dashFail then error("dash stub failure") end
  t.dashBuild = t.dashBuild + 1
  t.dashSize = { wgt.zone.w, wgt.zone.h, lvgl.isFullScreen() }
  t.dashRoot = root
  local d = { txt = "--" }
  lvgl.label(root, { x = 0, y = 0, text = function() return d.txt end })
  function d.update(w)
    t.dashUpdate = t.dashUpdate + 1
    t.seq[#t.seq + 1] = "dash"
    d.txt = w.S.connected and "LINK" or "--"
  end
  return d
end
return M
