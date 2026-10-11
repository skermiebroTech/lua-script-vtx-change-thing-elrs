-- glue_app_test.lua: lifecycle tests for main.lua + app.lua with stub modules
-- (tests/unit/glue_stubs). Run: cd "<root>" && lua tests/unit/glue_app_test.lua

local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local mock = dofile(here .. "/glue_mock.lua")

local function resetTrace()
  GLUE_TRACE = { crsf = 0, elrs = 0, vtx = 0, elrsNew = 0, theme = 0, dashBuild = 0, dashUpdate = 0,
                 pageBuild = 0, pageUpdate = 0, pageCtl = 0, thr = 0, thrNew = 0, thrBuild = 0, thrUpdate = 0,
                 thrCtl = 0, header = 0, seq = {}, dashFail = false }
  return GLUE_TRACE
end

-- Calls the visible function of every object, like the firmware property poll
-- (a cleared root box is used again only after that).
local function pollVisible()
  for _, o in ipairs(mock.objects) do
    if type(o.props.visible) == "function" then o.props.visible() end
  end
end

local function loadMain()
  local chunk = assert(loadfile(mock.WIDGET .. "main.lua"))
  return chunk()
end

local function zone() return { x = 0, y = 0, w = 480, h = 320, xabs = 0, yabs = 0 } end
-- vtx: 1 = VTX control on (vtxOff = 0), 0 = off (vtxOff = 1)
local function options(vtx)
  return { darkTheme = 1, transpLevel = 4, vtxOff = (vtx == 0) and 1 or 0, hideTrims = 0, rxCells = 0,
           extTrims = 0 }
end

---------------------------------------------------------------- main.lua table and options
do
  mock.install()
  local w = loadMain()
  mock.eq(w.name, "Telemetry Dashboard", "widget name unchanged")
  mock.eq(w.useLvgl, true, "useLvgl")
  for _, k in ipairs({ "create", "update", "refresh", "background" }) do
    mock.eq(type(w[k]), "function", k .. " defined")
  end
  local o = w.options
  mock.eq(#o, 8, "8 options")
  mock.check(o[1][1] == "darkTheme" and o[1][2] == BOOL and o[1][3] == 1, "option 0 darkTheme BOOL 1")
  mock.check(o[2][1] == "transpLevel" and o[2][2] == CHOICE and o[2][3] == 1 and #o[2][4] == 4,
    "option 1 transpLevel CHOICE 1 {1..4}")
  -- options after index 1 load as 0 on models that do not store them: 0 = normal
  mock.check(o[3][1] == "vtxOff" and o[3][2] == BOOL and o[3][3] == 0, "option 2 vtxOff BOOL 0")
  mock.check(o[4][1] == "hideTrims" and o[4][2] == BOOL and o[4][3] == 0, "option 3 hideTrims BOOL 0")
  mock.check(o[5][1] == "rxCells" and o[5][2] == VALUE and o[5][3] == 0 and o[5][4] == 0 and o[5][5] == 14,
    "option 4 rxCells VALUE 0 0 14")
  mock.check(o[6][1] == "extTrims" and o[6][2] == VALUE and o[6][3] == 0 and o[6][4] == 0 and o[6][5] == 2,
    "option 5 extTrims VALUE 0 0 2")
  mock.check(o[7][1] == "trailOff" and o[7][2] == BOOL and o[7][3] == 0, "option 6 trailOff BOOL 0")
  mock.check(o[8][1] == "showFps" and o[8][2] == BOOL and o[8][3] == 0, "option 7 showFps BOOL 0")
  CHOICE = nil
  o = loadMain().options
  mock.check(o[2][1] == "transpLevel" and o[2][2] == VALUE and o[2][4] == 0 and o[2][5] == 3,
    "no CHOICE: transpLevel VALUE 1 0 3")
  local f = io.open(mock.WIDGET .. "main.lua", "rb")
  local size = #f:read("a")
  f:close()
  mock.check(size < 3072, "main.lua < 3 KB (" .. size .. ")")
end

---------------------------------------------------------------- normal lifecycle
local W, wgt
do
  mock.install()
  local t = resetTrace()
  mock.add("RQly", 100); mock.add("TPWR", 25); mock.add("RFMD", 7)
  W = loadMain()
  wgt = W.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  mock.eq(wgt.err, nil, "create: no error")
  mock.eq(wgt.dir, "WIDGETS/FPVDASH/", "wgt.dir without leading slash")
  mock.eq(wgt.path, "/WIDGETS/FPVDASH/", "wgt.path with leading slash")
  for _, k in ipairs({ "telem", "inputs", "crsf", "elrs", "vtx", "thrcap", "theme", "layout", "dash", "vtxpage",
                       "thrpage" }) do
    mock.check(type(wgt.mods[k]) == "table", "module " .. k .. " loaded")
  end
  mock.check(wgt.S ~= nil and wgt.I ~= nil and wgt.C ~= nil and wgt.E ~= nil and wgt.V ~= nil, "state objects")
  mock.check(type(wgt.T) == "table" and t.thrNew == 1, "throttle cap state wgt.T = thrcap.new()")
  mock.eq(wgt.tab, "vtx", "default tab with VTX control on")
  mock.check(type(wgt.theme) == "table", "theme resolved")
  mock.eq(wgt.S.rateHz, 250, "create: first telemetry read with elrs.rateHz")
  mock.eq(t.crsf, 0, "create: no CRSF calls")
  mock.eq(t.dashBuild, 0, "create: no UI")

  W.update(wgt, wgt.options)              -- firmware calls update right after create
  mock.eq(t.dashBuild, 1, "update: dashboard built")
  mock.check(t.dashRoot ~= nil, "dashboard built inside a root box")
  mock.eq(wgt.built.fs, false, "built.fs false")
  mock.eq(wgt.built.w, 480, "built.w")
  mock.eq(t.dashUpdate, 1, "update: view updated once after build")
  W.update(wgt, wgt.options)
  mock.eq(t.dashBuild, 1, "second update without change: no rebuild")

  t.seq = {}
  mock.advance(5)
  W.refresh(wgt, nil, nil)
  mock.eq(table.concat(t.seq, ","), "crsf,elrs,vtx,thr,dash", "tick order")
  mock.eq(t.elrsAllow, true, "refresh: traffic allowed")
  mock.eq(t.thrAllow, true, "refresh: throttle cap may write the model")
  mock.eq(t.pageOpen, false, "refresh: page not open")
  mock.eq(t.dashBuild, 1, "refresh: no rebuild")
  mock.eq(wgt.now, mock.time, "wgt.now = getTime()")

  -- background
  t.seq = {}
  W.background(wgt)
  mock.eq(table.concat(t.seq, ","), "crsf,elrs,vtx,thr", "background: protocol and throttle cap only")
  mock.eq(t.elrsAllow, false, "background: no traffic")
  mock.eq(t.vtxAllow, false, "background: vtx no traffic")
  mock.eq(t.thrAllow, false, "background: throttle cap never writes the model")

  -- enter full screen (firmware calls update)
  mock.fs = true
  W.update(wgt, wgt.options)
  mock.eq(t.pageBuild, 1, "full screen: VTX page built")
  mock.eq(t.thrBuild, 1, "full screen: throttle page texts built too (below the button box)")
  mock.eq(t.header, 1, "full screen: Back and tabs made")
  mock.eq(t.headerTabs, true, "full screen: tabs with VTX control on")
  mock.eq(t.pageCtl, 1, "full screen: VTX page buttons made")
  mock.eq(t.thrCtl, 0, "full screen: throttle buttons not made before the tab is shown")
  mock.check(t.headerRoot ~= nil and t.headerRoot ~= t.pageRoot and t.headerRoot ~= t.thrRoot,
    "page buttons in their own root box")
  mock.check(t.ctlRoot ~= nil and t.ctlRoot.parent == t.headerRoot, "VTX buttons in a box of the button root box")
  mock.check(t.tabs == wgt.tabs and t.tabs.vtx == true and t.tabs.thr == false, "VTX tab shown")
  mock.eq(wgt.pageOpen, true, "pageOpen")
  mock.eq(wgt.vtxOpen, true, "vtxOpen")
  t.seq = {}
  W.refresh(wgt, 0, nil)
  mock.eq(table.concat(t.seq, ","), "crsf,elrs,vtx,thr,page", "page tick order")
  mock.eq(t.pageOpen, true, "vtx.tick pageOpen = true")
  -- Throttle tab (the tab button only sets wgt.tab): the next refresh shows it and
  -- makes its buttons; the VTX status poll stops
  wgt.tab = "thr"
  t.seq = {}
  W.refresh(wgt, 0, nil)
  mock.eq(t.thrCtl, 1, "Throttle tab: its buttons made")
  mock.check(t.thrCtlRoot ~= nil and t.thrCtlRoot.parent == t.headerRoot, "throttle buttons in the button root box")
  mock.eq(t.header, 1, "Throttle tab: Back and tabs kept")
  mock.eq(t.pageBuild + t.thrBuild, 2, "Throttle tab: no page rebuilt")
  mock.check(t.tabs.thr == true and t.tabs.vtx == false, "Throttle tab shown")
  mock.eq(wgt.vtxOpen, false, "Throttle tab: vtxOpen false")
  mock.eq(wgt.pageOpen, true, "Throttle tab: pageOpen")
  mock.eq(table.concat(t.seq, ","), "thrpage,crsf,elrs,vtx,thr", "tab change cycle: view update + protocol only")
  mock.eq(t.thrAllow, false, "tab change cycle: no model write in the rebuild cycle")
  mock.eq(t.pageOpen, false, "Throttle tab: vtx.tick pageOpen = false")
  t.seq = {}
  W.refresh(wgt, 0, nil)
  mock.eq(table.concat(t.seq, ","), "crsf,elrs,vtx,thr,thrpage", "throttle page tick order")
  mock.eq(t.thrAllow, true, "throttle page: model write allowed")
  -- back to the VTX tab: its buttons exist already
  wgt.tab = "vtx"
  W.refresh(wgt, 0, nil)
  mock.eq(t.pageCtl, 1, "VTX tab again: buttons kept")
  mock.eq(wgt.vtxOpen, true, "VTX tab again: vtxOpen")
  mock.eq(mock.objClears, 0, "tab changes clear nothing")
  -- RTN short press
  W.refresh(wgt, EVT_VIRTUAL_EXIT, nil)
  mock.eq(mock.exitCalls, 1, "EVT_VIRTUAL_EXIT -> exitFullScreen")
  -- App mode exit: no update call, refresh shows the dashboard again (kept, not
  -- rebuilt) and deletes the page buttons
  mock.fs = false
  local db, oc = t.dashBuild, mock.objClears
  local ctl = wgt.ctl
  t.seq = {}
  W.refresh(wgt, nil, nil)
  mock.eq(t.dashBuild, db, "exit full screen: dashboard kept, not rebuilt")
  mock.eq(wgt.pageOpen, false, "page closed")
  mock.eq(wgt.ctl, nil, "page buttons gone after exit")
  mock.eq(mock.objClears, oc + 1, "page buttons deleted with lvgl.clear(box)")
  -- the poll that handles the clear does not call the visible function of the box, and
  -- 2.12.x has no other poll in the exit cycle: the box (made in full screen, so
  -- clickable) must be hidden at once
  mock.check(ctl ~= nil and ctl.box.hidden == true, "cleared button box hidden at once (lvgl.hide)")
  mock.eq(ctl and ctl.show, false, "cleared button box: visible function returns false later")
  mock.eq(table.concat(t.seq, ","), "dash,crsf,elrs,vtx,thr", "exit cycle: view update + protocol only")
  mock.eq(wgt.vtxOpen, false, "vtxOpen false after exit")
  W.refresh(wgt, nil, nil)
  mock.eq(t.dashBuild, db, "no rebuild later")
  -- rc1: update is also called on exit (twice) -> no rebuild
  W.update(wgt, wgt.options)
  W.update(wgt, wgt.options)
  mock.eq(t.dashBuild, db, "rc1 double update: no rebuild")
  -- second entry: the page is kept, only its buttons are made again
  mock.fs = true
  W.update(wgt, wgt.options)
  mock.eq(t.pageBuild, 1, "second entry: page kept")
  mock.eq(t.thrBuild, 1, "second entry: throttle page kept")
  mock.eq(t.pageCtl, 2, "second entry: page buttons made again")
  mock.eq(t.header, 2, "second entry: Back and tabs made again")
  -- the tab choice is kept between visits
  wgt.tab = "thr"
  W.refresh(wgt, 0, nil)
  mock.fs = false
  W.refresh(wgt, nil, nil)
  mock.eq(t.dashBuild, db, "second exit: dashboard kept")
  pollVisible()
  mock.fs = true
  local pc, tc = t.pageCtl, t.thrCtl
  W.update(wgt, wgt.options)
  mock.eq(wgt.tab, "thr", "third entry: tab choice kept")
  mock.eq(t.thrCtl, tc + 1, "third entry: throttle buttons made")
  mock.eq(t.pageCtl, pc, "third entry: VTX buttons not made (tab not shown)")
  mock.check(wgt.ctl ~= nil and wgt.ctl.fs == true, "button root box tagged as made in full screen")
  -- a box made in full screen stays clickable on the radio: never used for the dashboard
  local fsBoxes = { [wgt.ctl.box] = true, [wgt.pv.slot.box] = true, [wgt.tv.slot.box] = true }
  wgt.tab = "vtx"
  W.refresh(wgt, 0, nil)
  mock.fs = false
  W.refresh(wgt, nil, nil)
  pollVisible()
  mock.check(#wgt.pool >= 1, "the button root box is free after the exit")
  for _, s in ipairs(wgt.pool) do
    mock.eq(s.fs, true, "the free boxes are full-screen boxes")
    mock.eq(s.seen, true, "the free boxes were polled")
  end
  wgt.options.transpLevel = 3             -- new option key: every view is built again
  W.update(wgt, wgt.options)
  pollVisible()
  mock.eq(t.dashBuild, db + 1, "option change on the dashboard: dashboard built again")
  mock.check(not fsBoxes[t.dashRoot], "dashboard not built in a box made in full screen")
  mock.eq(wgt.dv.slot.fs, false, "dashboard root box made outside full screen")
  mock.eq(wgt.pv, nil, "option change: VTX page dropped (built again in full screen)")
  mock.eq(wgt.tv, nil, "option change: throttle page dropped")
  -- the next entry uses free full-screen boxes for the pages; the button box is drawn
  -- above both page boxes (a free box made after them, or a new one)
  local dashBox = wgt.dv.slot.box
  local freeFs = {}
  for _, s in ipairs(wgt.pool) do
    if s.fs then freeFs[s.box] = true end
  end
  mock.fs = true
  W.update(wgt, wgt.options)
  mock.check(freeFs[wgt.pv.slot.box] ~= nil and freeFs[wgt.tv.slot.box] ~= nil,
    "page boxes from the free full-screen boxes")
  mock.check(wgt.ctl.seq > wgt.pv.slot.seq and wgt.ctl.seq > wgt.tv.slot.seq,
    "button box drawn above both page boxes")
  mock.check(wgt.pv.slot.fs and wgt.tv.slot.fs and wgt.ctl.fs, "page boxes tagged as made in full screen")
  mock.check(wgt.pv.slot.box ~= dashBox and wgt.tv.slot.box ~= dashBox and wgt.ctl.box ~= dashBox,
    "the dashboard box is not used for a page")
  mock.fs = false
  W.refresh(wgt, nil, nil)
  db = t.dashBuild

  -- zone size change (layout change)
  wgt.zone.w, wgt.zone.h = 430, 225
  W.refresh(wgt, nil, nil)
  mock.eq(t.dashBuild, db + 1, "zone size change -> rebuild")
  mock.eq(t.dashSize[1], 430, "dash built at the new size")

  -- rebuildRequested (the page asks for it when the module option lists change):
  -- the page goes, the dashboard stays
  wgt.rebuildRequested = true
  W.refresh(wgt, nil, nil)
  mock.eq(t.dashBuild, db + 1, "rebuildRequested on the dashboard: dashboard kept")
  mock.eq(wgt.pv, nil, "rebuildRequested: page dropped (built again on the next entry)")
  mock.eq(wgt.rebuildRequested, false, "flag cleared")

  -- option change: theme again, rebuild
  local th = t.theme
  wgt.options.darkTheme = 0
  W.update(wgt, wgt.options)
  mock.eq(t.dashBuild, db + 2, "option change -> rebuild")
  mock.eq(t.theme, th + 1, "option change -> theme resolved")

  -- vtxOff 0 -> 1 at run time: no more CRSF calls, fresh E
  local en = t.elrsNew
  wgt.options.vtxOff = 1
  W.update(wgt, wgt.options)
  mock.eq(wgt.vtxOn, false, "vtxOn false")
  mock.eq(t.elrsNew, en + 1, "E recreated (footer shows ELRS)")
  local c = t.crsf
  for _ = 1, 5 do W.refresh(wgt, nil, nil); W.background(wgt) end
  mock.eq(t.crsf, c, "vtxOff 1: no crsf.beginTick")
  mock.eq(wgt.tab, "thr", "vtxOff 1: tab = Throttle")
  -- full screen with vtxOff 1: only the throttle page
  wgt.zone.w, wgt.zone.h = 480, 320
  mock.fs = true
  local pb, tb, dbb, hb = t.pageBuild, t.thrBuild, t.dashBuild, t.header
  W.update(wgt, wgt.options)
  mock.eq(t.pageBuild, pb, "vtxOff 1 full screen: no VTX page")
  mock.eq(t.thrBuild, tb + 1, "vtxOff 1 full screen: throttle page built")
  mock.eq(t.dashBuild, dbb, "vtxOff 1 full screen: no dashboard in full screen")
  mock.eq(t.header, hb + 1, "vtxOff 1 full screen: Back made")
  mock.eq(t.headerTabs, false, "vtxOff 1 full screen: no tabs")
  mock.eq(wgt.pageOpen, true, "vtxOff 1 full screen: page open")
  mock.eq(wgt.vtxOpen, false, "vtxOff 1 full screen: no VTX page open")
  wgt.tab = "vtx"                         -- no VTX tab: the throttle page stays
  t.seq = {}
  W.refresh(wgt, 0, nil)
  mock.eq(table.concat(t.seq, ","), "thr,thrpage", "vtxOff 1 page tick: no CRSF calls")
  W.refresh(wgt, EVT_VIRTUAL_EXIT, nil)
  mock.eq(mock.exitCalls, 2, "vtxOff 1 full screen: RTN exits too")
  mock.fs = false
  W.refresh(wgt, nil, nil)
  mock.eq(wgt.ctl, nil, "vtxOff 1: page buttons gone after exit")
  -- VTX control on again: the VTX tab is the default again
  wgt.options.vtxOff = 0
  W.update(wgt, wgt.options)
  mock.eq(wgt.tab, "vtx", "vtxOff 0 again: VTX tab")
  mock.eq(mock.clears, 0, "no lvgl.clear() without argument in the whole lifecycle")
end

---------------------------------------------------------------- existing model: options not stored
do
  mock.install()
  local t = resetTrace()
  -- EdgeTX loads the options that a model does not store yet as 0
  local o = { darkTheme = 1, transpLevel = 4, vtxOff = 0, hideTrims = 0, rxCells = 0, extTrims = 0 }
  local w = loadMain().create(zone(), o, "/WIDGETS/FPVDASH/")
  w._app.update(w, w.options)
  mock.eq(w.vtxOn, true, "existing model: VTX control on")
  for _ = 1, 3 do mock.advance(5); w._app.refresh(w, nil, nil) end
  mock.check(t.crsf > 0, "existing model: CRSF ticks run")
end

---------------------------------------------------------------- vtxOff = 1 from the start
do
  mock.install()
  local t = resetTrace()
  local w = loadMain().create(zone(), options(0), "/WIDGETS/FPVDASH/")
  local M = w._app
  M.update(w, w.options)
  for _ = 1, 10 do M.refresh(w, nil, nil); M.background(w) end
  mock.eq(t.crsf + t.elrs + t.vtx, 0, "vtxOff 1: no CRSF module calls at all")
  mock.check(t.dashUpdate > 0, "vtxOff 1: dashboard still updates")
end

---------------------------------------------------------------- path variants and shared app
do
  mock.install()
  resetTrace()
  local W2 = loadMain()
  local a = W2.create(zone(), options(1), nil)
  local b = W2.create(zone(), options(1), "WIDGETS/FPVDASH")
  mock.eq(a.path, "/WIDGETS/FPVDASH/", "nil path -> default")
  mock.eq(b.path, "/WIDGETS/FPVDASH/", "path without slashes normalised")
  mock.check(a._app == b._app, "app.lua shared by instances")
  mock.check(a.S ~= b.S and a.mods ~= b.mods, "instance state not shared")
end

---------------------------------------------------------------- missing / broken modules
do
  mock.install()
  local t = resetTrace()
  mock.missing["lib/vtx.lua"] = true
  local W3 = loadMain()
  local w = W3.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  mock.check(type(w.err) == "string" and string.find(w.err, "lib/vtx.lua", 1, true) ~= nil,
    "missing module -> error names the file (" .. tostring(w.err) .. ")")
  W3.update(w, w.options)
  local lbl = nil
  for _, o in ipairs(mock.objects) do if o.kind == "label" then lbl = o end end
  mock.check(lbl ~= nil and string.find(lbl.props.text, "lib/vtx.lua", 1, true) ~= nil, "error label shown")
  W3.refresh(w, nil, nil); W3.background(w)
  mock.eq(t.crsf + t.dashBuild, 0, "error state: nothing runs")
  W3.refresh(w, EVT_VIRTUAL_EXIT, nil)

  mock.install()
  resetTrace()
  mock.override["ui/theme.lua"] = mock.STUBS .. "bad_load.lua"
  w = loadMain().create(zone(), options(1), "/WIDGETS/FPVDASH/")
  mock.check(type(w.err) == "string" and string.find(w.err, "broken module", 1, true) ~= nil,
    "module that errors at load -> error")

  mock.install()
  t = resetTrace()
  t.dashFail = true
  local W4 = loadMain()
  w = W4.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  W4.update(w, w.options)
  mock.check(type(w.err) == "string" and string.find(w.err, "dash stub failure", 1, true) ~= nil,
    "build error -> error label instead of a dead widget")
  W4.refresh(w, nil, nil)
  mock.eq(t.crsf, 0, "build error: no ticks")

  -- app.lua missing: main.lua shows the error itself
  mock.install()
  resetTrace()
  mock.missing["app.lua"] = true
  local W5 = loadMain()
  w = W5.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  mock.check(type(w.err) == "string" and w._app == nil, "app.lua missing -> main error object")
  W5.update(w, w.options)
  mock.eq(#mock.objects, 1, "main error label")
  W5.update(w, w.options)
  mock.eq(#mock.objects, 1, "main error label made once")
  mock.eq(mock.clears, 0, "main error path: no lvgl.clear()")
  W5.refresh(w, nil, nil); W5.background(w)
  -- full screen (App mode long-press): a short RTN leaves it
  mock.fs = true
  local ex = mock.exitCalls
  W5.refresh(w, EVT_VIRTUAL_EXIT, nil)
  mock.eq(mock.exitCalls, ex + 1, "main error path: RTN leaves full screen")
  mock.fs = false
  -- app.lua found later (no reboot needed: the failure is not cached)
  mock.missing["app.lua"] = nil
  w = W5.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  mock.eq(w.err, nil, "app.lua loads on the next create")

  -- firmware without LVGL
  mock.install()
  resetTrace()
  lvgl = nil
  local W6 = loadMain()
  w = W6.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  mock.check(type(w.err) == "string", "no lvgl -> error object")
  W6.update(w, w.options)
  W6.refresh(w, nil, nil)
  W6.background(w)
end

---------------------------------------------------------------- z-order of the full-screen controls
-- LVGL gives a tap to the topmost object at the point (LVGL 8 lv_indev_search_obj: the
-- children of an object are searched from the last one to the first; an object takes the
-- tap when no child takes it and it is clickable and not disabled). A box, rectangle or
-- circle made in full screen is clickable (rc1 lua_lvgl_widget.cpp:1501-1502, 2.12.0
-- :1616-1617), and controls always are. Rule: no visible clickable object that is drawn
-- above a control or that was made after it (except the parents of the control) may
-- overlap the rectangle of the control, and a tap at the centre of each visible enabled
-- control must reach that control. A full-size tab box made after Back and the tabs took
-- every tap on them.
-- This section does not use the test harness (tests/edgetx_mock.lua): it records the
-- object tree of the real app.lua, ui/thrpage.lua, ui/vtxpage.lua and ui/layout.lua (the
-- other modules are the glue stubs) with a small LVGL recorder.
do
  local Z = { roots = {}, fs = false, n = 0, fullClears = 0, badProps = {} }
  local ZCONTROL = { button = true, momentaryButton = true, toggle = true, textEdit = true, numberEdit = true,
                     choice = true, slider = true, verticalSlider = true }
  local ZFILL = { box = true, rectangle = true, circle = true }   -- clickable when made in full screen
  local ZKINDS = { "label", "rectangle", "box", "circle", "image", "hline", "vline", "arc", "line", "button",
                   "momentaryButton", "toggle", "textEdit", "numberEdit", "choice", "slider", "verticalSlider" }

  local function zDelete(list)
    for _, o in ipairs(list) do
      o.deleted = true
      zDelete(o.children)
    end
  end

  -- Replaces the global lvgl (call after mock.install).
  local function zInstall(fs)
    Z.roots, Z.fs, Z.n, Z.fullClears = {}, fs, 0, 0
    local L = { SCROLL_OFF = 0, FLOW_ROW = 0, FLOW_COLUMN = 1 }
    for _, kind in ipairs(ZKINDS) do
      L[kind] = function(a, b)
        local parent, t = nil, a
        if b ~= nil then parent, t = a, b end
        assert(type(t) == "table", kind .. ": parameter table expected")
        if ZCONTROL[kind] and not Z.fs then return nil end   -- controls only in full screen
        Z.n = Z.n + 1
        local o = { kind = kind, t = t, parent = parent, children = {}, seq = Z.n, shown = true,
                    deleted = false, clickable = (ZCONTROL[kind] or (ZFILL[kind] and Z.fs)) == true }
        local list = (parent ~= nil) and parent.children or Z.roots
        list[#list + 1] = o
        if type(t.visible) == "function" then o.shown = t.visible() == true end
        return o
      end
    end
    L.clear = function(o)
      if o == nil then
        Z.fullClears = Z.fullClears + 1
        zDelete(Z.roots)
        Z.roots = {}
        return
      end
      zDelete(o.children)
      o.children = {}
    end
    L.hide = function(o) o.shown = false end
    L.show = function(o) o.shown = true end
    L.isFullScreen = function() return Z.fs end
    L.exitFullScreen = function() end
    L.confirm = function() end
    L.menu = function() end
    lvgl = L
  end

  -- one property poll: the visible functions (a cleared root box is used again only after it)
  local function zPoll(list)
    for _, o in ipairs(list or Z.roots) do
      local v = o.t.visible
      if type(v) == "function" then
        local r = v()
        if type(r) ~= "boolean" then Z.badProps[#Z.badProps + 1] = o.kind .. ".visible returned " .. type(r) end
        o.shown = r == true
      end
      zPoll(o.children)
    end
  end

  local function zVisible(o)
    while o ~= nil do
      if o.deleted or not o.shown then return false end
      o = o.parent
    end
    return true
  end

  local function zEnabled(o)
    local a = o.t.active
    if type(a) == "function" then return a() ~= false end
    return true
  end

  local function zText(o)
    local t = o.t.text
    if type(t) == "function" then t = t() end
    return tostring(t or "")
  end

  -- absolute rectangle (x, y relative to the parent; circle x, y = centre)
  local function zRect(o)
    local t = o.t
    local x, y = t.x or 0, t.y or 0
    if type(t.pos) == "function" then x, y = t.pos() end
    local w, h = t.w or 0, t.h or 0
    if type(t.size) == "function" then w, h = t.size() end
    if o.kind == "circle" then
      local r = t.radius or 0
      x, y, w, h = x - r, y - r, 2 * r, 2 * r
    end
    local p = o.parent
    while p ~= nil do
      local px, py = p.t.x or 0, p.t.y or 0
      if type(p.t.pos) == "function" then px, py = p.t.pos() end
      x, y = x + px, y + py
      p = p.parent
    end
    return x, y, w, h
  end

  local function zAncestor(a, o)
    local p = o.parent
    while p ~= nil do
      if p == a then return true end
      p = p.parent
    end
    return false
  end

  local function zSearch(o, x, y)
    if o.deleted or not o.shown then return nil end
    local ax, ay, w, h = zRect(o)
    if x < ax or x >= ax + w or y < ay or y >= ay + h then return nil end
    for i = #o.children, 1, -1 do
      local f = zSearch(o.children[i], x, y)
      if f ~= nil then return f end
    end
    if o.clickable and zEnabled(o) then return o end
    return nil
  end

  local function zHit(x, y)
    for i = #Z.roots, 1, -1 do
      local f = zSearch(Z.roots[i], x, y)
      if f ~= nil then return f end
    end
    return nil
  end

  local function zDesc(o)
    local x, y, w, h = zRect(o)
    return string.format("%s#%d %q (%d,%d %dx%d)", o.kind, o.seq, zText(o), x, y, w, h)
  end

  -- Returns the problems (strings) and the texts of the visible controls.
  local function zCheck()
    local all, n = {}, 0
    local function walk(list)
      for _, o in ipairs(list) do
        n = n + 1
        o.order = n                    -- LVGL draws (and searches backwards) in this order
        all[#all + 1] = o
        walk(o.children)
      end
    end
    walk(Z.roots)
    local probs, names = {}, {}
    for _, c in ipairs(all) do
      if ZCONTROL[c.kind] and zVisible(c) then
        names[#names + 1] = zText(c)
        local cx, cy, cw, ch = zRect(c)
        for _, o in ipairs(all) do
          if o ~= c and o.clickable and zVisible(o) and (o.order > c.order or o.seq > c.seq)
             and not zAncestor(o, c) then
            local ox, oy, ow, oh = zRect(o)
            if ox < cx + cw and cx < ox + ow and oy < cy + ch and cy < oy + oh then
              probs[#probs + 1] = zDesc(c) .. " is under the clickable " .. zDesc(o)
            end
          end
        end
        if zEnabled(c) then
          local hx, hy = cx + cw // 2, cy + ch // 2
          local hit = zHit(hx, hy)
          if hit ~= c then
            probs[#probs + 1] = string.format("a tap at %d,%d on %s goes to %s", hx, hy, zDesc(c),
              hit and zDesc(hit) or "the widget")
          end
        end
      end
    end
    return probs, table.concat(names, ",")
  end

  -- visible clickable objects (outside full screen they would take the long press)
  local function zClickables()
    local r = {}
    local function walk(list)
      for _, o in ipairs(list) do
        if o.clickable and zVisible(o) then r[#r + 1] = zDesc(o) end
        walk(o.children)
      end
    end
    walk(Z.roots)
    return r
  end

  local function zExpect(tag, want)
    local probs, names = zCheck()
    for _, p in ipairs(probs) do mock.check(false, tag .. ": " .. p) end
    mock.eq(#probs, 0, tag .. ": controls reachable by touch")
    for _, w in ipairs(want) do
      mock.check(string.find("," .. names .. ",", "," .. w .. ",", 1, true) ~= nil,
        tag .. ": visible control '" .. w .. "' (controls: " .. names .. ")")
    end
  end

  local function zPress(text)
    local found = nil
    local function walk(list)
      for _, o in ipairs(list) do
        if found == nil and ZCONTROL[o.kind] and zVisible(o) and zText(o) == text then found = o end
        walk(o.children)
      end
    end
    walk(Z.roots)
    mock.check(found ~= nil and type(found.t.press) == "function", "z-order: button '" .. text .. "' to press")
    if found ~= nil and type(found.t.press) == "function" then found.t.press() end
  end

  ---------------------------------------------------------------- the checker finds the old order
  zInstall(true)
  local r = lvgl.box({ x = 0, y = 0, w = 480, h = 320 })
  lvgl.button(r, { x = 3, y = 3, w = 56, h = 36, text = "Back", press = function() end })
  lvgl.box(r, { x = 0, y = 0, w = 480, h = 320 })      -- a tab box made after Back (the old order)
  local probs = zCheck()
  mock.eq(#probs, 2, "z-order check: a full-size box made after Back covers it and takes the tap")
  zInstall(true)
  r = lvgl.box({ x = 0, y = 0, w = 480, h = 320 })
  lvgl.box(r, { x = 0, y = 0, w = 480, h = 320 })      -- the tab box first (the fixed order)
  lvgl.button(r, { x = 3, y = 3, w = 56, h = 36, text = "Back", press = function() end })
  probs = zCheck()
  mock.eq(#probs, 0, "z-order check: Back made after the tab box can be tapped")
  zInstall(false)
  r = lvgl.box({ x = 0, y = 0, w = 480, h = 320 })
  mock.eq(#zClickables(), 0, "z-order check: a box made outside full screen is not clickable")

  ---------------------------------------------------------------- the real pages in app.lua
  local function zWorld(vtx, h, vReady)
    mock.install()
    resetTrace()
    for _, f in ipairs({ "ui/thrpage.lua", "ui/vtxpage.lua", "ui/layout.lua" }) do
      mock.override[f] = mock.WIDGET .. f
    end
    zInstall(false)
    LCD_W, LCD_H = 480, h
    BOLD, CENTER, RIGHT, LIGHTGREY = 0x100 + 1, 1, 2, 7
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1 = 0x10000, 0x20000, 0x40000
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_ACTIVE = 0x60000, 0x70000, 0x90000
    COLOR_THEME_WARNING = 0xA0000
    mock.add("RQly", 100); mock.add("TPWR", 25); mock.add("RFMD", 7)
    local Wz = loadMain()
    local w = Wz.create({ x = 0, y = 0, w = 480, h = h, xabs = 0, yabs = 0 }, options(vtx), "/WIDGETS/FPVDASH/")
    mock.eq(w.err, nil, "z-order world: no error")
    if vReady then
      local V = w.V
      V.state, V.msg, V.ready = "ready", "VTX ready", true
      V.bandLabels = { "Off", "A", "B", "E", "F", "R", "L" }
      V.band, V.bandLetter, V.channel, V.freq = 5, "R", 4, 5769
      V.powerLabels, V.power = { "-", "1", "2", "3" }, 1
      V.pitLabels, V.pit = { "Off", "On" }, 0
      V.rev = V.rev + 1
    end
    Wz.update(w, w.options)
    zPoll()
    return Wz, w
  end

  local function cycle(Wz, w)
    Wz.refresh(w, 0, nil)
    zPoll()
  end

  local function enter(Wz, w)
    Z.fs = true
    Wz.update(w, w.options)
    zPoll()
    cycle(Wz, w)
    cycle(Wz, w)
  end

  -- rc1 calls update() twice when full screen ends; 2.12.x calls none in App mode
  local rc1 = false
  local function leave(Wz, w, tag)
    Z.fs = false
    if rc1 then
      Wz.update(w, w.options)
      zPoll()
      Wz.update(w, w.options)
      zPoll()
    end
    cycle(Wz, w)
    cycle(Wz, w)
    local cl = zClickables()
    for _, c in ipairs(cl) do mock.check(false, tag .. ": visible clickable object outside full screen: " .. c) end
    mock.eq(#cl, 0, tag .. ": nothing clickable visible outside full screen")
    mock.eq(Z.fullClears, 0, tag .. ": no no-argument lvgl.clear()")
  end

  local VTX_TAB = { "Back", "VTX", "Throttle", "Reload", "A", "R", "Off", "1", "8", "Keep", "Off", "Apply & Send" }
  local THR_TAB = { "Back", "VTX", "Throttle", "100%", "75%", "50%", "-5", "+5", "Set" }

  for run = 1, 4 do
    local h = (run % 2 == 1) and 320 or 272
    rc1 = run > 2
    local sz = "480x" .. h .. (rc1 and " rc1" or " 2.12.x")
    -- VTX control on, the VTX values loaded: both tabs, then a second visit (the button box
    -- comes from the pool of free root boxes)
    local Wz, w = zWorld(1, h, true)
    enter(Wz, w)
    zExpect(sz .. " VTX tab", VTX_TAB)
    zPress("Throttle")
    cycle(Wz, w)
    cycle(Wz, w)
    mock.eq(w.built and w.built.tab, "thr", sz .. ": Throttle tab shown by a tap")
    zExpect(sz .. " Throttle tab", THR_TAB)
    zPress("VTX")
    cycle(Wz, w)
    mock.eq(w.built and w.built.tab, "vtx", sz .. ": VTX tab shown by a tap")
    zExpect(sz .. " VTX tab again", VTX_TAB)
    leave(Wz, w, sz .. " exit")
    enter(Wz, w)
    zExpect(sz .. " second visit, VTX tab", VTX_TAB)
    zPress("Throttle")
    cycle(Wz, w)
    zExpect(sz .. " second visit, Throttle tab", THR_TAB)
    -- the cap cannot be changed: Back and the tabs stay usable
    w.T.state, w.T.msg, w.T.rev = "unsupported", "Thr input has 2 lines", w.T.rev + 1
    cycle(Wz, w)
    zExpect(sz .. " Throttle tab, unsupported", { "Back", "VTX", "Throttle" })
    leave(Wz, w, sz .. " second exit")

    -- VTX values not loaded: Back, the tabs and Reload
    Wz, w = zWorld(1, h, false)
    enter(Wz, w)
    zExpect(sz .. " VTX tab, not ready", { "Back", "VTX", "Throttle", "Reload" })
    leave(Wz, w, sz .. " exit, not ready")

    -- VTX control off: only the Throttle page
    Wz, w = zWorld(0, h, false)
    enter(Wz, w)
    zExpect(sz .. " VTX off", { "Back", "100%", "75%", "-5", "+5", "Set" })
    leave(Wz, w, sz .. " exit, VTX off")
    enter(Wz, w)
    zExpect(sz .. " VTX off, second visit", { "Back", "100%", "Set" })
    leave(Wz, w, sz .. " second exit, VTX off")
  end
  for _, b in ipairs(Z.badProps) do mock.check(false, "z-order: " .. b) end

  LCD_W, LCD_H, BOLD, CENTER, RIGHT, LIGHTGREY = nil, nil, nil, nil, nil, nil
  COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1 = nil, nil, nil
  COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_ACTIVE, COLOR_THEME_WARNING = nil, nil, nil, nil
end

---------------------------------------------------------------- CPU cost of the glue part of a tick
do
  mock.install()
  resetTrace()
  mock.add("RQly", 100); mock.add("TPWR", 25); mock.add("RFMD", 7); mock.add("1RSS", -60)
  mock.add("2RSS", -70); mock.add("RxBt", 16.4); mock.add("Curr", 1.2); mock.add("Capa", 120)
  mock.add("FM", "ACRO"); mock.add("RSNR", 5); mock.add("ANT", 0)
  local Wc = loadMain()
  local w = Wc.create(zone(), options(1), "/WIDGETS/FPVDASH/")
  Wc.update(w, w.options)
  for _ = 1, 50 do mock.advance(5); Wc.refresh(w, nil, nil) end
  local worst, total = 0, 0
  for i = 1, 100 do
    mock.advance(5)
    mock.set("rud", (i * 37) % 2048 - 1024)
    local n = mock.count(Wc.refresh, w, nil, nil)
    total = total + n
    if n > worst then worst = n end
  end
  mock.advance(5)
  local bg = mock.count(Wc.background, w)
  mock.fs = true
  local enter = mock.count(Wc.update, w, w.options)
  mock.advance(5)
  local pageTick = mock.count(Wc.refresh, w, 0, nil)
  mock.fs = false
  mock.advance(5)
  local exitTick = mock.count(Wc.refresh, w, nil, nil)
  print(string.format("glue refresh (stub UI/protocol): typical %d, worst %d; background %d; "
    .. "fs enter update %d; page tick %d; fs exit rebuild tick %d", total // 100, worst, bg, enter, pageTick, exitTick))
  mock.check(worst < 2000, "glue part of a tick below 2000 instructions")
end

mock.finish("glue_app_test")
