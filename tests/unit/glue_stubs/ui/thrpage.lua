-- Test stub (glue tests only): throttle page, its controls and the shared page header.
local M = {}
function M.build(wgt, root)
  local t = GLUE_TRACE
  t.thrBuild = (t.thrBuild or 0) + 1
  t.thrRoot = root
  local v = { txt = "" }
  lvgl.label(root, { x = 0, y = 0, text = function() return v.txt end })
  function v.update(w)
    t.thrUpdate = (t.thrUpdate or 0) + 1
    t.seq[#t.seq + 1] = "thrpage"
    v.txt = w.T.msg
  end
  return v
end
-- the controls (a label here): made when the tab is first shown in a full-screen visit
function M.controls(v, wgt, root)
  local t = GLUE_TRACE
  t.thrCtl = (t.thrCtl or 0) + 1
  t.thrCtlRoot = root
  lvgl.label(root, { x = 0, y = 80, text = "throttle controls" })
end
-- Back and the tabs (a label here): made on each full-screen entry
function M.header(wgt, root, tabs)
  local t = GLUE_TRACE
  t.header = (t.header or 0) + 1
  t.headerRoot = root
  t.tabs = tabs
  t.headerTabs = wgt.vtxOn
  lvgl.label(root, { x = 0, y = 0, text = "header" })
end
return M
