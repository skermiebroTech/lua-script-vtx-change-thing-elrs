-- Theme table from the widget options (darkTheme, transpLevel).
-- Colors are EdgeTX color constants or lcd.RGB() values (no raw RGB565 literals).
-- The greys are lcd.RGB() values: in EdgeTX 2.12 the constant GREY draws #404040 and
-- DARKGREY draws #606060 (colors.cpp has the two table entries in the other order),
-- and #404040 text cannot be read on the dark wash.

local M = {}

-- Wash opacity for transpLevel 1..4 (old transparency 6/8/10/12 of 15).
local WASH_OPA = { 153, 119, 85, 51 }

-- Round an option value to an integer, or nil when it is not a number.
local function optInt(v)
  if type(v) == "table" then v = v.value or v.val end
  if type(v) == "string" then v = tonumber(v) end
  if type(v) ~= "number" then return nil end
  return math.floor(v + 0.5)
end

-- Color constant, or an RGB fallback when the constant is missing.
local function col(c, r, g, b)
  if type(c) == "number" then return c end
  if lcd and lcd.RGB then return lcd.RGB(r, g, b) end
  return 0
end

-- RGB color, or the constant c when lcd.RGB is missing.
local function rgb(r, g, b, c)
  if lcd and lcd.RGB then return lcd.RGB(r, g, b) end
  if type(c) == "number" then return c end
  return 0
end

function M.resolve(options)
  local o = options or {}

  local dark = true
  local d = optInt(o.darkTheme)
  if o.darkTheme == false or (d ~= nil and d <= 0) then dark = false end

  -- transpLevel: CHOICE stores 1..4; the VALUE fallback stores 0..3.
  local idx = 2
  local n = optInt(o.transpLevel)
  if n == nil then
    idx = 1
  elseif n >= 1 and n <= 4 then
    idx = n
  elseif n == 0 then              -- n is already rounded to an integer
    idx = 1
  end

  local white = col(WHITE, 255, 255, 255)
  local black = col(BLACK, 0, 0, 0)
  local focus = col(COLOR_THEME_FOCUS, 240, 60, 56)
  local active = col(COLOR_THEME_ACTIVE, 255, 160, 0)
  -- secondary text (readable on the wash), trim track, trim centre tick, trim value box,
  -- the alert color (warn, the cap line, a trim beyond the normal range)
  local muted, track, tick, tbox, warn, extMark
  if dark then
    muted = rgb(160, 160, 160, LIGHTGREY)
    track = rgb(112, 112, 112, DARKGREY)
    tick = rgb(192, 192, 192, LIGHTGREY)
    tbox = rgb(64, 64, 64, GREY)
    warn = col(YELLOW, 240, 208, 16)
    extMark = active
  else
    -- Light mode: the white wash over a light theme background (default theme #E4EEF2)
    -- is almost white, so each part needs at least 3:1 contrast against it at every
    -- transparency level (WCAG ratios against #E9F1F4, the lightest wash on the default
    -- theme, and white): track #606060 5.5:1 .. 6.3:1; the tick crosses the track, so it
    -- is black (3.3:1 against the track); value box #808080 3.5:1 .. 4.0:1, with the
    -- black value text on it at 5.3:1. (#A0A0A0 gave only 2.3:1 .. 2.6:1.)
    muted = rgb(96, 96, 96, DARKGREY)
    track = rgb(96, 96, 96, DARKGREY)
    tick = rgb(0, 0, 0, BLACK)
    tbox = rgb(128, 128, 128, DARKGREY)
    -- Yellow (YELLOW, and the yellow ACTIVE #FFDE00 of the default theme) gives only 1.0 to
    -- 1.3:1 on the white wash. A dark amber #702C00 gives at least 3.3:1 against white,
    -- the washed #E4EEF2 and the darkest sky pixel of THEMES/EdgeTX/background.png behind
    -- the sticks and the timer row (#2486B9), at every transparency level, after RGB565.
    warn = rgb(112, 44, 0, ORANGE)
    extMark = warn
  end

  return {
    dark = dark,
    text = dark and white or black,
    shadow = dark and black or white,
    wash = dark and black or white,
    washOpa = WASH_OPA[idx],
    iconDir = dark and "icons/dark/" or "icons/light/",
    good = col(GREEN, 0, 200, 0),
    warn = warn,                         -- YELLOW (dark), dark amber (light)
    bad = col(RED, 229, 32, 30),
    muted = muted,
    accent = focus,
    -- extra fields used by the dashboard only
    focus = focus,
    active = active,
    cap = warn,                          -- throttle cap line and its label
    extMark = extMark,                   -- trim marker beyond the normal range (extended trims)
    stick = white,                       -- gimbal box border and dot rim
    dotIn = black,                       -- gimbal dot centre
    track = track,                       -- trim track
    tick = tick,                         -- trim centre tick
    tbox = tbox,                         -- trim value text background
  }
end

return M
