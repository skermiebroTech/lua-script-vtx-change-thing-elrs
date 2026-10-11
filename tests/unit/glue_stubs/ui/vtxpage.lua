-- Test stub (glue tests only).
local M = {}
function M.build(wgt, root)
  local t = GLUE_TRACE
  t.pageBuild = t.pageBuild + 1
  t.pageRoot = root
  local p = { txt = "" }
  lvgl.label(root, { x = 0, y = 0, text = function() return p.txt end })
  function p.update(w)
    t.pageUpdate = t.pageUpdate + 1
    t.seq[#t.seq + 1] = "page"
    p.txt = w.V.msg
  end
  return p
end
-- the buttons (a label here): made on each full-screen entry
function M.controls(p, wgt, root)
  local t = GLUE_TRACE
  t.pageCtl = (t.pageCtl or 0) + 1
  t.ctlRoot = root
  lvgl.label(root, { x = 0, y = 40, text = "controls" })
end
return M
