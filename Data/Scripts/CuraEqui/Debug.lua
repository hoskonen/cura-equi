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

function CuraEqui.Debug.ShowHUDLine(text, ms)
    local hud  = CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud or {}
    local dur  = tonumber(ms) or tonumber(hud.refresh) or tonumber(hud.refreshMs) or 1200
    local id   = hud.id or "CuraEqui_DebugHUD"
    local lane = hud.lane or "notification"
    if CuraEqui.UI and CuraEqui.UI.Toast then
        CuraEqui.UI.Toast(tostring(text or ""), dur, 999, id, lane)
    elseif Game and Game.SendInfoText then
        Game.SendInfoText(tostring(text or ""), false, "", dur / 1000)
    end
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
