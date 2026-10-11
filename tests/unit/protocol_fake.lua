-- Minimal fake ExpressLRS TX module for the protocol unit tests (desktop Lua only).
-- It answers like ELRS firmware (CRSFEndpoint.cpp / TXModuleParameters.cpp 4.1.0,
-- tx_devLUA.cpp 3.3.0): 0x28 -> 0x29, 0x2C -> chunked 0x2B, 0x2D -> value write,
-- field 0 -> 0x2E status, Send VTx command with the 2 s lcsQuery rule.
-- It installs the globals crossfireTelemetryPush / crossfireTelemetryPop.

local F = {}
F.__index = F

local UPB, DNB = string.char(192), string.char(193)

local function addStr(t, s)
  for i = 1, #s do t[#t + 1] = string.byte(s, i) end
  t[#t + 1] = 0
end

local function auxUpDown(n)
  local t = {}
  for i = 1, n do
    t[#t + 1] = "AUX" .. i .. UPB
    t[#t + 1] = "AUX" .. i .. DNB
  end
  return table.concat(t, ";")
end

local function optCount(opts)
  local n = 1
  for _ in string.gmatch(opts, ";") do n = n + 1 end
  return n
end

local function optLabel(opts, idx)
  local k = 0
  for o in string.gmatch(opts .. ";", "([^;]*);") do
    if k == idx then return o end
    k = k + 1
  end
  return ""
end

-- opt: layout "4.1" | "3.3", shift (extra fields before the VTX folder), noVtx,
--      name, ver {maj,min,rev}, serial, chunkMax, band, channel (1..8), power, pit
function F.new(opt)
  opt = opt or {}
  local m = setmetatable({}, F)
  m.layout = opt.layout or "4.1"
  m.name = opt.name or "RM TX15"
  m.ver = opt.ver or ((m.layout == "4.1") and { 4, 1, 0 } or { 3, 3, 2 })
  m.serial = opt.serial or "ELRS"
  m.chunkMax = opt.chunkMax or 56
  m.latency = opt.latency or 1
  m.now = 0
  m.q = {}
  m.log = {}
  m.reads = {}
  m.writes = {}
  m.sends = {}
  m.flags = opt.flags or 1
  m.silent = false
  m.noCrsf = false
  m.busy = 0
  m.violations = 0
  m.badAddr = 0
  m.badChunk = 0
  m.readSendDuringFlow = 0
  m.pushTicks = {}
  m.maxPushPerTick = 0
  m.cfg = {
    band = opt.band or 5,
    channel = (opt.channel or 4) - 1, -- stored 0-based like ELRS config
    power = opt.power or 2,
    pit = opt.pit or 0,
  }
  m.lastLcsPoll = -100000
  m.commitDelay = opt.commitDelay or 0 -- ticks until a write shows in the reported value
  m:build(opt)
  return m
end

function F:add(p)
  local id = #self.params + 1
  p.id = id
  p.parent = p.parent or 0
  self.params[id] = p
  return id
end

function F:build(opt)
  self.params = {}
  local v41 = (self.layout == "4.1")
  local shift = opt.shift or 0
  if v41 then self:add({ name = "RF Band", type = 9, options = "2.4GHz;900MHz", value = 0 }) end
  self:add({ name = "Packet Rate", type = 9, options = "50Hz;150Hz;250Hz;500Hz;D250;F1000", value = 2 })
  self:add({ name = "Telem Ratio", type = 9, options = "Std;Off;1:128;1:64;1:32", value = 0 })
  self:add({ name = "Switch Mode", type = 9, options = "Wide;Hybrid", value = 0 })
  if v41 then self:add({ name = "Antenna Mode", type = 9, options = "Gemini;Ant 1;Ant 2;Switch", value = 0 }) end
  self:add({ name = "Link Mode", type = 9, options = "Normal;MAVLink", value = 0 })
  self:add({ name = "Model Match", type = 9, options = "Off;On", value = 0 })
  local pf = self:add({ name = "TX Power", dyn = "TX Power (100mW)", type = 11 })
  self:add({ name = "Max Power", type = 9, options = "10;25;50;100;250;500;1000", value = 3, parent = pf })
  self:add({ name = "Dynamic", type = 9, options = "Off;Dyn;AUX9;AUX10", value = 0, parent = pf })
  if v41 then self:add({ name = "Fan Thresh", type = 9, options = "10mW;25mW;50mW", value = 0, parent = pf }) end
  for k = 1, shift do
    self:add({ name = "Extra " .. k, type = 9, options = "Off;On", value = 0 })
  end
  if not opt.noVtx then
    local vf = self:add({ name = "VTX Administrator", type = 11, vtx = "folder" })
    self.vtxFolder = vf
    if v41 then
      self.bandId = self:add({ name = "Band/Enable", type = 9, options = "Disabled;A;B;E;F;R;L", vtx = "band", parent = vf })
      self.chId = self:add({ name = "Channel", type = 0, min = 1, max = 8, vtx = "channel", parent = vf })
    else
      self.bandId = self:add({ name = "Band", type = 9, options = "Off;A;B;E;F;R;L", vtx = "band", parent = vf })
      self.chId = self:add({ name = "Channel", type = 9, options = "1;2;3;4;5;6;7;8", vtx = "channel", parent = vf })
    end
    self.pwrId = self:add({ name = "Pwr Lvl", type = 9, options = "-;1;2;3;4;5;6;7;8", vtx = "power", parent = vf })
    self.pitId = self:add({ name = "Pitmode", type = 9, options = "Off;On;" .. auxUpDown(10), vtx = "pit", parent = vf })
    self.sendId = self:add({ name = "Send VTx", type = 13, step = 0, info = "", vtx = "send", parent = vf })
  end
  local wf = self:add({ name = "WiFi Connectivity", type = 11 })
  self:add({ name = "Enable WiFi", type = 13, step = 0, info = "", parent = wf })
  self:add({ name = "Bind", type = 13, step = 0, info = "" })
  if not v41 then self:add({ name = "Bad/Good", type = 12, value = "0/250   C" }) end
  self:add({ name = string.format("%d.%d.%d ISM2G4", self.ver[1], self.ver[2], self.ver[3]), type = 12, value = "a1b2c3" })
end

-- values the module reports (they change only after the config commit)
function F:reported()
  if self.commitAt ~= nil and self.now >= self.commitAt then
    self.commitAt = nil
    self.rep = nil
  end
  return self.rep or self.cfg
end

-- current option/values of the VTX fields
function F:vtxValue(p)
  local c = self:reported()
  if p.vtx == "band" then return c.band end
  if p.vtx == "channel" then
    if p.type == 0 then return (c.channel + 1) % 256 end
    return c.channel
  end
  if p.vtx == "power" then return c.power end
  if p.vtx == "pit" then return c.pit end
  return p.value
end

function F:hidden(p)
  if self.layout ~= "4.1" or p.vtx == nil then return false end
  local c = self:reported()
  if p.vtx == "channel" or p.vtx == "power" then return c.band == 0 end
  if p.vtx == "pit" then return c.band == 0 or c.power == 0 end
  return false
end

function F:folderName(p)
  if p.vtx ~= "folder" then return p.dyn or p.name end
  local c = self:reported()
  if c.band == 0 then return p.name end
  local band = self.params[self.bandId]
  local s = "VTX Admin (" .. optLabel(band.options, c.band) .. ":" .. string.char(49 + c.channel % 200)
  if c.power ~= 0 then
    s = s .. ":" .. optLabel(self.params[self.pwrId].options, c.power)
    if c.pit == 1 then
      s = s .. ":P"
    elseif c.pit >= 2 then
      s = s .. ":" .. optLabel(self.params[self.pitId].options, c.pit)
    end
  end
  return s .. ")"
end

function F:entry(id)
  local p = self.params[id]
  local e = { p.parent, p.type + (self:hidden(p) and 128 or 0) }
  if p.type == 11 then
    addStr(e, self:folderName(p))
    for i = 1, #self.params do
      if self.params[i].parent == id then e[#e + 1] = i end
    end
    e[#e + 1] = 0xFF
    return e
  end
  addStr(e, p.name)
  if p.type == 9 then
    addStr(e, p.options)
    e[#e + 1] = self:vtxValue(p) % 256
    e[#e + 1] = 0
    e[#e + 1] = optCount(p.options) - 1
    e[#e + 1] = 0
    addStr(e, "")
  elseif p.type == 0 then
    e[#e + 1] = self:vtxValue(p) % 256
    e[#e + 1] = p.min
    e[#e + 1] = p.max
    e[#e + 1] = 0
    addStr(e, "")
  elseif p.type == 13 then
    e[#e + 1] = p.step
    e[#e + 1] = 200
    addStr(e, p.info)
  elseif p.type == 12 then
    addStr(e, p.value)
  end
  return e
end

function F:enqueue(cmd, data)
  self.q[#self.q + 1] = { at = self.now + self.latency, cmd = cmd, data = data }
end

function F:sendChunk(id, chunk)
  if self.beforeChunk ~= nil then self.beforeChunk(self, id, chunk) end
  local e = self:entry(id)
  local cm = self.chunkMax
  local cnt = (#e + cm - 1) // cm
  if chunk >= cnt then
    self.badChunk = self.badChunk + 1
    return
  end
  local d = { 0xEA, 0xEE, id, cnt - chunk - 1 }
  local last = (chunk + 1) * cm
  if last > #e then last = #e end
  for i = chunk * cm + 1, last do d[#d + 1] = e[i] end
  self:enqueue(0x2B, d)
end

function F:deviceInfo()
  local d = { 0xEA, 0xEE }
  addStr(d, self.name)
  for i = 1, 4 do d[#d + 1] = string.byte(self.serial, i) or 0 end
  for _ = 1, 4 do d[#d + 1] = 0 end
  d[#d + 1] = 0
  d[#d + 1] = self.ver[1]
  d[#d + 1] = self.ver[2]
  d[#d + 1] = self.ver[3]
  d[#d + 1] = #self.params
  d[#d + 1] = 0
  self:enqueue(0x29, d)
end

function F:status()
  local d = { 0xEA, 0xEE, 0, 0, 250, self.flags }
  addStr(d, "")
  self:enqueue(0x2E, d)
end

function F:sendCmd(p, arg)
  local millis = self.now * 10
  if arg < 5 then
    self.lastLcsPoll = millis
    local msg = "Sending..."
    if self.layout == "4.1" and self.cfg.band == 0 then
      msg = "Not enabled"
    elseif p.vtx == "send" then
      self.sends[#self.sends + 1] = self.now
      self.sendActive = true
    end
    p.step = 2
    p.info = msg
    self:sendChunk(p.id, 0)
  elseif arg == 5 or millis - self.lastLcsPoll > 2000 then
    p.step = 0
    p.info = ""
    self.sendActive = false
    self:sendChunk(p.id, 0)
  end
end

function F:write(id, arg)
  local p = self.params[id]
  if p == nil then return end
  self.writes[#self.writes + 1] = { t = self.now, id = id, arg = arg }
  if p.type == 13 then
    self:sendCmd(p, arg)
    return
  end
  local c = self.cfg
  if self.commitDelay > 0 and p.vtx ~= nil then
    if self.rep == nil then
      self.rep = { band = c.band, channel = c.channel, power = c.power, pit = c.pit }
    end
    self.commitAt = self.now + self.commitDelay
  end
  -- ELRS setters do no range check
  if p.vtx == "band" then
    c.band = arg
  elseif p.vtx == "channel" then
    if p.type == 0 then c.channel = (arg - 1) % 256 else c.channel = arg end
  elseif p.vtx == "power" then
    c.power = arg
  elseif p.vtx == "pit" then
    c.pit = arg
  else
    p.value = arg
  end
end

function F:push(cmd, payload)
  if self.noCrsf then return nil end
  if cmd == nil then return true end
  if self.busy > 0 then
    self.busy = self.busy - 1
    return false
  end
  local n = (self.pushTicks[self.now] or 0) + 1
  self.pushTicks[self.now] = n
  if n > self.maxPushPerTick then self.maxPushPerTick = n end
  local p = {}
  for i = 1, #payload do p[i] = payload[i] end
  self.log[#self.log + 1] = { t = self.now, cmd = cmd, p = p }
  if (p[1] ~= 0xEE and p[1] ~= 0x00) or p[2] ~= 0xEA then
    self.badAddr = self.badAddr + 1
    return true
  end
  if self.silent then return true end
  if cmd == 0x28 then
    self:deviceInfo()
  elseif cmd == 0x2C then
    local id, chunk = p[3], p[4]
    -- one request at a time: a new read must not start while the last one is unanswered
    if self.pendingRead ~= nil and self.now - self.pendingRead < 50 then
      self.violations = self.violations + 1
    end
    self.pendingRead = self.now
    self.reads[#self.reads + 1] = { t = self.now, id = id, chunk = chunk }
    if self.sendActive and id == self.sendId then
      self.readSendDuringFlow = self.readSendDuringFlow + 1
    end
    local prm = self.params[id]
    if prm ~= nil then
      if prm.type == 13 and chunk == 0 then
        prm.step = 0
        prm.info = ""
        if id == self.sendId then self.sendActive = false end
      end
      self:sendChunk(id, chunk)
    end
  elseif cmd == 0x2D then
    local id, arg = p[3], p[4]
    if id == 0 then
      self:status()
    elseif id ~= 0x2E then
      self:write(id, arg)
    end
  end
  return true
end

function F:pop()
  local f = self.q[1]
  if f == nil or f.at > self.now then return nil end
  table.remove(self.q, 1)
  if f.cmd == 0x2B then self.pendingRead = nil end
  return f.cmd, f.data
end

function F:install(counter)
  local m = self
  crossfireTelemetryPush = function(cmd, payload)
    local c = counter and counter.on
    if counter then counter.on = false end
    local r = m:push(cmd, payload)
    if counter then counter.on = c end
    return r
  end
  crossfireTelemetryPop = function()
    local c = counter and counter.on
    if counter then counter.on = false end
    local a, b = m:pop()
    if counter then counter.on = c end
    return a, b
  end
end

-- frames that answer another script (fan-out queues): random chunks of random fields
function F:injectForeign(seed)
  self.rs = self.rs or seed or 12345
  local function rnd(n)
    self.rs = (self.rs * 1103515245 + 12345) % 2147483648
    return self.rs % n
  end
  local id = rnd(#self.params) + 1
  local e = self:entry(id)
  local cnt = (#e + self.chunkMax - 1) // self.chunkMax
  local hook = self.beforeChunk
  self.beforeChunk = nil
  local saved = self.badChunk
  self:sendChunk(id, rnd(cnt))
  self.badChunk = saved
  self.beforeChunk = hook
  if rnd(4) == 0 then self:deviceInfo() end
  if rnd(4) == 0 then self:status() end
end

-- id of the parameter with this name, or nil
function F:paramId(name)
  for i = 1, #self.params do
    if self.params[i].name == name then return i end
  end
  return nil
end

-- A stray 0x2B (an answer to another script): chunk 0 of field `fromId`, sent with the
-- field id `id` to the destination `dest` (0xEA = this radio, 0xEF = the ELRS tool).
-- `raw` (a byte list) replaces the entry data, e.g. a later chunk of a field.
function F:stray(dest, id, fromId, raw, left)
  local e = raw or self:entry(fromId)
  local d = { dest, 0xEE, id, left or 0 }
  local n = #e
  if n > self.chunkMax then n = self.chunkMax end
  for i = 1, n do d[#d + 1] = e[i] end
  self:enqueue(0x2B, d)
end

-- count pushes matching cmd (and optional field id / value) since time t0
function F:count(cmd, id, val, t0)
  local n = 0
  for i = 1, #self.log do
    local l = self.log[i]
    if l.cmd == cmd and (id == nil or l.p[3] == id) and (val == nil or l.p[4] == val)
       and (t0 == nil or l.t >= t0) then
      n = n + 1
    end
  end
  return n
end

return F
