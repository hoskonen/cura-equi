-- Scripts/CuraEqui/Persist.lua
CuraEqui         = CuraEqui or {}
CuraEqui.Persist = CuraEqui.Persist or {}
local D          = CuraEqui.Config and CuraEqui.Config.Debug or {}

local P          = CuraEqui.Persist
P._ver           = 2
P._ns            = "CuraEqui"
P._localKey      = "horse.state" -- per-save (DB.Set / DB.Get)
P._gKey          = "horse.meta"  -- global (DB.SetG / DB.GetG) (reserved for future multi-horse)

-- Prefer the namespaced DB API if available
local _db        = nil
do
    local ok, inst = pcall(function()
        if DB and DB.Create then return DB:Create("CuraEqui") end
        return nil
    end)
    if ok and inst then _db = inst end
end

local function _now()
    return (CuraEqui and CuraEqui.Now and CuraEqui.Now())
        or ((Script and Script.GetTime and Script.GetTime()) or os.clock())
end

-- Load returns (hunger:number|nil, satedUntil:number|nil)
function P.Load()
    if not _db then
        return nil, nil
    end

    -- Fetch raw table from DB
    local t
    local ok, v = pcall(function()
        return (_db.Get and _db:Get(P._localKey))
            or (_db.Get and _db.Get(P._localKey))
            or nil
    end)

    if ok then
        t = v
    end

    if type(t) ~= "table" then
        return nil, nil
    end

    -- Hunger is the only thing we care about now
    local hunger = tonumber(t.hunger or -1) or -1
    if hunger < 0 then
        -- Treat "no hunger" as no state at all
        return nil, nil
    end

    -- Clamp to [0, 100]
    hunger = math.max(0, math.min(100, hunger))

    -- ⚠️ Important: sated is now *runtime-only* → never restored from DB
    local satedUntil = 0

    return hunger, satedUntil
end

-- Save current values; returns true on success
function P.Save(hunger, satedUntil)
    if not _db then return end

    -- Only persist hunger; sated is runtime-only
    local t = {
        hunger         = tonumber(hunger or -1) or -1,
        -- keep the fields for forward-compat but always zero them out
        satedRemainSec = 0,
        savedAt        = 0,
        version        = 2,
    }

    local ok, err = pcall(function()
        if _db.Set then
            return _db:Set(P._localKey, t)
        elseif _db.SetValue then
            return _db:SetValue(P._localKey, t)
        end
    end)

    if not ok and CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        System.LogAlways("[CuraEqui][Persist][ERROR] Save failed: " .. tostring(err))
    end
end

function P.Reopen()
    _db = nil
    local ok, inst = pcall(function()
        if DB and DB.Create then return DB:Create("CuraEqui") end
        return nil
    end)
    if ok and inst then _db = inst end
end

-- Throttled saver: writes only on >=1% delta or every N seconds
do
    local _lastPct, _nextAt, _lastRem = nil, 0, nil
    function P.MaybeSave(hunger, satedUntil, minDeltaPct, minEverySec)
        local now = _now()
        if not _db then return false end
        minDeltaPct = tonumber(minDeltaPct or 1) or 1
        minEverySec = tonumber(minEverySec or 20) or 20

        local pct = math.floor(tonumber(hunger or 0) + 0.5)
        local due = now >= (_nextAt or 0)
        local movedPct = (not _lastPct) or (math.abs(pct - _lastPct) >= minDeltaPct)

        local rem = 0
        if satedUntil and tonumber(satedUntil) then
            rem = math.max(0, tonumber(satedUntil) - now)
        end
        local movedRem = (_lastRem == nil) or (math.abs(rem - _lastRem) >= minEverySec)

        if due or movedPct or movedRem then
            local ok = P.Save(hunger, satedUntil)
            if ok then
                _lastPct = pct
                _lastRem = rem
                _nextAt  = now + minEverySec
            end
            return ok
        end
        return false
    end
end

-- Optional: expose low-level for debug
function P._Backend() return _db end
