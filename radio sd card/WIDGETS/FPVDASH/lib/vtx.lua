-- VTX Administrator controller: reads and writes the "VTX Administrator" folder
-- of the ExpressLRS TX module through CRSF parameter frames.
--   0x2C read  {0xEE, 0xEA, id, chunk}   -> 0x2B {0xEA, 0xEE, id, chunksLeft, data...}
--   0x2D write {0xEE, 0xEA, id, value}   -> no reply (command fields reply with 0x2B)
-- Field ids differ between firmware versions and targets, so the folder is found
-- by name ("VTX Admin...") and its children are classified by name and type.
-- Rules: one request at a time, one push per tick, no push when allow is false,
-- writes are clamped to the parsed range and read back after 300 ms, and the
-- "Send VTx" command is never read with 0x2C while it runs (a read resets it).
--
-- Public fields (see DESIGN.md 5.3): state, msg, ready, bandLabels, band,
-- bandLetter, channel, powerLabels, power, pitLabels, pit, freq, send, sendMsg, rev.

local M = {}

local TX, ME = 0xEE, 0xEA

-- arrow bytes 0xC0/0xC1 in ELRS option labels
local UP = (type(CHAR_UP) == "string") and CHAR_UP or "^"
local DN = (type(CHAR_DOWN) == "string") and CHAR_DOWN or "v"

-- timing in 10 ms ticks
local T_CHUNK = 50       -- reply timeout for one read
local MAX_TRIES = 3      -- resends of one chunk before the module counts as gone
local T_WGAP = 10        -- gap between two writes
local T_SETTLE = 30      -- wait after the last write before the read-back
local T_RECHECK = 50     -- second read-back when the first one shows the old value
local T_CLICK = 100      -- wait for the reply to the Send VTx click
local T_QUERY = 220      -- first status query after the click (module needs > 2 s)
local T_QREP = 50        -- repeat of the status query
local T_SENDMAX = 600    -- stop waiting for the send status
local T_POLL_PAGE = 200  -- folder poll while the VTX page is open
local T_POLL_DASH = 1500 -- folder poll on the dashboard (per frame of the folder)
local T_RESULT = 1000    -- time a send result stays shown

local MAX_ENTRY = 600    -- bytes kept for one field

-- ExpressLRS frequency table (src/lib/MSPVTX/freqTable.h), channel 1..8
local FREQ = {
  A = { 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725 },
  B = { 5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866 },
  E = { 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945 },
  F = { 5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880 },
  R = { 5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917 },
  L = { 5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621 },
}

local sbyte, ssub, sfind, sgsub, schar = string.byte, string.sub, string.find, string.gsub, string.char

function M.freqOf(letter, ch)
  local t = FREQ[letter]
  if t == nil or type(ch) ~= "number" then return 0 end
  return t[math.floor(ch + 0.5)] or 0
end

----------------------------------------------------------------------------
-- parsing

-- t[i], ..., t[j] as separate values, like table.unpack (black-and-white radios have no
-- table library). Up to eight values per call level keep the recursion short; nothing
-- when j < i.
local function vals(t, i, j)
  local n = j - i
  if n >= 7 then
    return t[i], t[i + 1], t[i + 2], t[i + 3], t[i + 4], t[i + 5], t[i + 6], t[i + 7], vals(t, i + 8, j)
  elseif n >= 3 then
    return t[i], t[i + 1], t[i + 2], t[i + 3], vals(t, i + 4, j)
  elseif n >= 1 then
    return t[i], t[i + 1], vals(t, i + 2, j)
  elseif n == 0 then
    return t[i]
  end
end

-- The bytes t[i..j] as a string. One string.char call per piece of up to 64 bytes (a CRSF
-- frame is at most 64 bytes); a longer entry joins its pieces.
local function bstr(t, i, j)
  if j < i then return "" end
  if j - i < 64 then return schar(vals(t, i, j)) end
  local s = ""
  while i <= j do
    local k = i + 63
    if k > j then k = j end
    s = s .. schar(vals(t, i, k))
    i = k + 1
  end
  return s
end

local function splitOpts(o)
  o = sgsub(o, "\192", UP)
  o = sgsub(o, "\193", DN)
  local t = {}
  for x in string.gmatch(o .. ";", "([^;]*);") do t[#t + 1] = x end
  return t
end

-- entry = [parent][type | 0x80 hidden][name..0][type data]
local function parse(s)
  local n = #s
  if n < 3 then return nil end
  local tb = sbyte(s, 2)
  local f = { parent = sbyte(s, 1), type = tb % 128, hidden = tb >= 128 }
  local z = sfind(s, "\0", 3, true)
  if z == nil then return nil end
  f.name = ssub(s, 3, z - 1)
  local i = z + 1
  local t = f.type
  if t == 9 then
    -- options..0 value min max default unit..0
    local z2 = sfind(s, "\0", i, true)
    if z2 == nil or z2 + 3 > n then return nil end
    f.raw = ssub(s, i, z2 - 1)
    f.options = splitOpts(f.raw)
    f.value, f.min, f.max = sbyte(s, z2 + 1, z2 + 3)
  elseif t <= 3 then
    -- (U)INT8 / (U)INT16: value min max default unit..0, big-endian
    local size = math.floor(t / 2) + 1
    if i + 3 * size - 1 > n then return nil end
    local v, mn, mx = 0, 0, 0
    for k = 0, size - 1 do
      v = v * 256 + sbyte(s, i + k)
      mn = mn * 256 + sbyte(s, i + size + k)
      mx = mx * 256 + sbyte(s, i + 2 * size + k)
    end
    if t % 2 == 1 then
      local half = (size == 1) and 128 or 32768
      if v >= half then v = v - 2 * half end
      if mn >= half then mn = mn - 2 * half end
      if mx >= half then mx = mx - 2 * half end
    end
    f.value, f.min, f.max = v, mn, mx
  elseif t == 11 then
    -- folder: child ids.. 0xFF
    local z3 = sfind(s, "\255", i, true)
    local e = z3 and (z3 - 1) or n
    if e >= i then f.children = { sbyte(s, i, e) } else f.children = {} end
  elseif t == 13 then
    -- command: status timeout info..0
    if i + 1 > n then return nil end
    f.status, f.timeout = sbyte(s, i, i + 1)
    local z4 = sfind(s, "\0", i + 2, true)
    f.info = ssub(s, i + 2, (z4 or (n + 1)) - 1)
  elseif t == 10 or t == 12 then
    local z5 = sfind(s, "\0", i, true)
    f.value = ssub(s, i, (z5 or (n + 1)) - 1)
  end
  return f
end

local function clamp(x, lo, hi)
  if type(x) ~= "number" then return lo end
  x = math.floor(x + 0.5)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function isVtxFolder(f)
  return f ~= nil and f.type == 11 and f.parent == 0 and ssub(f.name, 1, 9) == "VTX Admin"
end

----------------------------------------------------------------------------
-- public state

local function pub(V, state, msg, ready)
  if V.state ~= state or V.msg ~= msg or V.ready ~= ready then
    V.state = state
    V.msg = msg
    V.ready = ready
    V.rev = V.rev + 1
  end
end

local function setSend(V, send, msg, now)
  if V.send ~= send or V.sendMsg ~= msg then
    V.send = send
    V.sendMsg = msg
    V.rev = V.rev + 1
  end
  if now ~= nil and send ~= "idle" and send ~= "writing" and send ~= "sending" then
    V.resAt = now + T_RESULT
  else
    V.resAt = nil
  end
end

-- state/msg for an operational controller
local function pubReady(V)
  if V.job ~= nil or V.sf ~= nil or V.busyMsg ~= nil then
    pub(V, "busy", V.busyMsg or "Working...", true)
  elseif V.err ~= nil then
    pub(V, "error", V.err, true)
  elseif V.band == 0 then
    pub(V, "ready", "VTX Admin disabled", true)
  else
    pub(V, "ready", "Ready", true)
  end
end

local function resetValues(V)
  V.bandLabels = {}
  V.powerLabels = {}
  V.pitLabels = {}
  V.band, V.channel, V.power, V.pit, V.freq = 0, 0, 0, 0, 0
  V.bandLetter = ""
  V.bRaw, V.pRaw, V.tRaw = nil, nil, nil
  V.rev = V.rev + 1
end

-- copy the module values of the parsed fields into the public fields
local function refreshPublic(V)
  local ids, f = V.ids, V.f
  local ch = false
  local fb = f[ids.band]
  if fb ~= nil and fb.type == 9 then
    if fb.raw ~= V.bRaw then
      V.bRaw = fb.raw
      V.bandLabels = fb.options
      ch = true
    end
    local b = clamp(fb.value, 0, #V.bandLabels - 1)
    if b ~= V.band then V.band = b; ch = true end
  end
  local fc = f[ids.channel]
  if fc ~= nil and (fc.type == 0 or fc.type == 9) then
    local c
    if fc.type == 9 then
      c = tonumber(fc.options[(fc.value or 0) + 1] or "") or ((fc.value or 0) + 1)
    else
      c = fc.value or 0
    end
    if c < 1 or c > 8 then c = 0 end
    if c ~= V.channel then V.channel = c; ch = true end
  end
  local fp = ids.power and f[ids.power]
  if fp and fp.type == 9 then
    if fp.raw ~= V.pRaw then
      V.pRaw = fp.raw
      V.powerLabels = fp.options
      ch = true
    end
    local p = clamp(fp.value, 0, #V.powerLabels - 1)
    if p ~= V.power then V.power = p; ch = true end
  elseif V.pRaw ~= nil then
    V.pRaw = nil
    V.powerLabels = {}
    V.power = 0
    ch = true
  end
  local ft = ids.pit and f[ids.pit]
  if ft and ft.type == 9 then
    if ft.raw ~= V.tRaw then
      V.tRaw = ft.raw
      V.pitLabels = ft.options
      ch = true
    end
    local p = clamp(ft.value, 0, #V.pitLabels - 1)
    if p ~= V.pit then V.pit = p; ch = true end
  elseif V.tRaw ~= nil then
    V.tRaw = nil
    V.pitLabels = {}
    V.pit = 0
    ch = true
  end
  if ch then
    local letter = ""
    if V.band > 0 then letter = V.bandLabels[V.band + 1] or "" end
    V.bandLetter = letter
    V.freq = M.freqOf(letter, V.channel)
    V.rev = V.rev + 1
  end
end

----------------------------------------------------------------------------
-- request engine (one read at a time)

local function startRead(V, id, nameOnly)
  local r = V.rq
  r.active = true
  r.done = false
  r.sent = false
  r.failed = false
  r.id = id
  r.chunk = 0
  r.expect = -1
  r.n = 0
  r.s = ""
  r.tries = 0
  r.deadline = 0
  r.nameOnly = nameOnly
  -- expected parent and type of chunk 0 (all full reads are the VTX folder or its
  -- children), so a later chunk of the same field from someone else is not taken
  local par, typ = -1, -1
  local fo = V.ids.folder
  if not nameOnly and fo ~= nil then
    if id == fo then
      par, typ = 0, 11
    else
      par = fo
      local f = V.f[id]
      if f ~= nil then typ = f.type end
    end
  end
  r.par = par
  r.typ = typ
end

-- read a list of field ids one after the other; purpose decides what happens at the end
local function startList(V, list, purpose)
  V.rl = list
  V.rli = 1
  V.rlp = purpose
  V.pfail = 0
  if list[1] == nil then
    V.rq.active = false
    return false
  end
  startRead(V, list[1], false)
  return true
end

local function valueIds(V, withFolder)
  local ids = V.ids
  local l = {}
  if withFolder then l[#l + 1] = ids.folder end
  l[#l + 1] = ids.band
  l[#l + 1] = ids.channel
  if ids.power then l[#l + 1] = ids.power end
  if ids.pit then l[#l + 1] = ids.pit end
  return l
end

local function pumpRead(V, C, now)
  local r = V.rq
  if not r.sent then
    local pl = V.pl
    pl[3] = r.id
    pl[4] = r.chunk
    if C.push(C, 0x2C, pl) then
      r.sent = true
      r.deadline = now + T_CHUNK
    end
    return
  end
  if now > r.deadline then
    r.tries = r.tries + 1
    if r.tries > MAX_TRIES then
      r.active = false
      r.failed = true
    else
      r.sent = false
    end
  end
end

----------------------------------------------------------------------------
-- Send VTx command flow

local function endSend(V, send, msg, now)
  V.sf = nil
  V.busyMsg = nil
  if send == "failed" then V.err = msg else V.err = nil end
  setSend(V, send, msg, now)
  pubReady(V)
end

local function sendResult(V, E, now)
  if E.linkUp == false then
    endSend(V, "queued", "Queued: no RX link", now)
  else
    endSend(V, "sent", "Sent", now)
  end
end

local function startSend(V, now)
  V.sf = { phase = "click", sent = false, tries = 0, deadline = 0, tClick = nil, queryAt = 0 }
  V.busyMsg = "Sending..."
  setSend(V, "sending", "Sending...", nil)
  pubReady(V)
end

-- 0x2B for the Send VTx field while the flow runs: [dest][orig][id][left][parent][type][name..0][status][timeout][info..0]
local function onSendStatus(V, sf, d, now)
  local f = parse(bstr(d, 5, #d))
  if f == nil or f.type ~= 13 or f.parent ~= V.ids.folder then return end
  if f.status == 2 or f.status == 1 then
    if sf.phase == "click" and sf.sent then
      if f.info == "Not enabled" then
        sf.phase = "notenabled"
      else
        sf.phase = "wait"
        sf.queryAt = (sf.tClick or now) + T_QUERY
      end
    end
  elseif f.status == 0 then
    if sf.phase == "query" then sf.phase = "done" end
  elseif f.status == 3 then
    -- Send VTx never asks for confirmation; answer "cancel" to be safe
    sf.phase = "cancel"
  end
end

local function stepSend(V, C, E, now)
  local sf = V.sf
  local ph = sf.phase
  local pl = V.pl
  if ph == "notenabled" then
    endSend(V, "notenabled", "Enable a band first", now)
  elseif ph == "done" then
    sendResult(V, E, now)
  elseif ph == "cancel" then
    pl[3] = V.ids.send
    pl[4] = 5
    if C.push(C, 0x2D, pl) then endSend(V, "failed", "Send cancelled", now) end
  elseif ph == "click" then
    if not sf.sent then
      pl[3] = V.ids.send
      pl[4] = 1 -- lcsClick
      if C.push(C, 0x2D, pl) then
        sf.sent = true
        sf.tClick = now
        sf.deadline = now + T_CLICK
      end
    elseif now > sf.deadline then
      sf.tries = sf.tries + 1
      if sf.tries > 1 then
        endSend(V, "failed", "No reply to Send", now)
      else
        sf.sent = false -- click once more (only restarts the module timer)
      end
    end
  else -- "wait" or "query"
    if now >= sf.queryAt then
      if now > sf.tClick + T_SENDMAX then
        sendResult(V, E, now)
        return
      end
      pl[3] = V.ids.send
      pl[4] = 6 -- lcsQuery: the module answers status 0 once 2 s have passed
      if C.push(C, 0x2D, pl) then
        sf.phase = "query"
        sf.queryAt = now + T_QREP
      end
    end
  end
end

----------------------------------------------------------------------------
-- write job (apply)

local function endJob(V, now)
  V.job = nil
  V.busyMsg = nil
  pubReady(V)
end

local function failJob(V, msg, now)
  V.job = nil
  V.busyMsg = nil
  V.err = msg
  setSend(V, "failed", msg, now)
  pubReady(V)
end

local function afterWrites(V, now)
  local job = V.job
  if job.send then
    if V.band == 0 then
      V.job = nil
      V.busyMsg = nil
      V.err = nil
      setSend(V, "notenabled", "Enable a band first", now)
      pubReady(V)
    else
      V.job = nil
      V.err = nil
      startSend(V, now)
    end
  else
    V.err = nil
    setSend(V, "idle", "", nil)
    endJob(V, now)
  end
end

-- module value of a public channel number
local function channelWire(V, ch)
  local fc = V.f[V.ids.channel]
  if fc.type == 9 then
    local o = fc.options
    for k = 1, #o do
      if tonumber(o[k]) == ch then return k - 1 end
    end
    return clamp(ch - 1, 0, #o - 1)
  end
  local lo = fc.min or 1
  if lo < 1 then lo = 1 end
  local hi = fc.max or 8
  if hi < lo then hi = lo end
  return clamp(ch, lo, hi)
end

local function channelRange(V)
  local fc = V.f[V.ids.channel]
  if fc.type == 9 then return 1, #fc.options end
  local lo = fc.min or 1
  if lo < 1 then lo = 1 end
  local hi = fc.max or 8
  if hi < lo then hi = lo end
  return lo, hi
end

local function selMax(V, id)
  local f = V.f[id]
  local hi = #f.options - 1
  if f.max ~= nil and f.max < hi then hi = f.max end
  if hi < 0 then hi = 0 end
  return hi
end

local function startJob(V, now)
  local p = V.pend
  V.pend = nil
  local ids = V.ids
  local wid, wv = {}, {}
  if p.band ~= nil and ids.band then
    local b = clamp(p.band, 0, selMax(V, ids.band))
    if b ~= V.band then wid[#wid + 1] = ids.band; wv[#wv + 1] = b end
  end
  if p.channel ~= nil and ids.channel then
    local lo, hi = channelRange(V)
    local c = clamp(p.channel, lo, hi)
    if c ~= V.channel then wid[#wid + 1] = ids.channel; wv[#wv + 1] = channelWire(V, c) end
  end
  if p.power ~= nil and ids.power then
    local v = clamp(p.power, 0, selMax(V, ids.power))
    if v ~= V.power then wid[#wid + 1] = ids.power; wv[#wv + 1] = v end
  end
  if p.pit ~= nil and ids.pit then
    local v = clamp(p.pit, 0, selMax(V, ids.pit))
    if v ~= V.pit then wid[#wid + 1] = ids.pit; wv[#wv + 1] = v end
  end
  V.job = { req = p, ids = wid, wires = wv, wi = 1, nextAt = now, phase = "write", tries = 0, send = p.send }
  V.err = nil
  if #wid == 0 then
    afterWrites(V, now)
    return
  end
  V.busyMsg = "Writing..."
  setSend(V, "writing", "", nil)
  pubReady(V)
end

local function stepJob(V, C, now)
  local job = V.job
  if now < job.nextAt then return end
  if job.phase == "write" then
    local k = job.wi
    local pl = V.pl
    pl[3] = job.ids[k]
    pl[4] = job.wires[k]
    if C.push(C, 0x2D, pl) then
      job.wi = k + 1
      job.nextAt = now + T_WGAP
      if job.wi > #job.ids then
        job.phase = "settle"
        job.nextAt = now + T_SETTLE
      end
    end
  elseif job.phase == "settle" then
    local l = {}
    for k = 1, #job.ids do l[k] = job.ids[k] end
    l[#l + 1] = V.ids.folder
    job.phase = "verify"
    V.busyMsg = "Checking..."
    pubReady(V)
    startList(V, l, "verify")
  end
end

local function verifyDone(V, now)
  local job = V.job
  refreshPublic(V)
  local bid, bw = {}, {}
  for k = 1, #job.ids do
    local f = V.f[job.ids[k]]
    if f == nil or f.value ~= job.wires[k] then
      bid[#bid + 1] = job.ids[k]
      bw[#bw + 1] = job.wires[k]
    end
  end
  if #bid == 0 then
    afterWrites(V, now)
  elseif not job.rechecked then
    -- the module reports a new value only after its config commit: read once more
    job.rechecked = true
    job.ids = bid
    job.wires = bw
    job.phase = "settle"
    job.nextAt = now + T_RECHECK
  elseif job.tries < 2 then
    job.tries = job.tries + 1
    job.rechecked = false
    job.ids = bid
    job.wires = bw
    job.wi = 1
    job.phase = "write"
    job.nextAt = now
    V.busyMsg = "Writing..."
    pubReady(V)
  else
    failJob(V, "Write not applied", now)
  end
end

----------------------------------------------------------------------------
-- discovery and state changes

local function dropWork(V, why, now)
  V.rq.active = false
  V.busyMsg = nil
  if V.sf ~= nil then
    if V.sf.tClick ~= nil then
      V.sf = nil
      setSend(V, "sent", "Sent (not checked)", now)
    else
      V.sf = nil
      setSend(V, "failed", why, now)
    end
  end
  if V.job ~= nil then
    V.job = nil
    setSend(V, "failed", why, now)
  end
  if V.pend ~= nil then
    V.pend = nil
    setSend(V, "failed", why, now)
  end
end

-- module not usable: keep the last values but mark them not valid
local function setDown(V, state, msg, now)
  if V.st ~= "down" then
    V.st = "down"
    V.verify = false
    dropWork(V, msg, now)
    V.err = nil
  end
  pub(V, state, msg, false)
end

local function setNoVtx(V, now)
  V.st = "novtx"
  V.verify = false
  dropWork(V, "No VTX Admin", now)
  pub(V, "novtx", "No VTX Admin on module", false)
end

local function beginScan(V, E, now)
  V.rq.active = false
  if V.pend ~= nil or V.job ~= nil or V.sf ~= nil then dropWork(V, "Module changed", now) end
  V.ids = {}
  V.f = {}
  V.key = E.key
  V.fc = E.fieldCount or 0
  V.fname = nil
  V.err = nil
  resetValues(V)
  V.scanId = 1
  V.scanPass = V.verify and 2 or 1
  V.verify = false
  V.st = "scan"
  pub(V, "load", V.scanPass == 2 and "Checking VTX Admin" or "Searching VTX Admin", false)
  if V.fc < 1 then
    setNoVtx(V, now)
    return
  end
  V.rlp = "scan"
  startRead(V, 1, true)
end

-- Every id was read and none is the VTX folder. A stray reply that passed the checks of
-- on2B (another script's read of the same id) could have hidden the folder, and "No VTX
-- Admin" stays until a reload, so one more complete pass runs first: ping the module
-- again (this also checks the field count); its 0x29 reply starts the second pass
-- (M.tick: E.gen changes, beginScan with V.verify set). The second miss is final.
local function scanEnd(V, E, now)
  if V.scanPass >= 2 then
    setNoVtx(V, now)
    return
  end
  V.verify = true
  V.st = "verify"
  E.repingReq = true
  pub(V, "load", "Checking VTX Admin", false)
end

local function nextScan(V, E, now)
  V.st = "scan"
  V.rlp = "scan"
  V.scanId = V.scanId + 1
  if V.scanId > V.fc then
    scanEnd(V, E, now)
  else
    startRead(V, V.scanId, true)
  end
end

local function classify(V, now)
  local ids = V.ids
  local fo = V.f[ids.folder]
  local keep = {}
  keep[ids.folder] = fo
  for k = 1, #fo.children do
    local c = fo.children[k]
    local f = V.f[c]
    if f ~= nil then
      local nm, t = f.name, f.type
      if t == 9 and ssub(nm, 1, 4) == "Band" then
        ids.band = c
      elseif nm == "Channel" and (t == 0 or t == 9) then
        ids.channel = c
      elseif t == 9 and ssub(nm, 1, 3) == "Pwr" then
        ids.power = c
      elseif t == 9 and ssub(nm, 1, 3) == "Pit" then
        ids.pit = c
      elseif t == 13 and (ids.send == nil or ssub(nm, 1, 4) == "Send") then
        ids.send = c
      end
    end
  end
  if ids.band == nil or ids.channel == nil or ids.send == nil then
    setNoVtx(V, now)
    return
  end
  -- keep only the fields that are used
  keep[ids.band] = V.f[ids.band]
  keep[ids.channel] = V.f[ids.channel]
  if ids.power then keep[ids.power] = V.f[ids.power] end
  if ids.pit then keep[ids.pit] = V.f[ids.pit] end
  keep[ids.send] = V.f[ids.send]
  V.f = keep
  V.st = "ready"
  V.nextPoll = now + (V.pageWas and T_POLL_PAGE or T_POLL_DASH)
  V.pageEdge = false
  refreshPublic(V)
  pubReady(V)
end

local function readFailed(V, E, now)
  -- No reply, also during the scan: ELRS answers every id 1..fieldCount, so a missing
  -- reply means a transport problem, never an id without a parameter. Skipping the id
  -- could skip the VTX folder and give a wrong "No VTX Admin".
  -- The module stopped answering (reboot, removed, stall): find it again (the 0x29
  -- reply starts a new scan from id 1);
  -- wait 30 s before the next try when this keeps happening
  V.lostN = V.lostN + 1
  if V.lostN >= 3 then
    V.lostN = 0
    V.holdUntil = now + 3000
  end
  E.repingReq = true
  V.st = "lost"
  dropWork(V, "No reply from module", now)
  pub(V, "search", "Module not answering", false)
end

local function listDone(V, E, now)
  local p = V.rlp
  local ids = V.ids
  V.lostN = 0
  if p == "folder" then
    local fo = V.f[ids.folder]
    if not isVtxFolder(fo) then
      ids.folder = nil
      nextScan(V, E, now)
      return
    end
    V.fname = fo.name
    local l = {}
    for k = 1, #fo.children do l[k] = fo.children[k] end
    V.st = "load"
    pub(V, "load", "Loading VTX settings", false)
    if not startList(V, l, "load") then setNoVtx(V, now) end
  elseif p == "load" then
    classify(V, now)
  elseif p == "validate" then
    local fo = V.f[ids.folder]
    local ok = isVtxFolder(fo)
    if ok then
      local have = {}
      for k = 1, #fo.children do have[fo.children[k]] = true end
      ok = have[ids.band] and have[ids.channel] and have[ids.send]
    end
    if ok then
      V.fname = fo.name
      V.st = "reread"
      startList(V, valueIds(V, false), "reread")
    else
      beginScan(V, E, now)
    end
  elseif p == "reread" then
    V.st = "ready"
    V.nextPoll = now + (V.pageWas and T_POLL_PAGE or T_POLL_DASH)
    V.pageEdge = false
    refreshPublic(V)
    pubReady(V)
  elseif p == "poll" then
    local fo = V.f[ids.folder]
    if not isVtxFolder(fo) then
      beginScan(V, E, now)
      return
    end
    if fo.name ~= V.fname then
      -- changed outside this widget: read the values again
      V.fname = fo.name
      startList(V, valueIds(V, false), "refresh")
    end
  elseif p == "refresh" or p == "reload" then
    if V.f[ids.folder] ~= nil then V.fname = V.f[ids.folder].name end
    if p == "reload" then V.busyMsg = nil end
    refreshPublic(V)
    pubReady(V)
  elseif p == "verify" then
    V.fname = V.f[ids.folder] and V.f[ids.folder].name or V.fname
    verifyDone(V, now)
  end
end

local function readDone(V, E, now)
  local r = V.rq
  r.active = false
  if V.rlp == "scan" then
    -- chunk 0 only: parent, type and the start of the name
    local s = r.s
    local p, tb = sbyte(s, 1, 2)
    if p == 0 and tb ~= nil and tb % 128 == 11 and ssub(s, 3, 11) == "VTX Admin" then
      V.ids.folder = r.id
      V.st = "folder"
      startList(V, { r.id }, "folder")
    else
      nextScan(V, E, now)
    end
    return
  end
  local f = parse(r.s)
  if f == nil then
    -- broken entry (e.g. chunk size changed): read it again from chunk 0
    V.pfail = V.pfail + 1
    if V.pfail <= 2 then
      startRead(V, r.id, false)
    else
      readFailed(V, E, now)
    end
    return
  end
  if f.type == 11 and r.id == V.ids.folder then V.fchunks = r.chunk + 1 end
  V.f[r.id] = f
  V.rli = V.rli + 1
  local nid = V.rl[V.rli]
  if nid ~= nil then
    startRead(V, nid, false)
    return
  end
  listDone(V, E, now)
end

-- True when the 0x2B data d (len bytes) can be chunk 0 of a parameter entry:
-- [dest][origin][id][left][parent][type][name..0]. The parent is 0 (root) or a folder id
-- (<= fc), ELRS sends only types 0..13 (15 and 127 are allowed as well), and a name has
-- no control characters and ends with 0 in this chunk unless more chunks follow.
-- A later chunk of the same field (another script's read of it) or a frame that is not
-- an entry does not pass. A real chunk 0 always passes (a rejected answer would look like
-- a lost reply).
local function entryStart(d, len, left, fc)
  if len < 6 or d[5] > fc then return false end
  local t = d[6] % 128
  if t > 15 and t ~= 127 then return false end
  for i = 7, len do
    local b = d[i]
    if b == 0 then return true end
    if b < 32 or b == 127 then return false end
  end
  return left > 0
end

-- 0x2B parameter entry chunk. A reply is taken only when it belongs to the outstanding
-- request: from the TX module (origin 0xEE) to this radio (destination 0xEA; ELRS 4.1+
-- answers the ELRS tool at its own origin), the same field id, and the expected chunk
-- (chunk 0 must look like the start of an entry, later chunks must count down).
local function on2B(V, d, now)
  if d[2] ~= TX or d[1] ~= ME then return end
  local id = d[3]
  local r = V.rq
  if r.active and r.sent and not r.done and id == r.id then
    local left = d[4]
    local len = #d
    if left == nil or len < 5 then return end
    if r.expect >= 0 then
      if left ~= r.expect then return end -- duplicate or someone else's chunk
    elseif len < 7 or (r.par >= 0 and d[5] ~= r.par) or (r.typ >= 0 and d[6] % 128 ~= r.typ)
           or not entryStart(d, len, left, V.fc) then
      return
    end
    if r.n + len - 4 <= MAX_ENTRY then
      -- keep the entry as a string: one string per chunk, joined only for later chunks
      if r.n == 0 then r.s = bstr(d, 5, len) else r.s = r.s .. bstr(d, 5, len) end
      r.n = r.n + len - 4
    else
      left = 0
    end
    if left > 0 and not r.nameOnly then
      r.chunk = r.chunk + 1
      r.expect = left - 1
      r.tries = 0
      r.sent = false
    else
      r.done = true
    end
    return
  end
  local sf = V.sf
  if sf ~= nil and id == V.ids.send then onSendStatus(V, sf, d, now) end
end

----------------------------------------------------------------------------
-- API

function M.new()
  return {
    -- public
    state = "off",
    msg = "VTX control off",
    ready = false,
    bandLabels = {},
    band = 0,
    bandLetter = "",
    channel = 0,
    powerLabels = {},
    power = 0,
    pitLabels = {},
    pit = 0,
    freq = 0,
    send = "idle",
    sendMsg = "",
    rev = 0,
    -- private
    st = "down",
    gen = -1,
    epoch = nil,
    reg = nil,
    key = nil,
    ids = {},
    f = {},
    fc = 0,
    fname = nil,
    fchunks = 1,
    scanId = 0,
    scanPass = 1,      -- 2 = the verification pass before "No VTX Admin"
    verify = false,    -- the next scan is the verification pass
    lostN = 0,
    holdUntil = nil,
    rq = { active = false, done = false, sent = false, failed = false, s = "", n = 0,
           id = 0, chunk = 0, expect = -1, tries = 0, deadline = 0, nameOnly = false,
           par = -1, typ = -1 },
    rl = {},
    rli = 1,
    rlp = nil,
    pfail = 0,
    pl = { TX, ME, 0, 0 },
    pend = nil,
    job = nil,
    sf = nil,
    busyMsg = nil,
    err = nil,
    resAt = nil,
    reloadReq = false,
    pageWas = false,
    pageEdge = false,
    nextPoll = 0,
  }
end

-- Record a change request (called from UI callbacks; no CRSF work here).
-- sel = { band, channel, power, pit } in module value space (channel = 1..8), nil = keep.
function M.apply(V, sel, send)
  sel = sel or {}
  V.pend = { band = sel.band, channel = sel.channel, power = sel.power, pit = sel.pit, send = (send == true) }
  V.resAt = nil
  if V.send ~= "writing" or V.sendMsg ~= "" then
    V.send = "writing"
    V.sendMsg = ""
    V.rev = V.rev + 1
  end
  if V.ready and V.state ~= "busy" then
    V.state = "busy"
    V.msg = "Writing..."
    V.rev = V.rev + 1
  end
end

-- Read all VTX fields again (or search again when the module/folder was not found).
function M.reload(V)
  V.reloadReq = true
end

function M.tick(V, C, E, now, allow, pageOpen)
  if V.reg ~= C then
    C.on(C, 0x2B, on2B, V)
    V.reg = C
  end
  if pageOpen and allow then E.wantStatus = now end
  if pageOpen and not V.pageWas then V.pageEdge = true end
  V.pageWas = pageOpen and true or false

  -- a shown send result goes back to idle after a while
  if V.resAt ~= nil and now >= V.resAt then
    V.resAt = nil
    if V.err ~= nil then V.err = nil end
    setSend(V, "idle", "", nil)
    if V.st == "ready" then pubReady(V) end
  end

  -- after a pause: answers to our requests were dropped, start the work again later
  if V.epoch ~= C.epoch then
    V.epoch = C.epoch
    V.rq.active = false
    if V.job ~= nil then
      if V.pend == nil then V.pend = V.job.req end
      V.job = nil
      V.busyMsg = nil
    end
    if V.sf ~= nil then dropWork(V, "Interrupted", now) end
  end

  -- module level states
  if C.noCrsf then
    setDown(V, "nocrsf", "No CRSF module", now)
    if V.reloadReq then V.reloadReq = false; E.nextProbe = 0 end
    return
  end
  local est = E.st
  if est == "notelrs" then
    setDown(V, "noelrs", "No ELRS module", now)
  elseif not E.found then
    if E.pingTries >= 10 then
      setDown(V, "noelrs", "No reply from module", now)
    else
      setDown(V, "search", "Searching for ELRS", now)
    end
  elseif est == "notready" then
    setDown(V, "search", "Module not ready", now)
  end
  local st = V.st
  if st == "down" or st == "lost" then
    if V.reloadReq then
      V.reloadReq = false
      V.holdUntil = nil
      E.repingReq = true
    end
  end
  if V.pend ~= nil and (st == "down" or st == "novtx") then
    V.pend = nil
    setSend(V, "failed", V.msg, now)
  end
  if est ~= "ok" then return end -- (re)checking the module: no requests now

  if E.gen ~= V.gen and (V.holdUntil == nil or now >= V.holdUntil) then
    V.holdUntil = nil
    V.gen = E.gen
    V.rq.active = false
    if V.key ~= nil and V.key == E.key and V.ids.folder ~= nil and V.ids.send ~= nil
       and V.f[V.ids.band] ~= nil and V.f[V.ids.channel] ~= nil then
      -- same module: check the cached ids with one folder read
      V.st = "validate"
      pub(V, "load", "Loading VTX settings", false)
      startList(V, { V.ids.folder }, "validate")
    else
      beginScan(V, E, now)
    end
  end

  local r = V.rq
  if r.active and r.done then readDone(V, E, now) end

  if not allow then
    -- no traffic: keep a sent request alive until traffic is allowed again
    if r.active and r.sent and r.deadline < now + T_CHUNK then r.deadline = now + T_CHUNK end
    return
  end

  if r.active then
    pumpRead(V, C, now)
    if r.failed then readFailed(V, E, now) end
    return
  end
  if V.sf ~= nil then
    stepSend(V, C, E, now)
    return
  end
  if V.job ~= nil then
    stepJob(V, C, now)
    return
  end

  if V.st == "novtx" then
    if V.reloadReq then
      V.reloadReq = false
      beginScan(V, E, now)
    end
    return
  end
  if V.st ~= "ready" then return end

  -- idle: user requests first, then refreshes
  if V.pend ~= nil then
    startJob(V, now)
    if V.job ~= nil then stepJob(V, C, now) end
    return
  end
  if V.reloadReq then
    V.reloadReq = false
    V.pageEdge = false
    V.busyMsg = "Reading..."
    V.err = nil
    pubReady(V)
    startList(V, valueIds(V, true), "reload")
    V.nextPoll = now + (pageOpen and T_POLL_PAGE or T_POLL_DASH)
    pumpRead(V, C, now)
    return
  end
  if V.pageEdge then
    V.pageEdge = false
    startList(V, valueIds(V, true), "refresh")
    V.nextPoll = now + T_POLL_PAGE
    pumpRead(V, C, now)
    return
  end
  if now >= V.nextPoll then
    if pageOpen then
      V.nextPoll = now + T_POLL_PAGE
    else
      V.nextPoll = now + T_POLL_DASH * (V.fchunks or 1)
    end
    if not E.armed then
      startList(V, { V.ids.folder }, "poll")
      pumpRead(V, C, now)
    end
  end
end

return M
