CuraEqui = CuraEqui or {}
local U = CuraEqui.Utils or {}

function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function U.vlen2(a, b)
    if not (a and b) then return 0 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

CuraEqui.Utils = U
