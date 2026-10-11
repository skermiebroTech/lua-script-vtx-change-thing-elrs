-- CRSF dispatcher for one widget instance.
-- It is the only code that calls crossfireTelemetryPop/crossfireTelemetryPush.
-- EdgeTX 2.12 (color LCD) gives every widget instance its own receive queue
-- (a 256-byte FIFO, every frame is copied to every queue), so the modules of
-- one instance (elrs.lua, vtx.lua) must share this one pop loop.
--
-- C fields:
--   C.noCrsf   nil (not known yet) | true (no CRSF module runs) | false (CRSF ok)
--   C.epoch    increments when frames were dropped after a pause (> 1 s without a tick)
--   C.resumed  true during the tick that dropped stale frames
--   C.pushed   true when this tick already pushed a frame (one push per tick)
--   C.rx, C.tx, C.dropped   counters (debug)
-- C methods (so other modules do not need to load this file):
--   C.on(C, cmd, fn, ctx)      fn(ctx, data, now) is called for every frame of type cmd
--   C.push(C, cmd, payload)    true = queued, false = busy (retry next tick), nil = no CRSF
--   C.probe(C)                 true when a CRSF module runs (sends nothing)

local M = {}

local MAX_POP = 4     -- frames dispatched per tick
local MAX_DRAIN = 16  -- stale frames dropped per tick after a pause
local GAP = 100       -- 10 ms ticks: 1 s without a tick means the widget was paused

local function on(C, cmd, fn, ctx)
  local h = C.h[cmd]
  if h == nil then
    h = {}
    C.h[cmd] = h
  end
  for i = 1, #h, 2 do
    if h[i] == fn and h[i + 1] == ctx then return end
  end
  h[#h + 1] = fn
  h[#h + 1] = ctx
end

local function push(C, cmd, payload)
  if C.pushed then return false end
  if type(crossfireTelemetryPush) ~= "function" then
    C.noCrsf = true
    return nil
  end
  local ok = crossfireTelemetryPush(cmd, payload)
  if ok == nil then
    C.noCrsf = true
    return nil
  end
  C.noCrsf = false
  if ok then
    C.pushed = true
    C.tx = C.tx + 1
    return true
  end
  return false
end

local function probe(C)
  if type(crossfireTelemetryPush) ~= "function" then
    C.noCrsf = true
    return false
  end
  -- no argument: returns nil when no module runs CRSF, else true/false (buffer state)
  if crossfireTelemetryPush() == nil then
    C.noCrsf = true
    return false
  end
  C.noCrsf = false
  return true
end

function M.new()
  return {
    h = {},
    on = on,
    push = push,
    probe = probe,
    noCrsf = nil,
    epoch = 0,
    resumed = false,
    pushed = false,
    drain = false,
    now = 0,
    last = nil,
    rx = 0,
    tx = 0,
    dropped = 0,
  }
end

-- Pop and dispatch pending frames. Call once per tick before elrs.tick/vtx.tick.
function M.beginTick(C, now)
  C.pushed = false
  C.now = now
  local last = C.last
  C.last = now
  local pop = crossfireTelemetryPop
  if type(pop) ~= "function" then
    C.noCrsf = true
    C.resumed = false
    return
  end
  if last == nil or now - last > GAP or now < last or C.drain then
    -- first tick or the widget was paused (e.g. a tool ran): queued frames are
    -- answers to someone else or too old, drop them
    if not C.drain then C.epoch = C.epoch + 1 end
    C.resumed = true
    C.drain = false
    local n = 0
    while n < MAX_DRAIN do
      local cmd = pop()
      if cmd == nil then break end
      n = n + 1
    end
    C.dropped = C.dropped + n
    if n >= MAX_DRAIN then C.drain = true end
    return
  end
  C.resumed = false
  local h = C.h
  for _ = 1, MAX_POP do
    local cmd, data = pop()
    if cmd == nil then break end
    C.rx = C.rx + 1
    local l = h[cmd]
    if l ~= nil and data ~= nil then
      for i = 1, #l, 2 do
        l[i](l[i + 1], data, now)
      end
    end
  end
end

M.on = on
M.push = push
M.probe = probe

return M
