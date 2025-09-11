-- Scripts/CuraEqui/Core.lua
CuraEqui                     = CuraEqui or {}
CuraEqui.VERSION             = "0.1.0"
CuraEqui.state               = CuraEqui.state or { hungerTimer = nil, pausedForSleep = false, started = false }

-- Safe config (defaults if Config.lua not loaded yet)
local C                      = CuraEqui.Config or {
    Debug = { enabled = true, distanceTrace = true, distanceTraceStepM = 100.0 },
    Hunger = { hungerMax = 100, hungerStart = 30, tickSec = 10, ratePerMin = 1.0, ratePerKm = 15.0, debuffAt = 70 },
}

-- Wire flags/tunables
CuraEqui.DEBUG               = C.Debug.enabled
CuraEqui.DEBUG_DISTANCE      = C.Debug.distanceTrace
CuraEqui.DEBUG_DISTANCE_STEP = C.Debug.distanceTraceStepM

CuraEqui.HorseCfg            = {
    hungerMax   = C.Hunger.hungerMax,
    hungerStart = C.Hunger.hungerStart,
    tickSec     = C.Hunger.tickSec,
    ratePerMin  = C.Hunger.ratePerMin,
    ratePerKm   = C.Hunger.ratePerKm,
    debuffAt    = C.Hunger.debuffAt,
}

CuraEqui.Diet                = CuraEqui.Diet or {}
CuraEqui.Diet.aliasByLabel   = CuraEqui.Diet.aliasByLabel or {}

function CuraEqui.Feed_Bind(label, classGuid)
    if not label or not classGuid then
        System.LogAlways("[CuraEqui][Diet] Bind usage: lua CuraEqui.Feed_Bind('<labelFromLog>', '<guid-from-DietData>')")
        return
    end
    local key = tostring(label):lower():gsub("%s+", "")
    CuraEqui.Diet.aliasByLabel[key] = tostring(classGuid)
    System.LogAlways(("[CuraEqui][Diet] bound %s → %s"):format(key, classGuid))
end

function CuraEqui.Log(tag, fmt, ...)
    if CuraEqui.DEBUG then System.LogAlways(("[CuraEqui]%s %s"):format(tag and ("[" .. tag .. "]") or "", fmt:format(...))) end
end

-- Event glue (register once in init file or here)
if UIAction and UIAction.RegisterEventSystemListener and not CuraEqui.__eventsBound then
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnGameplayStarted", "OnGameplayStarted")
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnSetFaderState", "OnSetFaderState")
    CuraEqui.__eventsBound = true
end

-- Core.lua (OnGameplayStarted)
function CuraEqui.OnGameplayStarted()
    CuraEqui.Initialize(true)

    -- one-shot: log what APIs return
    if CuraEqui.Horse.Debug_LogPlayerHorseHandles then CuraEqui.Horse.Debug_LogPlayerHorseHandles() end

    -- staggered resolve attempts: 0ms, 300ms, 1200ms
    local tries = { 0, 300, 1200 }
    local function try(i)
        local h = CuraEqui.Horse.Resolve()
        if h then
            System.LogAlways(("[CuraEqui][Horse] resolved on start id=%s name=%s")
                :format(tostring(h.id), (h.GetName and h:GetName()) or "Horse"))
            CuraEqui.StopProbing(); CuraEqui.StartWatching()
        else
            if i < #tries then
                Script.SetTimer(tries[i + 1], function() try(i + 1) end)
            else
                CuraEqui.StartProbing()
            end -- light 10s probe until a horse appears
        end
    end
    try(1)
end

-- Sleep / fade handling (same idea as your UWH example)
function CuraEqui.OnSetFaderState(_actionName, eventName, argTable)
    -- argTable[1] usually "sleep" when starting sleep fade
    if eventName == "OnSetFaderState" and argTable and argTable[1] == "sleep" then
        CuraEqui.Log("poll", "Sleep starting → stopping hunger watcher")
        CuraEqui.StopWatching()
        CuraEqui.state.pausedForSleep = true
    elseif eventName == "OnHide" then
        -- UI fade finished (covers post-load and wake-up)
        CuraEqui.Log("poll", "UI resumed → ensuring hunger watcher is running")
        CuraEqui.Initialize(false)
        CuraEqui.state.pausedForSleep = false
    end
end

-- Idempotent init that (re)starts polling
function CuraEqui.Initialize(fullInit)
    if fullInit and CuraEqui.state.started then
        CuraEqui.Log("init", "Already initialized → skipping reload")
    else
        CuraEqui.state.started = true
    end

    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    if h then
        CuraEqui.StartWatching()
    else
        CuraEqui.StartProbing() -- new (see below)
    end
end

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
            System.LogAlways(("[CuraEqui][Buff][ERROR] %s used by %s and %s")
                :format(d.guid, d.a, d.b))
        end
    else
        System.LogAlways("[CuraEqui][Buff] GUIDs validated (no cross-channel duplicates).")
    end
end
