-- fake_elrs.lua : simulated ExpressLRS TX module, CRSF parameter endpoint only.
--
-- Written from research/elrs_crsf_vtx.md sections 4-8 and the ExpressLRS
-- sources (CRSFEndpoint.cpp, TXModuleParameters.cpp 4.1.0, tx_devLUA.cpp 3.3).
-- Desktop Lua only (test harness). It never touches the widget directly:
-- edgetx_mock.lua hands it the frames that the widget pushed and asks it for
-- the frames that are due for the Lua telemetry queues.
--
-- Usage:
--   local FakeElrs = dofile("tests/fake_elrs.lua")
--   local m = FakeElrs.new{ version = "4.1.0", band = 4, channel = 2 }
--   m:handle(nowMs, cmd, bytes)     -- a frame that EdgeTX sent to the module
--   local frames = m:poll(nowMs)    -- list of { cmd = n, data = {...} } due now
--
-- Frame "data" is exactly what crossfireTelemetryPop() returns as its second
-- value: data[1] = destination, data[2] = origin, then the payload.

local M = {}
M.__index = M

local ADDR_RADIO = 0xEA
local ADDR_TX = 0xEE
local ADDR_RX = 0xEC
local ADDR_FC = 0xC8
local ADDR_ELRS_LUA = 0xEF

local T_UINT8, T_INT8, T_TEXT, T_STRING, T_FOLDER, T_INFO, T_COMMAND = 0, 1, 9, 10, 11, 12, 13

local UP = string.char(0xC0)
local DN = string.char(0xC1)

M.TYPES = { UINT8 = 0, INT8 = 1, TEXT_SELECTION = 9, STRING = 10, FOLDER = 11, INFO = 12, COMMAND = 13 }
M.BAND_LETTERS = { "A", "B", "E", "F", "R", "L" }
M.FREQ = {
  A = { 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725 },
  B = { 5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866 },
  E = { 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945 },
  F = { 5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880 },
  R = { 5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917 },
  L = { 5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621 },
}

local function auxUpDown(n)
  local t = {}
  for i = 1, n do
    t[#t + 1] = "AUX" .. i .. UP
    t[#t + 1] = "AUX" .. i .. DN
  end
  return table.concat(t, ";")
end

local function auxList(n)
  local t = {}
  for i = 1, n do t[#t + 1] = "AUX" .. i end
  return table.concat(t, ";")
end

local function splitOpts(s)
  local r = {}
  for opt in string.gmatch(s .. ";", "([^;]*);") do r[#r + 1] = opt end
  return r
end

local function countSemicolons(s)
  local n = 0
  for _ in string.gmatch(s, ";") do n = n + 1 end
  return n
end

local function pushStr(t, s)
  for i = 1, #s do t[#t + 1] = string.byte(s, i) end
  t[#t + 1] = 0
end

local function parseVersion(v)
  local a, b, c = string.match(v or "", "^(%d+)%.(%d+)%.(%d+)")
  return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

-- deterministic pseudo random generator (LCG), so test runs repeat exactly
local function rng(seed)
  local s = seed or 12345
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

---------------------------------------------------------------------------
-- parameter table
---------------------------------------------------------------------------

local function newParam(m, name, ptype, parent, fields)
  local p = fields or {}
  p.name = name
  p.type = ptype
  p.parent = parent or 0
  p.hidden = p.hidden or false
  local id = #m.params + 1
  p.id = id
  m.params[id] = p
  return p
end

local function textSel(m, name, options, value, units, parent)
  return newParam(m, name, T_TEXT, parent, { options = options, value = value or 0, units = units or "" })
end

local function command(m, name, parent)
  return newParam(m, name, T_COMMAND, parent, { step = 0, info = "" })
end

local function folder(m, name, parent)
  return newParam(m, name, T_FOLDER, parent, {})
end

local function info(m, name, value, parent)
  return newParam(m, name, T_INFO, parent, { value = value or "" })
end

-- extra fields that shift ids (RF Band, Antenna Mode, Fan Thresh, ...)
local EXTRA_DEFS = {
  { "RF Band", "900MHz;2.4GHz;X-Band" },
  { "Antenna Mode", "Gemini;Ant 1;Ant 2;Switch" },
  { "Fan Thresh", "10mW;25mW;50mW;100mW;250mW;500mW;1000mW;2000mW;Never" },
  { "BT Telemetry", "Off;On" },
  { "Extra 5", "a;b;c" },
  { "Extra 6", "a;b;c" },
}

local function buildParams(m)
  m.params = {}
  local L = m.layout
  local is41 = (L == "4.1")
  local is3x = (L == "3.3" or L == "3.4")

  -- extra fields first: they shift every id that follows
  local extras = m.extraBefore
  if type(extras) == "number" then
    local n = extras
    extras = {}
    for i = 1, n do extras[i] = EXTRA_DEFS[((i - 1) % #EXTRA_DEFS) + 1] end
  end
  for i = 1, #extras do
    local e = extras[i]
    if type(e) == "string" then e = { e, "Off;On" } end
    textSel(m, e[1], e[2], 0, "")
  end

  textSel(m, "Packet Rate",
    "50Hz(-115dBm);100Hz Full(-112dBm);150Hz(-112dBm);250Hz(-108dBm);333Hz Full(-105dBm);500Hz(-105dBm);"
    .. "D250(-104dBm);D500(-104dBm);F500(-104dBm);F1000(-104dBm)", 5, "")
  textSel(m, "Telem Ratio", "Std;Off;1:128;1:64;1:32;1:16;1:8;1:4;1:2;Race", 0, " (1:4)")
  if not m.airport then textSel(m, "Switch Mode", "Wide;Hybrid", 1, "") end
  if not is3x then textSel(m, "Link Mode", "Normal;MAVLink", 0, "") end
  if not m.airport then textSel(m, "Model Match", "Off;On", 0, " (ID: 1)") end
  local pf = folder(m, "TX Power")
  pf.dynName = "TX Power (250mW)"
  textSel(m, "Max Power", "10;25;50;100;250;500;1000", 4, "mW", pf.id)
  textSel(m, "Dynamic", "Off;Dyn;AUX9;AUX10;AUX11;AUX12", 0, "", pf.id)

  if not m.airport then
    local vf = folder(m, "VTX Administrator")
    m.ids.folder = vf.id
    local band
    if is41 then
      band = textSel(m, "Band/Enable", "Disabled;A;B;E;F;R;L", 0, "", vf.id)
    else
      band = textSel(m, "Band", "Off;A;B;E;F;R;L", 0, "", vf.id)
    end
    m.ids.band = band.id
    local ch
    if L == "3.3" then
      ch = textSel(m, "Channel", "1;2;3;4;5;6;7;8", 0, "", vf.id)
    else
      ch = newParam(m, "Channel", T_UINT8, vf.id, { value = 1, min = 1, max = 8, units = "" })
    end
    m.ids.channel = ch.id
    local pw = textSel(m, "Pwr Lvl", "-;1;2;3;4;5;6;7;8", 0, "", vf.id)
    m.ids.power = pw.id
    local pitOpts = "Off;On;" .. auxUpDown(m.pitAux)
    local pit = textSel(m, "Pitmode", pitOpts, 0, "", vf.id)
    m.ids.pit = pit.id
    local send = command(m, "Send VTx", vf.id)
    m.ids.send = send.id
  end

  local wf = folder(m, "WiFi Connectivity")
  command(m, "Enable WiFi", wf.id)
  command(m, "Enable Rx WiFi", wf.id)
  command(m, "Enable Backpack WiFi", wf.id)
  command(m, "Enable VRx WiFi", wf.id)
  local bf = folder(m, "Backpack")
  textSel(m, "Backpack", "Off;On", 1, "", bf.id)
  textSel(m, "DVR Rec", "Off;" .. auxUpDown(10), 0, "", bf.id)
  textSel(m, "DVR Srt Dly", "0s;5s;15s;30s;45s;1min;2min", 0, "", bf.id)
  textSel(m, "DVR Stp Dly", "0s;5s;15s;30s;45s;1min;2min", 0, "", bf.id)
  textSel(m, "HT Enable", "Off;On;" .. auxUpDown(10), 0, "", bf.id)
  textSel(m, "HT Start Channel", "EdgeTX;" .. auxList(10), 0, "", bf.id)
  textSel(m, "Telemetry", "Off;ESPNOW;WiFi", 0, "", bf.id)
  info(m, "Version", "1.5.0", bf.id)
  command(m, "BLE Joystick")
  if not is41 then
    info(m, "Bad/Good", "0/250")
  end
  command(m, "Bind")
  info(m, m.version .. " ISM2G4", "a1b2c3")
  m.fieldCount = #m.params
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

-- opts:
--   version      "4.1.0" (default) | "4.0.1" | "3.4.2" | "3.3.2" ...
--   layout       "4.1" | "4.0" | "3.4" | "3.3"  (default from version)
--   name         device name (default "RM TX15")
--   isElrs       false -> serial is not "ELRS" (TBS style module)
--   airport      true  -> no VTX Administrator folder
--   extraBefore  number or list of extra fields registered first (shift ids)
--   pitAux       number of AUX switches in the Pitmode list (default 10; master = 12)
--   chunk        entry bytes per 0x2B chunk (default 56; 27 at slow baud)
--   latencyMs    reply delay (default 10)
--   dropRate     0..1 probability to lose a reply frame (default 0)
--   commitMs     delay before a written value shows in reads (default 100)
--   connected    RX link up (default true)
--   armed        armed flag in 0x2E (default false)
--   notReady     device info reports fieldCount 0
--   silent       module never answers
--   forwardBroadcast  broadcast pings also produce 0x29 from RX/FC when connected (default true)
--   band, channel, power, pit   initial VTX config (band 0..6, channel 1..8)
--   seed         random seed
function M.new(opts)
  opts = opts or {}
  local m = setmetatable({}, M)
  m.version = opts.version or "4.1.0"
  m.vmaj, m.vmin, m.vrev = parseVersion(m.version)
  local L = opts.layout
  if not L then
    if m.vmaj > 4 or (m.vmaj == 4 and m.vmin >= 1) then L = "4.1"
    elseif m.vmaj == 4 then L = "4.0"
    elseif m.vmaj == 3 and m.vmin >= 4 then L = "3.4"
    else L = "3.3" end
  end
  m.layout = L
  m.name = opts.name or "RM TX15"
  m.isElrs = (opts.isElrs ~= false)
  m.airport = opts.airport or false
  m.extraBefore = opts.extraBefore or 0
  m.pitAux = opts.pitAux or 10
  m.chunk = opts.chunk or 56
  m.latencyMs = opts.latencyMs or 10
  m.dropRate = opts.dropRate or 0
  m.commitMs = opts.commitMs or 100
  m.connected = (opts.connected ~= false)
  m.armed = opts.armed or false
  m.notReady = opts.notReady or false
  m.silent = opts.silent or false
  m.forwardBroadcast = (opts.forwardBroadcast ~= false)
  m.random = rng(opts.seed or 4242)
  m.ids = {}
  buildParams(m)

  -- RAM config (changes at once on a write) and published values (what reads show)
  m.cfg = {
    band = opts.band or 0,
    channel = opts.channel or 1,
    power = opts.power or 0,
    pit = opts.pit or 0,
  }
  m.commitAt = nil
  m:_publish()

  m.vtx = { band = m.cfg.band, channel = m.cfg.channel, power = m.cfg.power, pit = m.cfg.pit,
            sends = 0, clicks = 0, sent = {} }
  m.lastLcsPoll = -100000
  m.criticalFlags = 0
  m.pending = {}
  m.log = {}
  m.violations = {}
  m.stats = { pings = 0, reads = 0, writes = 0, valueWrites = 0, statusReq = 0, clicks = 0,
              queries = 0, cancels = 0, rx = 0, tx = 0, dropped = 0, ignored = 0, foreign = 0 }
  return m
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

function M:_violation(now, msg)
  self.violations[#self.violations + 1] = { t = now, msg = msg }
  self.log[#self.log + 1] = { t = now, dir = "!!", note = msg }
end

function M:_note(now, dir, cmd, data, note)
  self.log[#self.log + 1] = { t = now, dir = dir, cmd = cmd, data = data, note = note }
end

function M:_schedule(now, cmd, data, note)
  if self.dropRate > 0 and self.random() < self.dropRate then
    self.stats.dropped = self.stats.dropped + 1
    self:_note(now, "xx", cmd, data, "dropped: " .. (note or ""))
    return
  end
  self.pending[#self.pending + 1] = { at = now + self.latencyMs, cmd = cmd, data = data, note = note }
end

-- copy RAM config into the published parameter values (updateParameters())
function M:_publish()
  local ids, P, c = self.ids, self.params, self.cfg
  if not ids.folder then return end
  P[ids.band].value = c.band
  if self.layout == "3.3" then
    P[ids.channel].value = (c.channel - 1) % 256
  else
    P[ids.channel].value = c.channel % 256
  end
  P[ids.power].value = c.power
  P[ids.pit].value = c.pit
  -- visibility rules
  local L = self.layout
  P[ids.channel].hidden = false
  P[ids.power].hidden = false
  P[ids.pit].hidden = false
  if L == "4.1" and c.band == 0 then
    P[ids.channel].hidden = true
    P[ids.power].hidden = true
    P[ids.pit].hidden = true
  end
  if (L == "4.1" or L == "4.0" or L == "3.4") and c.power == 0 then
    -- Pitmode hidden when Pwr Lvl is "-" (since 3.6.0; 3.4 layout used as 3.6 here)
    P[ids.pit].hidden = true
  end
  -- dynamic folder name
  local f = P[ids.folder]
  if c.band == 0 then
    f.dynName = nil
  else
    local bandOpts = splitOpts(P[ids.band].options)
    local s = "VTX Admin (" .. (bandOpts[c.band + 1] or "?") .. ":" .. tostring(c.channel)
    if c.power ~= 0 then
      local pw = splitOpts(P[ids.power].options)
      s = s .. ":" .. (pw[c.power + 1] or "?")
      if c.pit == 1 then
        s = s .. ":P"
      elseif c.pit >= 2 then
        local po = splitOpts(P[ids.pit].options)
        s = s .. ":" .. (po[c.pit + 1] or "?")
      end
    end
    f.dynName = s .. ")"
  end
  self.vtx = self.vtx or {}
  self.vtx.band, self.vtx.channel, self.vtx.power, self.vtx.pit = c.band, c.channel, c.power, c.pit
end

-- serialized parameter entry ("entry bytes"), 1-based array
function M:entryBytes(id)
  local p = self.params[id]
  if id == 0 then
    -- root folder "HooJ"
    local e = { 0, T_FOLDER }
    pushStr(e, "HooJ")
    for i = 1, #self.params do
      if self.params[i].parent == 0 then e[#e + 1] = i end
    end
    e[#e + 1] = 0xFF
    return e
  end
  if not p then return nil end
  local e = { p.parent, p.type + (p.hidden and 0x80 or 0) }
  if p.type == T_FOLDER then
    pushStr(e, p.dynName or p.name)
    for i = 1, #self.params do
      if self.params[i].parent == p.id then e[#e + 1] = i end
    end
    e[#e + 1] = 0xFF
    return e
  end
  pushStr(e, p.name)
  if p.type == T_TEXT then
    pushStr(e, p.options)
    e[#e + 1] = p.value % 256
    e[#e + 1] = 0
    e[#e + 1] = countSemicolons(p.options)
    e[#e + 1] = 0
    pushStr(e, p.units or "")
  elseif p.type == T_UINT8 or p.type == T_INT8 then
    e[#e + 1] = p.value % 256
    e[#e + 1] = p.min % 256
    e[#e + 1] = p.max % 256
    e[#e + 1] = 0
    pushStr(e, p.units or "")
  elseif p.type == T_COMMAND then
    e[#e + 1] = p.step
    e[#e + 1] = 200
    pushStr(e, p.info or "")
  elseif p.type == T_INFO or p.type == T_STRING then
    pushStr(e, p.value or "")
  end
  return e
end

function M:chunkCount(id)
  local e = self:entryBytes(id)
  if not e then return 0 end
  return math.floor((#e + self.chunk - 1) / self.chunk)
end

function M:_replyDest(origin)
  if self.layout == "4.1" then return origin end
  return ADDR_RADIO
end

function M:_deviceInfo(dest, origin, name, serialIsElrs, fieldCount, maj, min, rev)
  local d = { dest, origin }
  pushStr(d, name)
  if serialIsElrs then
    d[#d + 1] = 0x45; d[#d + 1] = 0x4C; d[#d + 1] = 0x52; d[#d + 1] = 0x53
  else
    d[#d + 1] = 0x00; d[#d + 1] = 0x0A; d[#d + 1] = 0xE7; d[#d + 1] = 0xC6
  end
  d[#d + 1] = 0; d[#d + 1] = 0; d[#d + 1] = 0; d[#d + 1] = 0
  d[#d + 1] = 0; d[#d + 1] = maj; d[#d + 1] = min; d[#d + 1] = rev
  d[#d + 1] = fieldCount
  d[#d + 1] = 0
  return d
end

-- one 0x2B chunk for parameter id; returns data table
function M:_chunkFrame(dest, id, chunk)
  local e = self:entryBytes(id)
  local cnt = math.floor((#e + self.chunk - 1) / self.chunk)
  local d = { dest, ADDR_TX, id, (cnt - (chunk + 1)) % 256 }
  local first = chunk * self.chunk + 1
  local last = math.min(#e, first + self.chunk - 1)
  if chunk >= cnt then
    -- the real firmware underflows an unsigned byte here and sends garbage
    for _ = 1, self.chunk do d[#d + 1] = 0xAA end
    return d, true
  end
  for i = first, last do d[#d + 1] = e[i] end
  return d, false
end

---------------------------------------------------------------------------
-- frame handling (EdgeTX -> module)
---------------------------------------------------------------------------

function M:handle(now, cmd, bytes)
  self.stats.rx = self.stats.rx + 1
  self:_note(now, "tx", cmd, bytes)
  if self.commitAt and now >= self.commitAt then
    self.commitAt = nil
    self:_publish()
  end
  if self.silent then return end
  local dest, origin = bytes[1], bytes[2]
  if dest == nil or origin == nil then
    self:_violation(now, string.format("frame 0x%02X without dest/origin bytes", cmd))
    return
  end
  if cmd == 0x28 or cmd == 0x2C or cmd == 0x2D then
    if dest ~= ADDR_TX and dest ~= 0x00 then
      self.stats.ignored = self.stats.ignored + 1
      self:_note(now, "--", cmd, bytes, "not for the TX module (dest)")
      return
    end
    if self.layout == "3.3" or self.layout == "3.4" then
      if origin ~= ADDR_RADIO and origin ~= ADDR_ELRS_LUA then
        self.stats.ignored = self.stats.ignored + 1
        self:_violation(now, string.format("origin 0x%02X ignored by ELRS 3.x (use 0xEA)", origin))
        return
      end
    end
    if origin ~= ADDR_RADIO then
      self:_violation(now, string.format("origin 0x%02X used (recommended 0xEA)", origin))
    end
  end
  local rdest = self:_replyDest(origin)

  if cmd == 0x28 then
    self.stats.pings = self.stats.pings + 1
    if dest == 0x00 then
      self:_violation(now, "broadcast ping (recommended directed ping {0xEE,0xEA})")
    end
    local fc = self.notReady and 0 or self.fieldCount
    self:_schedule(now, 0x29, self:_deviceInfo(rdest, ADDR_TX, self.name, self.isElrs, fc,
      self.vmaj, self.vmin, self.vrev), "device info")
    if dest == 0x00 and self.connected and self.forwardBroadcast then
      self:_schedule(now + 5, 0x29, self:_deviceInfo(ADDR_RADIO, ADDR_RX, "RM RP2 ELRS", true, 12,
        self.vmaj, self.vmin, self.vrev), "device info from RX (broadcast forwarded)")
      self:_schedule(now + 8, 0x29, self:_deviceInfo(ADDR_RADIO, ADDR_FC, "BETAFLIGHT", false, 0,
        4, 5, 1), "device info from FC (broadcast forwarded)")
    end
    return
  end

  if cmd == 0x2C then
    self.stats.reads = self.stats.reads + 1
    local id, chunk = bytes[3], bytes[4]
    if id == nil or chunk == nil then
      self:_violation(now, "parameter read without id/chunk")
      return
    end
    local p = self.params[id]
    if id ~= 0 and not p then
      self:_note(now, "--", cmd, bytes, "unknown field id: no reply")
      return
    end
    if p and p.type == T_COMMAND and chunk == 0 then
      -- The send flow lasts from the click to tClick + 6 s (elrs_crsf_vtx.md 8.3).
      -- After that the "executing" step is stale (nobody queried it); a chunk-0
      -- read then only resets it, as elrs.lua r18 does when it reloads a folder.
      if p.step ~= 0 and p.id == self.ids.send and now - self.lastLcsPoll <= 6000 then
        self:_violation(now, "Send VTx read with 0x2C while executing: resets its status (poll with lcsQuery)")
      end
      p.step = 0
      p.info = ""
    end
    local d, garbage = self:_chunkFrame(rdest, id, chunk)
    if garbage then
      self:_violation(now, string.format("read of chunk %d of field %d past its last chunk", chunk, id))
    end
    self:_schedule(now, 0x2B, d, string.format("field %d chunk %d", id, chunk))
    return
  end

  if cmd == 0x2D then
    self.stats.writes = self.stats.writes + 1
    local id, value = bytes[3], bytes[4]
    if id == nil then
      self:_violation(now, "parameter write without id")
      return
    end
    if id == 0 then
      self.stats.statusReq = self.stats.statusReq + 1
      self:_schedule(now, 0x2E, self:_statusFrame(rdest), "ELRS status")
      return
    end
    if id == 0x2E then
      self.criticalFlags = 0
      return
    end
    local p = self.params[id]
    if not p then
      self:_note(now, "--", cmd, bytes, "write to unknown field")
      return
    end
    if value == nil then
      self:_violation(now, "write without a value byte to field " .. p.name)
      return
    end
    if p.type == T_COMMAND then
      if id ~= self.ids.send then
        self:_violation(now, "write to command '" .. p.name .. "' (not Send VTx)")
        return
      end
      self:_sendCommand(now, value, rdest)
      return
    end
    local vtxField = nil
    for k, v in pairs(self.ids) do
      if v == id and k ~= "send" and k ~= "folder" then vtxField = k end
    end
    if not vtxField then
      self:_violation(now, "write to non-VTX field '" .. p.name .. "'")
      return
    end
    self.stats.valueWrites = self.stats.valueWrites + 1
    -- range check: the ELRS setters do none, so a bad byte is stored as is
    if p.type == T_TEXT then
      local max = countSemicolons(p.options)
      if value > max then
        self:_violation(now, string.format("out of range write %d to '%s' (max %d)", value, p.name, max))
      end
    elseif p.type == T_UINT8 then
      if value < p.min or value > p.max then
        self:_violation(now, string.format("out of range write %d to '%s' (%d..%d)", value, p.name, p.min, p.max))
      end
    end
    if vtxField == "band" then
      self.cfg.band = value
    elseif vtxField == "channel" then
      if p.type == T_TEXT then
        self.cfg.channel = value + 1
      else
        self.cfg.channel = ((value - 1) % 256) + 1
      end
    elseif vtxField == "power" then
      self.cfg.power = value
    elseif vtxField == "pit" then
      self.cfg.pit = value
    end
    self.commitAt = now + self.commitMs
    self:_note(now, "..", cmd, bytes, "config " .. vtxField .. " = " .. tostring(value))
    return
  end

  self.stats.ignored = self.stats.ignored + 1
  self:_note(now, "--", cmd, bytes, "frame type ignored")
end

function M:_statusFrame(dest)
  local flags = self.criticalFlags
  if self.connected then flags = flags + 1 end
  if self.armed then flags = flags + 8 end
  local msg = self.armed and "[ ! Armed ! ]" or ""
  local d = { dest, ADDR_TX, 0, 0, 250, flags }
  pushStr(d, msg)
  return d
end

function M:_sendCommand(now, value, rdest)
  local p = self.params[self.ids.send]
  if value < 5 then
    self.stats.clicks = self.stats.clicks + 1
    self.vtx.clicks = self.vtx.clicks + 1
    self.lastLcsPoll = now
    local msg = "Sending..."
    local c = self.cfg
    if self.layout == "4.1" and c.band == 0 then
      msg = "Not enabled"
    elseif c.band ~= 0 then
      -- VtxTriggerSend(): the MSP goes out at +1.0/+1.5/+2.0 s; a click inside
      -- that window only restarts the timer (same send sequence)
      local rec = { t = now, band = c.band, channel = c.channel, power = c.power,
                    pit = c.pit, armed = self.armed, deferred = not self.connected }
      local last = self.vtx.sent[#self.vtx.sent]
      if last and now - last.t < 2000 then
        self.vtx.sent[#self.vtx.sent] = rec
        self.vtx.restarts = (self.vtx.restarts or 0) + 1
      else
        self.vtx.sends = self.vtx.sends + 1
        self.vtx.sent[#self.vtx.sent + 1] = rec
      end
    end
    p.step = 2
    p.info = msg
    self:_schedule(now, 0x2B, (self:_chunkFrame(rdest, p.id, 0)), "Send VTx: " .. msg)
  else
    if value == 6 then self.stats.queries = self.stats.queries + 1 end
    if value == 5 then self.stats.cancels = self.stats.cancels + 1 end
    if value == 5 or (now - self.lastLcsPoll) > 2000 then
      p.step = 0
      p.info = ""
      self:_schedule(now, 0x2B, (self:_chunkFrame(rdest, p.id, 0)), "Send VTx: idle")
    else
      self:_note(now, "--", 0x2D, nil, "lcsQuery within 2 s of the click: no reply")
    end
  end
end

---------------------------------------------------------------------------
-- module -> EdgeTX
---------------------------------------------------------------------------

-- returns the frames whose time has come (in order), and removes them
function M:poll(now)
  if self.commitAt and now >= self.commitAt then
    self.commitAt = nil
    self:_publish()
  end
  local due, keep = {}, {}
  for i = 1, #self.pending do
    local f = self.pending[i]
    if f.at <= now then due[#due + 1] = f else keep[#keep + 1] = f end
  end
  self.pending = keep
  table.sort(due, function(a, b) return a.at < b.at end)
  for i = 1, #due do
    self.stats.tx = self.stats.tx + 1
    self:_note(now, "rx", due[i].cmd, due[i].data, due[i].note)
  end
  return due
end

---------------------------------------------------------------------------
-- test controls
---------------------------------------------------------------------------

-- change the VTX config as another tool (the ELRS Lua script) would
function M:setConfig(c)
  for k, v in pairs(c) do self.cfg[k] = v end
  self.commitAt = nil
  self:_publish()
end

function M:setConnected(v) self.connected = v and true or false end
function M:setArmed(v) self.armed = v and true or false end

-- frames that answer other scripts (ELRS tool, EdgeTX itself): stray traffic
function M:injectForeign(now, n)
  for _ = 1, n do
    local r = self.random()
    if r < 0.15 then
      self:_schedule(now, 0x29, self:_deviceInfo(ADDR_RADIO, ADDR_TX, self.name, self.isElrs, self.fieldCount,
        self.vmaj, self.vmin, self.vrev), "foreign: device info")
    elseif r < 0.25 then
      self:_schedule(now, 0x2E, self:_statusFrame(ADDR_RADIO), "foreign: status")
    else
      local id = 1 + math.floor(self.random() * self.fieldCount)
      if id > self.fieldCount then id = self.fieldCount end
      local cnt = self:chunkCount(id)
      local chunk = math.floor(self.random() * cnt)
      if chunk >= cnt then chunk = cnt - 1 end
      self:_schedule(now, 0x2B, (self:_chunkFrame(ADDR_RADIO, id, chunk)),
        string.format("foreign: field %d chunk %d", id, chunk))
    end
    self.stats.foreign = self.stats.foreign + 1
  end
end

function M:paramByName(name)
  for i = 1, #self.params do
    if self.params[i].name == name then return self.params[i] end
  end
  return nil
end

function M.freqOf(band, channel)
  local letter = M.BAND_LETTERS[band]
  if not letter then return 0 end
  local t = M.FREQ[letter]
  return (t and t[channel]) or 0
end

local function hexBytes(d)
  if not d then return "" end
  local t = {}
  for i = 1, #d do t[#t + 1] = string.format("%02X", d[i] % 256) end
  return table.concat(t, " ")
end

function M:logText()
  local lines = {}
  for i = 1, #self.log do
    local e = self.log[i]
    lines[#lines + 1] = string.format("%8d %s %s %s %s", e.t, e.dir,
      e.cmd and string.format("0x%02X", e.cmd) or "    ", hexBytes(e.data), e.note or "")
  end
  return table.concat(lines, "\n")
end

function M:describe()
  return string.format("ELRS %s layout %s fields=%d chunk=%d vtx: band=%d ch=%d pwr=%d pit=%d sends=%d",
    self.version, self.layout, self.fieldCount, self.chunk, self.cfg.band, self.cfg.channel,
    self.cfg.power, self.cfg.pit, self.vtx.sends)
end

return M
