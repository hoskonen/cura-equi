-- Enable/disable distance milestone logs and set step size (meters).
CuraEqui.DEBUG_DISTANCE = CuraEqui.DEBUG_DISTANCE or false
function CuraEqui.Debug_EnableDistanceTrace(enabled, step)
    CuraEqui.DEBUG_DISTANCE = (enabled ~= false)
    CuraEqui.DEBUG_DISTANCE_STEP = tonumber(step) or 100.0
    System.LogAlways(("[CuraEqui][Debug] distance trace %s (step=%.0fm)")
        :format(CuraEqui.DEBUG_DISTANCE and "ON" or "OFF", CuraEqui.DEBUG_DISTANCE_STEP))
end

-- Hook the flag into the milestone calc (call this where you set _dbgNextLogAt)
-- Replace the fixed 100.0 with:
local step = (CuraEqui.DEBUG_DISTANCE and (CuraEqui.DEBUG_DISTANCE_STEP or 100.0)) or math.huge
S._dbgNextLogAt = S._dbgNextLogAt or step
if S.totalDist >= S._dbgNextLogAt then
    if CuraEqui.DEBUG_DISTANCE then
        System.LogAlways(("[CuraEqui][Horse] moved %.0fm (total=%.0fm) hunger=%d")
            :format(step, S.totalDist, tonumber(S.hunger or 0)))
    end
    S._dbgNextLogAt = S._dbgNextLogAt + step
end

function CuraEqui.Debug_PingTick()
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    local S = h and CuraEqui.HorseState[h.id] or nil
    System.LogAlways(("[CuraEqui][Debug] tick ping: horse=%s hunger=%s dist=%.1fm total=%.1fm")
        :format(tostring(h and (h.GetName and h:GetName() or "Horse") or "nil"),
            tostring(S and S.hunger or "nil"),
            tonumber(S and S.dist or 0.0),
            tonumber(S and S.totalDist or 0.0)))
end
