-- glue_inputs_test.lua: unit tests for lib/inputs.lua.
-- Run: cd "<root>" && lua tests/unit/glue_inputs_test.lua

local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local mock = dofile(here .. "/glue_mock.lua")
mock.install()

local inputs = dofile(mock.WIDGET .. "lib/inputs.lua")

---------------------------------------------------------------- stick modes
-- rud = +100 %, ele = -50 %, thr = +25 %, ail = -100 %
local function setSticks()
  mock.set("rud", 1024); mock.set("ele", -512); mock.set("thr", 256); mock.set("ail", -1024)
end

do
  mock.install()
  setSticks()
  local I = inputs.new()
  local want = {
    -- mode: left.x, left.y, right.x, right.y
    [1] = { 100, -50, -100, 25 },    -- LH rud, LV ele, RV thr, RH ail
    [2] = { 100, 25, -100, -50 },    -- LH rud, LV thr, RV ele, RH ail
    [3] = { -100, -50, 100, 25 },    -- LH ail, LV ele, RV thr, RH rud
    [4] = { -100, 25, 100, -50 },    -- LH ail, LV thr, RV ele, RH rud
  }
  for mode = 1, 4 do
    mock.stickMode = mode
    inputs.read(I)
    local w = want[mode]
    mock.eq(I.mode, mode, "mode " .. mode)
    mock.eq(I.left.x, w[1], "mode " .. mode .. " left.x")
    mock.eq(I.left.y, w[2], "mode " .. mode .. " left.y")
    mock.eq(I.right.x, w[3], "mode " .. mode .. " right.x")
    mock.eq(I.right.y, w[4], "mode " .. mode .. " right.y")
    mock.eq(math.type(I.left.x), "integer", "mode " .. mode .. " integer percent")
  end
  -- no getStickMode: mode 2
  local gsm = getStickMode
  getStickMode = nil
  inputs.read(I)
  mock.eq(I.mode, 2, "no getStickMode -> mode 2")
  getStickMode = gsm
  -- deadband 0.8 %
  mock.stickMode = 2
  mock.set("rud", 8)        -- 0.78 %
  mock.set("thr", -9)       -- -0.88 %
  inputs.read(I)
  mock.eq(I.left.x, 0, "deadband: 0.78 % -> 0")
  mock.eq(I.left.y, -1, "deadband: -0.88 % -> -1")
  mock.set("rud", 1100)
  inputs.read(I)
  mock.eq(I.left.x, 100, "clamp at 100")
end

---------------------------------------------------------------- trims, normal range
do
  mock.install()
  mock.stickMode = 2
  local I = inputs.new()
  mock.set("trim-thr", 512)     -- 64 steps of 128 = 50 %
  mock.set("trim-ele", -8)      -- 1 step
  mock.set("trim-rud", 1024)    -- full
  inputs.read(I)
  mock.eq(I.trimExt, false, "normal: not extended")
  mock.eq(I.trim.lv, 50.0, "normal: mode 2 left vertical = throttle trim")
  mock.eq(I.trimTxt.lv, "50", "normal: text 50")
  mock.near(I.trim.rv, -0.78125, 1e-9, "normal: one step on the elevator trim")
  mock.eq(I.trimTxt.rv, "1", "normal: one step text (no sign)")
  mock.eq(I.trim.lh, 100.0, "normal: full rudder trim")
  mock.eq(I.trimTxt.lh, "100", "normal: full text")
  mock.eq(I.trim.rh, 0.0, "normal: zero")
  mock.eq(I.trimTxt.rh, "", "normal: zero text is empty")
  -- mode 1: the left vertical trim is the elevator trim
  mock.stickMode = 1
  inputs.read(I)
  mock.near(I.trim.lv, -0.78125, 1e-9, "mode 1: left vertical = elevator trim")
  mock.eq(I.trim.rv, 50.0, "mode 1: right vertical = throttle trim")
  -- mode 4: LH = ail, RH = rud
  mock.stickMode = 4
  mock.set("trim-ail", -256)
  inputs.read(I)
  mock.eq(I.trim.lh, -25.0, "mode 4: left horizontal = aileron trim")
  mock.eq(I.trim.rh, 100.0, "mode 4: right horizontal = rudder trim")
  -- unchanged values: no new change count
  local c = I.changed
  inputs.read(I)
  mock.eq(I.changed, c, "no change -> same counter")
end

---------------------------------------------------------------- trims, extended range
do
  mock.install()
  mock.stickMode = 2
  local I = inputs.new()
  mock.set("trim-thr", 512)
  inputs.read(I)
  mock.eq(I.trim.lv, 50.0, "before extended: 50 %")
  mock.set("trim-ail", 2048)     -- 256 steps: only possible with extended trims
  inputs.read(I)
  mock.eq(I.trimExt, true, "extended detected")
  mock.eq(I.trim.rh, 50.0, "extended: 2048 = 50 %")
  mock.eq(I.trimTxt.rh, "50", "extended: text 50")
  mock.eq(I.trim.lv, 12.5, "extended: old value rescaled (512 = 12.5 %)")
  mock.eq(I.trimTxt.lv, "13", "extended: EdgeTX rounding 12.5 -> 13")
  mock.set("trim-ail", 0)
  inputs.read(I)
  mock.eq(I.trimExt, true, "extended stays on")
  mock.eq(I.trimTxt.rh, "", "extended: zero text empty")
  mock.set("trim-rud", -4096)
  inputs.read(I)
  mock.eq(I.trim.lh, -100.0, "extended: full negative")
  mock.eq(I.trimTxt.lh, "100", "extended: full text without sign")
  mock.set("trim-rud", 8)
  inputs.read(I)
  mock.eq(I.trimTxt.lh, "0", "extended: one step rounds to 0 % (as EdgeTX)")
end

---------------------------------------------------------------- extTrims option (Lua cannot read the model setting)
do
  mock.install()
  mock.stickMode = 2
  local I = inputs.new()
  mock.set("trim-ele", 512)      -- +64 steps of an extended trim: EdgeTX shows 13
  inputs.read(I, 2)
  mock.eq(I.trimExt, true, "extTrims 2: extended from the start")
  mock.eq(I.trim.rv, 12.5, "extTrims 2: 512 = 12.5 %")
  mock.eq(I.trimTxt.rv, "13", "extTrims 2: text 13 (as EdgeTX)")
  local c = I.changed
  inputs.read(I, 1)
  mock.eq(I.trimExt, false, "extTrims 1: normal trims")
  mock.eq(I.trim.rv, 50.0, "extTrims 1: 512 = 50 %")
  mock.check(I.changed > c, "extTrims change counts as an input change (redraw)")
  mock.set("trim-ail", 2048)
  inputs.read(I, 1)
  mock.eq(I.trimExt, false, "extTrims 1: stays normal even beyond 1024")
  mock.eq(I.trim.rh, 100.0, "extTrims 1: clamped to 100 %")
  inputs.read(I, 0)
  mock.eq(I.trimExt, true, "extTrims 0 (auto): detects again (2048 > 1024)")
  mock.set("trim-ail", 0)
  inputs.read(I, 1)
  inputs.read(I, 0)
  mock.eq(I.trimExt, false, "auto after normal: starts from normal trims")
  inputs.read(I, nil)
  mock.eq(I.trimExt, false, "nil = auto")
end

---------------------------------------------------------------- missing sources
do
  mock.install()
  mock.remove("rud"); mock.remove("trim-ele")
  mock.set("ele", 512)
  local I = inputs.new()
  inputs.read(I)
  mock.eq(I.left.x, 0, "missing rud -> 0")
  mock.eq(I.right.y, 50, "ele still read")
  mock.eq(I.trim.rv, 0.0, "missing trim -> 0")
  mock.eq(mock.getValueByName, 0, "getValue never called with a name")
end

---------------------------------------------------------------- CPU cost
do
  mock.install()
  local I = inputs.new()
  local worst = 0
  for i = 1, 100 do
    mock.set("rud", (i * 37) % 2048 - 1024)
    mock.set("trim-thr", (i % 3) * 8)
    local n = mock.count(inputs.read, I)
    if n > worst then worst = n end
  end
  print(string.format("inputs.read: worst %d instructions", worst))
  mock.check(worst < 600, "inputs.read below 600 instructions")
end

mock.finish("glue_inputs_test")
