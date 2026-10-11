-- Unit tests for lib/crsf.lua, lib/elrs.lua and lib/vtx.lua against a fake ELRS module.
-- Run: cd "<root>" && lua tests/unit/protocol_test.lua   (exit code 0 = all pass)

local here = string.match(arg and arg[0] or "", "^(.*)/[^/]*$") or "."
local LIB = os.getenv("PROTO_LIB") or (here .. "/../../radio sd card/WIDGETS/FPVDASH/lib/")
local Fake = dofile(here .. "/protocol_fake.lua")

local crsf = dofile(LIB .. "crsf.lua")
local elrs = dofile(LIB .. "elrs.lua")
local vtx = dofile(LIB .. "vtx.lua")

-- VM instruction counter (only while the widget code runs; the fake pauses it)
local counter = { on = false, n = 0 }
debug.sethook(function() if counter.on then counter.n = counter.n + 1 end end, "", 1)

local STATES = { off = 1, nocrsf = 1, search = 1, noelrs = 1, novtx = 1, load = 1, ready = 1, busy = 1, error = 1 }
local SENDS = { idle = 1, writing = 1, sending = 1, sent = 1, queued = 1, notenabled = 1, failed = 1 }

local function fail(msg) error(msg, 2) end
local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

local function checkFields(env)
  local V, E = env.V, env.E
  if not STATES[V.state] then fail("bad V.state " .. tostring(V.state)) end
  if type(V.msg) ~= "string" or #V.msg > 30 then fail("bad V.msg " .. tostring(V.msg)) end
  if type(V.ready) ~= "boolean" then fail("V.ready not boolean") end
  for _, k in ipairs({ "band", "channel", "power", "pit", "freq", "rev" }) do
    if math.type(V[k]) ~= "integer" then fail("V." .. k .. " not integer: " .. tostring(V[k])) end
  end
  for _, k in ipairs({ "bandLabels", "powerLabels", "pitLabels" }) do
    if type(V[k]) ~= "table" then fail("V." .. k .. " not a table") end
  end
  if type(V.bandLetter) ~= "string" then fail("V.bandLetter") end
  if not SENDS[V.send] then fail("bad V.send " .. tostring(V.send)) end
  if type(V.sendMsg) ~= "string" or #V.sendMsg > 30 then fail("bad V.sendMsg") end
  if V.channel < 0 or V.channel > 8 then fail("V.channel out of range") end
  if type(E.found) ~= "boolean" or type(E.label) ~= "string" or type(E.armed) ~= "boolean" then fail("E fields") end
  if E.version ~= nil and type(E.version) ~= "string" then fail("E.version") end
end

local function newEnv(opt)
  local fake = Fake.new(opt)
  local env = { fake = fake, now = 1000, allow = true, page = false, maxIns = 0, sumIns = 0, ticks = 0,
                sends = {}, states = {} }
  fake.now = env.now
  fake:install(counter)
  env.C = crsf.new()
  env.E = elrs.new()
  env.V = vtx.new()
  return env
end

local function tick(env, n)
  for _ = 1, n or 1 do
    env.now = env.now + 5
    env.fake.now = env.now
    counter.n = 0
    counter.on = true
    crsf.beginTick(env.C, env.now)
    elrs.tick(env.E, env.C, env.now, env.allow)
    vtx.tick(env.V, env.C, env.E, env.now, env.allow, env.page)
    counter.on = false
    if counter.n > env.maxIns then env.maxIns = counter.n end
    env.sumIns = env.sumIns + counter.n
    env.ticks = env.ticks + 1
    checkFields(env)
    local V = env.V
    if env.sends[#env.sends] ~= V.send then env.sends[#env.sends + 1] = V.send end
    if env.states[#env.states] ~= V.state then env.states[#env.states + 1] = V.state end
  end
end

local function runUntil(env, pred, maxTicks)
  for i = 1, maxTicks do
    tick(env)
    if pred(env) then return i end
  end
  return nil
end

local function ready(env) return env.V.state == "ready" end
local function settled(env)
  local V = env.V
  return (V.state == "ready" or V.state == "error") and V.send ~= "writing" and V.send ~= "sending"
end

local function has(list, v)
  for i = 1, #list do if list[i] == v then return true end end
  return false
end

----------------------------------------------------------------------------
local tests = {}
local function T(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

T("discovery ELRS 4.1 layout with shifted ids", function()
  local env = newEnv({ layout = "4.1", shift = 2, band = 5, channel = 4, power = 2, pit = 0 })
  local n = runUntil(env, ready, 200)
  if not n then fail("not ready, state " .. env.V.state .. " " .. env.V.msg) end
  local V, E, m = env.V, env.E, env.fake
  eq(V.ids.folder, m.vtxFolder, "folder id")
  eq(V.ids.band, m.bandId, "band id")
  eq(V.ids.channel, m.chId, "channel id")
  eq(V.ids.power, m.pwrId, "power id")
  eq(V.ids.pit, m.pitId, "pit id")
  eq(V.ids.send, m.sendId, "send id")
  eq(V.bandLabels[1], "Disabled", "band label 0")
  eq(#V.bandLabels, 7, "band labels")
  eq(V.band, 5, "band")
  eq(V.bandLetter, "R", "letter")
  eq(V.channel, 4, "channel")
  eq(V.freq, 5769, "freq")
  eq(#V.powerLabels, 9, "power labels")
  eq(V.power, 2, "power")
  eq(#V.pitLabels, 22, "pit labels")
  eq(V.pitLabels[3], "AUX1^", "pit label 3")
  eq(V.pitLabels[22], "AUX10v", "pit label 22")
  eq(V.ready, true, "ready")
  eq(V.msg, "Ready", "msg")
  eq(E.found, true, "E.found")
  eq(E.label, "RM TX15 4.1.0", "E.label")
  eq(E.version, "4.1.0", "E.version")
  eq(m.badAddr, 0, "frames with wrong addresses")
  eq(m.violations, 0, "overlapping reads")
  eq(m.badChunk, 0, "chunk index out of range")
  eq(m.maxPushPerTick, 1, "pushes per tick")
  -- the ping is directed to the TX module
  for i = 1, #m.log do
    if m.log[i].cmd == 0x28 then eq(m.log[i].p[1], 0xEE, "ping destination") end
  end
  print(string.format("    ready after %d ticks, %d frames pushed", n, #m.log))
end)

T("discovery ELRS 4.1 with 27-byte chunks (multi-chunk fields)", function()
  local env = newEnv({ layout = "4.1", chunkMax = 27, band = 2, channel = 8, power = 0, pit = 3 })
  if not runUntil(env, ready, 300) then fail("not ready: " .. env.V.msg) end
  local V = env.V
  eq(V.band, 2, "band")
  eq(V.channel, 8, "channel")
  eq(V.freq, 5866, "freq B8")
  eq(V.pit, 3, "pit")
  eq(#V.pitLabels, 22, "pit labels")
  eq(env.fake.badChunk, 0, "chunk index out of range")
  eq(env.fake.violations, 0, "overlapping reads")
end)

T("discovery ELRS 3.3 layout (Band, Channel TEXT_SELECTION) with shifted ids", function()
  local env = newEnv({ layout = "3.3", shift = 3, band = 1, channel = 6, power = 5, pit = 1 })
  if not runUntil(env, ready, 200) then fail("not ready: " .. env.V.msg) end
  local V, m = env.V, env.fake
  eq(V.ids.folder, m.vtxFolder, "folder id")
  eq(V.ids.channel, m.chId, "channel id")
  eq(V.f[V.ids.channel].type, 9, "channel type")
  eq(V.bandLabels[1], "Off", "band label 0")
  eq(V.band, 1, "band")
  eq(V.channel, 6, "channel")
  eq(V.freq, 5765, "freq A6")
  eq(V.power, 5, "power")
  eq(V.pit, 1, "pit")
  eq(env.E.version, "3.3.2", "version")
end)

T("apply band + channel + power with read-back (4.1)", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4, power = 2 })
  runUntil(env, ready, 200)
  local m, V = env.fake, env.V
  local t0 = env.now
  vtx.apply(V, { band = 1, channel = 2, power = 3 }, false)
  eq(V.send, "writing", "send after apply")
  eq(V.state, "busy", "state after apply")
  if not runUntil(env, settled, 200) then fail("apply did not finish: " .. V.state .. " " .. V.send) end
  eq(m.cfg.band, 1, "module band")
  eq(m.cfg.channel, 1, "module channel (0-based)")
  eq(m.cfg.power, 3, "module power")
  eq(V.band, 1, "V.band")
  eq(V.channel, 2, "V.channel")
  eq(V.power, 3, "V.power")
  eq(V.bandLetter, "A", "letter")
  eq(V.freq, 5845, "freq")
  eq(V.send, "idle", "send")
  eq(V.state, "ready", "state")
  eq(#m.sends, 0, "no VTX send")
  -- 3 writes, then reads of the written fields after >= 250 ms
  local w = {}
  for i = 1, #m.writes do if m.writes[i].t >= t0 then w[#w + 1] = m.writes[i] end end
  eq(#w, 3, "writes")
  eq(w[1].id, m.bandId, "band written first")
  eq(w[2].id, m.chId, "then channel")
  eq(w[2].arg, 2, "channel wire value (UINT8)")
  local lastW = w[3].t
  local readBack = 0
  for i = 1, #m.reads do
    local r = m.reads[i]
    if r.t > lastW then
      readBack = readBack + 1
      if r.t - lastW < 25 then fail("read-back too early") end
    end
  end
  if readBack < 4 then fail("read-back missing") end
  eq(m.violations, 0, "overlapping reads")
end)

T("apply channel on 3.3 writes the option index", function()
  local env = newEnv({ layout = "3.3", band = 5, channel = 1 })
  runUntil(env, ready, 200)
  vtx.apply(env.V, { channel = 8 }, false)
  runUntil(env, settled, 200)
  eq(env.fake.cfg.channel, 7, "module channel index")
  eq(env.V.channel, 8, "V.channel")
  eq(env.V.freq, 5917, "freq R8")
end)

T("writes are clamped to the parsed range", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4, power = 2 })
  runUntil(env, ready, 200)
  vtx.apply(env.V, { band = 99, channel = 0, power = 50, pit = -3 }, false)
  runUntil(env, settled, 200)
  local m = env.fake
  eq(m.cfg.band, 6, "band clamped")
  eq(m.cfg.channel, 0, "channel clamped to 1")
  eq(m.cfg.power, 8, "power clamped")
  eq(m.cfg.pit, 0, "pit clamped")
  for i = 1, #m.writes do
    if m.writes[i].arg > 21 then fail("write out of range: " .. m.writes[i].arg) end
  end
end)

T("Send VTx flow: click, status 2, lcsQuery after 2.2 s, no 0x2C on the command", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4, power = 2, flags = 1 })
  env.page = true
  runUntil(env, ready, 200)
  local m, V = env.fake, env.V
  env.sends = {}
  local t0 = env.now
  vtx.apply(V, { channel = 5 }, true)
  if not runUntil(env, settled, 400) then fail("send did not finish: " .. V.send) end
  eq(V.send, "sent", "send result")
  eq(V.state, "ready", "state")
  eq(#m.sends, 1, "VTX sends")
  eq(m.cfg.channel, 4, "channel written before send")
  eq(m.readSendDuringFlow, 0, "0x2C reads of Send VTx during the flow")
  if not (has(env.sends, "writing") and has(env.sends, "sending")) then fail("send states missing") end
  -- click before query; first query >= 2.2 s after the click
  local tClick, tQuery
  for i = 1, #m.log do
    local l = m.log[i]
    if l.t >= t0 and l.cmd == 0x2D and l.p[3] == m.sendId then
      if l.p[4] == 1 and tClick == nil then tClick = l.t end
      if l.p[4] == 6 and tQuery == nil then tQuery = l.t end
    end
  end
  if tClick == nil or tQuery == nil then fail("click or query missing") end
  if tQuery - tClick < 220 then fail("query too early: " .. (tQuery - tClick)) end
  eq(m.count(m, 0x2C, m.sendId, nil, tClick), 0, "reads of the command after the click")
  -- result goes back to idle after 10 s
  tick(env, 220)
  eq(V.send, "idle", "send result timeout")
  eq(m.violations, 0, "overlapping reads")
end)

T("Send VTx with the RX link down gives 'queued'", function()
  local env = newEnv({ layout = "4.1", band = 5, flags = 0 })
  env.page = true
  runUntil(env, ready, 200)
  tick(env, 10)
  eq(env.E.linkUp, false, "link flag")
  vtx.apply(env.V, {}, true)
  runUntil(env, settled, 400)
  eq(env.V.send, "queued", "send result")
  eq(#env.fake.sends, 1, "click sent")
end)

T("Send with band off: no click, 'notenabled'", function()
  local env = newEnv({ layout = "4.1", band = 0 })
  runUntil(env, ready, 200)
  eq(env.V.msg, "VTX Admin disabled", "msg")
  vtx.apply(env.V, {}, true)
  runUntil(env, settled, 100)
  eq(env.V.send, "notenabled", "send")
  eq(env.fake:count(0x2D, env.fake.sendId), 0, "no click")
end)

T("module answers 'Not enabled' (band disabled elsewhere)", function()
  local env = newEnv({ layout = "4.1", band = 3 })
  runUntil(env, ready, 200)
  env.fake.cfg.band = 0 -- changed behind the widget's back
  vtx.apply(env.V, {}, true)
  runUntil(env, settled, 200)
  eq(env.V.send, "notenabled", "send")
  eq(#env.fake.sends, 0, "no VTX send")
end)

T("no CRSF module, then CRSF comes back", function()
  local env = newEnv({ layout = "4.1" })
  env.fake.noCrsf = true
  tick(env, 40)
  eq(env.V.state, "nocrsf", "state")
  eq(env.E.found, false, "E.found")
  eq(env.E.label, "ELRS", "label")
  eq(#env.fake.log, 0, "no frames")
  env.fake.noCrsf = false
  if not runUntil(env, ready, 300) then fail("not ready after CRSF returned: " .. env.V.state) end
end)

T("module without VTX Administrator (airport build)", function()
  local env = newEnv({ layout = "4.1", noVtx = true })
  if not runUntil(env, function(e) return e.V.state == "novtx" end, 400) then fail("state " .. env.V.state) end
  eq(env.V.ready, false, "ready")
  eq(env.V.msg, "No VTX Admin on module", "msg")
  -- two complete passes (the second after a new ping) before "No VTX Admin"
  local m = env.fake
  local first, pings = 0, 0
  for i = 1, #m.reads do if m.reads[i].id == 1 and m.reads[i].chunk == 0 then first = first + 1 end end
  for i = 1, #m.log do if m.log[i].cmd == 0x28 then pings = pings + 1 end end
  eq(first, 2, "scan passes")
  eq(pings, 2, "pings (one before the verification pass)")
  local n = #env.fake.log
  tick(env, 1200) -- 60 s idle
  eq(#env.fake.log, n, "no traffic after novtx")
  vtx.apply(env.V, { band = 1 }, true)
  tick(env, 2)
  eq(env.V.send, "failed", "apply without VTX Admin")
end)

T("not an ELRS module", function()
  local env = newEnv({ layout = "4.1", serial = "TBS\0", name = "Crossfire" })
  tick(env, 40)
  eq(env.V.state, "noelrs", "state")
  eq(env.E.found, false, "found")
  eq(env.E.label, "ELRS", "label")
end)

T("module stops answering (reboot), then validates cached ids without a rescan", function()
  local env = newEnv({ layout = "4.1", shift = 1 })
  env.page = true
  runUntil(env, ready, 200)
  local m = env.fake
  m.silent = true
  if not runUntil(env, function(e) return e.V.state == "search" or e.V.state == "noelrs" end, 400) then
    fail("no loss detected: " .. env.V.state)
  end
  local t0 = env.now
  m.silent = false
  if not runUntil(env, ready, 600) then fail("not ready again: " .. env.V.state .. " " .. env.V.msg) end
  local other = 0
  for i = 1, #m.reads do
    local r = m.reads[i]
    if r.t >= t0 and r.id < m.vtxFolder then other = other + 1 end
  end
  eq(other, 0, "scan reads after the reboot")
end)

T("allowTraffic false: no pushes, frames still drained", function()
  local env = newEnv({ layout = "4.1" })
  env.allow = false

  tick(env, 5)
  env.fake:status() -- an unsolicited frame
  env.fake:deviceInfo()
  tick(env, 200)
  eq(#env.fake.log, 0, "frames pushed")
  eq(#env.fake.q, 0, "queue drained")
  env.allow = true
  if not runUntil(env, ready, 200) then fail("not ready") end
end)

T("stale frames after a pause are dropped and the values re-read", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  runUntil(env, ready, 200)
  local m, V = env.fake, env.V
  -- a frame that sits in the queue while the widget is paused (e.g. a tool ran)
  m:enqueue(0x2B, { 0xEA, 0xEE, m.bandId, 0, m.vtxFolder, 9, 66, 0 })
  m.cfg.channel = 6 -- changed by the tool
  env.now = env.now + 300
  m.now = env.now
  local dropped = env.C.dropped
  tick(env)
  if env.C.dropped <= dropped then fail("stale frame not dropped") end
  if not runUntil(env, function(e) return e.V.state == "ready" and e.V.channel == 7 end, 200) then
    fail("values not re-read: ch " .. V.channel .. " " .. V.state)
  end
end)

T("ELRS status poll only while the page is open; armed flag", function()
  local env = newEnv({ layout = "4.1", flags = 9 })
  runUntil(env, ready, 200)
  local m = env.fake
  local t0 = env.now
  tick(env, 1200)
  eq(m:count(0x2D, 0, nil, t0), 0, "status polls on the dashboard")
  eq(env.E.armed, false, "armed unknown")
  env.page = true
  local t1 = env.now
  tick(env, 200) -- 10 s
  local n = m:count(0x2D, 0, nil, t1)
  if n < 4 or n > 6 then fail("status polls on the page: " .. n) end
  eq(env.E.armed, true, "armed")
  env.page = false
  tick(env, 120)
  eq(env.E.armed, false, "armed after the status is old")
end)

T("dashboard idle traffic <= 1 frame per 15 s", function()
  local env = newEnv({ layout = "4.1" })
  runUntil(env, ready, 200)
  local t0 = env.now
  tick(env, 2400) -- 120 s
  local n = 0
  for i = 1, #env.fake.log do if env.fake.log[i].t >= t0 then n = n + 1 end end
  if n > 8 then fail("idle frames in 120 s: " .. n) end
  print(string.format("    %d frames in 120 s idle; average %.0f instructions/tick", n, env.sumIns / env.ticks))
end)

T("page open: quiet re-read and folder poll picks up outside changes", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  runUntil(env, ready, 200)
  env.fake.cfg.channel = 1
  env.page = true
  if not runUntil(env, function(e) return e.V.channel == 2 end, 40) then fail("no re-read on page open") end
  eq(env.V.state, "ready", "quiet refresh")
  env.fake.cfg.band = 2
  if not runUntil(env, function(e) return e.V.band == 2 end, 100) then fail("poll did not see the change") end
end)

T("apply coalesces: only the last request is written", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  runUntil(env, ready, 200)
  local t0 = env.now
  vtx.apply(env.V, { channel = 1 }, false)
  vtx.apply(env.V, { channel = 7 }, false)
  runUntil(env, settled, 200)
  local w = 0
  for i = 1, #env.fake.writes do if env.fake.writes[i].t >= t0 then w = w + 1 end end
  eq(w, 1, "writes")
  eq(env.V.channel, 7, "channel")
end)

T("rewrite when the read-back differs, then fail", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  runUntil(env, ready, 200)
  local m = env.fake
  local orig = m.write
  m.write = function(self, id, arg) if id ~= self.chId then orig(self, id, arg) else
    self.writes[#self.writes + 1] = { t = self.now, id = id, arg = arg } end end
  vtx.apply(env.V, { channel = 2 }, true)
  runUntil(env, settled, 400)
  eq(env.V.send, "failed", "send")
  eq(env.V.state, "error", "state")
  eq(#m.sends, 0, "no send after a failed write")
  local n = 0
  for i = 1, #m.writes do if m.writes[i].id == m.chId then n = n + 1 end end
  eq(n, 3, "channel write tries")
  tick(env, 220)
  eq(env.V.state, "ready", "error clears")
end)

T("module change (unsolicited 0x29 with a new key) rescans", function()
  local env = newEnv({ layout = "4.1", band = 5 })
  runUntil(env, ready, 200)
  local old = env.fake
  local m = Fake.new({ layout = "3.3", band = 2, channel = 3 })
  m.now = env.now
  m:install(counter)
  env.fake = m
  m:deviceInfo()
  if not runUntil(env, function(e) return e.V.state == "ready" and e.V.bandLabels[1] == "Off" end, 400) then
    fail("no rescan: " .. env.V.state)
  end
  eq(env.V.band, 2, "band")
  eq(env.V.channel, 3, "channel")
  eq(env.E.version, "3.3.2", "version")
  local _ = old
end)

T("module not ready (fieldCount 0) then ready", function()
  local env = newEnv({ layout = "4.1" })
  local m = env.fake
  local saved = m.params
  m.params = {}
  tick(env, 40)
  eq(env.V.state, "search", "state")
  eq(env.V.msg, "Module not ready", "msg")
  eq(env.E.found, true, "found")
  m.params = saved
  if not runUntil(env, ready, 400) then fail("not ready") end
end)

T("reload re-reads all fields", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4, power = 2 })
  runUntil(env, ready, 200)
  env.fake.cfg.power = 6
  vtx.reload(env.V)
  if not runUntil(env, function(e) return e.V.power == 6 end, 60) then fail("reload") end
  runUntil(env, ready, 20)
  eq(env.V.state, "ready", "state")
end)

T("busy output buffer (push returns false) is retried", function()
  local env = newEnv({ layout = "4.1" })
  env.fake.busy = 30
  if not runUntil(env, ready, 300) then fail("not ready") end
end)

T("beginTick dispatches at most 4 frames per tick", function()
  local env = newEnv({ layout = "4.1" })
  tick(env, 2)
  local m = env.fake
  for _ = 1, 10 do m:status() end
  m.now = env.now + 5
  local before = #m.q
  env.now = env.now + 5
  crsf.beginTick(env.C, env.now)
  eq(before - #m.q, 4, "frames popped")
end)

T("slow config commit: read-back waits instead of rewriting", function()
  local env = newEnv({ layout = "3.3", band = 5, channel = 4, commitDelay = 45 })
  runUntil(env, ready, 200)
  local t0 = env.now
  vtx.apply(env.V, { channel = 2 }, false)
  if not runUntil(env, settled, 300) then fail("not settled") end
  eq(env.V.send, "idle", "send")
  eq(env.V.channel, 2, "channel")
  local w = 0
  for i = 1, #env.fake.writes do if env.fake.writes[i].t >= t0 then w = w + 1 end end
  eq(w, 1, "writes")
end)

T("apply during discovery runs when ready", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  tick(env, 6)
  eq(env.V.ready, false, "not ready yet")
  vtx.apply(env.V, { channel = 3 }, false)
  eq(env.V.send, "writing", "send")
  if not runUntil(env, function(e) return e.V.ready and settled(e) end, 300) then fail("not done") end
  eq(env.fake.cfg.channel, 2, "module channel")
  eq(env.V.channel, 3, "V.channel")
end)

T("apply while a job runs is done after it", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  runUntil(env, ready, 200)
  vtx.apply(env.V, { channel = 1 }, false)
  tick(env, 3)
  eq(env.V.state, "busy", "busy")
  vtx.apply(env.V, { band = 1 }, false)
  runUntil(env, settled, 300)
  eq(env.fake.cfg.channel, 0, "first job")
  eq(env.fake.cfg.band, 1, "second job")
  eq(env.V.band, 1, "V.band")
  eq(env.V.channel, 1, "V.channel")
end)

T("pause during a job: the job runs again after the module check", function()
  local env = newEnv({ layout = "4.1", band = 5, channel = 4 })
  runUntil(env, ready, 200)
  vtx.apply(env.V, { band = 2, channel = 6 }, false)
  tick(env, 2) -- band written, channel not yet
  env.now = env.now + 400
  env.fake.now = env.now
  if not runUntil(env, function(e) return e.V.ready and settled(e) end, 400) then fail("not done") end
  eq(env.fake.cfg.band, 2, "band")
  eq(env.fake.cfg.channel, 5, "channel")
  eq(env.V.send, "idle", "send")
end)

T("stray and duplicate chunks during a multi-chunk read are ignored", function()
  local env = newEnv({ layout = "4.1", chunkMax = 27, band = 5, channel = 4, pit = 4 })
  local m = env.fake
  local done = {}
  m.beforeChunk = function(self, id, chunk)
    if id == self.pitId and chunk >= 1 and not done[chunk] then
      done[chunk] = true
      -- a repeat of chunk 0 (answer to another script) arrives first
      local hook = self.beforeChunk
      self.beforeChunk = nil
      self:sendChunk(id, 0)
      self.beforeChunk = hook
    end
  end
  if not runUntil(env, ready, 400) then fail("not ready: " .. env.V.msg) end
  eq(#env.V.pitLabels, 22, "pit labels")
  eq(env.V.pit, 4, "pit")
end)

T("foreign frames (other scripts' answers) do not corrupt reads", function()
  local env = newEnv({ layout = "4.1", chunkMax = 27, band = 5, channel = 4, power = 2, pit = 5 })
  local m = env.fake
  local function run(n)
    for _ = 1, n do
      m:injectForeign(777)
      tick(env)
    end
  end
  for _ = 1, 400 do
    if env.V.state == "ready" then break end
    run(1)
  end
  eq(env.V.state, "ready", "state")
  eq(env.V.band, 5, "band")
  eq(env.V.channel, 4, "channel")
  eq(env.V.pit, 5, "pit")
  eq(#env.V.pitLabels, 22, "pit labels")
  vtx.apply(env.V, { band = 3, channel = 7, power = 4 }, false)
  for _ = 1, 300 do
    if settled(env) then break end
    run(1)
  end
  eq(env.V.send, "idle", "send")
  eq(m.cfg.band, 3, "module band")
  eq(m.cfg.channel, 6, "module channel")
  eq(env.V.freq, 5925, "freq E7")
end)

T("a later chunk of the field being read is not taken as chunk 0", function()
  local env = newEnv({ layout = "4.1", band = 5, pit = 5 })
  local m = env.fake
  local once = false
  m.beforeChunk = function(self, id, chunk)
    if id == self.pitId and chunk == 0 and not once then
      once = true
      self.beforeChunk = nil
      self:sendChunk(id, 2) -- someone else's read of the last chunk, queued first
      self.beforeChunk = nil
    end
  end
  if not runUntil(env, ready, 300) then fail("not ready") end
  eq(#env.V.pitLabels, 22, "pit labels")
  local n = 0
  for i = 1, #m.reads do if m.reads[i].id == m.pitId and m.reads[i].chunk == 0 then n = n + 1 end end
  eq(n, 1, "pit chunk-0 reads")
end)

T("a 0x2B from the receiver (0xEC) with the same field id is ignored", function()
  local env = newEnv({ layout = "4.1", band = 5, pit = 5 })
  local m = env.fake
  m.beforeChunk = function(self, id, chunk)
    if id == self.pitId and chunk == 0 then
      self:enqueue(0x2B, { 0xEA, 0xEC, id, 0, self.vtxFolder, 9, 88, 0, 65, 59, 66, 0, 1, 0, 1, 0, 0 })
    end
  end
  if not runUntil(env, ready, 300) then fail("not ready") end
  eq(#env.V.pitLabels, 22, "pit labels")
  eq(env.V.pit, 5, "pit")
end)

T("stray 0x2B frames during the scan (other id, ELRS tool, later chunk) are ignored", function()
  local env = newEnv({ layout = "4.1", shift = 1, band = 5, channel = 4 })
  local m = env.fake
  local wifi = m:paramId("WiFi Connectivity")
  local injected = false
  m.beforeChunk = function(self, id, chunk)
    -- the scan's read of the folder id: three strays are queued before the real answer
    if id == self.vtxFolder and chunk == 0 and not injected then
      injected = true
      -- a different id (the answer to another widget's read)
      self:stray(0xEA, self.vtxFolder + 1, wifi)
      -- the same id for the ELRS tool (4.1+ answers it at 0xEF): a non-VTX folder entry
      self:stray(0xEF, self.vtxFolder, wifi)
      -- the same id, a later chunk (the tail of a folder: child ids and 0xFF)
      self:stray(0xEA, self.vtxFolder, nil, { 13, 14, 15, 16, 0xFF })
      -- the same id, a later chunk of a selection (option text)
      self:stray(0xEA, self.vtxFolder, nil, { 65, 85, 88, 55, 192, 59, 65, 85, 88, 55, 193, 0, 1 })
    end
  end
  if not runUntil(env, ready, 400) then fail("not ready: " .. env.V.state .. " " .. env.V.msg) end
  eq(injected, true, "strays injected during the scan")
  eq(has(env.states, "novtx"), false, "never 'No VTX Admin'")
  eq(env.V.ids.folder, m.vtxFolder, "folder id")
  eq(env.V.scanPass, 1, "found in the first pass")
  eq(env.V.band, 5, "band")
  eq(env.V.channel, 4, "channel")
end)

T("a stray entry that hides the folder in the first pass: the verification pass finds it", function()
  local env = newEnv({ layout = "4.1", shift = 2, band = 2, channel = 7 })
  local m = env.fake
  local wifi = m:paramId("WiFi Connectivity")
  local injected = 0
  m.beforeChunk = function(self, id, chunk)
    -- a well-formed chunk 0 of another folder with the folder's id, from this radio's
    -- address: it passes every check of on2B, so the first pass misses the folder
    if id == self.vtxFolder and chunk == 0 and injected == 0 then
      injected = 1
      self:stray(0xEA, self.vtxFolder, wifi)
    end
  end
  if not runUntil(env, ready, 600) then fail("not ready: " .. env.V.state .. " " .. env.V.msg) end
  eq(injected, 1, "stray injected")
  eq(has(env.states, "novtx"), false, "never 'No VTX Admin'")
  eq(env.V.scanPass, 2, "found in the verification pass")
  local pings = 0
  for i = 1, #m.log do if m.log[i].cmd == 0x28 then pings = pings + 1 end end
  eq(pings, 2, "pings (one before the verification pass)")
  eq(env.V.band, 2, "band")
  eq(env.V.channel, 7, "channel")
  eq(m.violations, 0, "overlapping reads")
end)

T("no folder poll while armed", function()
  local env = newEnv({ layout = "4.1", flags = 9 })
  env.page = true
  runUntil(env, ready, 200)
  tick(env, 20)
  eq(env.E.armed, true, "armed")
  local t0 = env.now
  tick(env, 200)
  eq(env.fake:count(0x2C, nil, nil, t0), 0, "reads while armed")
end)

T("rateHz mapping per ELRS major version", function()
  local E = elrs.new()
  eq(elrs.rateHz(E, 7), nil, "unknown version")
  E.found = true
  E.vmaj = 4
  eq(elrs.rateHz(E, 27), 250, "4.x 2.4G 250")
  eq(elrs.rateHz(E, 33), 1000, "4.x F1000")
  eq(elrs.rateHz(E, 30), 250, "4.x D250")
  eq(elrs.rateHz(E, 29), 500, "4.x 500")
  eq(elrs.rateHz(E, 0), 25, "4.x 900 25")
  eq(elrs.rateHz(E, 101), 150, "4.x dual 150")
  eq(elrs.rateHz(E, 15), nil, "4.x unused value")
  eq(math.type(elrs.rateHz(E, 27)), "integer", "integer result")
  E.vmaj = 3
  eq(elrs.rateHz(E, 7), 250, "3.x 250")
  eq(elrs.rateHz(E, 13), 1000, "3.x F1000")
  eq(elrs.rateHz(E, 9), 500, "3.x 500")
  eq(elrs.rateHz(E, 5), 150, "3.x 150")
  eq(elrs.rateHz(E, 27), nil, "3.x unknown")
  -- 2.x modules send version 0.0.0 (E.vmaj nil), so no 2.x table exists
  E.vmaj = 2
  eq(elrs.rateHz(E, 6), nil, "2.x: no table")
  E.vmaj = nil
  eq(elrs.rateHz(E, 7), nil, "version 0.0.0 (vmaj nil): RF n")
  E.vmaj = 5
  eq(elrs.rateHz(E, 7), nil, "unknown major")
  E.vmaj = 4
  eq(elrs.rateHz(E, -156), 100, "sign-extended byte")
  eq(elrs.rateHz(E, nil), nil, "nil")
end)

T("module with software version 0.0.0 (ELRS 2.x): no version in the label", function()
  local env = newEnv({ layout = "3.3", ver = { 0, 0, 0 }, name = "RM Ranger" })
  if not runUntil(env, ready, 300) then fail("not ready: " .. env.V.state .. " " .. env.V.msg) end
  local E = env.E
  eq(E.found, true, "found")
  eq(E.version, nil, "version unknown")
  eq(E.vmaj, nil, "vmaj unknown")
  eq(E.label, "RM Ranger", "label without 0.0.0")
  eq(elrs.rateHz(E, 7), nil, "no Hz without a version")
  if type(E.key) ~= "string" or string.find(E.key, "0.0.0", 1, true) == nil then
    fail("key should keep the raw version 0.0.0: " .. tostring(E.key))
  end
  -- a firmware update with a real version: label and key change
  env.fake.ver = { 3, 4, 2 }
  env.fake:deviceInfo()
  tick(env, 5)
  eq(E.label, "RM Ranger 3.4.2", "label after an update")
  eq(E.version, "3.4.2", "version after an update")
end)

T("a module stall during the scan does not skip the VTX folder", function()
  local env = newEnv({ layout = "4.1", shift = 2, band = 5, channel = 4 })
  local m = env.fake
  -- the read of the id before the VTX folder is answered; then the module stalls, so
  -- every send of the folder read is lost (4 sends in 2 s)
  local function beforeFolderRead()
    for i = 1, #m.log do
      local e = m.log[i]
      if e.cmd == 0x2C and e.p[3] == m.vtxFolder - 1 then return true end
    end
    return false
  end
  if not runUntil(env, beforeFolderRead, 400) then fail("the scan never reached the folder id") end
  m.silent = true
  tick(env, 50)          -- 2.5 s without any answer
  m.silent = false
  if not runUntil(env, ready, 1200) then
    fail("not ready after the stall: " .. env.V.state .. " " .. env.V.msg)
  end
  eq(env.V.ids.folder, m.vtxFolder, "folder found after the stall")
  eq(env.V.band, 5, "band after the stall")
end)

T("freqOf", function()
  eq(vtx.freqOf("R", 4), 5769, "R4")
  eq(vtx.freqOf("L", 8), 5621, "L8")
  eq(vtx.freqOf("", 4), 0, "no band")
  eq(vtx.freqOf("A", 9), 0, "bad channel")
end)

----------------------------------------------------------------------------
local failed, maxIns = 0, 0
local maxEnv = nil
for i = 1, #tests do
  local t = tests[i]
  local envSeen = {}
  local origNew = newEnv
  newEnv = function(opt) local e = origNew(opt); envSeen[#envSeen + 1] = e; return e end
  local ok, err = pcall(t.fn)
  newEnv = origNew
  for _, e in ipairs(envSeen) do
    if e.maxIns > maxIns then maxIns = e.maxIns; maxEnv = t.name end
  end
  if ok then
    print("PASS " .. t.name)
  else
    failed = failed + 1
    print("FAIL " .. t.name .. "\n     " .. tostring(err))
  end
end
debug.sethook()
print(string.format("max VM instructions in one tick (crsf+elrs+vtx): %d  (%s)", maxIns, tostring(maxEnv)))
if maxIns > 6000 then
  failed = failed + 1
  print("FAIL instruction budget")
end
print(string.format("%d tests, %d failed", #tests, failed))
os.exit(failed == 0 and 0 or 1)
