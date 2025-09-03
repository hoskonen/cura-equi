-- Scripts/CuraEqui/Hunger.lua

local U         = CuraEqui.Utils
local HGetState = CuraEqui.HorseStateGet
local function Q(...) CuraEqui.Log("Horse", ...) end

-- ---------- ONE-TIME PROBE ----------
local _probeDone = false
local function ProbeOnce(h)
    if _probeDone or not h then return end
    _probeDone = true

    local name = (h.GetName and h:GetName()) or "Horse"
    local class = (h.GetClassName and h:GetClassName()) or "?"
    local pid_from_player, pid_from_game = nil, nil
    pcall(function()
        if player and player.actor and player.actor.GetHorseId then
            pid_from_player = player.actor
                :GetHorseId()
        end
    end)
    pcall(function()
        if Game and Game.GetPlayerHorse then
            local ent = Game:GetPlayerHorse(); pid_from_game = ent and ent.id
        end
    end)

    System.LogAlways(("[CuraEqui][Probe] horse id=%s name=%s class=%s"):format(tostring(h.id), name, class))
    System.LogAlways(("[CuraEqui][Probe] ids: fromPlayer=%s fromGame=%s tracking=%s")
        :format(tostring(pid_from_player), tostring(pid_from_game), tostring(h.id)))

    local function has(ent, m) return ent and type(ent[m]) == "function" end
    local caps = {
        GetWorldPos = has(h, "GetWorldPos"),
        GetPos      = has(h, "GetPos"),
        GetVelocity = has(h, "GetVelocity") or (h.actor and has(h.actor, "GetVelocity")) or false,
    }
    for k, v in pairs(caps) do System.LogAlways(("[CuraEqui][Probe] cap %-11s = %s"):format(k, tostring(v))) end
end

-- ---------- TICK BODY (MAY THROW) ----------
function CuraEqui._HungerTickBody()
    local h = (CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil

    if not h then
        System.LogAlways("[CuraEqui][Tick] no player horse yet")
        return
    end
    if not h then return end
    ProbeOnce(h)

    local S = HGetState(h)
    if not S then return end

    -- one-shot sampler budget so we don't spam
    S.__dbgSamples = S.__dbgSamples or 10

    -- resolve vec3 from entity
    local function getPos(ent)
        if not ent then return nil end
        local p = nil
        if ent.GetWorldPos then p = ent:GetWorldPos() end
        if (not p) and ent.GetPos then p = ent:GetPos() end
        if not p then return nil end
        local x = p.x or p.X or p[1]
        local y = p.y or p.Y or p[2]
        local z = p.z or p.Z or p[3]
        if x and y and z then return { x = x, y = y, z = z } end
        return nil
    end

    local mounted = false
    pcall(function()
        mounted = player and player.actor and player.actor.IsMounted and player.actor:IsMounted() or false
    end)

    local hp = getPos(h)                           -- preferred
    local pp = (mounted and getPos(player)) or nil -- fallback when mounted
    local src, cp = "horse", hp or pp
    if (not hp) and pp then src = "player(mounted)" end

    -- velocity fallback if neither pos is available
    if not cp then
        local v = nil
        if h.GetVelocity then
            v = h:GetVelocity()
        elseif h.actor and h.actor.GetVelocity then
            v = h.actor:GetVelocity()
        end

        if v and (v.x or v[1]) then
            local vx    = v.x or v[1]; local vy = v.y or v[2]; local vz = v.z or v[3]
            local speed = math.sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2 + (vz or 0) ^ 2) -- m/s
            local d     = speed * (CuraEqui.HorseCfg.tickSec or 1)
            S.dist      = (S.dist or 0) + d
            S.totalDist = (S.totalDist or 0) + d
            S._posSrc   = "velocity"

            if CuraEqui.DEBUG_DISTANCE and S.__dbgSamples > 0 then
                System.LogAlways(("[CuraEqui][Trace] pos=nil → using velocity |v|=%.2f m/s Δ=%.2fm")
                    :format(speed, d))
                S.__dbgSamples = S.__dbgSamples - 1
            end
        else
            if CuraEqui.DEBUG_DISTANCE and S.__dbgSamples > 0 then
                System.LogAlways("[CuraEqui][Trace] no pos & no velocity → Δ=0")
                S.__dbgSamples = S.__dbgSamples - 1
            end
        end
    else
        -- sparse trace of picked position (first 10 samples)
        if CuraEqui.DEBUG_DISTANCE and S.__dbgSamples > 0 then
            System.LogAlways(("[CuraEqui][Trace] src=%s pos=(%.2f, %.2f, %.2f)"):format(src, cp.x, cp.y, cp.z))
        end

        -- compute delta
        local d = 0
        if S._lastPos then
            local dx    = cp.x - S._lastPos.x
            local dy    = cp.y - S._lastPos.y
            local dz    = cp.z - S._lastPos.z
            d           = math.sqrt(dx * dx + dy * dy + dz * dz)
            S.dist      = (S.dist or 0) + d
            S.totalDist = (S.totalDist or 0) + d
        end
        S._lastPos = cp
        S._posSrc  = src

        if CuraEqui.DEBUG_DISTANCE and S.__dbgSamples > 0 then
            System.LogAlways(("[CuraEqui][Trace] Δ=%.2fm (src=%s)"):format(d, src))
            S.__dbgSamples = S.__dbgSamples - 1
        end
    end

    -- milestone logs (guarded)
    local step = (CuraEqui.DEBUG_DISTANCE and (CuraEqui.DEBUG_DISTANCE_STEP or 100.0)) or math.huge
    S._dbgNextLogAt = S._dbgNextLogAt or ((S.totalDist or 0) + step)
    if CuraEqui.DEBUG_DISTANCE and (S.totalDist or 0) >= S._dbgNextLogAt then
        System.LogAlways(("[CuraEqui][Horse] +%.0fm (total=%.0fm) src=%s hunger=%d")
            :format(step, S.totalDist or 0, tostring(S._posSrc or "?"), tonumber(S.hunger or 0)))
        S._dbgNextLogAt = S._dbgNextLogAt + step
    end

    -- per-km hunger
    if (S.dist or 0) > 1000 then
        local km = (S.dist or 0) / 1000.0
        S.hunger = U.clamp((S.hunger or 0) + km * CuraEqui.HorseCfg.ratePerKm, 0, CuraEqui.HorseCfg.hungerMax)
        S.dist = (S.dist or 0) % 1000
    end

    -- time-based hunger
    S.hunger = U.clamp((S.hunger or 0) + (CuraEqui.HorseCfg.ratePerMin * (CuraEqui.HorseCfg.tickSec / 60.0)), 0,
        CuraEqui.HorseCfg.hungerMax)

    -- threshold ping (optional)
    if S.hunger >= CuraEqui.HorseCfg.debuffAt and not S._warned then
        Q("Hungry (hunger=%d)", tonumber(S.hunger or 0)); S._warned = true
    elseif S.hunger < CuraEqui.HorseCfg.debuffAt and S._warned then
        S._warned = nil
    end

    if CuraEqui.UpdateHorseDebuff then
        CuraEqui.UpdateHorseDebuff(h, S.hunger or 0)
    end
end

-- ---------- TIMER WRAPPER (ALWAYS REARMS) ----------
function CuraEqui_HungerTick()
    System.LogAlways("[CuraEqui][Tick] fired")
    local ok, err = xpcall(CuraEqui._HungerTickBody, debug.traceback)
    if not ok then
        System.LogAlways("[CuraEqui][Tick][ERROR] " .. tostring(err))
    end
    CuraEqui.state.hungerTimer =
        Script.SetTimerForFunction(CuraEqui.HorseCfg.tickSec * 1000, "CuraEqui_HungerTick")
end

-- ---------- START/STOP ----------
function CuraEqui.StartWatching()
    if CuraEqui.state.hungerTimer then
        Script.KillTimer(CuraEqui.state.hungerTimer)
    end
    CuraEqui.state.hungerTimer =
        Script.SetTimerForFunction(CuraEqui.HorseCfg.tickSec * 1000, "CuraEqui_HungerTick")
    CuraEqui.Log("poll", "Hunger watcher started (timerId=%s)", tostring(CuraEqui.state.hungerTimer))
end

function CuraEqui.StopWatching()
    if CuraEqui.state.hungerTimer then
        Script.KillTimer(CuraEqui.state.hungerTimer)
        CuraEqui.state.hungerTimer = nil
    end
    CuraEqui.Log("poll", "Hunger watcher stopped.")
end
