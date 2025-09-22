-- Scripts/CuraEqui/Persist.lua
CuraEqui         = CuraEqui or {}
CuraEqui.Persist = CuraEqui.Persist or {}

local P          = CuraEqui.Persist
P._ver           = 1
P._ns            = "CuraEqui"
P._localKey      = "horse.state" -- per-save (DB.Set / DB.Get)
P._gKey          = "horse.meta"  -- global (DB.SetG / DB.GetG) (reserved for future multi-horse)

-- Prefer the namespaced DB API if available
local _db        = nil
do
    local ok, inst = pcall(function()
        if DB and DB.Create then return DB:Create("CuraEqui") end
        if DB and DB.Create then return DB.Create("CuraEqui") end
        return nil
    end)
    if ok and inst then _db = inst end
end

local function _now()
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end

-- Load returns (hunger:number|nil, satedUntil:number|nil)
function P.Load()
    if not _db then return nil, nil end
    local t = nil

    -- Prefer per-save (local) store
    local ok, v = pcall(function()
        return (_db.Get and _db:Get(P._localKey)) or (_db.Get and _db.Get(P._localKey)) or nil
    end)
    if ok then t = v end
    if type(t) ~= "table" then return nil, nil end

    -- version tolerant
    local hunger = tonumber(t.hunger or 0)
    local sated  = tonumber(t.satedUntil or 0)

    if hunger then hunger = math.max(0, math.min(100, hunger)) end
    return hunger, sated
end

-- Save current values; returns true on success
function P.Save(hunger, satedUntil)
    if not _db then return false end
    local rec = {
        version    = P._ver,
        hunger     = math.max(0, math.min(100, tonumber(hunger or 0) or 0)),
        satedUntil = tonumber(satedUntil or 0) or 0,
        savedAt    = _now(),
    }
    local ok = false
    ok = pcall(function()
        if _db.Set then
            _db:Set(P._localKey, rec); return true
        end
    end)
    if not ok then
        System.LogAlways("[CuraEqui][Persist] Save failed (DB.Set missing?)")
        return false
    end

    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        System.LogAlways(("[CuraEqui][Persist] Saved hunger=%d sated=%s")
            :format(math.floor(hunger or -1), tostring(satedUntil)))
    end

    return true
end

-- Throttled saver: writes only on >=1% delta or every N seconds
do
    local _lastPct, _nextAt = nil, 0
    function P.MaybeSave(hunger, satedUntil, minDeltaPct, minEverySec)
        local state = CuraEqui.state or {}
        local now = _now()
        if state.persistMuteUntil and now < state.persistMuteUntil then
            return false
        end

        if not _db then return false end
        minDeltaPct = tonumber(minDeltaPct or 1) or 1
        minEverySec = tonumber(minEverySec or 20) or 20

        local pct = math.floor(tonumber(hunger or 0) + 0.5)
        local due = now >= (_nextAt or 0)
        local moved = (not _lastPct) or (math.abs(pct - _lastPct) >= minDeltaPct)

        if due or moved then
            _lastPct = pct
            _nextAt = now + minEverySec
            return P.Save(hunger, satedUntil)
        end
        return false
    end
end

-- Optional: expose low-level for debug
function P._Backend() return _db end
