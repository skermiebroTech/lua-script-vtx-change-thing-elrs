-- glue_mock.lua: small EdgeTX + LVGL mock for the glue unit tests (desktop Lua 5.5).
-- Usage: local mock = dofile(<this file>); mock.install(); ...
-- The full mock of the test harness is tests/edgetx_mock.lua; this one is only for
-- lib/telem.lua, lib/inputs.lua, app.lua and main.lua.

local M = {}

local src = debug.getinfo(1, "S").source
local here = string.match(string.sub(src, 2), "^(.*)/[^/]*$") or "."
M.HERE = here
M.ROOT = string.match(here, "^(.*)/tests/unit$") or (here .. "/../..")
M.SD = M.ROOT .. "/radio sd card"
M.WIDGET = M.SD .. "/WIDGETS/FPVDASH/"
M.STUBS = here .. "/glue_stubs/"

-- Files of the glue agent come from the SD card, all other modules from glue_stubs.
M.OWN = { ["main.lua"] = true, ["app.lua"] = true, ["lib/telem.lua"] = true, ["lib/inputs.lua"] = true }
M.missing = {}      -- rel path -> true: loadScript fails for it
M.override = {}     -- rel path -> absolute file to load instead
M.real = false      -- true: load every module from the SD card folder (integration test)

local nextId = 1000

function M.reset()
  M.time = 1000
  M.fields = {}          -- name -> id (any source)
  M.values = {}          -- id -> value
  M.fieldInfoCalls = 0
  M.getValueByName = 0   -- getValue called with a string
  M.dt = { year = 2026, mon = 10, day = 2, hour = 9, min = 5, sec = 0 }
  M.gs = { battWarn = 6.5, battMin = 6.4, battMax = 8.4 }
  M.stickMode = 2
  M.fmNum, M.fmName = 0, ""
  M.modelName = "75"
  M.timers = {
    { mode = 1, value = 0 },
    { mode = 0, value = 0 },
    { mode = 0, value = 0 },
  }
  M.fs = false
  M.exitCalls = 0
  M.objects = {}
  M.clears = 0
  M.objClears = 0
  M.hides = 0            -- lvgl.hide calls
  M.old = {}             -- id -> true: value kept from before a link loss (getSourceValue)
  M.missing = {}
  M.override = {}
  -- fixed radio sources (sticks, trims, timers, TX battery)
  for _, n in ipairs({ "rud", "ele", "thr", "ail", "trim-rud", "trim-ele", "trim-thr", "trim-ail",
                       "timer1", "timer2", "timer3", "tx-voltage" }) do
    M.add(n, 0)
  end
  M.values[M.fields["tx-voltage"]] = 7.8
end

function M.add(name, value)
  local id = M.fields[name]
  if id == nil then
    id = nextId
    nextId = nextId + 1
    M.fields[name] = id
  end
  M.values[id] = value
  return id
end

function M.remove(name)
  local id = M.fields[name]
  if id ~= nil then
    M.fields[name] = nil
    M.values[id] = nil
  end
end

-- Moves a sensor to a new id (as "delete all sensors" + discover can do).
function M.renumber(name)
  local v = M.values[M.fields[name]]
  M.remove(name)
  local id = nextId
  nextId = nextId + 1
  M.fields[name] = id
  M.values[id] = v
  return id
end

function M.set(name, value)
  local id = M.fields[name]
  assert(id ~= nil, "unknown source " .. name)
  M.values[id] = value
  M.old[id] = nil
end

-- Marks a value as old (EdgeTX keeps it after a link loss; getSourceValue tells it).
function M.setOld(name)
  local id = M.fields[name]
  assert(id ~= nil, "unknown source " .. name)
  M.old[id] = true
end

function M.advance(ticks)
  M.time = M.time + ticks
end

-- Calls fn once to check that a property function returns a value of the right kind.
local function checkProp(key, v)
  if type(v) == "function" then
    local r = v()
    if key == "text" then assert(type(r) == "string", "text function must return a string") end
    if key == "color" then assert(type(r) == "number", "color function must return a number") end
    if key == "visible" then assert(type(r) == "boolean", "visible function must return a boolean") end
  elseif key == "visible" or key == "pos" or key == "size" or key == "active" then
    error("property " .. key .. " must be a function")
  end
end

local VALID = {
  label = { x = 1, y = 1, w = 1, h = 1, color = 1, opacity = 1, visible = 1, size = 1, pos = 1,
            text = 1, font = 1, align = 1 },
  rectangle = { x = 1, y = 1, w = 1, h = 1, color = 1, opacity = 1, visible = 1, size = 1, pos = 1,
                flexFlow = 1, flexPad = 1, active = 1, thickness = 1, filled = 1, rounded = 1,
                scrollBar = 1, scrollDir = 1, scrollTo = 1, scrolled = 1, align = 1 },
  box = { x = 1, y = 1, w = 1, h = 1, color = 1, opacity = 1, visible = 1, size = 1, pos = 1,
          flexFlow = 1, flexPad = 1, active = 1, scrollBar = 1, scrollDir = 1, scrollTo = 1, scrolled = 1,
          align = 1 },
}

-- lvgl.kind(t) or lvgl.kind(parent, t)
local function makeObj(kind, a, b)
  local parent, t = nil, a
  if b ~= nil then parent, t = a, b end
  local valid = VALID[kind]
  for k, v in pairs(t) do
    if valid ~= nil and valid[k] == nil then error("Invalid property '" .. tostring(k) .. "' on " .. kind) end
    checkProp(k, v)
  end
  local o = { kind = kind, props = t, parent = parent }
  M.objects[#M.objects + 1] = o
  return o
end

function M.install()
  M.reset()
  BOOL, VALUE, CHOICE = 1, 2, 9
  COMBO = nil
  SMLSIZE, STDSIZE, MIDSIZE, DBLSIZE, TINSIZE = 0x100, 0, 0x300, 0x500, 0x200
  BLACK, WHITE, RED, YELLOW, GREEN, GREY = 1, 2, 3, 4, 5, 6
  EVT_VIRTUAL_EXIT = 1543

  getTime = function() return M.time end
  getFieldInfo = function(name)
    M.fieldInfoCalls = M.fieldInfoCalls + 1
    local id = M.fields[name]
    if id == nil then return nil end
    return { id = id, name = name, desc = name }
  end
  getValue = function(src)
    if type(src) == "string" then
      M.getValueByName = M.getValueByName + 1
      local id = M.fields[src]
      if id == nil then return 0 end
      src = id
    end
    local v = M.values[src]
    if v == nil then return 0 end
    return v
  end
  -- value, not old, fresh; nothing for an unknown source
  getSourceValue = function(src)
    if type(src) == "string" then
      M.getValueByName = M.getValueByName + 1
      src = M.fields[src]
    end
    local v = src ~= nil and M.values[src] or nil
    if v == nil then return end
    return v, M.old[src] ~= true, M.old[src] ~= true
  end
  getDateTime = function()
    local d = M.dt
    return { year = d.year, mon = d.mon, day = d.day, hour = d.hour, min = d.min, sec = d.sec }
  end
  getGeneralSettings = function()
    if M.gs == nil then return { imperial = 0 } end
    return { battWarn = M.gs.battWarn, battMin = M.gs.battMin, battMax = M.gs.battMax }
  end
  getFlightMode = function() return M.fmNum, M.fmName end
  getStickMode = function() return M.stickMode end
  model = {
    getInfo = function() return { name = M.modelName } end,
    getTimer = function(i)
      local t = M.timers[i + 1]
      if t == nil then return nil end
      return { mode = t.mode, value = t.value, start = 0 }
    end,
  }
  lcd = { drawText = function() end, exitFullScreen = function() M.exitCalls = M.exitCalls + 1 end }
  lvgl = {
    -- no argument: every object; lvgl.clear(box): the objects inside the box
    clear = function(o)
      if o == nil then
        M.clears = M.clears + 1
        M.objects = {}
        return
      end
      M.objClears = M.objClears + 1
      local keep = {}
      for _, x in ipairs(M.objects) do
        local p, inside = x.parent, false
        while p ~= nil do
          if p == o then inside = true end
          p = p.parent
        end
        if not inside then keep[#keep + 1] = x end
      end
      M.objects = keep
    end,
    -- lvgl.hide/show act at once (a visible function changes it again at the next poll)
    hide = function(o)
      assert(type(o) == "table" and o.kind ~= nil, "lvgl.hide: lvgl object expected")
      o.hidden = true
      M.hides = M.hides + 1
    end,
    show = function(o)
      assert(type(o) == "table" and o.kind ~= nil, "lvgl.show: lvgl object expected")
      o.hidden = false
    end,
    label = function(a, b) return makeObj("label", a, b) end,
    rectangle = function(a, b) return makeObj("rectangle", a, b) end,
    box = function(a, b) return makeObj("box", a, b) end,
    isFullScreen = function() return M.fs end,
    exitFullScreen = function() M.exitCalls = M.exitCalls + 1 end,
    SCROLL_OFF = 0,
  }
  loadScript = function(path, mode)
    local rel = string.match(path, "^/WIDGETS/FPVDASH/(.*)$")
    if rel == nil then return nil, "loadScript(\"" .. path .. "\") error: File not found" end
    if M.missing[rel] then return nil, "loadScript(\"" .. path .. "\") error: File not found" end
    local file = M.override[rel]
    if file == nil then
      if M.OWN[rel] or M.real then file = M.WIDGET .. rel else file = M.STUBS .. rel end
    end
    local chunk, err = loadfile(file)
    if chunk == nil then return nil, err end
    return chunk
  end
end

-- Counts VM instructions of fn(...) that run in widget files (desktop Lua 5.5; close to
-- the radio's Lua 5.3). Mock code (EdgeTX API, LVGL polling, stubs) is not counted: on
-- the radio it is C code, and a C call counts as one instruction (the CALL in widget code).
function M.count(fn, ...)
  local n = 0
  local getinfo, find = debug.getinfo, string.find
  local seen = {}
  debug.sethook(function()
    local s = getinfo(2, "S").source
    local w = seen[s]
    if w == nil then
      w = find(s, "/WIDGETS/FPVDASH/", 1, true) ~= nil
      seen[s] = w
    end
    if w then n = n + 1 end
  end, "", 1)
  fn(...)
  debug.sethook()
  return n
end

-- Tiny test runner
M.failures = 0
M.passes = 0
function M.check(cond, msg)
  if cond then
    M.passes = M.passes + 1
  else
    M.failures = M.failures + 1
    print("FAIL: " .. msg)
  end
end
function M.eq(a, b, msg)
  M.check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
function M.near(a, b, eps, msg)
  M.check(type(a) == "number" and math.abs(a - b) <= eps, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
function M.finish(name)
  print(string.format("%s: %d passed, %d failed", name, M.passes, M.failures))
  if M.failures > 0 then os.exit(1) end
end

return M
