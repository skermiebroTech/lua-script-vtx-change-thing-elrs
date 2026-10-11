-- Dummy LVGL widget used only by the test harness self-test (tests/run.lua --selftest).
-- It follows the FPVDASH main.lua contract in a small form.

local OPTION_COMBO = (type(COMBO) == "number" and COMBO) or (type(CHOICE) == "number" and CHOICE)

local options = {
  { "darkTheme", BOOL, 1 },
  OPTION_COMBO and { "transpLevel", OPTION_COMBO, 1, { "1", "2", "3", "4" } } or { "transpLevel", VALUE, 1, 0, 3 },
  { "vtxCtl", BOOL, 1 },
  { "showTrims", BOOL, 1 },
  { "rxCells", VALUE, 0, 0, 14 },
  { "bad", VALUE, 0, 0, 20 },
}

local appChunk = nil
local appErr = nil

local function create(zone, opts, path)
  local dir = path or "/WIDGETS/HDUMMY/"
  if string.sub(dir, 1, 1) == "/" then dir = string.sub(dir, 2) end
  if not appChunk and not appErr then
    local chunk, err = loadScript(dir .. "app.lua")
    if chunk then appChunk = chunk() else appErr = err end
  end
  if not appChunk then
    return { zone = zone, options = opts, err = appErr or "app.lua missing" }
  end
  return appChunk.create(zone, opts, dir)
end

local function update(wgt, opts)
  if wgt.err then
    lvgl.clear()
    lvgl.label({ x = 0, y = 0, text = wgt.err, color = RED })
    return
  end
  return appChunk.update(wgt, opts)
end

local function refresh(wgt, event, touchState)
  if wgt.err then return end
  return appChunk.refresh(wgt, event, touchState)
end

local function background(wgt)
  if wgt.err then return end
  return appChunk.background(wgt)
end

return { name = "Harness Dummy", options = options, create = create, update = update,
         refresh = refresh, background = background, useLvgl = true }
