-- Mock of the lib/vtx.lua request API used by ui/vtxpage.lua.
-- apply/reload only record the requests; freqOf uses the ELRS table.
local FREQ = {
  A = { 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725 },
  B = { 5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866 },
  E = { 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945 },
  F = { 5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880 },
  R = { 5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917 },
  L = { 5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621 },
}

local function new()
  local vtx = { applied = {}, reloads = 0 }
  function vtx.apply(V, sel, send)
    vtx.applied[#vtx.applied + 1] = { sel = sel, send = send }
  end
  function vtx.reload(V)
    vtx.reloads = vtx.reloads + 1
  end
  function vtx.freqOf(letter, ch)
    local t = FREQ[letter]
    if t ~= nil and t[ch] ~= nil then return t[ch] end
    return 0
  end
  return vtx
end

return { new = new, FREQ = FREQ }
