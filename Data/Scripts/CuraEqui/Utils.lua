-- Scripts/CuraEqui/Utils.lua
CuraEqui = CuraEqui or {}
local U = {}

function U.clamp(x, lo, hi) return (x < lo) and lo or ((x > hi) and hi or x) end

function U.vlen2(a, b)
    if not (a and b) then return 0 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

CuraEqui.Utils = U
