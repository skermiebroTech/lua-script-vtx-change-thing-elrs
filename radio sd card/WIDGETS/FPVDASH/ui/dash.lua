-- Dashboard view: five washed regions filled by the region builders.
-- dash.build(wgt, root) -> d ; d.update(wgt) runs every visible tick.
-- root: the box that holds the view (app.lua); without it the objects go to the widget.

local M = {}

local NAMES = { "topbar", "sticks", "grid", "timers", "footer" }
local REGION = { topbar = "top", sticks = "sticks", grid = "grid", timers = "timers", footer = "footer" }

-- Loaded module tables (code only, no instance state).
local cache = {}

-- dir: widget folder, e.g. "/WIDGETS/FPVDASH/" (a missing leading slash is added).
local function loadMod(dir, rel)
  local m = cache[rel]
  if m ~= nil then return m end
  if string.sub(dir, 1, 1) ~= "/" then dir = "/" .. dir end
  local chunk, err = loadScript(dir .. rel, "btd")
  if chunk == nil then return nil, tostring(err or "cannot load") end
  m = chunk()
  if type(m) ~= "table" then return nil, "bad module" end
  cache[rel] = m
  return m
end

-- Helpers shared by the region builders (one table per build).
local function makeU(wgt, L, th)
  local U = { th = th, L = L, dir = wgt.dir or "WIDGETS/FPVDASH/", measure = L.measure }

  local function mk(kind, parent, t)
    if parent ~= nil then return lvgl[kind](parent, t) end
    return lvgl[kind](t)
  end
  U.mk = mk

  -- Shadowed label at a fixed place. text: string or function; color: number or function.
  function U.label(parent, x, y, font, text, color, w, align)
    local s = { x = x + 1, y = y + 1, font = font, color = th.shadow, text = text }
    local m = { x = x, y = y, font = font, color = color, text = text }
    if w ~= nil then
      s.w, s.align = w, align
      m.w, m.align = w, align
    end
    mk("label", parent, s)
    return mk("label", parent, m)
  end

  -- Shadowed label moved by pos functions (main and shadow).
  function U.labelPos(parent, font, text, color, pos, spos)
    mk("label", parent, { x = 0, y = 0, font = font, color = th.shadow, text = text, pos = spos })
    return mk("label", parent, { x = 0, y = 0, font = font, color = color, text = text, pos = pos })
  end

  -- One image per state, shown by a visible function. Returns the state table
  -- (name -> bool, all false). Files: prefix .. name .. ".png".
  function U.states(parent, x, y, w, h, names, prefix)
    local vis = {}
    for i = 1, #names do vis[names[i]] = false end
    for i = 1, #names do
      local n = names[i]
      mk("image", parent, { x = x, y = y, w = w, h = h, file = prefix .. n .. ".png",
                            visible = function() return vis[n] end })
    end
    return vis
  end

  -- Show state 'new' and hide 'old' (vis may be nil when the icons are not built).
  function U.show(vis, old, new)
    if vis == nil then return end
    if old ~= nil then vis[old] = false end
    if new ~= nil then vis[new] = true end
  end

  -- Cut text so that it fits in maxW px (keeps whole UTF-8 characters).
  function U.fit(text, font, maxW)
    if maxW <= 0 then return "" end
    local measure = L.measure
    if measure(text, font) <= maxW then return text end
    local n = #text
    while n > 0 do
      n = n - 1
      local b = string.byte(text, n + 1)
      if b == nil or b < 128 or b >= 192 then
        local s = string.sub(text, 1, n)
        if measure(s, font) <= maxW then return s end
      end
    end
    return ""
  end

  return U
end

-- New object in the root box, or in the widget when there is no root box.
local function inRoot(root, kind, t)
  if root ~= nil then return lvgl[kind](root, t) end
  return lvgl[kind](t)
end

function M.build(wgt, root)
  local d = {}
  local list = {}
  local dir = wgt.path or wgt.dir or "/WIDGETS/FPVDASH/"

  local L = wgt.mods and wgt.mods.layout
  local lerr
  if L == nil then L, lerr = loadMod(dir, "ui/layout.lua") end
  local th = wgt.theme
  if th == nil then
    local T = wgt.mods and wgt.mods.theme
    local terr
    if T == nil then T, terr = loadMod(dir, "ui/theme.lua") end
    if T then th = T.resolve(wgt.options) else lerr = lerr or terr end
  end
  if L == nil or th == nil then
    inRoot(root, "label", { x = 2, y = 2, font = SMLSIZE, color = RED, text = "FPVDASH: " .. tostring(lerr) })
    d.update = function(w) end
    return d
  end

  local z = wgt.zone
  local regs = L.regions(z.w, z.h)
  if regs ~= nil then
    local U = makeU(wgt, L, th)
    for i = 1, #NAMES do
      local name = NAMES[i]
      local r = regs[REGION[name]]
      if r ~= nil then
        -- the scroll keys work only in full screen, where the pages are shown instead of
        -- the dashboard; they keep the regions fixed if the dashboard is ever shown there
        local wash = inRoot(root, "rectangle", { x = r.x, y = r.y, w = r.w, h = r.h, filled = true,
                                                 color = th.wash, opacity = th.washOpa,
                                                 scrollBar = false, scrollDir = lvgl.SCROLL_OFF })
        -- app.lua loads the region modules in create (wgt.mods); load here only without it
        local m, err = wgt.mods and wgt.mods[name], nil
        if m == nil then m, err = loadMod(dir, "ui/" .. name .. ".lua") end
        if m ~= nil then
          list[#list + 1] = { m = m, st = m.build(U, wash, r, wgt) }
        else
          lvgl.label(wash, { x = 2, y = 0, font = SMLSIZE, color = th.bad, text = name .. ": " .. err })
        end
      end
    end
  end

  -- the caller (app.lua) runs d.update(wgt) right after build
  local n = #list
  function d.update(w)
    if w.S == nil then return end
    for i = 1, n do
      local e = list[i]
      e.m.update(e.st, w)
    end
  end
  return d
end

return M
