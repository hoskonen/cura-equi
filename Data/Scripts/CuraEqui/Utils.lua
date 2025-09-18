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

-- Treat small numbers as seconds (≤60), larger as ms → seconds
function CuraEqui.Utils.ms_to_s(v)
    local n = tonumber(v or 0) or 0
    if n <= 60 then return math.max(0.1, n) end
    return math.max(0.1, n / 1000.0)
end

-- Returns true only when enough time passed for this key.
-- Usage: if U.throttle("tick-fired", 10) then System.LogAlways("fired") end
do
    local _next = {} -- key → nextAllowedTime (seconds)
    function CuraEqui.Utils.throttle(key, intervalSec)
        local now = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local t   = tonumber(intervalSec or 1) or 1
        local nxt = _next[key] or 0
        if now >= nxt then
            _next[key] = now + t
            return true
        end
        return false
    end
end

CuraEqui       = CuraEqui or {}
CuraEqui.Utils = CuraEqui.Utils or {}

function CuraEqui.Utils.hunger_label(hungerPct, satedUntil)
    local tier   = (CuraEqui.Buffs and CuraEqui.Buffs._pickTierName)
        and CuraEqui.Buffs._pickTierName(tonumber(hungerPct or 0) or 0, satedUntil) or "ok"

    local HUD    = CuraEqui.Config and CuraEqui.Config.HUD or {}
    local names  = HUD.hungerNames or {}
    local pretty = names[tier]
    if not pretty then
        -- decent defaults if config omits hungerNames
        local defaults = { ok = "OK", minor = "Mild", moderate = "Hungry", critical = "Starving", sated = "Sated" }
        pretty = defaults[tier] or (tier:gsub("^%l", string.upper))
    end

    return pretty, tier
end

CuraEqui.Utils = U
