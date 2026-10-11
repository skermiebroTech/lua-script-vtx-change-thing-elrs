# FPVDASH test harness

Desktop tests for the LVGL rewrite of the "Telemetry Dashboard" widget
(`radio sd card/WIDGETS/FPVDASH`). The tests run the real widget files from the SD
card copy inside a strict mock of the EdgeTX 2.12 Lua environment, with a simulated
ExpressLRS TX module on the CRSF side. Nothing in this folder goes on the SD card.

The binding contract is `docs/DESIGN.md`. The mock follows the research notes
(`lvgl_api.md`, `elrs_crsf_vtx.md`, `fpvdash_spec.md`, `testing.md`).

## Requirements

- Desktop Lua 5.5 (`lua`, `luac`; Homebrew `/opt/homebrew/bin/lua`).
- EdgeTX's own compiler `tools/edgetx-luac` for the syntax check.
- No network access, no other tools.

## How to run

All paths contain spaces: always quote them.

```sh
cd "<repository root>"

sh tests/check.sh                      # everything: syntax + self-test + scenarios (rc1 and 2.12.x) + unit tests
lua tests/run.lua                      # all scenarios, rc1 firmware behaviour (the radio today)
lua tests/run.lua --mode v212x         # all scenarios, 2.12.0 .. 2.12.4 behaviour
lua tests/run.lua --only a,b-rc1       # some scenarios
lua tests/run.lua --list               # list the scenario ids
lua tests/run.lua --verbose            # all warnings and info lines
lua tests/run.lua --selftest           # test the harness itself with a dummy widget
```

Other options: `--sd <SD card copy>` (default `radio sd card`), `--widget /WIDGETS/<DIR>/`
(default `/WIDGETS/FPVDASH/`).

Exit code 0 means that all selected scenarios passed. `check.sh` gives exit code 0 only
when the syntax checks, the self-test, both scenario runs and every unit test
(`tests/unit/*_test.lua`, each in its own process) pass.

`lua tests/unit/integ_soak_test.lua [cycles]` is a long random soak of the real widget
(default 6000 cycles = 5 simulated minutes per run, 6 runs: rc1 and 2.12.x, ELRS 4.1.0,
3.4.2 and 3.3.2). It mixes link loss, sensor changes, stick and trim moves, full screen
enter and exit, page button presses (VTX and Throttle tabs, so the throttle input line is
swapped many times), number edits, popups, armed and RX flags, external VTX changes,
module reboots, CRSF off/on, paused widget, option and zone changes. Then it checks that
the instance is alive, the contract holds (also `wgt.T`), the CPU limits hold, no protocol
violation happened, the widget tables did not grow, the mixer emulation saw no glitch, every
model write came from `refresh()`, no visible clickable object stayed on the dashboard, and
a normal Apply & Send still works (it presses the VTX tab first: the tab choice is kept
between visits).

## Files

| File | Purpose |
|---|---|
| `edgetx_mock.lua` | Strict mock of the EdgeTX 2.12 Lua environment and the LVGL API, the model input/mix API with the input stage of the mixer (throttle cap), the widget runner, the instruction meter, the layout dumps and the overlap checker. |
| `fake_elrs.lua` | Simulated ELRS TX module: CRSF device info, parameter tree, chunked reads, writes, Send VTx, ELRS status. |
| `run.lua` | The scenarios (PASS/FAIL with reasons) and the command line. |
| `check.sh` | `edgetx-luac -p` and `luac -p` on every `.lua` in the widget and in `tests/`, then the self-test, both scenario runs and the unit tests, then a summary. |
| `unit/harness_selftest.lua`, `unit/harness_dummy/` | Self-test of the harness with a small dummy widget (`WIDGETS/HDUMMY`). |
| `unit/thrcap_test.lua`, `unit/thrcap_mock.lua` | `lib/thrcap.lua` alone against a firmware-exact input store and mixer (field-store orders, failure injection at each step, control tests with the unsafe orders, the mix check of the throttle input: raw Thr, inputs inverted by the source or by a negative weight, "Thr input not used", "---" lines that hide the mix, also for the input of two that the CH3 mix picks; a pending request dropped after a line change or after 5 s). |
| `unit/thrpage_test.lua` | `ui/thrpage.lua` with a strict page mock (presets, steps, staged number input, custom and refused lines, 480x272, CPU). |
| `unit/thrpage_harness_test.lua` | The real widget in this harness on the mock's model emulation (user model "75"): tabs, layout, a preset, -5 taps and Set reaching the model line (other fields kept), the dashboard line, stick mode 1, VTX control off, a refused line (model not written), 480x272. It fails on the mock records too (mixer glitch, write outside `refresh()`, float argument, two swaps in one call, visible clickable object outside full screen). Writes `out/thr_*.svg/.txt/.json`. |
| `unit/theme_contrast_test.lua` | Contrast of the light-theme colours (track, tick, trim value box, warn, cap, extMark) at every transparency level. |
| `unit/glue_app_test.lua`, `unit/glue_mock.lua`, `unit/glue_stubs/` | `main.lua` options and `app.lua` lifecycle with stub modules: tick order, tabs, root box reuse (`slot.fs`), a cleared button box hidden at once (`lvgl.hide`), errors, CPU. A z-order test records the object tree of the real `app.lua` and page files and does an LVGL-order hit test (children from the last to the first, a clickable parent when no child is hit) at the centre of every visible control in full screen: each tap must reach its own control (480x320 and 480x272, rc1 and 2.12.x, VTX control on and off, both tabs). |
| `unit/glue_telem_test.lua` | `lib/telem.lua` alone: sensors, the RX cell count (rest window, plug-in, pack changes with and without Capa, the same pack through gaps, an FC start without a link loss, an FC start while a tool is open, a power cut, the FC on USB (a pack unplugged with a filtered voltage fall at 20 Hz .. 0.5 Hz battery frames, a slow tail, a bench start that sends 0.1 V first, ESC passthrough), a used pack of unknown history, sensors found in background, an old RX voltage with the link up, a gap without a working current meter, the upward rule, rxCells), timers, TX battery, CPU. |
| `unit/*` (other prefixes) | Unit tests per area (dash, glue, page, protocol) and the integration soak (`integ_soak_test.lua`). |
| `out/` | Generated. Reports and layout dumps. Safe to delete. |

## Outputs (`tests/out/`)

- `report.txt` (rc1 run), `v212x/report.txt` (2.12.x run), `selftest_report.txt`.
- `<name>.svg`: the LVGL object tree with absolute geometry, drawn at 2x. Open it in a
  browser. Rectangles use their fill and opacity, labels are drawn as text with an
  estimated width, images use the real PNG files from the SD card, buttons show their text.
  Hover over an object to see its type, id and the source line that created it.
- `<name>.txt`: the same tree as indented text (type, id, absolute box, text, font, color,
  which properties are functions, hidden/disabled flags, creating source line).
- `<name>.json`: the same tree as JSON.
- `<name>_crsf.log`: every CRSF frame between the widget and the fake module, with time
  stamps and notes (`tx` = widget to module, `rx` = module to widget, `xx` = dropped,
  `!!` = protocol violation).

## Scenarios

| Id | What it checks |
|---|---|
| `static` | Widget table (name "Telemetry Dashboard", `useLvgl`, create/update/refresh), the six options and their order (every option after index 1 defaults to 0), `main.lua` < 3 KB, the files from DESIGN section 3, no `loadScript` at radio start, source lint (string method syntax, `lvgl.CHOICE`, `floating`, `borderPad`, `XLSIZE`, raw RGB565 literals, `os`/`debug`/`require`, ...). |
| `a` | App mode 480x320, ELRS 4.1, telemetry connected, 300 cycles: no errors, refresh max < 14000 and average < 8000 VM instructions, VTX cell shows `F2` within about 3 s, sensor values in `wgt.S`, idle traffic <= 1 frame per 15 s, footer and timers, layout check (severe overlaps fail). The default world flies at 12.3 A: no cell count (the dashboard shows '16.40V' with the neutral battery icon). The widget started with this pack in use (Capa 850 mAh): with Curr 0.3 A it still gets no count ('16.40V'); after a pack change (link lost 6 s, Capa 0) the count latches 4S after the 3 s rest window ('4.10V (4S)', full icon). |
| `b-rc1`, `b-212x` | Full-screen VTX page: press band R, channel 4, power 2, Apply & Send. The fake module must end with band R, channel 4, power 2 and exactly 1 send. The page layout has no severe overlaps. Then Back, RTN and long RTN must leave full screen, delete the page buttons and show the dashboard (rc1: update on exit; 2.12.x: no update on exit). Five more App-mode visits: the dashboard objects stay, only the page buttons are made again (objects made = wrappers leaked per visit, reported), the live object count does not grow. |
| `c` | ELRS 3.3 layout (Channel is a TEXT_SELECTION, index 0..7) with ids shifted by 2 extra fields; apply channel 6. |
| `d` | No CRSF module (push returns nil): no crash, `V.state == "nocrsf"`, no band/channel in the cell, few push calls, page shows only Back. |
| `e` | ELRS module without VTX Administrator (airport build): `V.state == "novtx"`, nearly no traffic afterwards. |
| `f` | Telemetry disconnected: `S.connected == false`, no `nil`/`nan` text, VTX values still load from the TX module. |
| `g` | Zones 480x272, 480x275, 430x225, 240x137: no errors, instructions < 14000, layout warnings only. |
| `h` | Dark and light theme with transpLevel 1..4: theme fields and >= 4 wash rectangles with the right opacity. |
| `i` | vtxOff = 1: no `crossfireTelemetryPush`/`Pop` call at all, footer "ELRS", no VTX cell; full screen shows only the Throttle page (Back, the 7 presets, -5, +5, Set and the number input, no tabs); later App-mode visits make and leak only the page controls (14 objects), the live object count stays the same. |
| `j` | Sticks and trims at the extremes, extended trims (raw +-4096), the extTrims option (2 = extended, 1 = normal, back to auto), stick modes 2 and 1, hideTrims = 1. |
| `k` | Armed flag from ELRS status 0x2E: Apply shows a confirm popup; cancel writes nothing; confirm applies. |
| `l` | Two instances: no shared state, `app.lua` loaded once, instance B is paused while A is full screen, B picks up the change. |
| `m-bg`, `m-frozen` | 200 cycles in background (or with no calls, as while the ELRS tool runs) with foreign frames in the queue and an external VTX change, then resume: no traffic while paused, values stay in range, the change shows after resume. |
| `n` | Lossy link: 20 % of the replies lost, 60 ms latency, 27-byte chunks, output buffer busy for 300 ms: the values still load and Apply & Send still works. |
| `o` | Existing model: only options 0 and 1 are stored, every other option loads as 0 (as EdgeTX does). The VTX cell, the trim markers, the CRSF traffic, the dashboard cap label, the full-screen VTX page and the Throttle tab (a preset writes the model) must be there. |
| `p` | 480x272 radio (TX16S class) in App mode: dashboard, then the VTX page with no overlapping or clipped labels/buttons and all buttons on the screen (also with power Keep, where the Pit button is hidden, and with a staged selection), then Apply & Send. |
| `q` | RX cell count with real telemetry behaviour: after a link loss the old RxBt comes back (marked old) and must not set a count (the dashboard shows the total voltage); a 6S in flight (Curr 18 A, set with RxBt like a CRSF battery frame) that comes back after a 6 s link loss gets no count under load ('21.00V' with the neutral battery icon) and 6S once landed at rest; LiHV full packs at rest (17.5 V = 4S, 26.2 V = 6S, 8.7 V = 2S); a count that is too low goes up; an FC start without a link loss (Capa 0, the same 21.6 V) keeps 6S ('3.60V (6S)'); 0.4 V without a count shows the dead battery icon. |
| `cap-page` | Throttle tab on each of the user's 4 models ("75" 75/-25, "sim" 50/-50, "100% pro" and "100% pro gemini" 100/0): cap, header line and note shown; preset 60 %, -5, +5, number input (no write) + Set 37, the number input stops at 20 and 100, -5 at 20 and +5 at 100 write nothing. After each step: input 3 is one line W / W-100, every other field and the input name are kept, the mixer output is -100 % at stick low and the cap at full stick, each change is exactly `insertInput(2, 1)` + `deleteInput(2, 0)`. At the end the model is the same as at the start. |
| `cap-taps` | Six -5 taps 50 ms apart give one swap 400 ms after the last tap; four presets within 400 ms give one swap to the last value; taps 600 ms apart give one swap each; a pending value waits while only `background()` runs and is written in the first refresh cycles after the widget shows again. |
| `cap-armed` | ELRS reports armed: a VTX Apply & Send (with its confirm) runs, then 5 cap changes on the Throttle tab with the throttle stick moving every cycle: no confirm popup, each change is written, the VTX send still completes. Control: the harness finds a glitch with the unsafe orders (delete then insert; insert before the live line). |
| `cap-refuse` | 18 layouts that cannot be changed safely (CH3 takes the raw Thr stick, no mix uses input 3, CH3 takes only the raw stick while input 3 feeds CH6, CH3 takes input 3 with weight -100, switch, flight mode mask, side, 2 lines, line 0 not thr, GVAR weight or offset, inverted source, function curve, weight 0, thr in two inputs with an unclear CH3 mix, thr in two inputs with the raw stick on CH3, no thr input, no input API): the right `T.msg` on the page, no cap controls, no cap line, and a forced request writes nothing. Also: two thr inputs where the CH3 mix decides (input 3 or input 5), expo 30 kept, custom 80/-10 (shown, -5/+5 inactive, a preset replaces it), all 64 lines used, failure injection (insert error, delete does nothing, delete error, read-back mismatch: the model stays as before), a model change before the debounce (nothing written). |
| `cap-line` | Dashboard cap line at 75 % in stick modes 1-4: inside the throttle box (left in modes 2/4, right in 1/3), with the stick at the cap level the dot is on the line, the "75%" label is next to it; 50 % (model "sim"); 100 %: no line, no label; a change made on the page moves the line; light theme and no trims. |
| `cap-vtxoff` | VTX control off: full screen shows only the Throttle page with the title "Throttle cap", a preset writes the model, Back leaves, the line follows, no CRSF calls. |
| `fs-loop` | 30 App-mode full-screen visits with tab changes, cap taps, three exit ways (Back, RTN, long RTN) and option changes on the dashboard and in full screen: after each exit no button and no visible clickable object, the dashboard is shown, the live objects stay bounded. Control: a box made in full screen and left visible is reported. |
| `fs-touch` | Full-screen touch: an LVGL-order hit test (children from the last to the first, a clickable parent takes a point that no child takes) at the centre of each visible control must reach that control; taps on Throttle, VTX and Back through the hit test change the tab and leave full screen. Two visits each with VTX control on and off, 480x272, no throttle input (only Back) and no ELRS module. Control: a button under a later full-size box is reported. |
| `cap-cpu` | Throttle tab at 480x320 and 480x272: first the layout (no overlapping or clipped object, every control on the screen, also with "Pending: 60%" shown; dumps `out/cap_cpu_320_page.*` and `out/cap_cpu_272_page.*`), then 400 cycles with a tap every 750 ms (27 swaps), stick moves, telemetry changes and VTX traffic: refresh max < 14000, average < 8000, swap cycles < 14000, callbacks < 2000. |

Every scenario also checks the field contract of DESIGN section 5 (`wgt.V`, `wgt.E`, `wgt.S`,
`wgt.I`, `wgt.theme`, `wgt.T`) every 20 cycles, global variable writes, `loadScript` calls outside
`create` (DESIGN section 8), background instruction counts, ELRS protocol violations reported by
the fake module, and that the widget never calls the no-argument `lvgl.clear()` after its first
build (it would delete the firmware's focus border). It reports the LVGL objects made and the
wrappers leaked by clears per instance. It also fails on:

- a visible clickable object while the instance is shown and not full screen (the mock looks at
  the end of every cycle; such an object takes the long press that opens full screen);
- a mixer glitch, a model write outside `refresh()`, a float argument to the model API, or more
  than one `insertInput` in one firmware call (see "Model inputs" below).

Identical failure lines are listed once in the report.

The scenarios read the widget state through `wgt.V`, `wgt.E`, `wgt.S`, `wgt.I`. If `create`
returns a wrapper, `Mock.appOf` looks for these fields in `wgt.app`, `wgt.wgt`, `wgt.inst`,
`wgt.state`, `wgt.ctx` or any sub-table that has both `V` and `E`.

## What the mock enforces

Firmware behaviour (rc1 7b9c7c0 by default, `--mode v212x` for 2.12.0 .. 2.12.4):

- Options: the declared defaults for a new widget; with `createInstance{ storedOptions = n }` an
  existing model that stores only options 0..n-1, so every other option loads as 0
  (`WidgetFactory::create(init = false)` does not parse the Lua defaults).
- Screen size: 480x320 by default, `Mock.new{ lcdW = 480, lcdH = 272 }` for a TX16S class radio.
- Lifecycle: `create(zone, options, "/WIDGETS/FPVDASH/")`, then `update` at once (LVGL
  widgets), then `refresh(wgt, event, touchState)` every 50 ms cycle while visible or full
  screen, `background(wgt)` otherwise. rc1 calls `background` before `refresh` when the
  previous cycle had no refresh. Full screen enter: zone becomes 480x320 and `update` is
  called (rc1 with a property poll, 2.12.x without). Full screen exit: rc1 calls `update`
  again; 2.12.x only when the zone size changed (not in App mode). `lvgl.exitFullScreen()`
  takes effect at the start of the next cycle. While one instance is full screen, the other
  instances get no call (rc1) or only `background` (2.12.x).
- Property polling after create (once per object), after `update` (rc1) and after every
  `refresh`: `visible` first (a hidden object skips its own functions and its whole subtree),
  then `color`, `opacity`, `size`, `pos`, then the children, then `active`, `filled`,
  `text`, `font`, `align`, `radius`, angles, `pts`, `file`. Control `get` functions of
  choice/toggle/slider are polled every cycle.
- Instruction meter: a count hook (`debug.sethook(fn, "", 1)`) counts the Lua VM
  instructions of widget code for each firmware call (`refresh` plus the property poll share
  one budget). Mock code is not counted; a mock API call costs one instruction, like a C
  function on the radio. More than 20000 instructions in one call raise "CPU limit" and
  disable the instance.
- Strict LVGL checks (each one disables the instance with a clear message and the source
  line): unknown property keys per object type (`lvgl_api.md` section 5.5, the 2.12.x
  "Invalid property" rule), `floating`/`borderPad`/`edited`, `visible`/`pos`/`size`/`active`
  that are not functions, property functions that fail, return `nil` or the wrong type,
  negative or zero sizes for rectangles/images/boxes, hline/vline without `w` and `h`,
  triangles larger than 127 px, use of a handle after `lvgl.clear()`, use of an object of
  another instance, `lvgl.clear()` inside a control callback, a new child in a box that was
  cleared with `lvgl.clear(box)` before the next poll (the firmware drops the refs of its children
  at that poll). Every object deleted by a clear counts as a leaked C++ wrapper (`inst.leaked`);
  no-argument clears made while objects exist are counted (`inst.fullClearsAfterBuild`). Controls (`button`, `toggle`,
  `choice`, `page`, ...) return `nil` outside full screen. rc1 `lvgl.build` returns `{}`
  and has `lvgl.CHOIDE`; 2.12.x has `lvgl.CHOICE`.
- Lua environment: no `os`, `debug`, `utf8`, `coroutine`, `require`, global `unpack`,
  `loadstring`; `bit32` exists; string method syntax (`s:sub()`) raises an error (no string
  metatable on the radio); `string.format("%d", 3.5)` floors with a warning (`LUA_FLOORN2I`);
  global variable writes are recorded and fail the scenario.
- EdgeTX API: `getValue`/`getFieldInfo` from a table of sources and sensors (unknown name:
  `getValue` 0, `getFieldInfo` nil; telemetry reads 0 while not streaming, and the old value
  again after the link is back), `getSourceValue` (value, not old, fresh: `setStreaming(false)`
  marks every sensor old, `setSensor` gives a new value), `getTime`
  (10 ms ticks of a simulated clock), `getDateTime`, `getVersion` ("2.12.0", "tx15", ...),
  `getStickMode`, `getFlightMode`, `getGeneralSettings`, `model.getInfo/getTimer/getModule`,
  the model input and mix API and `defaultChannel` (see "Model inputs" below),
  `loadScript` (maps `/WIDGETS/...` to the SD card copy), `lcd.sizeText` (per-character
  widths from `fpvdash_spec.md` section 3.4), `lcd.RGB`, `lcd.exitFullScreen`; `lcd.draw*`
  are no-ops.
- Clickable objects: boxes, rectangles and circles made while the widget is full screen keep
  `LV_OBJ_FLAG_CLICKABLE`; made outside full screen they do not (rc1 `lua_lvgl_widget.cpp:1501-1502`,
  2.12.0 `:1616-1617`). Arcs, images, labels and lines are never clickable, controls always are.
  `R:clickables(inst)` lists the visible ones. A poll that handles a pending `lvgl.clear(box)`
  returns before the box's `visible` function (`LvglWidgetObjectBase::callRefs`), so a cleared
  box keeps its old visibility until the next poll; `lvgl.hide(obj)` hides at once.
- CRSF transport: one input queue per instance (255 usable bytes, created on the first pop
  or push, every frame copied to every queue), one shared output slot. `crossfireTelemetryPush`
  returns `nil` without a CRSF module, `false` while the slot is busy, `true` when the frame
  was taken. The frame reaches the module at the end of that cycle (4 ms later), and the
  module replies after its latency (default 10 ms), so a reply can be popped in the next cycle.

## Model inputs (throttle cap)

The mock has the model input and mix API of EdgeTX 2.12 (`model.getInputsCount`, `getInput`,
`insertInput`, `deleteInput`, `getMixesCount`, `getMix`, `getGlobalVariable`, `getInfo` with the
model file name, the global `defaultChannel`) on a per-radio copy of the firmware data
(`ExpoData` bit fields, SourceNumVal, `insertExpo` default line, `deleteExpo`, 64 lines, the
"srcRaw 0 ends the list" rule). It is the same emulation as `unit/thrcap_mock.lua`, with the
mock's source ids: sticks `rud` 1, `ele` 2, `thr` 3, `ail` 4, `input1..32` = 10..41,
`gvar1..9` = 50..58, switches `sa..sf` = 100..105 (`Mock.SRC`).

- Default model: the user's model "75" (`Mock.userModel(1)`). `Mock.USER_MODELS` lists all four
  (`model1.yml` "75" 75/-25, `model2.yml` "sim" 50/-50, `model3.yml` "100% pro" and `model4.yml`
  "100% pro gemini" 100/0): inputs Rud, Ele, Thr, Ail on chn 0..3 with one plain line each,
  mixes CH1 = I4, CH2 = I2, CH3 = I3, CH4 = I1 and the switch channels.
  `Mock.userModel(i, { thr = {lines}, extra = {lines}, mixes = {...}, gvars = {...} })` changes
  it; a spec field `inj` injects failures (`insertNoop`, `insertError` = fields stored before an
  error, `insertCorrupt` = field name, `deleteNoop` / `deleteError` = counts).
  `Mock.new{ model = spec }` or `world(t, { model = spec })` selects it, `model = false` removes
  the API. `R:loadModel(spec)` changes the model of a running radio.
- Mixer: after `insertExpo` (the new line still has its default content), after every field
  store of the `insertInput` copy loop (in a shuffled key order, like `lua_next`) and after
  `deleteExpo`, the mock runs the input stage of the mixer (`applyExpos`: the first active line
  wins, an input without an active line keeps its last value; expo, weight, offset in the
  firmware integer math) for throttle -100, -50, 0, +50, +100 %. At the end of each 50 ms cycle
  every one of these mixer cycles must show, for each input, the output from before the cycle or
  the one after it; anything else is a glitch (`R.mdl.glitches`).
- Write rules (recorded in `R.mdl`, `finish()` fails on them): `badWrites` (a write outside
  `refresh()`), `floatArgs` (a float argument: the radio floors it, `LUA_FLOORN2I`), `multi` (two
  `insertInput` calls in one firmware call). `R.mdl.writes` lists every write call with its time,
  cycle and phase.
- Inspection: `R:inputLines(chn)` (lines as `getInput` tables), `R:modelSnapshot()` (text of the
  whole expo table, for "nothing changed"), `R:modelOut(chn, thrRaw)` (input output at a stick
  value).

## The fake ELRS module (`fake_elrs.lua`)

`Fake.new{...}` options: `version` ("4.1.0", "4.0.1", "3.4.2", "3.3.2"; picks the layout),
`layout`, `name`, `isElrs`, `airport` (no VTX folder), `extraBefore` (number of extra fields
before the VTX folder, to shift the ids), `pitAux`, `chunk` (entry bytes per 0x2B chunk,
default 56), `latencyMs`, `dropRate`, `commitMs`, `connected`, `armed`, `notReady`,
`silent`, `band`, `channel`, `power`, `pit`, `seed`.

It answers 0x28 ping (0x29 device info), 0x2C read (chunked 0x2B), 0x2D write (no reply for
value fields; Send VTx click gives status 2 "Sending..." or "Not enabled" on 4.1 with band 0;
lcsQuery answers only more than 2 s after the click; a 0x2C read of a command resets it),
0x2D field 0 (0x2E status with the connected and armed flags). It applies the 4.1 visibility
rules and the dynamic folder name, and it records protocol violations (wrong origin, reads
past the last chunk, out-of-range writes, reading Send VTx while it runs, broadcast pings).
Test code reads the result from `fake.cfg` (band/channel/power/pit), `fake.vtx.sends`,
`fake.vtx.sent`, `fake.stats` and `fake:logText()`.

## Writing a new scenario

```lua
scenario("x", "my scenario", function(t)
  local R, fake = world(t, { moduleOpts = { version = "4.1.0", band = 5, channel = 4 } })
  if not R then return end
  local inst = stdCreate(R)                      -- App mode 480x320
  local app = appOf(R, inst)                     -- wgt with V/E/S/I
  runChecked(t, R, inst, 100)                    -- 100 cycles of 50 ms, contract checks
  R:enterFullScreen(inst); R:cycle(3)
  local B = classify(R, inst)                    -- page buttons by row: B.band.R, B.channel[4], B.power["2"], B.apply, B.back
  press(t, R, inst, B.band.R, "band R")
  local p = R:openPopup(inst)                    -- newest confirm/message/menu popup
  if p then R:answerPopup(inst, true) end        -- confirm: true/false; menu: index or label
  t:check(fake.cfg.band == 5, "band should be R")
  finish(t, R, fake, { instrLimits = { 14000, 8000 }, dumpName = "x" })
end)
```

Useful mock calls: `R:cycle(n, stopFn)`, `R:runUntil(ms, stopFn)`, `R:setSensor`,
`R:setSource`, `R:setStreaming`, `R:setTimer`, `R:setVisible`, `R:freeze`, `R:setZone`,
`R:setOptions`, `R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)`, `R:exitFullScreen` (long RTN),
`R:findText`, `R:findButton`, `R:press`, `R:editNumber(inst, obj, value)` (a number input edit:
value kept in min..max, `set`, then `get`), `R:clickables(inst)`, `R:layoutCheck`, `R:dump`,
`R:holdOutputBuffer`, `R:instrStats(inst, "refresh")`, `R:loadModel`, `R:inputLines`,
`R:modelSnapshot`, `R:modelOut`.

Throttle cap helpers in `run.lua`: `openThrottle(t, R, inst, tag)` (full screen, Throttle tab),
`tap(t, R, inst, "60%", tag)`, `thrLine(R)` (line 0 of input 3), `capLineObj(R, inst)` and
`capLabel(R, inst, 75)` (the dashboard line and its label), `gimbals(R, inst)`,
`writesFrom(R, n0)`.

## Limits (check these on the radio or in Companion)

- Text widths are estimates (+-2 px at SMLSIZE); real glyph metrics and line wrapping may
  differ. Overlap results are warnings unless an overlap is large. Labels under buttons
  (more than 20 % of the text) and buttons over buttons are severe.
- Instruction counts are desktop Lua 5.5 counts. EdgeTX runs Lua 5.3.6 with a count hook
  every 200 instructions; the numbers are close but not identical. Memory use, LVGL
  rendering time and the 8-image cache are not measured.
- 32-bit integers and floats, and the rc1 bug `0.5 == 0` is true, are not simulated: desktop
  Lua uses 64-bit numbers. The `static` lint does not look for mixed int/float `==`.
- Real CRSF timing (baud rate, the mixer slot, the 2 s output buffer expiry), the real ELRS
  module, the RX and the VTX are simulated from source code only. The final check of Send VTx
  must be on the radio with a powered quad.
- Touch, focus and rotary encoder navigation are not simulated; buttons are pressed by
  calling their `press` callbacks. The clickable check finds objects that would take a touch;
  it does not simulate the touch itself.
- The mixer emulation covers the input stage only (no mixes, limits, trims, curves other than
  expo and DIFF, `throttleReversed`), with fixed values for the other sticks. The mixer period,
  a mixer cycle skipped while `insertExpo`/`deleteExpo` stop it, and the ELRS reaction to it are
  not simulated (`throttle_cap.md` section 8).
