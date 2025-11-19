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
    -- Hard requirement: use the same clock as Hunger / BuffLogic.
    if CuraEqui and CuraEqui.Now then
        return CuraEqui.Now()
    end

    -- Absolute last-ditch fallback (mod is half-broken anyway at this point).
    return os.clock()
end

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

    local now        = _now()
    local satedUntil = 0
    local rem        = 0
    local ver        = tonumber(t.version or 1) or 1

    if ver >= 2 then
        -- New schema: we stored remaining seconds directly
        rem = math.max(0, tonumber(t.satedRemainSec or 0) or 0)
        -- clamp insane values (>24h) → treat as no sated
        if rem > 24 * 3600 then
            rem = 0
        end
        satedUntil = (rem > 0) and (now + rem) or 0
    else
        -- V1 migration path: old absolute clock
        local abs   = tonumber(t.satedUntil or 0) or 0
        local saved = tonumber(t.savedAt or 0) or 0
        rem         = math.max(0, abs - saved)
        if rem > 24 * 3600 then
            rem = 0
        end
        satedUntil = (rem > 0) and (now + rem) or 0
    end

    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        System.LogAlways(("[CuraEqui][Persist] Load: hunger=%s rem=%.0fs")
            :format(tostring(hunger), rem))
    end

    return hunger, satedUntil
end

-- Save current values; returns true on success
function P.Save(hunger, satedRemainSec)
    if not _db then return false end

    local now = _now()

    local h = tonumber(hunger or 0) or 0
    if h < 0 then h = 0 end
    if h > 100 then h = 100 end

    local rem = tonumber(satedRemainSec or 0) or 0
    if rem < 0 then rem = 0 end
    -- clamp nonsense: > 24h means “something went wrong”, treat as 0
    if rem > 24 * 3600 then rem = 0 end

    local payload = {
        version        = 2,
        savedAt        = now,
        hunger         = h,
        satedRemainSec = rem,
    }

    local ok = false
    local ok2, err = pcall(function()
        if _db.Set then
            _db:Set(P._localKey, payload)
        elseif _db.SetValue then
            _db:SetValue(P._localKey, payload)
        end
        ok = true
    end)

    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
        System.LogAlways(("[CuraEqui][Persist] Saved hunger=%.4f satedRemain=%.2f")
            :format(h, rem))
    end

    return ok and ok2
end

function P.Reopen()
    _db = nil
    local ok, inst = pcall(function()
        if DB and DB.Create then return DB:Create("CuraEqui") end
        return nil
    end)
    if ok and inst then _db = inst end
end

-- Optional: expose low-level for debug
function P._Backend() return _db end
