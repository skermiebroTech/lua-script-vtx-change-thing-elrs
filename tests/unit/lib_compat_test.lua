-- lib_compat_test.lua: the shared lib must run on black-and-white EdgeTX radios (RadioMaster
-- Boxer) and on EdgeTX 2.10 (Lua 5.2), and the Boxer SD tree must hold an exact copy of it.
-- Run: cd "<root>" && lua tests/unit/lib_compat_test.lua   (exit code 0 = all pass)
--
-- Files: radio sd card/WIDGETS/FPVDASH/lib/*.lua (colour widget, the source) and
--        boxer sd card/SCRIPTS/FPVDASH/lib/*.lua (Boxer copy, made by tools/sync-boxer.sh).
--
-- Rules, checked on the tokens of each file (comments and string contents are skipped):
--   table    no use of the table library (B&W radios have no table library)
--   global   no global unpack, loadstring, require, module, setfenv, getfenv (absent on B&W)
--   lib      no os, io, utf8, coroutine, debug or package library (absent on B&W or not for
--            lib code), no Lua 5.3-only math/string functions (absent in Lua 5.2)
--   idiv     no // operator (a syntax error in Lua 5.2); use math.floor(a / b)
--   bitop    no & | ~ << >> operators (syntax errors in Lua 5.2); ~= is not one
--   method   no method syntax a:b(...): B&W radios have no string metatable, so s:sub()
--            fails, and the lib has no objects
--   setglobal  no assignment to a global (all scripts share one Lua state); needs luac
-- Copies: every colour lib file has a byte-identical Boxer copy, and the Boxer lib folder has
-- no other .lua file. A Boxer lib .luac (made by tools/build-boxer.sh) is optional, but when
-- it is there it must be the stripped bytecode of the .lua next to it (tools/edgetx-luac -s)
-- and not older than that .lua: else the radio runs old code or compiles the .lua again.
-- Fix a copy failure with: sh tools/build-boxer.sh   (it runs tools/sync-boxer.sh first)

local here = string.match(arg and arg[0] or "", "^(.*)/[^/]*$") or "."
local ROOT = here .. "/../.."
local COLOUR = ROOT .. "/radio sd card/WIDGETS/FPVDASH/lib"
local BOXER = ROOT .. "/boxer sd card/SCRIPTS/FPVDASH/lib"
local ETX = ROOT .. "/tools/edgetx-luac"
local LUAC = os.getenv("LUAC") or "luac"
-- used only when a folder cannot be listed
local KNOWN = { "crsf.lua", "elrs.lua", "inputs.lua", "telem.lua", "thrcap.lua", "vtx.lua" }

local passed, failed = 0, 0
local function check(cond, what)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. what)
  end
end

----------------------------------------------------------------------------
-- helpers (desktop Lua: the test itself may use the table library)

local function shq(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

local function readAll(path)
  local f = io.open(path, "rb")
  if f == nil then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function popenLines(cmd)
  local ok, p = pcall(io.popen, cmd)
  if not ok or p == nil then return nil end
  local out = {}
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

-- .lua file names in a folder (sorted), or nil when the folder cannot be listed
local function listLua(dir)
  local lines = popenLines("ls -1 " .. shq(dir) .. " 2>/dev/null")
  if lines == nil then return nil end
  local out = {}
  for _, name in ipairs(lines) do
    if string.match(name, "^[^.].*%.lua$") then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function isFile(path)
  local f = io.open(path, "rb")
  if f == nil then return false end
  f:close()
  return true
end

----------------------------------------------------------------------------
-- lexer: tokens { t = "name" | "op" | "str" | "num", v = text, line = n }

local OPS3 = { ["..."] = true }
local OPS2 = { [".."] = true, ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true,
               ["<<"] = true, [">>"] = true, ["//"] = true, ["::"] = true }

local function lex(src)
  local toks = {}
  local i, n, line = 1, #src, 1
  local function newlines(a, b)
    local _, c = string.gsub(string.sub(src, a, b), "\n", "")
    line = line + c
  end
  while i <= n do
    local c = string.sub(src, i, i)
    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif string.match(c, "%s") then
      i = i + 1
    elseif string.sub(src, i, i + 1) == "--" then
      local lvl = string.match(src, "^%[(=*)%[", i + 2)
      local e
      if lvl ~= nil then
        local _, ce = string.find(src, "]" .. lvl .. "]", i + 4 + #lvl, true)
        e = ce or n
      else
        e = (string.find(src, "\n", i, true) or (n + 1)) - 1
      end
      newlines(i, e)
      i = e + 1
    elseif c == "[" and string.match(src, "^%[=*%[", i) then
      local lvl = string.match(src, "^%[(=*)%[", i)
      local _, ce = string.find(src, "]" .. lvl .. "]", i + 2 + #lvl, true)
      local e = ce or n
      toks[#toks + 1] = { t = "str", v = "", line = line }
      newlines(i, e)
      i = e + 1
    elseif c == '"' or c == "'" then
      local first = line
      local j = i + 1
      while j <= n do
        local ch = string.sub(src, j, j)
        if ch == "\\" then
          local esc = string.sub(src, j + 1, j + 1)
          if esc == "\n" then line = line + 1 end
          j = j + 2
          if esc == "z" then
            -- \z skips the white space (also line breaks) that follows
            local _, we = string.find(src, "^%s*", j)
            newlines(j, we)
            j = we + 1
          end
        elseif ch == c or ch == "\n" then
          break
        else
          j = j + 1
        end
      end
      toks[#toks + 1] = { t = "str", v = "", line = first }
      i = j + 1
    elseif string.match(c, "%d") or (c == "." and string.match(src, "^%.%d", i)) then
      local _, e = string.find(src, "^0[xX]%x*%.?%x*", i)
      if e ~= nil then
        local _, e2 = string.find(src, "^[pP][+-]?%d+", e + 1)
        e = e2 or e
      else
        _, e = string.find(src, "^%d*%.?%d*", i)
        local _, e2 = string.find(src, "^[eE][+-]?%d+", e + 1)
        e = e2 or e
      end
      toks[#toks + 1] = { t = "num", v = string.sub(src, i, e), line = line }
      i = e + 1
    elseif string.match(c, "[%a_]") then
      local _, e = string.find(src, "^[%w_]+", i)
      toks[#toks + 1] = { t = "name", v = string.sub(src, i, e), line = line }
      i = e + 1
    else
      local op = string.sub(src, i, i + 2)
      if not OPS3[op] then
        op = string.sub(src, i, i + 1)
        if not OPS2[op] then op = c end
      end
      toks[#toks + 1] = { t = "op", v = op, line = line }
      i = i + #op
    end
  end
  return toks
end

----------------------------------------------------------------------------
-- rules

local ABSENT_GLOBALS = { unpack = true, loadstring = true, require = true, module = true,
                         setfenv = true, getfenv = true }
local ABSENT_LIBS = { os = true, io = true, utf8 = true, coroutine = true, debug = true, package = true }
local NEW_IN_53 = { math = { type = true, tointeger = true, ult = true, maxinteger = true,
                             mininteger = true },
                    string = { pack = true, unpack = true, packsize = true } }
local BITOPS = { ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true }

-- Returns a list of { rule = ..., line = n, text = ... }
local function lint(src)
  local toks = lex(src)
  local found = {}
  local function add(rule, tok, text) found[#found + 1] = { rule = rule, line = tok.line, text = text } end
  -- names declared as locals (or local functions) somewhere in the file
  local declared = {}
  for k = 1, #toks do
    local a, b = toks[k], toks[k + 1]
    if a.t == "name" and a.v == "local" and b ~= nil then
      if b.t == "name" and b.v == "function" then
        local c = toks[k + 2]
        if c ~= nil and c.t == "name" then declared[c.v] = true end
      else
        local m = k + 1
        while toks[m] ~= nil and toks[m].t == "name" do
          declared[toks[m].v] = true
          if toks[m + 1] ~= nil and toks[m + 1].v == "," then m = m + 2 else break end
        end
      end
    end
  end
  for k = 1, #toks do
    local tok, prev, nxt = toks[k], toks[k - 1], toks[k + 1]
    local isField = prev ~= nil and prev.t == "op" and (prev.v == "." or prev.v == ":")
    if tok.t == "op" then
      if tok.v == "//" then add("idiv", tok, "//") end
      if BITOPS[tok.v] then add("bitop", tok, tok.v) end
      if tok.v == ":" and nxt ~= nil and nxt.t == "name" then add("method", tok, ":" .. nxt.v) end
    elseif tok.t == "name" and not isField then
      local nv = nxt ~= nil and nxt.t == "op" and nxt.v or nil
      local key = nv == "=" and prev ~= nil and (prev.v == "{" or prev.v == "," or prev.v == ";")
      if tok.v == "table" and not declared.table and not key then
        add("table", tok, "table" .. (nv or ""))
      elseif ABSENT_GLOBALS[tok.v] and not declared[tok.v] and not (prev ~= nil and prev.v == "local") then
        add("global", tok, tok.v)
      elseif ABSENT_LIBS[tok.v] and not declared[tok.v] and (nv == "." or nv == "[" or nv == ":") then
        add("lib", tok, tok.v .. nv)
      elseif NEW_IN_53[tok.v] and nv == "." and toks[k + 2] ~= nil and NEW_IN_53[tok.v][toks[k + 2].v] then
        add("lib", tok, tok.v .. "." .. toks[k + 2].v)
      end
    end
  end
  return found
end

local function rulesOf(found)
  local set = {}
  for _, f in ipairs(found) do set[f.rule] = (set[f.rule] or 0) + 1 end
  return set
end

----------------------------------------------------------------------------
-- self-check of the lexer and the rules

local BAD = {
  { "local x = table.insert", "table" },
  { "local x = table[\"concat\"]", "table" },
  { "local t = table", "table" },
  { "local y = a // b", "idiv" },
  { "local z = a & 1", "bitop" },
  { "local z = a | 1", "bitop" },
  { "local z = ~a", "bitop" },
  { "local z = a ~ b", "bitop" },
  { "local z = a << 1", "bitop" },
  { "local z = a >> 1", "bitop" },
  { "local n = s:len()", "method" },
  { "local r = (\"x\"):rep(3)", "method" },
  { "local q = s:sub(1, 2) .. t", "method" },
  { "f:write\"x\"", "method" },
  { "local v = unpack(t)", "global" },
  { "local f = loadstring(s)", "global" },
  { "local m = require(\"x\")", "global" },
  { "local m = math.type(1)", "lib" },
  { "local p = string.pack(\"i\", 1)", "lib" },
  { "local t = os.time()", "lib" },
  { "local f = io.open(\"x\")", "lib" },
}
for _, c in ipairs(BAD) do
  local set = rulesOf(lint(c[1]))
  check(set[c[2]] ~= nil, "self-check: '" .. c[1] .. "' gives rule " .. c[2])
end

local GOOD = [===[
-- a // b & c | d ~ e << f >> g table.insert s:len() unpack(t) os.time()
--[[ s:sub(1) // table.concat
  more & lines ]]
--[=[ x ]] y // z ]=]
local s = "a // b & c :len() table.x \" // still a string"
local e = "q\"//\"" .. 'x\'//\''
local l = [[ x // y ]]
local q = [==[ table.x ]] ]==]
local ok = a ~= b
local c = a .. b .. "c"
local d = { ... }
local t = { table = 1, os = 2 }
local u = t.table.unpack
local h = 0x1F + 1e3 + 0x1p4 + .5 + 3.
local function unpack(x) return x end
local w = unpack(1)
local m = math.floor(7 / 2) % 2
local z = "a\z
      b // c"
::top::
]===]
local goodFound = lint(GOOD)
check(#goodFound == 0, "self-check: the good snippet gives no findings"
  .. (goodFound[1] and (", first: " .. goodFound[1].rule .. " '" .. goodFound[1].text
                        .. "' line " .. goodFound[1].line) or ""))
local lines = lex("a\n--[[\n\n]]\nb\n'x\\\ny'\nc")
check(lines[1].line == 1 and lines[2].line == 5 and lines[3].line == 6 and lines[4].line == 8,
  "self-check: line numbers after comments and strings")

----------------------------------------------------------------------------
-- the lib files

local colourList = listLua(COLOUR)
if colourList == nil or #colourList == 0 then
  print("note: cannot list " .. COLOUR .. "; using the known module list")
  colourList = KNOWN
end
check(#colourList >= #KNOWN, "colour lib has the " .. #KNOWN .. " known modules (found " .. #colourList .. ")")

-- global writes, from the desktop luac listing (skipped when luac does not run)
local function globalWrites(path)
  local lines = popenLines(shq(LUAC) .. " -l -l -p " .. shq(path) .. " 2>&1")
  if lines == nil then return nil end
  local listed = false
  for _, l in ipairs(lines) do
    if string.match(l, "^main <") then listed = true end
  end
  if not listed then return nil end -- luac did not run, or the file does not parse
  local out = {}
  for _, l in ipairs(lines) do
    local name = string.match(l, "SETTABUP.-;%s*_ENV%s+\"([^\"]+)\"")
    if name ~= nil then out[#out + 1] = name end
  end
  return out
end

local function lintFile(path, label)
  local src = readAll(path)
  check(src ~= nil, label .. ": readable")
  if src == nil then return end
  local found = lint(src)
  for _, f in ipairs(found) do
    print(string.format("  %s:%d: %s (%s)", label, f.line, f.rule, f.text))
  end
  check(#found == 0, label .. ": B&W and Lua 5.2 safe (" .. #found .. " findings)")
  local gw = globalWrites(path)
  if gw ~= nil then
    check(#gw == 0, label .. ": no global writes" .. (gw[1] and (" (writes " .. gw[1] .. ")") or ""))
  else
    print("note: " .. label .. ": no luac listing (luac missing or a syntax error); global-write check skipped")
  end
end

local etxOk = isFile(ETX)
local tmpdir = os.getenv("TMPDIR") or "/tmp"
if string.sub(tmpdir, -1) == "/" then tmpdir = string.sub(tmpdir, 1, -2) end
math.randomseed(os.time())
local luacChecked = 0

for _, name in ipairs(colourList) do
  local src = COLOUR .. "/" .. name
  local dst = BOXER .. "/" .. name
  lintFile(src, "colour lib/" .. name)
  local a, b = readAll(src), readAll(dst)
  check(b ~= nil, "Boxer copy of " .. name .. " exists (run sh tools/build-boxer.sh)")
  if b ~= nil then
    lintFile(dst, "boxer lib/" .. name)
    check(a == b, "Boxer copy of " .. name .. " is identical to the colour lib (run sh tools/build-boxer.sh)")
    -- optional bytecode next to the copy
    local luac = BOXER .. "/" .. string.sub(name, 1, -5) .. ".luac"
    if isFile(luac) then
      local older = popenLines("[ " .. shq(luac) .. " -ot " .. shq(dst) .. " ] && echo older || echo ok")
      if older ~= nil and older[1] ~= nil then
        check(older[1] == "ok", "boxer lib/" .. name .. "c is not older than its .lua (run sh tools/build-boxer.sh)")
      end
      if etxOk then
        local tmp = string.format("%s/fpvdash_libcompat_%d_%d.luac", tmpdir, os.time(), math.random(1, 999999999))
        popenLines(shq(ETX) .. " -s -o " .. shq(tmp) .. " " .. shq(dst) .. " 2>&1")
        local want, have = readAll(tmp), readAll(luac)
        os.remove(tmp)
        check(want ~= nil and want == have,
          "boxer lib/" .. name .. "c is the stripped bytecode of its .lua (run sh tools/build-boxer.sh)")
        luacChecked = luacChecked + 1
      end
    end
  end
end

-- no stale .lua in the Boxer lib folder
local boxerList = listLua(BOXER)
if boxerList ~= nil then
  local inColour = {}
  for _, name in ipairs(colourList) do inColour[name] = true end
  for _, name in ipairs(boxerList) do
    check(inColour[name] == true, "boxer lib/" .. name .. " has a colour lib source (run sh tools/sync-boxer.sh)")
  end
end

print(string.format("lib_compat_test: %d passed, %d failed (%d lib files, %d .luac compared)",
  passed, failed, #colourList, luacChecked))
os.exit(failed == 0 and 0 or 1)
