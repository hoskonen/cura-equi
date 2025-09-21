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

function U.hunger_label(hungerPct, satedUntil)
    local HUD   = CuraEqui.Config and CuraEqui.Config.HUD or {}
    local th    = HUD.thresholds or { minor = 20, moderate = 50, critical = 80 }
    local names = HUD.hungerNames or {
        ok = "OK",
        minor = "Mild",
        moderate = "Hungry",
        critical = "Starving",
        sated =
        "Sated"
    }

    -- Sated override
    local now   = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local rem   = math.max(0, (tonumber(satedUntil or 0) or 0) - now)
    if rem > 0 then return names.sated, "sated" end

    local h = tonumber(hungerPct or 0) or 0
    local tier = (h >= (th.critical or 80)) and "critical"
        or (h >= (th.moderate or 50)) and "moderate"
        or (h >= (th.minor or 20)) and "minor"
        or "ok"

    return names[tier] or tier, tier
end

CuraEqui.Utils = U
