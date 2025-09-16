-- Scripts/CuraEqui/Debug.lua
CuraEqui.Debug = CuraEqui.Debug or {}
-- Enable/disable distance milestone logs and set step size (meters).
CuraEqui.DEBUG_DISTANCE = CuraEqui.DEBUG_DISTANCE or false
function CuraEqui.Debug_EnableDistanceTrace(enabled, stepMeters)
    CuraEqui.DEBUG_DISTANCE = (enabled ~= false)
    CuraEqui.DEBUG_DISTANCE_STEP = tonumber(stepMeters) or CuraEqui.DEBUG_DISTANCE_STEP or 100.0
    if CuraEqui.Config and CuraEqui.Config.Debug then
        CuraEqui.Config.Debug.distanceTrace      = CuraEqui.DEBUG_DISTANCE
        CuraEqui.Config.Debug.distanceTraceStepM = CuraEqui.DEBUG_DISTANCE_STEP
    end
    for _, S in pairs(CuraEqui.HorseState or {}) do
        local step      = CuraEqui.DEBUG_DISTANCE and CuraEqui.DEBUG_DISTANCE_STEP or math.huge
        local base      = (S.totalDist or 0)
        S._dbgNextLogAt = base + step
        S.__dbgSamples  = 10 -- also reset short sampler window
    end
    System.LogAlways(("[CuraEqui][Debug] distance trace %s (step=%.0fm)")
        :format(CuraEqui.DEBUG_DISTANCE and "ON" or "OFF", CuraEqui.DEBUG_DISTANCE_STEP))
end

-- Snapshot ping
function CuraEqui.Debug_PingTick()
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    local S = h and CuraEqui.HorseState[h.id] or nil
    System.LogAlways(("[CuraEqui][Debug] tick ping: horse=%s hunger=%s dist=%.1fm total=%.1fm")
        :format(tostring(h and (h.GetName and h:GetName() or "Horse") or "nil"),
            tostring(S and S.hunger or "nil"),
            tonumber(S and S.dist or 0.0),
            tonumber(S and S.totalDist or 0.0)))
end

-- Central HUD emitter: respects Config.Debug.hud.{lane,refresh,id}
CuraEqui.Debug = CuraEqui.Debug or {}
function CuraEqui.Debug.ShowHUDLine(text, ms, lane, prio, id)
    local t   = tostring(text or "")
    local H   = (CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud) or {}
    local dur = math.max(1, tonumber(ms or H.refresh or 1200) or 1200)
    local ln  = lane or H.lane or "notification" -- "notification" | "tutorial" | "infotext"
    local tag = tostring(id or H.id or "CuraEqui_DebugHUD")
    local pr  = tonumber(prio or 0) or 0

    -- Special: engine center text
    if ln == "infotext" and Game and Game.SendInfoText then
        pcall(Game.SendInfoText, t, false, tag, dur)
        return true
    end

    -- Preferred: Scaleform lanes via our UI shim
    if CuraEqui.UI and CuraEqui.UI.Toast then
        local ok = pcall(function() CuraEqui.UI.Toast(t, dur, pr, tag, ln) end)
        if ok then return true end
    end

    -- Fallback: engine info text
    if Game and Game.SendInfoText then
        pcall(Game.SendInfoText, t, false, tag, dur)
        return true
    end

    System.LogAlways("[CuraEqui][HUD] " .. t)
    return false
end

function CuraEqui.Debug.SetHorseHunger(n)
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve(); if not h then return end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h); if not S then return end
    S.hunger = math.max(0, math.min(100, tonumber(n) or 0))
    System.LogAlways("[CuraEqui][DBG] hunger set to " .. tostring(S.hunger))
end

function CuraEqui.Debug.SetSated(sec)
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve(); if not h then return end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h); if not S then return end
    local now = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local add = math.max(0, tonumber(sec) or 0)
    S.satedUntil = now + add
    System.LogAlways("[CuraEqui][DBG] sated set to +" .. tostring(add) .. "s")
end

function CuraEqui.Debug.DietBind(key, nutrition)
    local D = CuraEqui.Diet or {}; if not D then return end
    nutrition = tonumber(nutrition) or 10
    key = tostring(key or "")
    if key:find("%-") then
        -- looks like a GUID
        D.byGuid[key] = D.byGuid[key] or { token = "dev" }
        D.byGuid[key].nutrition = nutrition
        System.LogAlways(("[CuraEqui][Diet][DEV] bind GUID %s → %d"):format(key, nutrition))
    else
        local token = string.lower(key)
        D.byToken[token] = D.byToken[token] or { guid = nil }
        D.byToken[token].nutrition = nutrition
        System.LogAlways(("[CuraEqui][Diet][DEV] bind token %s → %d"):format(token, nutrition))
    end
end

function CuraEqui.Debug.DietLookup(entOrKey)
    local D = CuraEqui.Diet or {}; if not D then return end
    if type(entOrKey) == "userdata" then
        local diet = pcall and (CE_ResolveDiet and CE_ResolveDiet(entOrKey))
        System.LogAlways("[CuraEqui][Diet] resolve → " ..
            tostring(diet and
                (diet.source .. " " .. (diet.token or "?") .. " " .. (diet.guid or "-") .. " n=" .. diet.nutrition) or
                "nil"))
    else
        local key = tostring(entOrKey or "")
        local row = D.byGuid[key] or D.byToken[string.lower(key)]
        if row then
            System.LogAlways(("[CuraEqui][Diet] lookup %s → n=%s"):format(key, tostring(row.nutrition)))
        else
            System.LogAlways(("[CuraEqui][Diet] lookup %s → nil"):format(key))
        end
    end
end

function CuraEqui.Debug_EnableHungerTrace(enabled, everyNTicks)
    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    D.hungerTrace = (enabled ~= false)
    D.hungerTraceEvery = tonumber(everyNTicks) or D.hungerTraceEvery or 1
    -- reset per-horse counters so schedules align immediately
    for _, S in pairs(CuraEqui.HorseState or {}) do
        S._dbgHungerTick = 0
    end
    System.LogAlways(("[CuraEqui][Debug] hunger trace %s (every=%d ticks)")
        :format(D.hungerTrace and "ON" or "OFF", D.hungerTraceEvery or 1))
end
