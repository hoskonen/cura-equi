-- Scripts/CuraEqui/Core.lua
CuraEqui                     = CuraEqui or {}
CuraEqui.VERSION             = "0.2.0"
CuraEqui.state               = CuraEqui.state or { hungerTimer = nil, pausedForSleep = false, started = false }

-- Safe config (defaults if Config.lua not loaded yet)
local C                      = CuraEqui.Config or {
    Debug  = { enabled = true, distanceTrace = true, distanceTraceStepM = 100.0, hud = { enabled = false, refresh = 1200 } },
    Hunger = {
        hungerMax         = 100,
        hungerStart       = 30,
        tickSec           = 10,
        -- NEW dials (no legacy names here):
        ratePerMinIdle    = 0.5,  -- idle (unmounted or mounted-but-standing)
        ratePerMinMounted = 1.0,  -- mounted & moving: time drift
        ratePerKmMounted  = 4.0,  -- mounted & moving: per-km
        speedIdleMps      = 0.2,  -- movement threshold
        satedDrainMul     = 0.75, -- Sated multiplier
        debuffAt          = 70,
    },
    Diet   = { strict = "guid+token", allowKeywords = { "ui_nm_", "apple", "bread", "carrot" }, keywordNutrition = 10 },
}

-- Wire flags/tunables
CuraEqui.DEBUG               = C.Debug.enabled
CuraEqui.DEBUG_DISTANCE      = C.Debug.distanceTrace
CuraEqui.DEBUG_DISTANCE_STEP = C.Debug.distanceTraceStepM

-- Keep HorseCfg minimal (only what scheduler/clamp needs)
CuraEqui.HorseCfg            = {
    hungerMax   = C.Hunger.hungerMax,
    hungerStart = C.Hunger.hungerStart,
    tickSec     = C.Hunger.tickSec,
    debuffAt    = C.Hunger.debuffAt,
}

-- ---------------------------------------------------------------------------
-- Logging helper (safe varargs)
-- ---------------------------------------------------------------------------
function CuraEqui.Log(tag, fmt, ...)
    if not CuraEqui.DEBUG then return end
    local prefix = "[CuraEqui]" .. (tag and ("[" .. tostring(tag) .. "]") or "")
    local ok, msg = pcall(string.format, tostring(fmt or ""), ...)
    System.LogAlways(prefix .. " " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- Runtime Diet maps (hydrated once from DietData.lua)
-- ---------------------------------------------------------------------------
CuraEqui.Diet = CuraEqui.Diet or {}

do
    CuraEqui.Config      = CuraEqui.Config or {}
    CuraEqui.Config.Diet = CuraEqui.Config.Diet or {}
    if not CuraEqui.Config.Diet.strict then
        CuraEqui.Config.Diet.strict = "guid+token" -- "guid-only" | "guid+token" | "guid+token+keywords"
    end

    CuraEqui.Diet.byGuid        = {}
    CuraEqui.Diet.byToken       = {}
    CuraEqui.Diet._unmappedSeen = {} -- once-per-session guard for unmapped logs

    local DD                    = CuraEqui.DietData or {}

    -- 1) byGuid ← source
    if DD.byGuid then
        for guid, row in pairs(DD.byGuid) do
            CuraEqui.Diet.byGuid[tostring(guid)] = {
                token     = row.token,
                nutrition = tonumber(row.nutrition) or 0,
            }
        end
    end

    -- 2) byToken ← source (or fold from byGuid; choose highest nutrition on dup tokens)
    if DD.byToken then
        for token, row in pairs(DD.byToken) do
            CuraEqui.Diet.byToken[string.lower(token)] = {
                guid      = row.guid and tostring(row.guid) or nil,
                nutrition = tonumber(row.nutrition) or 0,
            }
        end
    else
        for guid, row in pairs(DD.byGuid or {}) do
            local t = row.token and string.lower(row.token) or nil
            if t and t ~= "" then
                local curr = CuraEqui.Diet.byToken[t]
                if (not curr) or ((tonumber(row.nutrition) or 0) > (curr.nutrition or 0)) then
                    CuraEqui.Diet.byToken[t] = {
                        guid      = tostring(guid),
                        nutrition = tonumber(row.nutrition) or 0,
                    }
                end
            end
        end
    end

    local function _count(t)
        local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n
    end
    System.LogAlways(("[CuraEqui][Diet] byGuid=%d byToken=%d ready")
        :format(_count(CuraEqui.Diet.byGuid), _count(CuraEqui.Diet.byToken)))
end

-- (DEV) Optional quick binder: update runtime map without reload (GUID or token).
function CuraEqui.Debug_DietBind(key, nutrition)
    if not key then return end
    nutrition = tonumber(nutrition) or 10
    local k = tostring(key)
    if k:find("%-") then
        -- GUID
        CuraEqui.Diet.byGuid[k] = CuraEqui.Diet.byGuid[k] or { token = "dev" }
        CuraEqui.Diet.byGuid[k].nutrition = nutrition
        System.LogAlways(("[CuraEqui][Diet][DEV] GUID %s → %d"):format(k, nutrition))
    else
        -- token
        local t = string.lower(k:gsub("^@", ""):gsub("^ui_nm_", ""):gsub("%s+", ""))
        CuraEqui.Diet.byToken[t] = CuraEqui.Diet.byToken[t] or { guid = nil }
        CuraEqui.Diet.byToken[t].nutrition = nutrition
        System.LogAlways(("[CuraEqui][Diet][DEV] token %s → %d"):format(t, nutrition))
    end
end

-- ---------------------------------------------------------------------------
-- GUID validator (player status vs horse debuffs)
-- ---------------------------------------------------------------------------
function CuraEqui.ValidateBuffGuids()
    local HUD = CuraEqui.Config and CuraEqui.Config.HUD or {}
    local seen, dups = {}, {}
    local function add(list, label)
        for _, row in ipairs(list or {}) do
            local g = row and row.uidd
            if g and g ~= "" then
                if seen[g] then
                    dups[#dups + 1] = { guid = g, a = seen[g], b = label .. "." .. (row.name or "?") }
                else
                    seen[g] = label .. "." .. (row.name or "?")
                end
            end
        end
    end
    add(HUD.playerStatusTiers, "player")
    add(HUD.horseDebuffTiers, "horse")

    if #dups > 0 then
        System.LogAlways("[CuraEqui][Buff][ERROR] Duplicate GUIDs across player/horse tiers:")
        for _, d in ipairs(dups) do
            System.LogAlways(("[CuraEqui][Buff][ERROR] %s used by %s and %s"):format(d.guid, d.a, d.b))
        end
    else
        System.LogAlways("[CuraEqui][Buff] GUIDs validated (no cross-channel duplicates).")
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle glue
-- ---------------------------------------------------------------------------

-- Event glue (register once)
if UIAction and UIAction.RegisterEventSystemListener and not CuraEqui.__eventsBound then
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnGameplayStarted", "OnGameplayStarted")
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnSetFaderState", "OnSetFaderState")
    CuraEqui.__eventsBound = true
end

-- Call this whenever we think gameplay (re)started or a save was loaded.
function CuraEqui.Bootstrap(reason)
    CuraEqui.Log("init", "Bootstrap (%s)", tostring(reason or ""))

    -- kill any stale timers, then (re)start
    if CuraEqui.StopWatching then CuraEqui.StopWatching() end
    if CuraEqui.Initialize then CuraEqui.Initialize(false) end

    -- re-apply buffs once (don’t rely on last-known)
    if CuraEqui.Buffs then CuraEqui.Buffs._lastPlayerUuid = nil end
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
    if S then S._lastHorseDebuffUuid = nil end

    -- kick an immediate tick a hair later so souls/HUD are definitely up
    if Script and Script.SetTimerForFunction then
        _G["CuraEqui_HungerTick_Once"] = function()
            if CuraEqui_HungerTick then pcall(CuraEqui_HungerTick) end
        end
        Script.SetTimerForFunction(200, "CuraEqui_HungerTick_Once")
    end
end

-- Idempotent init that (re)starts polling
function CuraEqui.Initialize(fullInit)
    if fullInit and CuraEqui.state.started then
        CuraEqui.Log("init", "Already initialized → skipping reload")
    else
        CuraEqui.state.started = true
    end

    -- Fallback: if we still have a sleep start timestamp, run catch-up once here.
    if CuraEqui.state and CuraEqui.state._sleepStartTOD and CuraEqui.Hunger_CatchUpAfterSleep then
        local ok, minutes, delta, before, after = pcall(CuraEqui.Hunger_CatchUpAfterSleep)
        if ok and minutes and minutes > 0 then
            System.LogAlways(("[CuraEqui][Hunger][catchup] +%.1f min → Δ=%.2f → %d→%d")
                :format(minutes, delta or 0, math.floor(before or 0), math.floor(after or 0)))
        end
        CuraEqui.state._sleepStartTOD = nil
    end

    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    if h then
        if CuraEqui.StartWatching then CuraEqui.StartWatching() end
    else
        if CuraEqui.StartProbing then CuraEqui.StartProbing() end -- light 10s probe until a horse appears
    end
end

-- Sleep / fade handling (same idea as UWH)
function CuraEqui.OnSetFaderState(_actionName, eventName, argTable)
    -- argTable[1] usually "sleep" when starting sleep fade
    if eventName == "OnSetFaderState" and argTable and argTable[1] == "sleep" then
        CuraEqui.Log("poll", "Sleep starting → stopping hunger watcher")
        if CuraEqui.StopWatching then CuraEqui.StopWatching() end
        CuraEqui.state.pausedForSleep = true

        local tod = (Calendar and Calendar.GetTimeOfDay and Calendar.GetTimeOfDay()) or nil
        CuraEqui.state._sleepStartTOD = tod
    elseif eventName == "OnHide" then
        -- UI fade finished (covers post-load and wake-up)
        CuraEqui.Log("poll", "UI resumed → ensuring hunger watcher is running")
        -- apply a small hunger catch-up based on skipped world minutes
        -- UI fade finished (covers post-load and wake-up)
        System.LogAlways("[CuraEqui][Sleep] waking → running hunger catch-up")
        if CuraEqui.Hunger_CatchUpAfterSleep then
            local ok, minutes, delta, before, after = pcall(CuraEqui.Hunger_CatchUpAfterSleep)
            if ok and minutes and minutes > 0 then
                System.LogAlways(("[CuraEqui][Hunger][catchup] +%.1f min → Δ=%.2f → %d→%d")
                    :format(minutes, delta or 0, math.floor(before or 0), math.floor(after or 0)))
            end
        end

        CuraEqui.Initialize(false)
        CuraEqui.state.pausedForSleep = false
        CuraEqui.state._sleepStartTOD = nil
    end
end

-- Gameplay start entry
function CuraEqui.OnGameplayStarted()
    CuraEqui.ValidateBuffGuids()
    CuraEqui.Initialize(true)
    CuraEqui.Bootstrap("OnGameplayStarted")

    -- Staggered horse resolve attempts: 0ms, 300ms, 1200ms
    local tries = { 0, 300, 1200 }
    local function try(i)
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        if h then
            System.LogAlways(("[CuraEqui][Horse] resolved on start id=%s name=%s")
                :format(tostring(h.id), (h.GetName and h:GetName()) or "Horse"))
            if CuraEqui.StopProbing then CuraEqui.StopProbing() end
            if CuraEqui.StartWatching then CuraEqui.StartWatching() end
        else
            if i < #tries then
                if Script and Script.SetTimer then Script.SetTimer(tries[i + 1], function() try(i + 1) end) end
            else
                if CuraEqui.StartProbing then CuraEqui.StartProbing() end
            end
        end
    end
    try(1)
end
