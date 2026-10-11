-- harness_selftest.lua : self-test of the test harness (mock + fake ELRS),
-- run with:  lua tests/run.lua --selftest
-- Uses the dummy widget in tests/unit/harness_dummy/WIDGETS/HDUMMY.

return function(H)
  local Mock, Fake, scenario = H.Mock, H.Fake, H.scenario
  local C = Mock.C
  local sformat = string.format
  local SD = H.TESTS .. "/unit/harness_dummy"
  local DIR = "/WIDGETS/HDUMMY/"

  local function dummyWorld(t, o)
    o = o or {}
    local fake = nil
    if o.module ~= false then fake = Fake.new(o.moduleOpts or { version = "4.1.0", band = 4, channel = 2, power = 1 }) end
    local R = Mock.new({ mode = o.mode or "rc1", module = fake, crsf = (o.crsf ~= false), sdRoot = SD })
    R:defineSensors({ { name = "RQly", value = 100 }, { name = "RxBt", value = 16.4, prec = 1 }, { name = "FM", text = "ACRO" } })
    local wt, err = R:loadWidget(DIR)
    if not wt then t:fail("dummy did not load: " .. tostring(err)) return nil end
    return R, fake, wt
  end

  -------------------------------------------------------------------------
  scenario("self-meter", "instruction meter counts widget code only", function(t)
    local cal = Mock.calibration
    t:info(sformat("calibration api=%d cb=%d top=%d", cal.apiOverhead, cal.cbOverhead, cal.topOverhead))
    local function loop() local s = 0 for i = 1, 1000 do s = s + i end return s end
    local n = Mock.meteredCall(1e9, loop)
    t:metric("1000-iteration loop", n)
    t:check(n >= 2000 and n <= 2100, "a 1000-iteration numeric loop should count about 2000 instructions, got " .. n)
    local R = Mock.new({ sdRoot = SD })
    local gv = R.env.getValue
    local n1 = Mock.meteredCall(1e9, function() for i = 1, 100 do gv("RQly") end end)
    local noop = function() end
    local n2 = Mock.meteredCall(1e9, function() for i = 1, 100 do noop() end end)
    t:metric("100 getValue calls vs 100 empty Lua calls", sformat("%d vs %d", n1, n2))
    t:check(math.abs(n1 - n2) <= 110, "mock API calls should cost about one instruction each (got " .. n1 .. " vs " .. n2 .. ")")
    -- property functions are part of the refresh budget
    do
      local Rd = dummyWorld(t, {})
      if Rd then
        local inst = Rd:createInstance({ w = 480, h = 320, options = { vtxCtl = 0 } })
        Rd:cycle(3)
        local before = inst.instr.refresh[#inst.instr.refresh]
        Rd.current = inst
        Rd.env.lvgl.label({ x = 0, y = 300, text = function() local s = 0 for i = 1, 500 do s = s + i end return "p" end })
        Rd.current = nil
        Rd:cycle(3)
        local after = inst.instr.refresh[#inst.instr.refresh]
        t:metric("refresh before/after a 500-iteration text function", sformat("%d / %d", before, after))
        t:check(after - before >= 1000 and after - before <= 1100, "property function instructions should be counted in refresh")
      end
    end
    -- CPU limit
    local n3, ok, err = Mock.meteredCall(20000, function() local s = 0 for i = 1, 20000 do s = s + i end return s end)
    t:check(not ok and string.find(tostring(err and err.msg or err), "CPU limit", 1, true) ~= nil, "20000-iteration loop should hit the CPU limit")
    Mock.installStringTrap(false)
  end)

  -------------------------------------------------------------------------
  scenario("self-fake", "fake ELRS module protocol details", function(t)
    local m = Fake.new({ version = "4.1.0", band = 4, channel = 2, power = 1 })
    t:check(m.ids.folder == 9 and m.ids.band == 10 and m.ids.send == 14, sformat("4.1 default ids: folder %s band %s send %s",
      tostring(m.ids.folder), tostring(m.ids.band), tostring(m.ids.send)))
    -- ping
    m:handle(0, 0x28, { 0xEE, 0xEA })
    local f = m:poll(100)
    t:check(#f == 1 and f[1].cmd == 0x29, "ping should give one 0x29")
    if f[1] then
      local d = f[1].data
      t:check(d[1] == 0xEA and d[2] == 0xEE, "0x29 dest/origin")
      local i = 3
      local name = {}
      while d[i] ~= 0 do name[#name + 1] = string.char(d[i]) i = i + 1 end
      local o = i + 1
      t:check(table.concat(name) == "RM TX15", "device name")
      t:check(d[o] == 0x45 and d[o + 1] == 0x4C and d[o + 2] == 0x52 and d[o + 3] == 0x53, "serial ELRS")
      t:check(d[o + 9] == 4 and d[o + 10] == 1 and d[o + 11] == 0, "version 4.1.0 at o+9..o+11")
      t:check(d[o + 12] == m.fieldCount and d[o + 13] == 0 and #d == o + 13, "field count and param version")
    end
    -- chunking: Pitmode has 3 chunks at 56
    local pit = m.ids.pit
    local e = m:entryBytes(pit)
    t:check(#e == 144, "Pitmode entry should be 144 bytes, is " .. #e)
    local cat = {}
    local rem = {}
    for c = 0, 2 do
      m:handle(0, 0x2C, { 0xEE, 0xEA, pit, c })
      local fr = m:poll(1000)[1]
      rem[#rem + 1] = fr.data[4]
      for k = 5, #fr.data do cat[#cat + 1] = fr.data[k] end
    end
    t:check(rem[1] == 2 and rem[2] == 1 and rem[3] == 0, "chunksRemaining 2,1,0")
    local same = #cat == #e
    for k = 1, #e do if cat[k] ~= e[k] then same = false end end
    t:check(same, "concatenated chunks equal the entry")
    m:handle(0, 0x2C, { 0xEE, 0xEA, pit, 3 })
    m:poll(1000)
    t:check(#m.violations == 1, "read past the last chunk is a violation")
    -- write band, published after commit
    m:handle(2000, 0x2D, { 0xEE, 0xEA, m.ids.band, 5 })
    t:check(m.cfg.band == 5 and m.params[m.ids.band].value == 4, "write: RAM config at once, read value after commit")
    m:poll(2200)
    t:check(m.params[m.ids.band].value == 5, "value published after commit")
    t:check(m.params[m.ids.folder].dynName == "VTX Admin (R:2:1)", "folder name " .. tostring(m.params[m.ids.folder].dynName))
    -- send flow
    m:handle(3000, 0x2D, { 0xEE, 0xEA, m.ids.send, 1 })
    local s1 = m:poll(3100)[1]
    t:check(s1 and s1.cmd == 0x2B and s1.data[3] == m.ids.send, "click gives a 0x2B for Send VTx")
    if s1 then
      local d = s1.data
      -- entry: parent, type, "Send VTx\0", status, timeout, info
      local i = 7
      while d[i] ~= 0 do i = i + 1 end
      t:check(d[i + 1] == 2 and d[i + 2] == 200, "status 2 timeout 200")
      local info = {}
      i = i + 3
      while d[i] and d[i] ~= 0 do info[#info + 1] = string.char(d[i]) i = i + 1 end
      t:check(table.concat(info) == "Sending...", "info Sending...")
    end
    t:check(m.vtx.sends == 1 and m.vtx.sent[1].band == 5, "send recorded")
    m:handle(4000, 0x2D, { 0xEE, 0xEA, m.ids.send, 6 })
    t:check(#m:poll(4100) == 0, "lcsQuery within 2 s: no reply")
    m:handle(5100, 0x2D, { 0xEE, 0xEA, m.ids.send, 6 })
    t:check(#m:poll(5200) == 1, "lcsQuery after 2 s: reply")
    -- not enabled
    m:handle(6000, 0x2D, { 0xEE, 0xEA, m.ids.band, 0 })
    m:poll(6200)
    t:check(m.params[m.ids.channel].hidden and m.params[m.ids.pit].hidden, "4.1: channel/power/pit hidden when band 0")
    m:handle(6300, 0x2D, { 0xEE, 0xEA, m.ids.send, 1 })
    m:poll(6400)
    t:check(m.vtx.sends == 1 and m.params[m.ids.send].info == "Not enabled", "4.1: Not enabled when band 0")
    -- status
    m:setArmed(true)
    m:handle(7000, 0x2D, { 0xEE, 0xEA, 0, 0 })
    local st = m:poll(7100)[1]
    t:check(st and st.cmd == 0x2E and st.data[6] == 9, "0x2E flags connected+armed = 9")
    -- 3.3 layout
    local m3 = Fake.new({ version = "3.3.2", extraBefore = 2, band = 5, channel = 3 })
    t:check(m3.layout == "3.3" and m3.ids.band == 11, "3.3 with 2 extra fields: band id 11, is " .. tostring(m3.ids.band))
    t:check(m3.params[m3.ids.channel].type == 9 and m3.params[m3.ids.channel].value == 2, "3.3 channel TEXT_SELECTION index 2")
    m3:handle(0, 0x28, { 0xEE, 0xEC })
    t:check(#m3:poll(100) == 0 and #m3.violations == 1, "3.x ignores origin 0xEC")
    m3:handle(0, 0x2D, { 0xEE, 0xEA, m3.ids.channel, 5 })
    t:check(m3.cfg.channel == 6, "3.3 write index 5 = channel 6")
    -- airport
    local ma = Fake.new({ airport = true })
    t:check(ma.ids.folder == nil and ma:paramByName("Pitmode") == nil, "airport: no VTX folder")
    -- slow baud chunk size
    local m27 = Fake.new({ chunk = 27 })
    t:check(m27:chunkCount(m27.ids.pit) == 6, "chunk 27: Pitmode 6 chunks")
  end)

  -------------------------------------------------------------------------
  scenario("self-crsf", "CRSF transport: queues, output slot, nil push", function(t)
    local R = Mock.new({ sdRoot = SD, module = Fake.new({}) })
    local inst = { id = 99, crsfPush = 0, crsfPushOk = 0, crsfBusy = 0, crsfPop = 0, pushThisCycle = 0 }
    R.current = inst
    t:check(R.env.crossfireTelemetryPop() == nil, "empty queue pops nothing (and creates the queue)")
    t:check(R.env.crossfireTelemetryPush(0x28, { 0xEE, 0xEA }) == true, "first push true")
    t:check(R.env.crossfireTelemetryPush(0x28, { 0xEE, 0xEA }) == false, "second push in the same cycle false")
    t:check(R.env.crossfireTelemetryPush() == false, "no-arg probe false while busy")
    R.current = nil
    R:_crsfFlush()
    R.clock = R.clock + 50
    R:_crsfDeliver()
    R.current = inst
    local cmd, d = R.env.crossfireTelemetryPop()
    t:check(cmd == 0x29 and type(d) == "table" and d[2] == 0xEE, "reply popped from the instance queue")
    -- capacity: 60-byte frames, only 4 fit in 255 bytes
    local big = {}
    for i = 1, 60 do big[i] = i end
    for _ = 1, 10 do R:injectFrame(0x2B, big) end
    local n = 0
    while R.env.crossfireTelemetryPop() do n = n + 1 end
    t:check(n == 4, "queue keeps 4 frames of 62 bytes, kept " .. n)
    local okx = pcall(R.env.crossfireTelemetryPush, "x", {})
    t:check(not okx, "push with a non-number command raises (buffer free)")
    R.current = nil
    local R2 = Mock.new({ sdRoot = SD, crsf = false })
    R2.current = inst
    t:check(R2.env.crossfireTelemetryPush(0x28, { 0xEE, 0xEA }) == nil, "push returns nil without CRSF")
    t:check(R2.env.crossfireTelemetryPush() == nil, "probe returns nil without CRSF")
    t:check(R2.env.crossfireTelemetryPush("x", {}) == nil, "without CRSF the arguments are not checked (nil)")
    Mock.installStringTrap(false)
  end)

  -------------------------------------------------------------------------
  scenario("self-dummy", "dummy widget: dashboard, CRSF scan, page, popups, exit (rc1 and 2.12.x)", function(t)
    for _, mode in ipairs({ "rc1", "v212x" }) do
      local R, fake = dummyWorld(t, { mode = mode })
      if not R then return end
      local inst = R:createInstance({ w = 480, h = 320, appMode = true })
      local app = R:app(inst)
      t:check(app ~= nil, mode .. ": app accessor found V/E/S")
      local hit, ms = R:runUntil(4000, function() return app and app.V.ready end)
      t:check(hit, mode .. ": dummy should read the Band field within 4 s")
      t:metric(mode .. " dummy ready after", sformat("%.2f s", ms / 1000))
      t:check(R:findText(inst, "VTX F") ~= nil, mode .. ": label VTX F visible")
      t:check(R:findText(inst, "RM TX15 4.1.0") ~= nil, mode .. ": footer shows E.label")
      local p = R:dump(inst, "selftest_dummy_dash_" .. mode)
      t:check(Mock.fileExists(p), "svg dump written")
      local svg = Mock.readFile(p) or ""
      t:check(string.find(svg, "<svg", 1, true) ~= nil and string.find(svg, "data:image/png;base64", 1, true) ~= nil,
        "svg contains the embedded icon")
      H.layoutReport(t, R, inst, "warn", mode)
      -- page
      R:enterFullScreen(inst)
      R:cycle(2)
      local B = H.classify(R, inst)
      t:check(B.band.R ~= nil and B.apply ~= nil and B.back ~= nil, mode .. ": page buttons found: " .. B.all)
      H.press(t, R, inst, B.band.R, "R")
      H.press(t, R, inst, B.apply, "Apply")
      R:runUntil(3000, function() return fake.vtx.sends >= 1 end)
      t:check(fake.cfg.band == 5 and fake.vtx.sends == 1, mode .. ": write + send reached the module")
      -- menu popup
      local menuBtn = R:findButton(inst, "^Menu$")
      t:check(R:press(inst, menuBtn), "press Menu")
      local pop = R:openPopup(inst)
      t:check(pop and pop.kind == "menu" and pop.selected == 5, mode .. ": menu popup recorded with get() = 5")
      R:answerPopup(inst, 3)
      t:check(inst.ctx.sel == 3, mode .. ": menu set(3) applied")
      -- armed confirm
      app.E.armed = true
      H.press(t, R, inst, H.classify(R, inst).apply, "Apply armed")
      local c = R:openPopup(inst)
      t:check(c and c.kind == "confirm" and c.title == "Armed", mode .. ": confirm popup recorded")
      R:answerPopup(inst, true)
      t:check(inst.ctx.writeBand == 3, mode .. ": confirm callback ran")
      app.E.armed = false
      R:cycle(10)
      -- back
      H.press(t, R, inst, H.classify(R, inst).back, "Back")
      R:cycle(2)
      t:check(not inst.fullscreen, mode .. ": Back left full screen")
      t:check(#R:buttons(inst, false) == 0, mode .. ": page objects removed after exit")
      t:check(R:findText(inst, "DUMMY") ~= nil, mode .. ": dashboard rebuilt")
      t:check(inst.updates == (mode == "rc1" and 3 or 2), mode .. ": update() calls " .. inst.updates)
      -- RTN event
      R:enterFullScreen(inst)
      R:cycle(2)
      R:sendEvent(inst, C.EVT_VIRTUAL_EXIT)
      R:cycle(3)
      t:check(not inst.fullscreen, mode .. ": RTN left full screen")
      H.finish(t, R, fake, {})
    end
  end)

  -------------------------------------------------------------------------
  scenario("self-strict", "strict LVGL / runtime checks kill the instance with a clear message", function(t)
    local cases = {
      { 1, "Invalid property 'colour'" },
      { 2, "must be a function" },
      { 3, "returned nil" },
      { 4, "Invalid lvgl object" },
      { 6, "string method syntax" },
      { 7, "CPU limit" },
      { 8, "attempt to index a nil value" },
      { 10, "needs both w and h" },
      { 11, "rectangle with w=0" },
      { 12, "attempt to call a nil value" },
    }
    for _, cs in ipairs(cases) do
      local R = dummyWorld(t, {})
      if not R then return end
      local inst = R:createInstance({ w = 480, h = 320, appMode = true, options = { bad = cs[1] } })
      R:cycle(3)
      local msg = inst.err and tostring(inst.err.msg) or ""
      t:check(inst.dead and string.find(msg, cs[2], 1, true) ~= nil,
        sformat("bad=%d: expected death with %q, got %s", cs[1], cs[2], inst.dead and msg or "no error"))
      if inst.dead then t:info(sformat("bad=%d -> %s", cs[1], msg)) end
    end
    -- global write
    local R = dummyWorld(t, {})
    local inst = R:createInstance({ w = 480, h = 320, options = { bad = 5 } })
    R:cycle(2)
    t:check(#R.globalWrites == 1 and R.globalWrites[1].name == "leakedGlobal", "global write recorded")
    -- lvgl.clear inside a callback
    R = dummyWorld(t, {})
    inst = R:createInstance({ w = 480, h = 320, appMode = true, options = { bad = 9 } })
    R:cycle(2)
    R:enterFullScreen(inst)
    R:cycle(2)
    R:press(inst, H.classify(R, inst).apply.o)
    t:check(inst.dead and string.find(tostring(inst.err.msg), "inside a control callback", 1, true) ~= nil,
      "lvgl.clear() in a callback is reported: " .. tostring(inst.err and inst.err.msg))
    -- controls return nil outside full screen and buttons cannot be created there
    R = dummyWorld(t, {})
    inst = R:createInstance({ w = 480, h = 320 })
    R:cycle(1)
    R.current = inst
    local b = R.env.lvgl.button({ x = 0, y = 0, text = "x" })
    t:check(b == nil, "lvgl.button returns nil outside full screen")
    R.current = nil
    -- property returning wrong type
    R = dummyWorld(t, {})
    inst = R:createInstance({ w = 480, h = 320 })
    R.current = inst
    local ok, e = pcall(R.env.lvgl.label, { x = 0, y = 0, text = "a", color = function() return "red" end })
    t:check(not ok and string.find(tostring(e and e.msg or e), "number expected", 1, true) ~= nil,
      "color function returning a string is reported")
    ok, e = pcall(R.env.lvgl.rectangle, { x = 0, y = 0, w = 10, h = 10, size = function() return 5 end })
    t:check(not ok and string.find(tostring(e and e.msg or e), "two numbers", 1, true) ~= nil, "size returning one number is reported")
    ok, e = pcall(R.env.lvgl.image, { x = 0, y = 0, file = "x.png" })
    t:check(not ok and string.find(tostring(e and e.msg or e), "needs w and h", 1, true) ~= nil, "image without w/h is reported")
    R.current = nil
    -- rc1 build returns {}
    R = dummyWorld(t, { mode = "rc1" })
    inst = R:createInstance({ w = 480, h = 320 })
    R.current = inst
    local named = R.env.lvgl.build({ { type = "label", name = "n1", text = "a" } })
    t:check(type(named) == "table" and next(named) == nil, "rc1 lvgl.build returns an empty table")
    t:check(R.env.lvgl.CHOIDE == 17 and R.env.lvgl.CHOICE == nil, "rc1 has lvgl.CHOIDE only")
    R.current = nil
    R = dummyWorld(t, { mode = "v212x" })
    inst = R:createInstance({ w = 480, h = 320 })
    R.current = inst
    named = R.env.lvgl.build({ { type = "label", name = "n1", text = "a" } })
    t:check(type(named) == "table" and named.n1 ~= nil, "2.12.x lvgl.build returns named handles")
    R.current = nil
    -- no-context calls
    t:check(R.env.lvgl.label({ x = 0, y = 0, text = "z" }) == nil, "lvgl calls without a widget context return nil")
    -- cross-instance handle use
    R = dummyWorld(t, {})
    local i1 = R:createInstance({ w = 480, h = 320 })
    local i2 = R:createInstance({ w = 240, h = 137 })
    R.current = i1
    local h1 = R.env.lvgl.label({ x = 0, y = 0, text = "a" })
    R.current = i2
    ok, e = pcall(h1.set, h1, { text = "b" })
    t:check(not ok and string.find(tostring(e and e.msg or e), "belongs to widget instance", 1, true) ~= nil,
      "handle of instance 1 used by instance 2 is reported")
    R.current = nil
    Mock.installStringTrap(false)
  end)

  -------------------------------------------------------------------------
  scenario("self-nocrsf", "dummy without CRSF and with vtxCtl=0", function(t)
    local R = dummyWorld(t, { module = false, crsf = false })
    if not R then return end
    local inst = R:createInstance({ w = 480, h = 320 })
    R:cycle(40)
    local app = R:app(inst)
    t:check(app.V.state == "nocrsf", "dummy sees nocrsf")
    H.finish(t, R, nil, {})
    R = dummyWorld(t, {})
    inst = R:createInstance({ w = 480, h = 320, options = { vtxCtl = 0 } })
    R:cycle(40)
    t:check(R.crsf.pushCalls == 0 and R.crsf.popCalls == 0, "vtxCtl=0: no CRSF calls")
    local z = R:createInstance({ w = 240, h = 137 })
    R:cycle(5)
    local res = R:layoutCheck(z)
    t:info("layout findings at 240x137: " .. #res)
    H.finish(t, R, R.crsf.module, {})
  end)

  -------------------------------------------------------------------------
  scenario("self-firmware", "existing-model options, old telemetry values, clear(box) refs, wrapper count, overlaps", function(t)
    -- options a model does not store load as 0 (WidgetFactory::create with init = false)
    local R = dummyWorld(t, {})
    if not R then return end
    local inst = R:createInstance({ w = 480, h = 320, storedOptions = 2, options = { darkTheme = 1, transpLevel = 3 } })
    t:check(inst.options.darkTheme == 1 and inst.options.transpLevel == 3, "stored options keep their values")
    t:check(inst.options.vtxCtl == 0 and inst.options.showTrims == 0 and inst.options.rxCells == 0,
      "options after the stored ones load as 0, not as the declared default")
    local inst2 = R:createInstance({ w = 480, h = 320 })
    t:check(inst2.options.vtxCtl == 1 and inst2.options.showTrims == 1, "a new widget gets the declared defaults")
    -- old telemetry values: getValue 0 while not streaming, the old value after; getSourceValue tells it
    local gv, gsv = R.env.getValue, R.env.getSourceValue
    R:setStreaming(false)
    t:check(gv("RxBt") == 0, "not streaming: getValue reads 0")
    local v, cur = gsv("RxBt")
    t:check(math.abs(v - 16.4) < 1e-6 and cur == false, "not streaming: getSourceValue gives the old value, not current")
    R:setStreaming(true)
    t:check(math.abs(gv("RxBt") - 16.4) < 1e-6, "streaming again: getValue gives the old value")
    v, cur = gsv("RxBt")
    t:check(cur == false, "streaming again: still old until a new value arrives")
    R:setSensor("RxBt", 25.2)
    v, cur = gsv("RxBt")
    t:check(math.abs(v - 25.2) < 1e-6 and cur == true, "new value: current")
    t:check(gsv("NoSuchSensor") == nil, "unknown source: nothing")
    -- lvgl.clear(box): children go at once, their refs at the next poll; filling the box
    -- before that poll is reported; every cleared object counts as a leaked wrapper
    R = dummyWorld(t, {})
    inst = R:createInstance({ w = 480, h = 320, appMode = true })
    R:cycle(1)
    R.current = inst
    local L = R.env.lvgl
    local box = L.box({ x = 0, y = 0, w = 100, h = 100 })
    L.label(box, { x = 0, y = 0, text = "a" })
    L.label(box, { x = 0, y = 20, text = "b" })
    local made, leaked = inst.created, inst.leaked
    L.clear(box)
    local ok, e = pcall(L.label, box, { x = 0, y = 0, text = "c" })
    t:check(not ok and string.find(tostring(e and e.msg or e), "cleared in this cycle", 1, true) ~= nil,
      "a box filled before the poll after its clear is reported")
    R.current = nil
    R:_pollInstance(inst)
    t:check(inst.leaked == leaked + 2, "2 cleared labels count as 2 leaked wrappers, got " .. (inst.leaked - leaked))
    R.current = inst
    ok = pcall(L.label, box, { x = 0, y = 0, text = "d" })
    t:check(ok and inst.created == made + 1, "the box can be filled after the poll")
    local nfull = inst.fullClearsAfterBuild
    L.clear()
    t:check(inst.fullClearsAfterBuild == nfull + 1, "a no-argument clear after objects exist is counted")
    R.current = nil
    -- buttons over labels and over buttons are layout problems
    R:enterFullScreen(inst)
    R.current = inst
    L.button({ x = 10, y = 10, w = 100, h = 40, text = "One" })
    L.button({ x = 60, y = 20, w = 100, h = 40, text = "Two" })
    L.label({ x = 20, y = 15, text = "under a button" })
    R.current = nil
    local over, under = false, false
    for _, r in ipairs(R:layoutCheck(inst)) do
      if string.find(r.msg, "buttons \"One\" and \"Two\" overlap", 1, true) then over = r.severe end
      if string.find(r.msg, "overlaps button", 1, true) then under = true end
    end
    t:check(over, "overlapping buttons are a severe layout problem")
    t:check(under, "a label under a button is reported")
    -- screen size of the radio
    local R2 = Mock.new({ sdRoot = SD, lcdW = 480, lcdH = 272 })
    t:check(R2.env.LCD_W == 480 and R2.env.LCD_H == 272, "LCD_W/LCD_H follow the radio screen size")
  end)

  -------------------------------------------------------------------------
  scenario("self-cover", "an instance covered by a full-screen instance: rc1 no calls, 2.12.x background", function(t)
    for _, mode in ipairs({ "rc1", "v212x" }) do
      local R = dummyWorld(t, { mode = mode })
      if not R then return end
      local a = R:createInstance({ w = 480, h = 320, appMode = true })
      local b = R:createInstance({ w = 240, h = 137 })
      R:cycle(5)
      local r0, g0 = b.refreshes, b.backgrounds
      R:enterFullScreen(a)
      R:cycle(10)
      t:check(b.refreshes == r0, mode .. ": covered instance got refresh() calls: " .. (b.refreshes - r0))
      local nbg = b.backgrounds - g0
      if mode == "rc1" then
        t:check(nbg == 0, "rc1: covered instance should get no background() call, got " .. nbg)
      else
        t:check(nbg == 10, "2.12.x: covered instance should get background() every cycle, got " .. nbg)
      end
      t:check(a.refreshes >= 10, mode .. ": the full-screen instance keeps its refresh() calls")
      R:exitFullScreen(a)
      R:cycle(3)
      t:check(b.refreshes == r0 + 3, mode .. ": covered instance refreshes again after the exit")
      H.finish(t, R, R.crsf.module, {})
    end
  end)
end
