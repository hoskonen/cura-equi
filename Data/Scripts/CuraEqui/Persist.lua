-- Scripts/CuraEqui/Persist.lua
CuraEqui         = CuraEqui or {}
CuraEqui.Persist = CuraEqui.Persist or {}

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
    if not _db then return nil, nil end
    local t
    local ok, v = pcall(function()
        return (_db.Get and _db:Get(P._localKey)) or (_db.Get and _db.Get(P._localKey)) or nil
    end)
    if ok then t = v end
    if type(t) ~= "table" then return nil, nil end

    local hunger = tonumber(t.hunger or 0)
    if hunger then hunger = math.max(0, math.min(100, hunger)) end

    local now = _now()
    local satedUntil = 0

    if tonumber(t.version or 1) >= 2 then
        -- New schema: we stored remaining seconds
        local rem = math.max(0, tonumber(t.satedRemainSec or 0) or 0)
        -- sanity clamp: >24h remaining is likely corrupt/old → clamp to 0
        if rem > 24 * 3600 then rem = 0 end

        satedUntil = (rem > 0) and (now + rem) or 0
    else
        -- V1 migration path: we stored absolute using a process clock.
        -- Use savedAt to recover intended "remaining at save time".
        local abs   = tonumber(t.satedUntil or 0) or 0
        local saved = tonumber(t.savedAt or 0) or 0
        local rem   = math.max(0, abs - saved)      -- intended remaining at save
        if rem > 24 * 3600 then rem = 0 end         -- guard nonsense

        satedUntil = (rem > 0) and (now + rem) or 0 -- rebase to current clock
    end

    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        CuraEqui._dbg_rawLoadedUntil = satedUntil
    else
        CuraEqui._dbg_rawLoadedUntil = nil
    end

    -- Round-to-nearest-full-tier (ties go up), then set internal to that tier.
    do
        local rem = math.max(0, (tonumber(satedUntil or 0) or 0) - now)
        local T = CuraEqui.Buffs and CuraEqui.Buffs.SATED_TIERS
        if rem > 0 and T and #T > 0 then
            local nearest  = 0
            local bestDiff = math.huge
            for i = 1, #T do
                local sec = tonumber(T[i].sec) or 0
                local d   = math.abs(rem - sec)
                if (d < bestDiff) or (d == bestDiff and sec > nearest) then
                    -- tie-break upward
                    bestDiff, nearest = d, sec
                end
            end
            satedUntil = (nearest > 0) and (now + nearest) or 0
        else
            -- nearest to 0 -> drop
            satedUntil = 0
        end
    end

    -- (optional but nice) show what happened
    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        local remOld = math.max(0, (tonumber((CuraEqui._dbg_rawLoadedUntil or satedUntil) or 0) - now))
        local remNew = math.max(0, (tonumber(satedUntil or 0) - now))
        System.LogAlways(("[CuraEqui][Persist] Load-round: rem=%.0fs → tier=%.0fs"):format(remOld, remNew))
    end

    CuraEqui._dbg_rawLoadedUntil = nil

    return hunger, satedUntil
end

-- Save current values; returns true on success
function P.Save(hunger, satedUntil)
    if not _db then return false end
    local now = _now()
    local rem = 0
    if satedUntil and tonumber(satedUntil) then
        rem = math.max(0, tonumber(satedUntil) - now)
    end
    local rec = {
        version        = P._ver,
        hunger         = math.max(0, math.min(100, tonumber(hunger or 0) or 0)),
        satedRemainSec = rem,
        savedAt        = now,
    }
    local ok, wrote = pcall(function()
        if _db.Set then
            _db:Set(P._localKey, rec); return true
        end
        return false
    end)
    if not ok or not wrote then
        System.LogAlways("[CuraEqui][Persist] Save failed (DB.Set missing?)")
        return false
    end
    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        System.LogAlways(("[CuraEqui][Persist] Saved hunger=%d satedRemain=%.2f")
            :format(math.floor(hunger or -1), rem))
    end
    return true
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
