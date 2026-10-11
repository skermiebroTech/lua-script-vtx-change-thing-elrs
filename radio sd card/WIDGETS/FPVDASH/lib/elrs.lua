-- ExpressLRS TX module: device info (0x28 ping / 0x29 reply) and ELRS status (0x2E).
--
-- E fields read by the UI:
--   E.found    bool          an ELRS TX module answered (0x29 from 0xEE with serial "ELRS")
--   E.label    string        "<device name> <maj>.<min>.<rev>" when found, else "ELRS";
--                            only "<device name>" when the module sends version 0.0.0
--   E.version  string|nil    "4.1.0"; nil when not found or the version is 0.0.0
--   E.armed    bool          ELRS status flag bit 3 (false when unknown or older than 5 s)
-- Other fields (used by vtx.lua and telem.lua):
--   E.st       "idle" | "nocrsf" | "ping" | "ok" | "notready" (fieldCount 0) | "notelrs"
--   E.gen      increments every time the module is (re)acquired or replaced
--   E.key      "<name>|<maj>.<min>.<rev>|<fieldCount>" (raw version bytes)
--   E.vmaj, E.vmin, E.vrev (nil when the version is 0.0.0), E.fieldCount, E.name
--   E.linkUp   nil | bool    ELRS status flag bit 0 (RX connected), nil when unknown
--   E.pingTries               pings sent without a reply
--   E.wantStatus              set by vtx.lua (time) while the VTX page is open
--   E.repingReq               set by vtx.lua when the module stopped answering
--   E.rev      increments when found/label/version/armed change
--
-- Frames always use origin 0xEA (radio) and destination 0xEE (TX module).
-- The ping is directed (not broadcast) so the receiver/FC do not answer too.

local M = {}

local TX, ME = 0xEE, 0xEA
local PING = { TX, ME }
local STATUS = { TX, ME, 0, 0 }   -- write to field 0 = "send ELRS status (0x2E)"

local T_PING = 100       -- 1 s between pings
local T_PING_SLOW = 500  -- after 10 unanswered pings
local T_NOTREADY = 500   -- module answered with fieldCount 0
local T_NOTELRS = 1000   -- not an ELRS module
local T_PROBE = 200      -- CRSF module check while none runs
local T_STATUS = 200     -- ELRS status poll while the VTX page is open
local T_STATUS_OLD = 500 -- status older than this is unknown
local LOST_AFTER = 3     -- unanswered re-validation pings before "not found"

----------------------------------------------------------------------------
-- RFMD (CRSF link statistics rf_Mode) -> packet rate in Hz.
--
-- EdgeTX shows the raw rf_Mode byte as sensor RFMD (telemetry/crossfire.cpp,
-- LINK_ID case; the byte is sign-extended, so values >= 128 arrive negative).
-- ExpressLRS sets rf_Mode in src/src/tx_main.cpp:
--   2.x : no table here. 2.x modules send software version 0 in the device info
--         (CRSF.cpp: softwareVer = 0), so the major version is not known; builds
--         with FORCE_NO_DEVICE_VERSION send 0 too. Version 0.0.0 -> no Hz.
--   3.x : rf_Mode = enum_rate             (3.0.0 L346 ... 3.6.4 L441)
--   4.x : rf_Mode = enum_rate             (4.0.0 L506, 4.1.0 L503, master L511)
-- enum expresslrs_RFrates_e is in src/include/common.h of each tag:
--   3.0.0: 0..13; 3.3.0 adds 14 (DVDA 50); 3.4.0 adds 15 (200 Hz 8ch);
--   3.5.x/3.6.x add 16..19 (FSK). 4.0.0 renumbered: 900 MHz 0..11, 2.4 GHz 20..36,
--   dual band 100..101; 4.0.1, 4.1.0 and master use the same enum.
-- The value is the RC update rate: DVDA modes give the effective rate
-- (D250 = 1000 Hz air rate sent 4 times = 250), as the ELRS Lua names them.
-- Unknown major version or unknown value -> nil (show "RF n" instead).
local RATE3 = {
  [0] = 4,    -- RATE_LORA_4HZ
  25,         -- 1  RATE_LORA_25HZ
  50,         -- 2  RATE_LORA_50HZ
  100,        -- 3  RATE_LORA_100HZ
  100,        -- 4  RATE_LORA_100HZ_8CH
  150,        -- 5  RATE_LORA_150HZ
  200,        -- 6  RATE_LORA_200HZ
  250,        -- 7  RATE_LORA_250HZ
  333,        -- 8  RATE_LORA_333HZ_8CH
  500,        -- 9  RATE_LORA_500HZ
  250,        -- 10 RATE_DVDA_250HZ (FLRC)
  500,        -- 11 RATE_DVDA_500HZ (FLRC)
  500,        -- 12 RATE_FLRC_500HZ
  1000,       -- 13 RATE_FLRC_1000HZ
  50,         -- 14 RATE_DVDA_50HZ (900 MHz)
  200,        -- 15 RATE_LORA_200HZ_8CH
  500,        -- 16 RATE_FSK_2G4_DVDA_500HZ
  1000,       -- 17 RATE_FSK_2G4_1000HZ
  1000,       -- 18 RATE_FSK_900_1000HZ
  1000,       -- 19 RATE_FSK_900_1000HZ_8CH
}
local RATE4 = {
  [0] = 25,   -- RATE_LORA_900_25HZ
  [1] = 50,   -- RATE_LORA_900_50HZ
  [2] = 100,  -- RATE_LORA_900_100HZ
  [3] = 100,  -- RATE_LORA_900_100HZ_8CH
  [4] = 150,  -- RATE_LORA_900_150HZ
  [5] = 200,  -- RATE_LORA_900_200HZ
  [6] = 200,  -- RATE_LORA_900_200HZ_8CH
  [7] = 250,  -- RATE_LORA_900_250HZ
  [8] = 333,  -- RATE_LORA_900_333HZ_8CH
  [9] = 500,  -- RATE_LORA_900_500HZ
  [10] = 50,  -- RATE_LORA_900_50HZ_DVDA
  [11] = 1000, -- RATE_FSK_900_1000HZ_8CH
  [20] = 25,  -- RATE_LORA_2G4_25HZ
  [21] = 50,  -- RATE_LORA_2G4_50HZ
  [22] = 100, -- RATE_LORA_2G4_100HZ
  [23] = 100, -- RATE_LORA_2G4_100HZ_8CH
  [24] = 150, -- RATE_LORA_2G4_150HZ
  [25] = 200, -- RATE_LORA_2G4_200HZ
  [26] = 200, -- RATE_LORA_2G4_200HZ_8CH
  [27] = 250, -- RATE_LORA_2G4_250HZ
  [28] = 333, -- RATE_LORA_2G4_333HZ_8CH
  [29] = 500, -- RATE_LORA_2G4_500HZ
  [30] = 250, -- RATE_FLRC_2G4_250HZ_DVDA
  [31] = 500, -- RATE_FLRC_2G4_500HZ_DVDA
  [32] = 500, -- RATE_FLRC_2G4_500HZ
  [33] = 1000, -- RATE_FLRC_2G4_1000HZ
  [34] = 250, -- RATE_FSK_2G4_250HZ_DVDA
  [35] = 500, -- RATE_FSK_2G4_500HZ_DVDA
  [36] = 1000, -- RATE_FSK_2G4_1000HZ
  [100] = 100, -- RATE_LORA_DUAL_100HZ_8CH
  [101] = 150, -- RATE_LORA_DUAL_150HZ
}
local RATES = { [3] = RATE3, [4] = RATE4 }

-- Packet rate in Hz (integer) for an RFMD value, or nil when it cannot be
-- determined exactly (no ELRS version known, other major version, unknown value).
function M.rateHz(E, rfmd)
  if E == nil or rfmd == nil or type(rfmd) ~= "number" then return nil end
  local maj = E.vmaj
  if maj == nil or not E.found then return nil end
  local t = RATES[maj]
  if t == nil then return nil end
  local r = math.floor(rfmd + 0.5)
  if r < 0 then r = r + 256 end
  return t[r]
end

----------------------------------------------------------------------------

local function lose(E)
  if E.found or E.version ~= nil or E.label ~= "ELRS" then
    E.found = false
    E.version = nil
    E.vmaj = nil
    E.vmin = nil
    E.vrev = nil
    E.vkey = nil
    E.label = "ELRS"
    E.rev = E.rev + 1
  end
end

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

-- 0x29 device info: [dest][origin][name..0][serial 4][hw 4][sw 4][fieldCount][paramVersion]
local function on29(E, d, now)
  if d[2] ~= TX then return end
  local n = #d
  local o = 3
  while o <= n and d[o] ~= 0 do o = o + 1 end
  if o + 13 > n then return end
  local name = ""
  if o > 3 then name = string.char(vals(d, 3, o - 1)) end
  o = o + 1
  E.rxAt = now
  if not (d[o] == 0x45 and d[o + 1] == 0x4C and d[o + 2] == 0x52 and d[o + 3] == 0x53) then
    -- a CRSF module that is not ExpressLRS (no VTX Administrator)
    E.name = name
    E.st = "notelrs"
    E.nextPing = now + T_NOTELRS
    E.key = nil
    lose(E)
    return
  end
  local maj, mi, rv, fc = d[o + 9], d[o + 10], d[o + 11], d[o + 12]
  local vkey = string.format("%d.%d.%d", maj, mi, rv)
  E.pingTries = 0
  if not E.found or E.vkey ~= vkey or E.name ~= name then
    E.vkey = vkey
    E.name = name
    if maj > 0 or mi > 0 or rv > 0 then
      E.vmaj, E.vmin, E.vrev, E.version = maj, mi, rv, vkey
    else
      -- version 0.0.0 (ELRS 2.x, or a build without a device version): unknown
      E.vmaj, E.vmin, E.vrev, E.version = nil, nil, nil, nil
    end
    if name == "" then name = "ELRS" end
    if E.version ~= nil then E.label = name .. " " .. E.version else E.label = name end
    E.found = true
    E.rev = E.rev + 1
  end
  E.fieldCount = fc
  if fc == 0 then
    E.st = "notready"
    E.nextPing = now + T_NOTREADY
    return
  end
  local key = E.name .. "|" .. vkey .. "|" .. string.format("%d", fc)
  if E.st ~= "ok" or E.key ~= key then
    E.key = key
    E.gen = E.gen + 1
  end
  E.st = "ok"
end

-- 0x2E ELRS status: [dest][origin][bad][good hi][good lo][flags][message..0]
local function on2E(E, d, now)
  if d[2] ~= TX then return end
  local fl = d[6]
  if fl == nil then return end
  -- bit 3 and bit 0 of the flags byte. Arithmetic, not bit operators: Lua 5.2 (EdgeTX
  -- 2.10) has none, and bit32 is not in every Lua (desktop Lua 5.4+ has no bit32).
  local armed = fl % 16 >= 8
  E.linkUp = fl % 2 == 1
  E.statusAt = now
  if E.armed ~= armed then
    E.armed = armed
    E.rev = E.rev + 1
  end
end

function M.new()
  return {
    found = false,
    label = "ELRS",
    version = nil,
    armed = false,
    st = "idle",
    gen = 0,
    key = nil,
    name = nil,
    vmaj = nil,
    vmin = nil,
    vrev = nil,
    vkey = nil,
    fieldCount = 0,
    linkUp = nil,
    statusAt = nil,
    pingTries = 0,
    nextPing = 0,
    nextProbe = 0,
    nextStatus = 0,
    statusOn = false,
    wantStatus = nil,
    repingReq = false,
    epoch = nil,
    reg = nil,
    rev = 0,
  }
end

function M.tick(E, C, now, allow)
  if E.reg ~= C then
    C.on(C, 0x29, on29, E)
    C.on(C, 0x2E, on2E, E)
    E.reg = C
  end
  -- after a pause the module may have changed: check it again (keeps E.found)
  if E.epoch ~= C.epoch then
    E.epoch = C.epoch
    if E.st ~= "idle" and E.st ~= "nocrsf" then
      E.st = "ping"
      E.pingTries = 0
      E.nextPing = now
    end
  end
  if E.repingReq then
    E.repingReq = false
    if E.st ~= "nocrsf" then
      E.st = "ping"
      E.pingTries = 0
      E.nextPing = now
    end
  end
  -- status older than 5 s is unknown
  if E.statusAt ~= nil and now - E.statusAt > T_STATUS_OLD then
    E.statusAt = nil
    E.linkUp = nil
    if E.armed then
      E.armed = false
      E.rev = E.rev + 1
    end
  end

  if C.noCrsf then
    if E.st ~= "nocrsf" then
      E.st = "nocrsf"
      E.key = nil
      E.nextProbe = now + T_PROBE
      lose(E)
    end
    if not allow or now < E.nextProbe then return end
    E.nextProbe = now + T_PROBE
    if not C.probe(C) then return end
    E.st = "ping"
    E.pingTries = 0
    E.nextPing = now
  end
  if not allow then return end

  local st = E.st
  if st == "idle" then
    st = "ping"
    E.st = st
    E.nextPing = now
  end

  if st == "ok" then
    -- ELRS status (armed, RX connected) only while the VTX page asks for it
    local w = E.wantStatus
    if w ~= nil and now - w <= 30 then
      if not E.statusOn then
        E.statusOn = true
        E.nextStatus = now
      end
      if now >= E.nextStatus and C.push(C, 0x2D, STATUS) then
        E.nextStatus = now + T_STATUS
      end
    else
      E.statusOn = false
    end
    return
  end

  -- "ping", "notready", "notelrs": ping until a usable answer arrives
  if now < E.nextPing then return end
  if not C.push(C, 0x28, PING) then return end
  E.pingTries = E.pingTries + 1
  if st == "ping" then
    if E.pingTries < 10 then
      E.nextPing = now + T_PING
    else
      E.nextPing = now + T_PING_SLOW
    end
    if E.found and E.pingTries > LOST_AFTER then lose(E) end
  elseif st == "notready" then
    E.nextPing = now + T_NOTREADY
  else
    E.nextPing = now + T_NOTELRS
  end
end

return M
