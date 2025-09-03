-- Scripts/CuraEqui/Hunger.lua
local U         = CuraEqui.Utils
local HGetState = CuraEqui.HorseStateGet
local function Q(fmt, ...) CuraEqui.Log("Horse", fmt, ...) end

-- Global function name for the timer (required by SetTimerForFunction)
function CuraEqui_HungerTick()
    System.LogAlways("[CuraEqui][Tick] running")
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    if h then
        local S = HGetState(h)
        if S then
            -- distance accumulation
            pcall(function()
                if h.GetWorldPos then
                    local pos = h:GetWorldPos()
                    if S._lastPos then
                        local dx, dy, dz = pos.x - S._lastPos.x, pos.y - S._lastPos.y, pos.z - S._lastPos.z
                        local d          = math.sqrt(dx * dx + dy * dy + dz * dz)
                        S.dist           = (S.dist or 0) + d
                        S.totalDist      = (S.totalDist or 0) + d

                        -- (optional) milestone log (guarded by flag)
                        local step       = (CuraEqui.DEBUG_DISTANCE and (CuraEqui.DEBUG_DISTANCE_STEP or 100.0)) or
                            math.huge
                        S._dbgNextLogAt  = S._dbgNextLogAt or step
                        if S.totalDist >= S._dbgNextLogAt then
                            if CuraEqui.DEBUG_DISTANCE then
                                System.LogAlways(("[CuraEqui][Horse] moved %.0fm (total=%.0fm) hunger=%d")
                                    :format(step, S.totalDist, tonumber(S.hunger or 0)))
                            end
                            S._dbgNextLogAt = S._dbgNextLogAt + step
                        end

                        -- per-km hunger accrual
                        if S.dist > 1000 then
                            local km = S.dist / 1000.0
                            S.hunger = U.clamp((S.hunger or 0) + km * CuraEqui.HorseCfg.ratePerKm, 0,
                                CuraEqui.HorseCfg.hungerMax)
                            S.dist = S.dist % 1000
                        end
                    end
                    S._lastPos = pos
                end
            end)

            -- time-based hunger
            S.hunger = U.clamp((S.hunger or 0) + (CuraEqui.HorseCfg.ratePerMin * (CuraEqui.HorseCfg.tickSec / 60.0)), 0,
                CuraEqui.HorseCfg.hungerMax)

            -- threshold ping (non-spam)
            if S.hunger >= CuraEqui.HorseCfg.debuffAt and not S._warned then
                Q("Horse is getting hungry (hunger=%d)", tonumber(S.hunger or 0)); S._warned = true
            elseif S.hunger < CuraEqui.HorseCfg.debuffAt and S._warned then
                S._warned = nil
            end

            -- optional: apply tiered debuffs + HUD indicator
            if CuraEqui.UpdateHorseDebuff then CuraEqui.UpdateHorseDebuff(h, S.hunger or 0) end
        end
    end

    -- re-arm the timer
    CuraEqui.state.hungerTimer = Script.SetTimerForFunction(CuraEqui.HorseCfg.tickSec * 1000, "CuraEqui_HungerTick")
end

function CuraEqui.StartWatching()
    if CuraEqui.state.hungerTimer then
        Script.KillTimer(CuraEqui.state.hungerTimer)
        CuraEqui.Log("poll", "Killed old hunger timer")
    end
    CuraEqui.state.hungerTimer = Script.SetTimerForFunction(CuraEqui.HorseCfg.tickSec * 1000, "CuraEqui_HungerTick")
    CuraEqui.Log("poll", "Hunger watcher started (timerId=%s)", tostring(CuraEqui.state.hungerTimer))
end

function CuraEqui.StopWatching()
    if CuraEqui.state.hungerTimer then
        Script.KillTimer(CuraEqui.state.hungerTimer)
        CuraEqui.state.hungerTimer = nil
    end
    CuraEqui.Log("poll", "Hunger watcher stopped.")
end
