# FPVDASH v2 — LVGL rewrite + VTX control + trim display + throttle cap — DESIGN CONTRACT

This file is the binding contract for every agent that writes code for this rewrite.
If something here conflicts with your own idea, follow this file and report the conflict.

Paths (note the spaces — always quote them in shell commands):

- Project root: `<repository root>`
- SD card copy: `<root>/radio sd card` — the widget is `<root>/radio sd card/WIDGETS/FPVDASH`
- Original widget backup (read-only reference): `<root>/backup/FPVDASH-2026-10-02`
- Tests (NOT on the SD card): `<root>/tests`
- Tools: `<root>/tools/edgetx-luac` (EdgeTX's own Lua 5.3 compiler; `edgetx-luac -p file.lua` = syntax check)
- Desktop Lua 5.5.1: `/opt/homebrew/bin/lua` (for the mock test harness only)
- Research references (READ the parts relevant to your task; they cite firmware source):
  `R=<research notes folder (not in this repository)>`
  - `$R/lvgl_api.md` — EdgeTX 2.12 LVGL Lua API from firmware source (rc1 + 2.12.x differences). **Authoritative.**
  - `$R/lvgl_patterns.md` — idioms from working LVGL widgets, skeleton, pitfalls.
  - `$R/elrs_crsf_vtx.md` — CRSF/ELRS parameter protocol, VTX Administrator, state machine pseudocode. **Authoritative.**
  - `$R/fpvdash_spec.md` — exact spec of the CURRENT dashboard (geometry, colors, data, bugs).
  - `$R/trims.md` — trim sources, ranges, EdgeTX trim drawing.
  - `$R/testing.md` — Lua version facts, simulator facts, checker facts.
  - `$R/throttle_cap.md` — model input API, mixer concurrency, the glitch-free swap order. **Authoritative**
    for the throttle cap (one correction: `luaL_checkinteger` floors a float, `LUA_FLOORN2I 1` in rc1
    `luaconf.h:160`; it does not raise an error. Pass integers anyway, see §5.5).

## 1. Goal

Rewrite the "Telemetry Dashboard" widget (folder `WIDGETS/FPVDASH`) to use the EdgeTX LVGL Lua API, and add:

1. **VTX control** through the ExpressLRS TX module's "VTX Administrator" CRSF parameters:
   - a **VTX cell** on the dashboard (status only — LVGL controls cannot be pressed outside full screen);
   - a **full-screen VTX control page** (the widget's full-screen view) with touch buttons.
2. **Trim display**: four trim bars around the two stick boxes.
3. **Throttle cap** (§5.5, §6, §7.3): the widget sets the maximum throttle by editing the model's throttle
   input line: weight = cap, offset = cap − 100 (cap 75 → 75 / −25; stick low always gives −100 %). The user
   does this by hand today (model "75" = 75/−25, "sim" = 50/−50, "100% pro" = 100/0; one plain line on
   Input 3, chn 2). It applies at any time, also when armed, so the change must be glitch-free.
   - Values: presets 100, 90, 80, 75, 70, 60, 50 %, −5 / +5 steps, a manual number input with a Set button;
     range 20..100 %.
   - Dashboard: a line across the THROTTLE stick box at the cap level with a small "NN%" label.
   - Full screen: tabs "VTX" and "Throttle" (only the Throttle page when VTX control is off).

Keep the current look and data of the dashboard (see `$R/fpvdash_spec.md` §4–§5), with the bug fixes in §9.

The user's radio: RadioMaster TX15, 480x320 color touch screen, EdgeTX **v2.12.0-rc1** (commit 7b9c7c0; may later be
updated to 2.12.x), dashboard used in **App mode** layout (zone = full 480x320; a long-press/tap opens full screen),
theme "Dark Theme", stick mode 2, ELRS Lua r18 on the SD card (= ELRS 4.1.x module likely). Model sensors (model1):
1RSS, 2RSS, RQly, RSNR, ANT, RFMD, TPWR, TRSS, TQly, TSNR, FM, RxBt, Curr, Capa, Bat%, Ptch, Roll, Yaw. No GPS.

## 2. Hard runtime rules (every file)

Lua:
- EdgeTX 2.12 = **Lua 5.3.6**, 32-bit ints, 32-bit floats, `LUA_FLOORN2I` (floats floored where an int is required).
  `bit32` exists. `//` and `& | ~ << >>` work. **No** `os`, `utf8`, `coroutine`, `debug`, global `unpack`, `loadstring`.
- **Do not use string method syntax** (`s:sub()`, `s:match()`, `("x"):format()`): the string metatable is probably
  absent. Always write `string.sub(s, ...)`, `string.format(...)`, etc.
- **Never compare a possibly-fractional number with an integer literal using `==`/`~=`** (rc1..2.12.3 bug:
  `0.5 == 0` is true). Use `<`, `>`, `<=`, `>=`, or compare with float literals (`v == 0.0`), or round first.
- No Lua 5.4/5.5 syntax (`<const>`, `<close>`, `global`). Do not assign to a `for` loop control variable
  (EdgeTX allows it, desktop Lua 5.5 rejects it — keep both happy).
- **No global variables.** Every file starts with locals and returns a table. Module-level locals are shared by all
  instances of the widget: keep per-instance state in tables passed in (the `wgt` table).
- `tostring(10/2)` gives `"5.0"` — always format numbers with `string.format("%d", math.floor(x + 0.5))` etc.
- `getValue(name)` returns 0 (not nil) for an unknown name — resolve ids with `getFieldInfo(name)` first.
- Every file must pass `<root>/tools/edgetx-luac -p` AND `luac -p` (5.5).

LVGL (read `$R/lvgl_api.md` §3–§9 before writing UI code):
- Objects are created in `update()`/rebuild only, never every refresh. Coordinates are **relative to the widget zone**
  (zone.x = zone.y = 0) or to the parent object.
- **Never call the no-argument `lvgl.clear()` after the first build.** It deletes every LVGL child of the widget,
  also the ones the firmware owns (the focus border in widget-select mode, which the firmware deletes again later:
  use after free). Build every view inside a root `box` and delete views with `lvgl.clear(box)`. The firmware
  drops the Lua refs of the cleared children only at the next property poll of that box, so fill a cleared box
  again only after it was polled once (app.lua: `slot.seen`).
- Every `lvgl.clear()` (with or without argument) leaks the C++ wrapper of each deleted object (about 150 bytes):
  do not delete and rebuild views that can be kept and hidden.
- `visible`, `pos`, `size`, `active` accept **only functions**. Never pass booleans/numbers for them.
- Property functions (`text`, `color`, `visible`, `pos`, `size`, `value`, `active`, `filled`, `file`…) are called every
  ~50 ms and once at creation. They must be **cheap field reads** and must **never return nil** (text → string,
  color → number, visible → boolean). Initialise all fields they read *before* creating the object.
- Use **only valid property keys** for each object type (`$R/lvgl_api.md` §5.5). 2.12.0+ raises
  `Invalid property` for unknown keys (rc1 ignores them). Do not use `floating`, `borderPad`, `edited`, `XLSIZE`,
  `lvgl.CHOICE`/`lvgl.CHOIDE` (use the string type names if you ever need `lvgl.build`).
- **rc1 bugs to avoid:** `lvgl.build()` returns `{}` (keep constructor return values instead of `name=`);
  label `VCENTER` ignores x/y (put the label at x=0,y=0 inside a sized `box` if you need vertical centering);
  triangles > 127 px; `page{backButton=true}`; `choice` values cannot change after creation.
- Controls (`button`, `toggle`, `choice`, `page`, …) return **nil outside full screen**. The dashboard (not full
  screen) must use only: `label, rectangle, box, image, hline, vline, circle, arc, line`.
- **Nothing clickable may be visible outside full screen.** A `box`, `rectangle` or `circle` made while the widget
  is full screen keeps `LV_OBJ_FLAG_CLICKABLE` (only objects made outside full screen get it cleared: rc1
  `lua_lvgl_widget.cpp:1501-1502`, 2.12.0 `:1616-1617`); controls are always clickable. Such an object on the
  dashboard takes the touch, and the long press that opens full screen (App mode) or the widget menu stops
  working. Arcs, images, labels and lines are never clickable. So a root box made in full screen is used again
  only in full screen (app.lua `slot.fs`) and is hidden on exit, and every control is deleted on exit.
  A poll that handles a pending `lvgl.clear(box)` returns before it calls the box's `visible` function
  (`LvglWidgetObjectBase::callRefs`): a cleared box keeps its old visibility until the next poll. 2.12.x calls no
  `update()` on a full-screen exit in App mode, so that poll is the only one of the exit cycle: hide such a box at
  once with `lvgl.hide(box)` (it acts immediately; the `visible` function keeps it hidden later) before
  `lvgl.clear(box)`. The test harness fails a scenario when a visible clickable object exists at the end of
  any cycle outside full screen.
- **Z-order: a later sibling takes the tap.** LVGL (`lv_indev_search_obj`) searches the children of an object
  from the last made to the first, and a clickable parent takes a point that none of its children takes. A box
  made in full screen is clickable, so a box made after a control and covering it takes every tap on that
  control (also when the box has no child at that point). Make covering boxes first and the controls above them
  later. A child added later to an existing box does not change the order of that box among its siblings.
  The harness checks this with an LVGL-order hit test at the centre of every visible control (scenario
  `fs-touch`, `tests/unit/glue_app_test.lua`); `Radio:press` alone calls the callback without a hit test.
- `lcd.*` drawing does nothing in an LVGL widget (`lcd.sizeText`, `lcd.RGB`, `lcd.exitFullScreen` still work).
- `opacity` works only on rectangle/circle/arc/lines. Labels have no shadow: draw a second label at +1,+1 first.
- `rectangle`: `filled=true` → no border. For filled + border, stack two rectangles.
- `hline`/`vline`: always set both `w` and `h`. Rectangles: always set `w` and `h` (≥ 1).
- Images: `lvgl.image{x,y,w,h,file=...}`; `file` without a leading slash: `wgt.dir .. "icons/dark/clock.png"`
  where `wgt.dir = "WIDGETS/FPVDASH/"`. To switch icons, create one image per state and toggle `visible`
  (do not change `file`). Keep the number of DISTINCT image files visible at once small (LVGL caches 8).
- Button `press` callbacks must be tiny: set request fields only; never do CRSF work there; return nothing (nil).
  Never delete/rebuild the UI inside a callback — set a flag and rebuild in `refresh`.
- CPU: `refresh` + all property functions share **one budget of ~20,000 Lua VM instructions per 50 ms cycle**.
  Exceeding it kills the widget ("CPU limit"). Targets measured by the test harness (desktop VM instruction count):
  **typical tick < 8,000, worst-case tick < 14,000.** Precompute strings/colors once per tick into plain fields;
  property functions only return those fields. Avoid per-tick string concatenation when the value has not changed.
- Fonts (std set): `TINSIZE` 9 px, `SMLSIZE` 13 px (line 17), `STDSIZE` 16 px, `MIDSIZE` 24 px (line 29),
  `DBLSIZE` 32 px bold (line 40). `BOLD` is a separate 16-px font, not a modifier (MIDSIZE+BOLD = DBLSIZE).
- Colors: use EdgeTX color constants (`WHITE`, `BLACK`, `RED`, `GREEN`, `YELLOW`, `LIGHTGREY`,
  `ORANGE`, `COLOR_THEME_*`) or `lcd.RGB(r,g,b)`. **Never raw RGB565 literals** like `0x0000`.
  **Do not use `GREY` or `DARKGREY` for greys:** in EdgeTX 2.12 `GREY` draws #404040 and `DARKGREY` draws #606060
  (the two entries of `colors.cpp` are in the other order), and #404040 cannot be read on the dark wash.
  Use `lcd.RGB` greys from `ui/theme.lua` (`muted`, `track`, `tick`, `tbox`).

## 3. Files (all under `WIDGETS/FPVDASH/`)

| File | Owner | Purpose |
|---|---|---|
| `main.lua` | glue | Tiny. Options, widget table, loads `app.lua` lazily in `create`. |
| `app.lua` | glue | Per-instance app: lifecycle, module loading, rebuild logic, tick ordering. |
| `lib/telem.lua` | glue | Telemetry snapshot `S` (sensors, TX battery, timers, clock, model name). |
| `lib/inputs.lua` | glue | Sticks and trims `I` (stick-mode aware). |
| `lib/crsf.lua` | protocol | CRSF dispatcher (pop/route frames, guarded push). |
| `lib/elrs.lua` | protocol | ELRS TX module device info + ELRS status (0x2E) → `E`. |
| `lib/vtx.lua` | protocol | VTX Administrator controller → `V` (+ request API). |
| `lib/thrcap.lua` | thrcap | Throttle cap → `T` (+ request API): finds the throttle input, swaps its line glitch-free (§5.5). |
| `ui/theme.lua` | dash | Theme table from options. |
| `ui/layout.lua` | dash | Region geometry, `pageHeader(W)` for the full-screen header strip. |
| `ui/dash.lua` | dash | Builds the dashboard (calls the region builders), returns `d` with `d.update(wgt)`. |
| `ui/topbar.lua`, `ui/sticks.lua`, `ui/grid.lua`, `ui/timers.lua`, `ui/footer.lua` | dash | Region builders. `ui/sticks.lua` includes the trims; `ui/timers.lua` includes the VTX cell. |
| `ui/vtxpage.lua` | page | Full-screen VTX control page ("VTX" tab), returns `p` with `p.update(wgt)`. |
| `ui/thrpage.lua` | page | Full-screen throttle cap page ("Throttle" tab), returns `t` with `t.update(wgt)`; also the shared header buttons (Back, tabs). |
| `icons/...` | — | Unchanged PNGs (see `$R/fpvdash_spec.md` §8 for sizes). |

The old files (`layout/`, `render/`, `telemetry/`, all `.luac`) are removed at integration (backup exists).
Folder names ≤ 8 chars. Tests live in `<root>/tests` (never on the SD card).

## 4. Lifecycle (main.lua + app.lua)

`main.lua` (keep tiny; it is loaded at radio start for every model):
- Options — **the first two must stay exactly as today** (stored model values map by index and type):
  ```lua
  local OPTION_COMBO = (type(COMBO) == "number" and COMBO) or (type(CHOICE) == "number" and CHOICE)
  -- index 0, 1: unchanged
  { "darkTheme", BOOL, 1 },
  OPTION_COMBO and { "transpLevel", OPTION_COMBO, 1, { "1","2","3","4" } } or { "transpLevel", VALUE, 1, 0, 3 },
  -- new (appended), each with the normal value 0:
  { "vtxOff",    BOOL, 0 },          -- 0 = VTX cell + VTX page + CRSF traffic; 1 = off (no CRSF parameter traffic)
  { "hideTrims", BOOL, 0 },          -- 0 = draw trim bars; 1 = no trim bars
  { "rxCells",   VALUE, 0, 0, 14 },  -- 0 = auto (latched at rest); 1..14 = fixed RX cell count
  { "extTrims",  VALUE, 0, 0, 2 },   -- trim range: 0 = auto, 1 = normal (+-1024), 2 = extended (+-4096)
  ```
  **Every option after index 1 must have 0 as its normal value.** A model that was saved with an older widget
  stores only the options it knew. At model load the layout creates the widget with
  `WidgetFactory::create(..., init = false)`: the Lua option defaults are not parsed then
  (`LuaWidgetFactory::parseOptionDefaults` runs only for a newly added widget or when the settings page opens),
  and `setDefault()` resets each missing entry to `opt->deflt`, which is still 0. So a missing option loads as 0,
  whatever its declared default (confirmed in the EdgeTX 2.12.0 simulator). A new option must never be a CHOICE
  either: the settings page shows stored value - 1, so a missing CHOICE (0) has no valid entry.
- Return `{ name = "Telemetry Dashboard", options = ..., create, update, refresh, background, useLvgl = true }`.
  **The name must stay exactly "Telemetry Dashboard"** (models store it). Define both `update` and `refresh`
  (rc1 requirement).
- `create(zone, options, path)`: `path` is the widget folder (e.g. "/WIDGETS/FPVDASH/"), may be nil → default.
  Load `app.lua` with `loadScript(dir .. "app.lua")` once (cache the loaded chunk result in a main.lua upvalue so
  several instances share the code), call `app.create(zone, options, dir)` → `wgt`. If loading fails, keep the
  error string and show it with an `lvgl.label` in `update`.
- `update/refresh/background` forward to app functions (forward `event`, `touchState`).
- If `lvgl == nil` (firmware < 2.11) show nothing harmful (refresh may `lcd.drawText` a message; useLvgl is ignored).

`app.lua` (per instance; `wgt` = the table returned by create):
```
wgt.zone, wgt.options, wgt.dir ("WIDGETS/FPVDASH/" — no leading slash, for images), wgt.path ("/WIDGETS/FPVDASH/")
wgt.mods = { telem, inputs, crsf, elrs, vtx, thrcap, theme, layout, dash, vtxpage, thrpage,
             topbar, sticks, grid, timers, footer }      -- loaded once per instance, in create
wgt.S = telem.new(), wgt.I = inputs.new(), wgt.T = thrcap.new()
wgt.C = crsf.new(), wgt.E = elrs.new(), wgt.V = vtx.new()
wgt.theme = theme.resolve(options)
wgt.now = getTime()                       -- 10 ms ticks
wgt.vtxOn = options.vtxOff == 0           -- VTX control on
wgt.view = nil  -- the shown UI object: d (dashboard), p (VTX page) or t (Throttle page)
wgt.built = { fs = bool, w = n, h = n, key = string, tab = "vtx"|"thr" }   -- the mode that is currently shown
wgt.dv, wgt.pv, wgt.tv = { slot, view, key, w, h }      -- dashboard, VTX page, Throttle page (kept while hidden)
wgt.ctl = slot (+ vtxBox, thrBox)                        -- root box of the page buttons (full screen only)
                                                         -- and its tab boxes (made before Back and the tabs)
wgt.tab = "vtx"|"thr"                                    -- tab choice, set by the tab buttons, kept between visits
wgt.tabs = { vtx = bool, thr = bool }                    -- the tab that is shown (read by the tab buttons)
wgt.pageOpen, wgt.vtxOpen                                -- a page is shown / the VTX tab is shown
wgt.pool = { slot, ... }, wgt.seq                        -- cleared root boxes for later use, root boxes made
```
- **View rule** (one function `build`, called by `rebuild` in pcall): each view is built inside its own root box
  (a `slot`: `{ box, show, seen, w, h, seq, fs }`; the box `visible` function sets `slot.seen` and returns
  `slot.show`; `fs` = the screen mode the box was made in).
  - **Full screen always shows the pages.** VTX control on: the tabs "VTX" and "Throttle"; VTX control off: only
    the Throttle page (no tabs, title "Throttle cap"). The page texts (`thrpage.build`, and `vtxpage.build` when
    VTX control is on) are built once, then only hidden. Above them, the button box `wgt.ctl` is made on each
    full-screen entry, in this order (z-order rule, §2): first the empty full-size box of each tab (`c.vtxBox`
    only when VTX control is on, then `c.thrBox`; their `visible` functions read `wgt.tabs`), then Back and the
    tabs (`thrpage.header(wgt, box, wgt.tabs)`). The controls of a tab (`vtxpage.controls` /
    `thrpage.controls`) go into its tab box the first time that tab shows during the visit. A full-screen box
    made after the header buttons would take their taps: Back and the tabs could then not be reached by touch.
    Reload stays inside the VTX tab box (it does not overlap Back or the tabs); a separate header-only root box
    above the slot is not used, because it would take the Reload taps. A tab press
    only sets `wgt.tab`; `needBuild` compares `built.tab` with the tab to show, so the next refresh shows it.
    `wgt.tab` defaults to "vtx" (VTX control on) or "thr", and goes back to the default when `vtxOff` changes.
  - Not full screen: the dashboard `dash.build(wgt, box)`.
  - Leaving full screen hides the pages and **deletes the button box contents** (`lvgl.clear(ctl.box)`): a hidden
    button can keep the key focus of the main view, and the main view then does not get the MDL, SYS and TELE keys
    (`LvglWrapper.cpp` sends non-LVGL keys to the focused object; `Widget::onEvent` does not pass them on).
    The dashboard and the page texts are kept and only hidden, so an App-mode visit makes and leaks only the
    page controls (VTX tab: 35 objects; VTX control off: 14), not the dashboard.
  - **Clickable rule** (§2): a free root box is used again only in the screen mode it was made in (`slot.fs`);
    page boxes are hidden outside full screen; a box made in full screen that is cleared on exit must be hidden at
    once (`lvgl.hide`), because 2.12.x has only one poll in the exit cycle. In full screen, `showError` makes only
    the label (no backdrop rectangle: it would stay clickable on the dashboard).
  - A view is built again only when the zone size or the option key changes; `wgt.rebuildRequested` (set by the
    page when the module option lists change) builds the page again. The widget settings page calls `update()`
    only once, when it closes (`WidgetSettings::onCancel`, rc1 and 2.12.0 `widget_settings.cpp:217-220`), so an
    option change builds the views once per settings visit and leaks the wrappers of the cleared views once
    (harness: 109 objects for the dashboard, 157 when the page texts exist too; about 16 to 24 KB). This is
    accepted: option changes are rare.
  - Called from `update()` when mode/size/options changed (compare with `wgt.built`), and from `refresh()` when
    `lvgl.isFullScreen()`, the tab or zone w/h differ from `wgt.built` (2.12.x does not call update on full-screen
    exit in App mode).
  - Errors show a label once (no repeated clearing in the error state).
- **tick(wgt, visible, rebuilt)** — called by `refresh` (visible = true; rebuilt = the view was just built in this
  cycle) and `background` (visible = false):
  ```
  wgt.now = getTime()
  if wgt.vtxOn then
    crsf.beginTick(wgt.C, wgt.now)                        -- pops/dispatches pending frames
    elrs.tick(wgt.E, wgt.C, wgt.now, visible)
    vtx.tick(wgt.V, wgt.C, wgt.E, wgt.now, visible, visible and wgt.vtxOpen)   -- 0x2E poll only on the VTX tab
  end
  thrcap.tick(wgt.T, wgt.now, visible and not rebuilt)    -- model writes only from refresh, never in a rebuild cycle
  if not visible then telem.track(wgt.S, wgt.now)
  elseif not rebuilt then
    telem.read(wgt.S, wgt.now, wgt.options, wgt.E, elrs, wgt.pageOpen)   -- skips heavy parts when a page is open
    if not wgt.pageOpen then inputs.read(wgt.I, options.extTrims) end
    wgt.view.update(wgt)                                  -- region/page display fields for property functions
  end
  ```
  With `vtxOff == 1`: do not call `crsf.beginTick`/`elrs.tick`/`vtx.tick` at all (no CRSF traffic, no queue).
  The footer then shows "ELRS" without version. `thrcap.tick` always runs (the cap works without VTX control).
- In `refresh`, if full screen and `event == EVT_VIRTUAL_EXIT` → `lvgl.exitFullScreen()` (also in the error
  state, and in main.lua when app.lua could not be loaded).
- Wrap nothing in pcall inside the hot path (cost); but `app.create` must survive missing modules (show error label).

## 5. Module contracts

### 5.1 `lib/telem.lua` (glue) — data only, no formatting of display strings beyond the listed fields
```
telem.new() -> S
telem.read(S, now, options)   -- fills S in place; cheap; resolves sensor ids via getFieldInfo with a negative cache
S.connected   bool   -- live link (RQly > 0 or TPWR > 0 or valid RFMD), as today (read.lua updateConnectionFlag)
S.rxV         number|nil   -- RX battery volts (VFAS, RxBt, Bat, BATT, A4 — first that exists); nil without link,
                           -- and nil when the value is old for more than 2 s while the link is up (the link
                           -- came back before the next battery frame, or the FC sends no battery frame)
S.cells       int|nil      -- options.rxCells if > 0 (always, also without link), else automatic (v4), and nil
                           -- while rxV < telem.PACK_MIN (not a pack). Principle: in doubt no count (the
                           -- dashboard shows the total voltage with the neutral icon 'battery-none'); where a
                           -- rule must choose, the count is too high (the cell voltage too low): never show a
                           -- used pack fuller than it is.
                           --   Fresh values only: link up and getSourceValue "not old" (EdgeTX keeps old sensor
                           --   values after a link loss, marked old; it marks a value old only at a link loss
                           --   or after 20 s without a new value) for the RX voltage V, Curr and Capa.
                           --   New pack -> nil until a rest window latches: (a) the first fresh V after the
                           --   widget started; (b) a fresh Capa more than 10 mAh below the last one when the
                           --   fresh V had a gap of more than 1 s since the last Capa reading (the FC sets Capa
                           --   to about 0 when it starts; a pack change cuts the power of the RX, so the link
                           --   is lost); (c) fresh V below telem.PACK_MIN (2.5 V) for 1 s with the link up (no
                           --   pack, FC on USB).
                           --   Same pack, the count stays: a Capa drop without that gap (an FC start from the
                           --   OSD menu, the configurator or a tool: the RX keeps its power and the link); V
                           --   below PACK_MIN for less than 1 s (the voltage filter of an FC that starts again
                           --   begins at 0 V and passes 2.5 V in about 60 ms); a gap of any length without a
                           --   Capa drop (link lost, failsafe, tool script open, widget not run).
                           --   Used pack of unknown history: the first fresh Capa after the widget started is
                           --   > 100 mAh and no count is latched yet (model change away and back, radio restart,
                           --   USB storage visit): no count until the next new pack (or rxCells).
                           --   Rest window: every fresh V within 0.15 V and every fresh Curr <= 2.5 A (an FC with
                           --   an HD VTX idles at about 2 A; no fresh Curr: V alone). A tick without a fresh V,
                           --   or > 1 s without a read, ends the window.
                           --   Rest voltage (for the keep rule): the last reading of a rest window of >= 0.5 s
                           --   (no minimum when the window ends with a gap: the RX lost its power with the pack).
                           --   A window that starts > 0.15 V below the reading before it counts only after 3 s,
                           --   and with a count n a V below 3.12 x n is no rest. Reason: a pack unplugged from an
                           --   FC on USB (the link stays up) falls through the Betaflight display filter (PT1,
                           --   tau about 0.48 s) to 0 V in about 1 s, and with one battery frame per second a
                           --   reading of that fall stays for 1 s; it must not become the rest voltage.
                           --   Latch (only while there is no count): cells = max(1, ceil(V / 4.42)) of a reading
                           --   after 3 s of rest (4.42 = 4.35 V LiHV full + sensor step + about 1 % FC error).
                           --   After (b) or (c) the old count n stays instead when n > ceil(V / 4.42), V / n >=
                           --   3.20 and V is within -0.04..+0.08 V per cell of the old pack's rest voltage (for
                           --   (b) the one from before the gap: the last one when no fresh V >= PACK_MIN came
                           --   after the gap, e.g. USB on the bench sends 0.1 V first) - the same pack plugged in
                           --   again, e.g. after a power cut, an FC start while a tool script was open, or on USB.
                           --   A second new pack before the latch keeps that old count and voltage. The result is
                           --   never lower than the latch.
                           --   Upward: fresh V > cells x 4.42 + 0.10 V for 1.5 s -> ceil(V / 4.42).
                           --   No other rule changes a latched count: it goes down only through (b) or (c)
                           --   and a later rest latch. There is no downward check after a gap.
                           --   An old RX voltage with the link up shows for 2 s, then S.rxV is nil (above).
                           --   The auto logic also runs in fixed mode (a change back to 0 continues at once) and
                           --   in background (telem.track, without public fields, with the same round-robin
                           --   sensor id check as telem.read).
                           --   Limits (set rxCells for such packs, and always for 7S+ and Li-ion packs):
                           --   - The voltage cannot count a pack that is not full: a pack of n cells at rest
                           --     below (n-k) x 4.42 / n V per cell gets k cells less (one cell below 3S 2.95,
                           --     4S 3.32, 5S 3.54, 6S 3.68, 8S 3.87, 12S 4.05; two cells below 6S 2.95, 8S 3.32,
                           --     12S 3.68; a 6S at 21.6 V = 5S at 4.32 V, an 8S at 26.4 V = 6S at 4.40 V), and
                           --     the cell voltage shows 4.1..4.4 V ('full'); the upward rule cannot fix it. This
                           --     happens to a used pack plugged in that is not at the old pack's rest voltage
                           --     (another pack, or one unplugged before it was at rest), to a used pack that the
                           --     widget finds without a Capa sensor (model change, radio restart), and to a widget
                           --     that starts in flight without a Curr sensor.
                           --   - Without a Capa drop with a gap (no Capa sensor, an FC that always sends Capa 0,
                           --     a pack changed before it used 10 mAh) the count never goes down: a later pack
                           --     with fewer cells shows too low (6S, then a full 4S at 16.8 V = 6S at 2.80 V);
                           --     more cells: upward rule. After (b) or (c), a pack with fewer cells at about the
                           --     old rest voltage keeps the old count too (6S landed at 21.0 V, then a full 5S
                           --     = 6S at 3.50 V). Both are too low: the safe side.
                           --   - An RX with its own battery keeps its link: a pack change in < 20 s is the same
                           --     pack. Details: header of lib/telem.lua.
S.cellV       number|nil   -- rxV / cells (nil without a count)
S.rxImplausible bool       -- link up and 0.05 <= rxV < PACK_MIN (no pack, e.g. FC on USB)
S.lq          int|nil      -- RQly
S.rssi1, S.rssi2, S.rssi    -- dBm (negative) or nil; 0 means missing → nil; S.rssi = best of 1RSS/2RSS
S.snr         int|nil      -- RSNR (dB)
S.rfmd        int|nil      -- raw RFMD
S.rateHz      int|nil      -- packet rate from RFMD (see §9 item 2), nil when unknown
S.tpwr        int|nil      -- TPWR mW
S.curr        number|nil   -- Curr A
S.capa        int|nil      -- Capa mAh
S.sats        int|nil, S.gps bool   -- Sats; gps = a GPS sensor exists (getFieldInfo("GPS") ~= nil)
S.fm          string|nil   -- FM sensor text, else flight mode name (local _, name = getFlightMode())
S.ant         int|nil
S.txV         number|nil   -- radio battery V (getValue("tx-voltage"))
S.txState     "full"|"ok"|"warn"|"low"|"dead"   -- from the radio's own vBatMin/vBatMax if readable, else 7.1/7.5/7.9 V
S.modelName   string       -- model.getInfo().name or "MODEL"
S.timers      { {sec=int|nil}, {sec=int|nil}, {sec=int|nil} }   -- timer1..3 (getValue("timer1") etc.); nil when unused
S.clock       "HH:MM",  S.date "2 Oct"
S.changed     int          -- increments when any field changes (optional optimisation)
```
### 5.2 `lib/inputs.lua` (glue)
```
inputs.new() -> I
inputs.read(I, ext)   -- ext = options.extTrims: 0/nil = auto, 1 = normal trims, 2 = extended trims
I.mode       1..4  (getStickMode() if it exists, else 2)
I.left  = { x = -100..100, y = -100..100 }   -- physical LEFT gimbal: x = horizontal, y = vertical (+ = up)
I.right = { x = ..., y = ... }                -- physical RIGHT gimbal
           (mode 2: left x = rud, left y = thr, right x = ail, right y = ele; map other modes, see $R/trims.md §1.5)
I.trim  = { lh = pct, lv = pct, rv = pct, rh = pct }   -- physical trim positions, -100..100 % of the full range
I.trimTxt = { lh = "", lv = "", rv = "", rh = "" }      -- EdgeTX-style value text: percent, no sign, "" when 0
I.trimExt = bool   -- extended trims: range ±4096 instead of ±1024. Lua cannot read the model setting, so it is
                   -- the extTrims option; with auto it turns on once any |raw| > 1024 was seen
```
Trim sources: `trim-rud`, `trim-ele`, `trim-thr`, `trim-ail` via `getFieldInfo` ids (see `$R/trims.md` §6).
Stick sources: `rud`, `ele`, `thr`, `ail` (raw ±1024 → ±100, deadband 0.8 as today).

### 5.3 `lib/crsf.lua`, `lib/elrs.lua`, `lib/vtx.lua` (protocol)
Entry points used by app.lua (exact):
```
crsf.new() -> C ;  crsf.beginTick(C, now)
elrs.new() -> E ;  elrs.tick(E, C, now, allowTraffic)
vtx.new()  -> V ;  vtx.tick(V, C, E, now, allowTraffic, pageOpen)
```
Fields read by the UI (must always exist with the documented type; never nil unless stated):
```
E.found    bool          -- an ELRS TX module answered (0x29 from 0xEE with serial "ELRS")
E.label    string        -- footer text: "<device name> <maj>.<min>.<rev>" when found, else "ELRS";
                         -- only "<device name>" when the module sends version 0.0.0 (ELRS 2.x)
E.version  string|nil    -- "4.1.0"; nil when the version is 0.0.0 (no RFMD table then: "RF n")
E.armed    bool          -- from ELRS status 0x2E flags (false when unknown)
V.state    string        -- "off" | "nocrsf" | "search" | "noelrs" | "novtx" | "load" | "ready" | "busy" | "error"
V.msg      string        -- short status text for the UI (≤ 30 chars), always set
V.ready    bool          -- current values below are valid
V.bandLabels  table      -- option labels, index = value+1, e.g. {"Off","A","B","E","F","R","L"} (4.1: "Disabled")
V.band     int           -- current band value (0 = off); 0 when unknown
V.bandLetter string      -- "A".."L" or "" when off/unknown
V.channel  int           -- 1..8; 0 when unknown
V.powerLabels table      -- {"-","1",...,"8"} or {} when no power field
V.power    int           -- 0 = "-" (no change) ; 0 when unknown/absent
V.pitLabels table        -- {"Off","On","AUX1↑",...} or {} when absent
V.pit      int           -- 0 = Off
V.freq     int           -- MHz for band/channel, 0 when unknown or off
V.send     string        -- "idle" | "writing" | "sending" | "sent" | "queued" | "notenabled" | "failed"
V.sendMsg  string        -- human text for the send result (always set, "" when idle)
V.rev      int           -- increments every time any field above changes (cheap change detection)
```
Request API used by the VTX page (callbacks only call these; they only record requests):
```
vtx.apply(V, sel, send)   -- sel = { band = int|nil, channel = int|nil, power = int|nil, pit = int|nil } (module
                          -- value space, nil = keep). Writes only changed fields (clamped to the parsed range), waits,
                          -- reads back, then if send == true clicks "Send VTx". Coalesces: a new apply replaces a
                          -- pending one that has not started writing.
vtx.reload(V)             -- re-read all VTX fields
vtx.freqOf(letter, ch)    -- MHz (ELRS table, $R/elrs_crsf_vtx.md §6.2) or 0
```
Protocol behaviour: follow `$R/elrs_crsf_vtx.md` §7–§14 (origin 0xEA, device 0xEE, discovery by name, one
outstanding request, chunking, timeouts, Send VTx flow, 0x2E status poll only while the page is open, no traffic
when `allowTraffic` is false — but still pop/drain frames, slow idle refresh ≤ 1 frame per 15 s on the dashboard).
The old `telemetry/elrs.lua` behaviour (device ping until found) moves here.
A scan read without a reply never skips the id: ELRS answers every id 1..fieldCount, so a lost reply is a transport
problem (stall, reboot). It starts the lost path (re-ping; the 0x29 reply starts a new scan from id 1), so a short
stall cannot skip the VTX folder and give a false "No VTX Admin".
A 0x2B is taken only with dest 0xEA, origin 0xEE, the outstanding field id and the expected chunk: chunk 0 must
look like the start of an entry (parent <= fieldCount, type 0..15 or 127, no control characters in the name, the
0 terminator present unless more chunks follow); later chunks count down. ELRS 4.1+ answers the ELRS tool at its
own origin, so strays are common. A scan pass that ends without the VTX folder re-pings and runs one more complete
pass (`V.state` "load", `V.msg` "Checking VTX Admin"); only a second miss gives "novtx".

### 5.4 UI builders
```
dash.build(wgt, root) -> d ; d.update(wgt)    -- dashboard for wgt.zone.w x wgt.zone.h inside the box root
                                              -- (not full screen)
vtxpage.build(wgt, root) -> p ; p.update(wgt) -- VTX tab texts inside the box root (use LCD_W/LCD_H); adds Reload
                                              -- and the status texts of the header strip
vtxpage.controls(p, wgt, root)                -- the VTX tab buttons inside the box root (full screen only)
thrpage.build(wgt, root) -> t ; t.update(wgt) -- Throttle tab texts inside the box root (use LCD_W/LCD_H)
thrpage.controls(t, wgt, root)                -- presets, -5/+5, number input, Set (full screen only)
thrpage.header(wgt, root, tabs)               -- Back, and the VTX / Throttle tab buttons when VTX control is on
                                              -- (tabs = wgt.tabs; a tab press only sets wgt.tab)
layout.pageHeader(W) -> { h = 42, btnY, btnH, backX, backW, tabX = {}, tabW = {}, titleX, textX, textR,
                          reloadX, reloadW }  -- at 480: Back 3..59, tabs 63..113 and 117..197, texts 202..413,
                                              -- Reload 417..477
```
(root nil = objects go to the widget itself; the unit tests use that.)
- `build` creates all LVGL objects once and stores in its own table only what `update` needs.
- `update(wgt)` runs every visible tick: compute display strings/colors **only when inputs changed** and store them in
  plain fields that the property functions return.
- Theme: `wgt.theme = { dark = bool, text = WHITE|BLACK, shadow = BLACK|WHITE, wash = BLACK|WHITE,
  washOpa = 153|119|85|51 (transpLevel 1..4), iconDir = "icons/dark/"|"icons/light/", good = GREEN,
  warn = YELLOW (dark) | dark amber lcd.RGB(112,44,0) (light), bad = RED, muted = lcd.RGB grey (#A0A0A0 dark,
  #606060 light), accent = COLOR_THEME_FOCUS, track/tick/tbox = lcd.RGB greys (dark #707070 / #C0C0C0 /
  #404040; light #606060 / black / #808080), focus, active, stick, dotIn,
  cap = warn (the throttle cap line and its label), extMark = COLOR_THEME_ACTIVE (dark) | warn (light) (a trim
  marker beyond the normal range) }` (dash agent writes `ui/theme.lua`; the pages may use it or plain theme
  colors). Light mode: yellow (YELLOW, and the yellow ACTIVE #FFDE00 of the default theme) gives only 1.0 to
  1.3:1 on the white wash, so every light-mode part (track, tick, tbox, warn, cap, extMark) has at least 3:1
  against white, the washed #E4EEF2 and the darkest sky pixel of THEMES/EdgeTX/background.png, at every
  transparency level (`tests/unit/theme_contrast_test.lua`). Dark mode keeps YELLOW and ACTIVE.

### 5.5 `lib/thrcap.lua` (thrcap) — throttle cap
```
local thrcap = loadScript(...)() ; thrcap.MIN = 20 ; thrcap.MAX = 100
thrcap.new() -> T
thrcap.tick(T, now, allowWrite)   -- now = getTime(); allowWrite = true only from refresh() (and not in a rebuild
                                  -- cycle); background() passes false. Looks for a model change every 0.5 s
                                  -- (model.getInfo().name / filename), reads the throttle input again every 2 s,
                                  -- after a model change and just before a write, and makes at most ONE pending
                                  -- swap per call, when allowWrite and 400 ms passed since the last request.
thrcap.request(T, cap)            -- rounds and clamps to MIN..MAX, sets T.pending and T.pendAt (getTime(); each
                                  -- new tap renews it) and a snapshot of the line it is for (the input index and
                                  -- every field of the last read line); never touches the model (button
                                  -- callbacks call only this)
thrcap.target(T), thrcap.step(T, d)   -- helpers: value to show (pending, else cap, else custom weight, else 0);
                                      -- request(target + d)
```
Fields (always present with these types; `pending` may be nil):
```
T.state    "ok" | "none" | "unsupported" | "busy" | "error"
T.msg      string <= 30 chars: "Ready", "Setting NN%...", "Cap set to NN%", "Cap is NN% already",
           "Custom line: tap to replace", a refusal reason, or an error or a dropped request (shown 4 s)
T.cap      int 0..100 (0 = unknown or custom)        T.custom  bool: weight/offset do not fit the cap formula
T.weight, T.offset  ints (0 when unknown)            T.pending int 20..100 or nil
T.input    0-based input index, -1 = none            T.rev     int, increments when any field changes
```
**Mix policy: refuse when in doubt, never write.** The cap is allowed only when ALL of these are true (else
state "unsupported" or "none" with the reason, and the model is never written):
- a) Exactly one input has a line whose source is the Thr stick (`getFieldInfo("thr").id`, or −thr). Two or
  more: "Thr in N inputs" (also when the mix shows which one the throttle channel takes; `T.input = −1`).
- b) That input has exactly one line, and line 0 has: source thr (not −thr), switch 0, flightModes 0, side 3
  (both), plain weight and offset (Lua value −1023..1023: a value ≥ 1024 or ≤ −1024 is a GVAR or another source,
  `sourceNumValToLuaInt`), weight > 0, and curveValue 0 or curveType 1 (expo; it keeps the end points and is
  copied). Diff, function and custom curves are refused.
- c) At least one mix line that Lua can read (any of the 32 channels) takes the input (source `src` =
  `getFieldInfo("input1").id + chn`; 2.12.0 `api_general.cpp:408`, `MIXSRC_FIRST_INPUT` = 1; `getMix().source`
  is `srcRaw`, an inverted source is negative) with a plain weight > 0. Else "Thr input not in mixes".
- d) No mix line that Lua can read, on any channel, takes: the raw Thr stick (tid or −tid; also a small
  Thr -> elevator mix of a plane): "CHn uses raw Thr"; the input inverted (−src, with any weight) or
  with a negative weight: "CHn inverts the Thr input" (stick high is then the idle end, and the cap would move
  it); the input with a GVAR weight: "CHn mix weight uses GVAR"; the input with a function or custom curve
  (curveValue ≠ 0 and curveType 2 or 3; a custom curve can invert, |x| folds): "CHn Thr mix has a curve". Expo
  and differential on the mix line keep the direction and are allowed. A line that takes the input with weight
  0 neither counts for c) nor refuses.
The checks run in this order: a), b), then c) and d) in one pass over the mix (channel order, then line order;
the first problem found is the reason, and its channel is named). An input refusal reads no mix line.
Hidden mix lines: the Lua mix list stops at the first line with the source "---" (srcRaw 0; 2.12.0
`api_model.cpp` getFirstMix and getMixesCountFromFirst, lines 781-806): Lua sees the lines of that channel
before it, and every later channel shows 0 lines. The colour mixer skips that line and uses the lines after it
(`mixer.cpp` evalFlightModeMixes 852-858: `continue` with COLORLCD). Lua cannot tell such hidden lines from empty
channels. When the hidden lines include the one that takes the input, c) refuses "Thr input not in mixes" (a
rare false refusal, accepted). Limit: when the "---" line comes after the visible line that takes the input, a
raw Thr or inverted line hidden after it cannot be seen, and the cap is allowed. Not checked either: the output
reverse setting, MULTIPLY / REPLACE mix lines, and Lua mix scripts. API: without `model.getMixesCount` /
`model.getMix`: state "none", "No mix API"; without the id of `input1`: "No input source id".
This check runs only in the scan (every 2 s, after a model change and just before a write: a mix edited while a
request waits drops the request). Read-back: `cap = weight` when
`0 < weight <= 100` and `offset == weight − 100`, else custom.

Refusal messages (state "unsupported", the model is never written; all <= 30 chars, n = 1..32): "Thr in N
inputs", "Thr input has N lines", "Thr source inverted", "Thr input not simple" (line 0 source not thr,
switch ≠ 0, flightModes ≠ 0 or side ≠ 3), "Weight uses GVAR" / "Offset uses GVAR" (|value| ≥ 1024 = a source
reference), "Thr input has a curve" (curveValue ≠ 0 and curveType ≠ 1), "Thr weight 0 or less", "CHn uses raw
Thr", "CHn inverts the Thr input", "CHn mix weight uses GVAR", "CHn Thr mix has a curve", "Mix read failed"
(getMix gave nil for a counted line), "Thr input not in mixes". State "none": "No input API", "No mix API",
"No thr source", "No input source id", "No throttle input".
A custom line (for example 80/−10) is state "ok", `custom = true`, `cap = 0`; a request replaces it with the
formula line (the page shows "Custom 80/−10", −5/+5 are inactive, presets and Set replace it).

**The swap (glitch-free, `$R/throttle_cap.md` §2.4 C and §3)** — no Lua function changes a line in place, and
the mixer task can run between any two Lua instructions, also during the field copy loop of `insertInput`:
1. `new` = a copy of EVERY key of line 0 (name, source, scale, weight, offset, switch, curveType, curveValue,
   trimSource, side, flightModes; not inputName) with `weight = cap`, `offset = cap − 100`. Integers only.
2. `model.insertInput(chn, 1, new)` — AFTER the live line 0. Line 0 is always active (no switch, no flight mode
   mask, side 3), the first active line of an input wins, so line 1 is never evaluated while it is filled.
3. Read back: the input must have 2 lines, line 0 equal to the old line and line 1 equal to `new` (every key).
4. `model.deleteInput(chn, 0)` — one memmove while the mixer is stopped: the next cycle uses the new line.
5. Read back: one line, equal to `new`.
Every model call is in pcall. If a step fails, the extra line 1 is deleted again (line 0 stays the live line;
never delete the last line) and `T.state = "error"` with "Insert failed", "No free input line (64 used)",
"Read-back mismatch", "Delete failed" or "Check failed".

A pending request is dropped (no write, `T.state = "error"`, message shown 4 s):
- "Model changed: not set": the model changed after the request.
- "Line changed: not set": the input index or any field of the line differs from the snapshot made at request
  time (for example an edit by hand in the Inputs editor while the request waited). Checked after each scan,
  also in background, and in the fresh scan just before the swap: a newer manual setting is never overwritten.
- "Request expired: not set": the request is more than 5 s old (from the last tap) when the swap would run
  (refresh() did not run for that time: another view or a menu was shown). The cap never changes later without
  a new tap. A request that waits less (for example 3 s in background) is applied at the next refresh.
Never write from `background()` (it also runs while the Inputs editor is open, which
holds lines by index) and never from a callback. `model.deleteInputs()` and `defaultInputs()` are never used.
`insertExpo`/`deleteExpo` each call `storageDirty`: one SD write 15 s after the last change (TX15).

## 6. Dashboard layout (480x320; other sizes scale like `$R/fpvdash_spec.md` §4)

Same 5 regions as today (`layout.lua` formulas): topBar 0,0,480,44 · sticks 0,46,480,102 · grid 0,150,480,106 ·
timer row 0,258,480,44 · footer 0,304,480,16 (footer only if h ≥ 290). Each region has a wash rectangle
(`filled`, color `theme.wash`, opacity `theme.washOpa`), 2-px unwashed gaps between regions.

- **Top bar**: as today (model name DBLSIZE, TX battery icon + "7.8V" MIDSIZE, link icon, clock + date SMLSIZE,
  42-px reserve on the left for the EdgeTX menu button in App mode). Measure text with `lcd.sizeText`.
- **Sticks**: as today (LQ block left, RX battery block right, two 2-px WHITE gimbal boxes with 9x9 WHITE / 7x7 dark
  dot) **plus trims** (if `options.hideTrims == 0`). RX battery block: with a cell count "3.85V (4S)" and the
  icon of the cell voltage (full > 4.0, ok > 3.7, warn > 3.5, low > 3.3, else dead); without a count the total
  voltage "16.40V" with the neutral icon `icons/battery/battery-none.png` (grey outline, no bars: the charge
  is unknown), and the dead icon below `telem.PACK_MIN`.
  - Shrink the boxes so a horizontal trim fits under each box inside the region (box ≈ 80 px at 480x320).
  - `lh` horizontal bar under the left box, `rh` under the right box (same width as the box);
    `lv` vertical bar on the OUTER side of the left box, `rv` on the outer side of the right box (same height as the box).
  - Track: 4-px rounded bar `COLOR_THEME_SECONDARY1`-like but visible on the dark wash (`theme.track`, an
    lcd.RGB grey); centre tick; marker 9x9 rounded square `COLOR_THEME_FOCUS` (`theme.extMark` when beyond ±128
    steps on extended trims: ACTIVE in dark mode, the dark amber in light mode), moved with `pos` functions;
    optional TINSIZE value text (`I.trimTxt`) at the far end of the
    bar opposite to the marker, only when non-zero.
  - Nothing may overlap the LQ text/icon or the RX battery block.
  - **Throttle cap line** (`wgt.T`): a 2-px `hline` across the THROTTLE box (the left box in stick modes 2 and 4,
    the right box in modes 1 and 3), `w = B − 4`, at `cap/100` of the travel of the dot centre from the bottom:
    with the throttle stick where the output reaches the cap (stick % = 2·cap − 100) the dot sits on the line.
    A TINSIZE "NN%" label (with shadow) in the 20-px gap between the boxes, or inside the box when the gap is too
    narrow; color `theme.cap` (YELLOW in dark mode, the dark amber in light mode). Made before the boxes (the
    dot stays on top).
    Hidden at 100 %, when the cap is unknown, for a custom line, for the states "none" and "unsupported", and
    when `wgt.T` is nil. Computed again only when `T.rev`, the T table or `I.mode` changes.
- **Grid**: 2x4 icon + value metrics as today (Curr, Rate, TX power, RSSI / Sats, FM, SNR, Capa) with fixes (§9).
- **Timer row**: **4 cells** of equal width: Timer1, Timer2, Timer3 (clock icon + "MM:SS", "H:MM:SS" when ≥ 1 h,
  "--:--" when unused) and the **VTX cell**:
  - vtxOff = 1 → cell shows nothing (or a 4th timer? no: leave the 3 timers at 1/3 width each instead).
  - Two lines: line 1 `VTX` (SMLSIZE, muted) + state dot (good = ready, warn = busy/search, bad = error, muted = off);
    line 2 `R4 5769` (band letter + channel + MHz, STDSIZE/BOLD) or `OFF` (band 0) or a short state (`--`, `NO ELRS`,
    `NO VTX`) ; append ` P` or a pit marker when pit mode is on; power level shown as `P2` if space allows,
    in the text color (it is data; the muted color is only for the `VTX` header). The tag with pit mode on
    ("P2 PIT") is in `theme.warn` (YELLOW in dark mode, the dark amber in light mode).
  - A tiny hint is not needed (App mode: long-press opens full screen).
- **Footer**: `E.label` left, EdgeTX version right (`getVersion()`), SMLSIZE, shadowed.

## 7. Full-screen pages (480x320) — owner: page agent

Must be usable with a finger (buttons ≥ 40 px wide, ≥ 34 px high where possible) and with the rotary encoder
(LVGL focus moves between buttons). Leave ≥ 2 px around controls for the focus outline.

### 7.1 Header and tabs (shared, `thrpage.header`, `layout.pageHeader`)
42-px strip: **Back** (3..59) → `lvgl.exitFullScreen()`; with VTX control on the tab buttons **VTX** (63..113)
and **Throttle** (117..197), the shown tab in the focus color; with VTX control off the title "Throttle cap"
in their place. Status texts of the shown page at x 202..413 (cut to fit with `lcd.sizeText`, only when they
change). The VTX tab adds **Reload** at 417..477.

### 7.2 VTX page (the "VTX" tab)
Content (suggested; the page agent may improve):
1. Header: state dot + `V.msg`, the current applied setting (`Now: R4 5769 MHz · P2 · Pit Off`) and ARMED in the
   status area of §7.1 (the message ends before ARMED while armed); Reload at the right.
2. **Band** row: one button per band option from `V.bandLabels` (skip index 0 "Off"/"Disabled"; add an "Off" button
   at the end of the row or in the pit row).
3. **Channel** row: buttons 1–8; the selected band's frequency for each channel shown in the button text if it fits
   (e.g. "4\n5800" only if two-line button text renders on the radio — otherwise show the frequency of the
   selection in the summary line).
4. **Power** row: buttons from `V.powerLabels` (index 0 "-" = "Keep"), hidden if the list is empty.
5. **Pit mode**: button showing the current pit label; press opens `lvgl.menu{title="Pit mode", values=V.pitLabels,
   get=..., set=...}` (1-based ↔ value+1). Hidden if no pit field. ELRS sends the pit mode only with a power
   level (power "-" = Keep sends neither, and 3.6+ hides the Pitmode field), so with power Keep selected the pit
   button is hidden ("Needs a power level"), pit is not written, and no text shows pit as active.
6. **Apply & Send** button (wide): calls `vtx.apply(V, sel, true)`; text changes with `V.send`
   ("Apply & Send", "Writing…", "Sending…", "Sent ✓", "Queued (no RX)", "Enable a band", "Failed – retry").
   A failed result shows "Failed - retry" (warning color) and the module message until the result times out, also
   while the selection is still staged.
   If `E.armed` is true → `lvgl.confirm{title="Armed", message="Change VTX while armed?", confirm=...}` first.
   A small **Reload** button calls `vtx.reload(V)`.
7. Selection model: the page keeps `p.sel = {band, channel, power, pit}` initialised from `V` when the page is
   built and whenever `V.rev` changes while nothing is staged. Tapping a button only changes `p.sel`.
   Colors: selected = `COLOR_THEME_FOCUS` background; current (applied, not selected) = `COLOR_THEME_ACTIVE`;
   others = default button color. Summary line shows the staged selection + frequency.
   **Text colour rule** (both pages): the text on a FOCUS, ACTIVE or WARNING button is BLACK or WHITE, the one
   with more contrast against the real theme colour (`lcd.getColor` returns the RGB565 value in bits 16..31 with
   the flag 0x8000; read once per build). One of the two always gives at least 4.5:1. The theme text colours do
   not: on "Dark Theme" PRIMARY1 on ACTIVE is 1.65:1 and PRIMARY2 on FOCUS 2.9:1. A text in the FOCUS colour on
   the page (the staged summary, "Pending: NN%") uses FOCUS only when it gives 4.5:1 on SECONDARY3, else
   PRIMARY1, else BLACK or WHITE. Without `lcd.getColor` the theme colours are kept (PRIMARY2 on FOCUS and
   WARNING, PRIMARY1 on ACTIVE, FOCUS for the page texts). The unit tests check every highlighted pair at 4.5:1
   or more on "Dark Theme", the default theme, a theme with a dark ACTIVE and every `THEMES/*/theme.yml`.
8. When `V.ready` is false: show a large status text (`V.msg`) and only the Back and Reload buttons
   (use `visible` functions on a container box, not rebuilds).
9. `RTN` short press exits (handled in app.lua). Do not use `lvgl.page` (header icon/back button rc1 issues) unless
   you verify it in `$R/lvgl_api.md` — plain objects are preferred.
10. Screens lower than 300 px (480x272): rows 40 px, buttons 34 px; when the summary does not fit under the rows,
    Apply goes to the right of the Pit button and the summary has two lines under the rows. Nothing overlaps.
11. Each full-screen entry makes new buttons: the staged selection and an old request are dropped.

### 7.3 Throttle page (the "Throttle" tab; the whole full screen when VTX control is off)
- Header status: state dot + `T.msg`, then "Input N: weight W, offset O" (only "Input N" for a refused line).
- Body (shown while `T.state` is not "none"/"unsupported"): the cap big ("75%", DBLSIZE; "Custom 80/−10",
  MIDSIZE when too wide; "--" when unknown) with the caption "Max throttle"; "Pending: NN%" while a request
  waits; a row of presets 100 90 80 75 70 60 50 % (pending = focus color, applied = active color; text colours
  by the rule in §7.2 item 7); −5 / +5 (from
  the pending value, else the applied cap; inactive when the cap is unknown or custom); a `numberEdit` (20..100,
  display "NN%") with a **Set** button: the value is staged in the page table and the script never changes it while
  the input exists (rc1 reads `get` only at creation), a new set of controls stages the shown cap; notes
  "Applies immediately, also when armed." and "Stick low stays at −100. Range 20..100 %.".
- States "none"/"unsupported": the controls are hidden; a large `T.msg` with two hint lines.
- Callbacks only call `thrcap.request` or change the staged number. No confirmation, also when armed.
- 480x272: rows 40 px, buttons 34 px; nothing overlaps (also the number input).

## 8. Performance & memory
- One tick must not parse more than ~4 CRSF frames (crsf.beginTick limit).
- `d.update`/`p.update` must early-exit per region when inputs are unchanged.
- `thrcap.tick` (desktop VM instructions): idle about 30, a read of the inputs with the mix check about 740
  (64 lines: 1600), a tick with a swap about 2000. On the Throttle tab with a swap every 750 ms the harness
  measures refresh max about 2800 and average about 720.
- `telem.read` with the cell count: typical about 460, worst about 680; `telem.track` about 190 (one
  getFieldInfo check every 4th call, as in `telem.read`).
- Load modules only in `create` (not at radio start). Keep `main.lua` < 3 KB.

## 9. Bug fixes to include (from `$R/fpvdash_spec.md` §10)
1. RX battery cell count: latch at rest or use option `rxCells` (S.cells; rules in §5.1).
2. RFMD → Hz: use a table verified against ELRS source for the module's major version (protocol/glue agents
   coordinate through `$R/elrs_crsf_vtx.md`; if a value cannot be verified, show `"RF n"` instead of a wrong Hz).
   telem.lua may read `wgt.E.version` (pass E as optional argument: `telem.read(S, now, options, E)`).
3. Colors: no raw RGB565 literals (dark wash/shadow = BLACK, light text = BLACK, light shadow = WHITE).
4. SNR unit "dB" (not "dBm"); SNR 0 is valid; FM fallback uses the flight-mode NAME.
5. Shadow of colored text (satellite count) = theme shadow color.
6. Stick-mode aware gimbals (inputs.lua).
7. Timers: hours, unused timers "--:--".
8. Text widths from `lcd.sizeText` instead of char-count estimates; truncate the model name to fit.

## 10. Tests (owner: harness agent; everyone runs them)
`<root>/tests/run.lua` (desktop Lua 5.5) loads `tests/edgetx_mock.lua` (strict LVGL + EdgeTX API mock) and
`tests/fake_elrs.lua` (simulated ELRS TX module), then runs the real widget from the SD-card folder through
create/update/refresh/background in many scenarios, measures VM instructions per tick with a count hook, checks
property-function rules, and writes an SVG/PNG-free text report plus `tests/out/*.svg` layout dumps.
Command: `cd "<root>" && lua tests/run.lua` → exit code 0 = all pass. `sh tests/check.sh` runs everything
(syntax checks, harness self-test, scenarios in rc1 and 2.12.x mode, unit tests). The scenarios also check that no
no-argument `lvgl.clear()` runs after the first build, count the leaked wrappers per page visit, load the options
like EdgeTX does for an existing model (scenario o), check a 480x272 radio (scenario p), the RX cell count with old
telemetry values after a link loss, a loss in flight and an FC start without a link loss (scenario q), and the touch reach of every full-screen
control with an LVGL-order hit test (scenario fs-touch).

Throttle cap in the harness: the mock emulates the model input/mix API and the input stage of the mixer from the
firmware source (one model per radio; default the user's model "75", `Mock.USER_MODELS` has all four). It runs a
mixer cycle after `insertExpo` (the default line), after every field store of the `insertInput` copy loop (keys
shuffled like `lua_next`) and after `deleteExpo`, for throttle −100..+100 %. At the end of each 50 ms cycle every
such mixer cycle must show, per input, the output from before or after the cycle (else a glitch). Every scenario
fails on a glitch, a model write outside `refresh()`, a float argument, two swaps in one call, a `wgt.T` contract
problem, or a visible clickable object outside full screen (checked at the end of every cycle). Scenarios:
`cap-page` (the 4 user models: presets, −5/+5, number input + Set, other fields kept, model the same at the end),
`cap-taps` (debounce, background), `cap-armed` (armed, during a VTX send, stick moving; controls with the unsafe
orders), `cap-refuse` (18 refused layouts, two thr inputs, expo, custom line, 64 lines, failure injection, model
change), `cap-line` (stick modes 1-4, 50 %, 100 %), `cap-vtxoff` (only the Throttle page), `fs-loop` (App-mode
full-screen loops with option changes), `fs-touch` (hit test of every visible control, both tabs, VTX control
on and off), `cap-cpu` (Throttle tab layout at 480x320 and 480x272, then CPU with swaps), and `i` (VTX control
off).
`tests/unit/thrcap_test.lua` tests `lib/thrcap.lua` alone with every field-store order and failure injection, the
mix check of a single throttle input and the dropped requests (line changed, expired).
`tests/unit/glue_telem_test.lua` tests the RX cell count (rest window, resets, pack swaps, FC starts with and
without a link loss, a used pack of unknown history, gaps without a working current meter, sensors found in
background, an old RX voltage with the link up, upward rule, CPU).
