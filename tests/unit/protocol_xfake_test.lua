-- Cross-check: lib/crsf.lua + lib/elrs.lua + lib/vtx.lua against the harness fake
-- (tests/fake_elrs.lua, written independently). Desktop Lua only.
-- Run: cd "<root>" && lua tests/unit/protocol_xfake_test.lua

local here = string.match(arg and arg[0] or "", "^(.*)/[^/]*$") or "."
local LIB = os.getenv("PROTO_LIB") or (here .. "/../../radio sd card/WIDGETS/FPVDASH/lib/")
local X = dofile(here .. "/../fake_elrs.lua")
local crsf = dofile(LIB .. "crsf.lua")
local elrs = dofile(LIB .. "elrs.lua")
local vtx = dofile(LIB .. "vtx.lua")

local FIFO = 255 -- bytes of one EdgeTX Lua telemetry queue

local function newEnv(opts)
  local m = X.new(opts)
  local env = { m = m, now = 1000, q = {}, qBytes = 0, allow = true, page = false, lost = 0, noCrsf = false }
  crossfireTelemetryPush = function(cmd, payload)
    if env.noCrsf then return nil end
    if cmd == nil then return true end
    local p = {}
    for i = 1, #payload do p[i] = payload[i] end
    m:handle(env.now * 10, cmd, p)
    return true
  end
  crossfireTelemetryPop = function()
    local f = table.remove(env.q, 1)
    if f == nil then return nil end
    env.qBytes = env.qBytes - (#f.data + 2)
    return f.cmd, f.data
  end
  env.C = crsf.new()
  env.E = elrs.new()
  env.V = vtx.new()
  return env
end

local function tick(env, n, foreign)
  for _ = 1, n or 1 do
    env.now = env.now + 5
    if foreign then env.m:injectForeign(env.now * 10, 1) end
    local due = env.m:poll(env.now * 10)
    for i = 1, #due do
      local sz = #due[i].data + 2
      if env.qBytes + sz < FIFO then
        env.q[#env.q + 1] = due[i]
        env.qBytes = env.qBytes + sz
      else
        env.lost = env.lost + 1
      end
    end
    crsf.beginTick(env.C, env.now)
    elrs.tick(env.E, env.C, env.now, env.allow)
    vtx.tick(env.V, env.C, env.E, env.now, env.allow, env.page)
  end
end

local function runUntil(env, pred, max, foreign)
  for i = 1, max do
    tick(env, 1, foreign)
    if pred(env) then return i end
  end
  return nil
end

local function settled(env)
  local V = env.V
  return V.ready and V.state ~= "busy" and V.send ~= "writing" and V.send ~= "sending"
end

local failed, count = 0, 0
local function check(name, cond, info)
  count = count + 1
  if not cond then
    failed = failed + 1
    print("FAIL " .. name .. (info and ("  " .. info) or ""))
  end
end

local function violations(m)
  local t = {}
  for i = 1, #m.violations do t[#t + 1] = m.violations[i].msg end
  return table.concat(t, " | ")
end

-- discovery + apply + send on several firmware layouts
local versions = { "4.1.0", "4.0.1", "3.4.2", "3.3.2" }
for _, ver in ipairs(versions) do
  for _, chunk in ipairs({ 56, 27 }) do
    for _, extra in ipairs({ 0, 3 }) do
      local tag = string.format("%s chunk %d shift %d", ver, chunk, extra)
      local env = newEnv({ version = ver, chunk = chunk, extraBefore = extra, band = 5, channel = 4, power = 2, pit = 0 })
      env.page = true
      local n = runUntil(env, function(e) return e.V.state == "ready" end, 400)
      check(tag .. ": ready", n ~= nil, env.V.state .. " " .. env.V.msg)
      if n then
        local V, m = env.V, env.m
        check(tag .. ": values", V.band == 5 and V.channel == 4 and V.power == 2 and V.freq == 5769,
          string.format("b%d c%d p%d f%d", V.band, V.channel, V.power, V.freq))
        check(tag .. ": E.version", env.E.version == ver, tostring(env.E.version))
        vtx.apply(V, { band = 3, channel = 7, power = 3, pit = 1 }, true)
        runUntil(env, settled, 600)
        check(tag .. ": send result", V.send == "sent", V.send .. " " .. V.sendMsg)
        check(tag .. ": module cfg", m.cfg.band == 3 and m.cfg.channel == 7 and m.cfg.power == 3 and m.cfg.pit == 1,
          string.format("b%d c%d p%d t%d", m.cfg.band, m.cfg.channel, m.cfg.power, m.cfg.pit))
        check(tag .. ": one VTX send", m.vtx.sends == 1, tostring(m.vtx.sends))
        check(tag .. ": V values", V.band == 3 and V.channel == 7 and V.power == 3 and V.pit == 1 and V.freq == 5925)
        check(tag .. ": no violations", #m.violations == 0, violations(m))
      end
    end
  end
end

-- lossy link + foreign traffic
do
  local env = newEnv({ version = "4.1.0", chunk = 27, dropRate = 0.15, band = 1, channel = 2, power = 1, seed = 99 })
  local n = runUntil(env, function(e) return e.V.state == "ready" end, 1500, true)
  check("lossy: ready", n ~= nil, env.V.state .. " " .. env.V.msg)
  if n then
    check("lossy: values", env.V.band == 1 and env.V.channel == 2 and env.V.power == 1)
    vtx.apply(env.V, { band = 6, channel = 1 }, false)
    runUntil(env, settled, 1500, true)
    check("lossy: applied", env.m.cfg.band == 6 and env.m.cfg.channel == 1, env.V.send .. " " .. env.V.msg)
    check("lossy: V values", env.V.band == 6 and env.V.channel == 1 and env.V.freq == 5362)
  end
  check("lossy: no violations", #env.m.violations == 0, violations(env.m))
end

-- band disabled on 4.1 and on 3.3
for _, ver in ipairs({ "4.1.0", "3.3.2" }) do
  local env = newEnv({ version = ver, band = 0, channel = 1 })
  runUntil(env, function(e) return e.V.state == "ready" end, 400)
  vtx.apply(env.V, {}, true)
  runUntil(env, settled, 200)
  check(ver .. " band off: notenabled", env.V.send == "notenabled", env.V.send)
  check(ver .. " band off: no click", env.m.stats.clicks == 0)
  vtx.apply(env.V, { band = 2 }, true)
  runUntil(env, settled, 600)
  check(ver .. " enable + send", env.V.send == "sent" and env.m.vtx.sends == 1, env.V.send)
end

-- link down: queued
do
  local env = newEnv({ version = "4.1.0", band = 4, connected = false })
  env.page = true
  runUntil(env, function(e) return e.V.state == "ready" end, 400)
  tick(env, 10)
  vtx.apply(env.V, { channel = 3 }, true)
  runUntil(env, settled, 600)
  check("link down: queued", env.V.send == "queued", env.V.send)
end

-- armed flag on the page
do
  local env = newEnv({ version = "4.1.0", band = 4, armed = true })
  env.page = true
  runUntil(env, function(e) return e.V.state == "ready" end, 400)
  tick(env, 20)
  check("armed flag", env.E.armed == true)
end

-- module states
do
  local env = newEnv({ version = "4.1.0", airport = true })
  runUntil(env, function(e) return e.V.state == "novtx" end, 600)
  check("airport: novtx", env.V.state == "novtx", env.V.state)
  env = newEnv({ version = "4.1.0", isElrs = false })
  tick(env, 40)
  check("not ELRS: noelrs", env.V.state == "noelrs" and not env.E.found, env.V.state)
  env = newEnv({ version = "4.1.0", notReady = true })
  tick(env, 40)
  check("not ready: search", env.V.state == "search" and env.V.msg == "Module not ready", env.V.msg)
  env = newEnv({ version = "4.1.0", silent = true })
  tick(env, 300)
  check("silent: noelrs", env.V.state == "noelrs", env.V.state .. " " .. env.V.msg)
  env = newEnv({ version = "4.1.0" })
  env.noCrsf = true
  tick(env, 20)
  check("no CRSF: nocrsf", env.V.state == "nocrsf", env.V.state)
  env.noCrsf = false
  check("no CRSF -> ready", runUntil(env, function(e) return e.V.state == "ready" end, 400) ~= nil, env.V.state)
end

-- change made by another tool is seen by the page poll
do
  local env = newEnv({ version = "4.1.0", band = 4, channel = 2 })
  env.page = true
  runUntil(env, function(e) return e.V.state == "ready" end, 400)
  env.m:setConfig({ channel = 8 })
  check("outside change", runUntil(env, function(e) return e.V.channel == 8 end, 100) ~= nil, tostring(env.V.channel))
end

print(string.format("%d checks, %d failed", count, failed))
os.exit(failed == 0 and 0 or 1)
