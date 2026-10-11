-- Telemetry Dashboard (FPVDASH). Runs at radio start for every model, so it is
-- small: app.lua loads only when the widget is created.

local OPTION_COMBO = (type(COMBO) == "number" and COMBO) or (type(CHOICE) == "number" and CHOICE)

-- Models keep option values by index and type: index 0 and 1 must not change.
-- An option a model does not store loads as 0, so 0 is the normal value after 1.
local options = {
  { "darkTheme", BOOL, 1 },
  OPTION_COMBO and { "transpLevel", OPTION_COMBO, 1, { "1", "2", "3", "4" } }
    or { "transpLevel", VALUE, 1, 0, 3 },
  { "vtxOff", BOOL, 0 },          -- 1 = no VTX, no CRSF traffic
  { "hideTrims", BOOL, 0 },       -- 1 = no trim bars
  { "rxCells", VALUE, 0, 0, 14 }, -- 0 = auto, else fixed RX cells
  { "extTrims", VALUE, 0, 0, 2 }, -- trims: 0 auto, 1 normal, 2 extended
  { "trailOff", BOOL, 0 },        -- 1 = no trail behind the stick dots
  { "showFps", BOOL, 0 },         -- 1 = update rate in the footer
}

-- app module, shared by all instances.
local app

-- "btd": newer of .lua/.luac, with line numbers.
local function loadApp(dir)
  if app ~= nil then return nil end
  local chunk, err = loadScript(dir .. "app.lua", "btd")
  if chunk == nil then return tostring(err or "app.lua: cannot load") end
  local ok, res = pcall(chunk)
  if ok and type(res) == "table" then
    app = res
    return nil
  end
  return "app.lua: " .. tostring(res)
end

local function create(zone, opts, path)
  local dir = path or "/WIDGETS/FPVDASH/"
  if string.sub(dir, 1, 1) ~= "/" then dir = "/" .. dir end
  if string.sub(dir, -1) ~= "/" then dir = dir .. "/" end
  if lvgl == nil then
    return { zone = zone, options = opts, err = "needs EdgeTX 2.11 or later" }
  end
  local err = loadApp(dir)
  if err ~= nil then return { zone = zone, options = opts, err = err } end
  local ok, wgt = pcall(app.create, zone, opts, dir)
  if ok and type(wgt) == "table" then
    wgt._app = app
    return wgt
  end
  return { zone = zone, options = opts, err = "create: " .. tostring(wgt) }
end

-- Error label, made once (no lvgl.clear()).
local function update(wgt, opts)
  if wgt._app ~= nil then return wgt._app.update(wgt, opts) end
  if lvgl == nil or wgt.shown then return end
  wgt.shown = true
  lvgl.label({ x = 4, y = 4, w = math.max(60, (wgt.zone.w or 0) - 8), font = SMLSIZE, color = YELLOW,
               text = "FPVDASH error:\n" .. tostring(wgt.err) })
end

local function refresh(wgt, event, touchState)
  if wgt._app ~= nil then return wgt._app.refresh(wgt, event, touchState) end
  if lvgl == nil then
    lcd.drawText((wgt.zone.x or 0) + 2, (wgt.zone.y or 0) + 2, "FPVDASH: " .. tostring(wgt.err), SMLSIZE)
  elseif event == EVT_VIRTUAL_EXIT and lvgl.isFullScreen() then
    (lvgl.exitFullScreen or lcd.exitFullScreen)()
  end
end

local function background(wgt)
  if wgt._app ~= nil then return wgt._app.background(wgt) end
end

return {
  name = "Telemetry Dashboard",
  options = options,
  create = create,
  update = update,
  refresh = refresh,
  background = background,
  useLvgl = true,
}
