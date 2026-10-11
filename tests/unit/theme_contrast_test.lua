-- theme_contrast_test.lua: contrast of the trim greys of ui/theme.lua (WCAG ratio).
-- Run: cd "<root>" && lua tests/unit/theme_contrast_test.lua   (exit code 0 = all pass)
--
-- Light mode (darkTheme = 0): the track, the centre tick and the value box must have at
-- least 3:1 contrast against the white-washed background (white, and the default theme
-- background #E4EEF2 under the lightest wash), the tick also against the track, and the
-- black value text at least 4.5:1 on the value box. Dark mode keeps its values.

local here = string.match(arg and arg[0] or "", "^(.*)/[^/]*$") or "."
local WIDGET = here .. "/../../radio sd card/WIDGETS/FPVDASH/"

-- lcd.RGB packs 8-bit r, g, b (with bit 24 set, so black is not 0) so the test can read
-- the colour back
local RGBFLAG = 16777216
lcd = { RGB = function(r, g, b) return RGBFLAG + r * 65536 + g * 256 + b end }
WHITE, BLACK, GREEN, YELLOW, RED, LIGHTGREY, GREY, DARKGREY = 1, 2, 3, 4, 5, 6, 7, 8
COLOR_THEME_FOCUS, COLOR_THEME_ACTIVE = 9, 10

local theme = dofile(WIDGET .. "ui/theme.lua")

local passed, failed = 0, 0
local function check(cond, what)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. what)
  end
end

local function rgbOf(c)
  if c == BLACK then return 0, 0, 0 end
  if c == WHITE then return 255, 255, 255 end
  assert(c >= RGBFLAG, "not an lcd.RGB colour: " .. tostring(c))
  c = c - RGBFLAG
  return c // 65536, (c // 256) % 256, c % 256
end

local function lin(v)
  v = v / 255
  if v <= 0.04045 then return v / 12.92 end
  return ((v + 0.055) / 1.055) ^ 2.4
end
local function lum(r, g, b) return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) end
local function ratio(a, b)
  if a < b then a, b = b, a end
  return (a + 0.05) / (b + 0.05)
end
local function colLum(c) return lum(rgbOf(c)) end

-- background after the white wash with opacity opa (0..255)
local function washed(r, g, b, opa)
  local f = opa / 255
  return lum(r + (255 - r) * f, g + (255 - g) * f, b + (255 - b) * f)
end

-- light mode at every transparency level
for level = 1, 4 do
  local th = theme.resolve({ darkTheme = 0, transpLevel = level })
  check(th.dark == false, "light mode")
  check(th.wash == WHITE, "light wash is white")
  local bgs = {
    { "white", 1.0 },
    { "default theme #E4EEF2", washed(228, 238, 242, th.washOpa) },
  }
  for _, bg in ipairs(bgs) do
    for _, k in ipairs({ "track", "tick", "tbox" }) do
      local r = ratio(colLum(th[k]), bg[2])
      check(r >= 3.0, string.format("light transpLevel %d: %s contrast %.2f:1 on %s (>= 3:1)", level, k, r, bg[1]))
    end
  end
  local tr = ratio(colLum(th.tick), colLum(th.track))
  check(tr >= 3.0, string.format("light: tick on track %.2f:1 (>= 3:1)", tr))
  local tx = ratio(colLum(th.text), colLum(th.tbox))
  check(tx >= 4.5, string.format("light: value text on the value box %.2f:1 (>= 4.5:1)", tx))
  for _, k in ipairs({ "muted", "track", "tick", "tbox" }) do
    check(th[k] ~= GREY and th[k] ~= DARKGREY, "light: " .. k .. " is not the swapped GREY/DARKGREY constant")
  end
end

-- Light mode, the alert colors: warn (VTX busy dot, pit tag, sats, TX battery text), cap
-- (the throttle cap line and its "NN%" label) and extMark (a trim beyond the normal range).
-- They were yellow (YELLOW #FFFF00, ACTIVE #FFDE00 of the default theme): 1.0 to 1.3:1 on
-- the white wash. Each must have at least 3:1 at every transparency level against white,
-- the washed default theme color #E4EEF2, and the washed sky of THEMES/EdgeTX/background.png
-- (the default theme's background photo): #2486B9 is its darkest pixel behind the sticks
-- region (x 130..350, y 51..148), #A2A1A0 its darkest pixel behind the VTX cell of the timer
-- row (x 360..480, y 258..282). The radio shows lcd.RGB colors as RGB565: rounded first.
local function q565(r, g, b)
  local r5, g6, b5 = r >> 3, g >> 2, b >> 3
  return (r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)
end
local function alertLum(c) return lum(q565(rgbOf(c))) end
for level = 1, 4 do
  local th = theme.resolve({ darkTheme = 0, transpLevel = level })
  local bgs = {
    { "white", 1.0 },
    { "default theme #E4EEF2", washed(228, 238, 242, th.washOpa) },
    { "EdgeTX sky #2486B9 (sticks)", washed(36, 134, 185, th.washOpa) },
    { "EdgeTX sky #A2A1A0 (timer row)", washed(162, 161, 160, th.washOpa) },
  }
  for _, k in ipairs({ "warn", "cap", "extMark" }) do
    check(th[k] ~= nil and th[k] ~= YELLOW and th[k] ~= COLOR_THEME_ACTIVE,
      string.format("light transpLevel %d: %s is not yellow", level, k))
    if th[k] ~= nil and th[k] ~= YELLOW and th[k] ~= COLOR_THEME_ACTIVE then
      for _, bg in ipairs(bgs) do
        local r = ratio(alertLum(th[k]), bg[2])
        check(r >= 3.0, string.format("light transpLevel %d: %s contrast %.2f:1 on %s (>= 3:1)", level, k, r, bg[1]))
      end
    end
  end
  -- control: the old yellow fails on the sky
  local old = ratio(lum(255, 222, 0), washed(36, 134, 185, th.washOpa))
  check(old < 3.0, string.format("light transpLevel %d: control, yellow ACTIVE on the sky %.2f:1 (< 3:1)", level, old))
end

-- dark mode is unchanged
local th = theme.resolve({ darkTheme = 1, transpLevel = 1 })
check(th.warn == YELLOW, "dark warn is YELLOW")
check(th.cap == YELLOW, "dark cap line is YELLOW")
check(th.extMark == COLOR_THEME_ACTIVE and th.active == COLOR_THEME_ACTIVE, "dark extended trim marker is ACTIVE")
local function hex(c) return string.format("#%02X%02X%02X", rgbOf(c)) end
check(hex(th.muted) == "#A0A0A0", "dark muted #A0A0A0, is " .. hex(th.muted))
check(hex(th.track) == "#707070", "dark track #707070, is " .. hex(th.track))
check(hex(th.tick) == "#C0C0C0", "dark tick #C0C0C0, is " .. hex(th.tick))
check(hex(th.tbox) == "#404040", "dark tbox #404040, is " .. hex(th.tbox))
check(th.text == WHITE and th.wash == BLACK, "dark text and wash")

print(string.format("theme_contrast_test: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
