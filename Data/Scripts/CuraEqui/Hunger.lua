-- Scripts/CuraEqui/Hunger.lua
local function Q(...) CuraEqui.Log("Horse", ...) end

-- ---------- ONE-TIME PROBE ----------
local _probeDone = false

local U = CuraEqui.Utils or {}
local function clamp(x, lo, hi)
    local f = U and U.clamp
    if f then return f(x, lo, hi) end
    return (x < lo) and lo or ((x > hi) and hi or x)
end

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

-- ONE source of truth for hunger dials (+ legacy fallbacks)
local function _H()
    local H = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
    return {
        tickSec       = tonumber(H.tickSec) or 10,
        rateIdle      = tonumber(H.ratePerMinIdle or H.ratePerMin) or 0.5,
        rateMounted   = tonumber(H.ratePerMinMounted or H.ratePerMinActive or H.ratePerMin) or 1.0,
        rateKmMounted = tonumber(H.ratePerKmMounted or H.ratePerKm) or 4.0,
        speedIdle     = tonumber(H.speedIdleMps) or 0.2,
        satedMul      = tonumber(H.satedDrainMul) or 0.75,
    }
end

function CuraEqui.StartProbing()
    if CuraEqui.state.probeTimer then Script.KillTimer(CuraEqui.state.probeTimer) end
    local periodMs = 10000 -- every 10s; make configurable later if you want
    _G["CuraEqui_HorseProbeTick"] = function()
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        if h then
            CuraEqui.StopProbing()
            return CuraEqui.StartWatching()
        end
        CuraEqui.state.probeTimer = Script.SetTimerForFunction(periodMs, "CuraEqui_HorseProbeTick")
    end
    CuraEqui.state.probeTimer = Script.SetTimerForFunction(500, "CuraEqui_HorseProbeTick") -- first probe in 0.5s
    CuraEqui.Log("poll", "Probe started.")
end

function CuraEqui.StopProbing()
    if CuraEqui.state.probeTimer then Script.KillTimer(CuraEqui.state.probeTimer) end
    CuraEqui.state.probeTimer = nil
    CuraEqui.Log("poll", "Probe stopped.")
end

-- ---------- TICK BODY (MAY THROW) ----------
function CuraEqui._HungerTickBody()
    local h = (CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil

    if not h then
        System.LogAlways("[CuraEqui][Tick] no player horse yet")
        return
    end

    ProbeOnce(h)

    local S = (CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h)) or nil
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
        mounted = (CuraEqui.Horse and CuraEqui.Horse.IsMounted and CuraEqui.Horse.IsMounted()) or false
    end)
    S._mountedNow = mounted

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

    -- idle vs mounted-moving
    do
        local C     = _H()

        local dt    = (CuraEqui.HorseCfg.tickSec or C.tickSec)
        local distM = (S._posSrc and (S.dist or 0)) or 0
        local speed = distM / math.max(dt, 0.001)

        -- idle if not mounted OR mounted but below movement threshold
        local idle  = (not mounted) or (speed < C.speedIdle)

        -- log mount flips once (optional)
        do
            local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
            if D.mountTrace then
                if S._dbgMountedPrev == nil then
                    S._dbgMountedPrev = mounted
                elseif mounted ~= S._dbgMountedPrev then
                    System.LogAlways(("[CuraEqui][Mount] changed: %s → %s (spd=%.2f)")
                        :format(S._dbgMountedPrev and "mounted" or "unmounted",
                            mounted and "mounted" or "unmounted",
                            speed or 0))
                    S._dbgMountedPrev = mounted
                end
            end
        end

        -- time drift
        local timePerMin = (mounted and (idle and C.rateIdle or C.rateMounted)) or 0
        local timeDrain  = timePerMin * (dt / 60.0)

        -- per-km only when mounted-moving
        local distDrain  = (mounted and not idle) and (C.rateKmMounted * (distM / 1000.0)) or 0

        -- grazing recovery when unmounted & idle (negative reduces hunger)
        local Hcfg       = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
        local gP         = tonumber(Hcfg.grazePerMinIdleUnmtd) or 0
        local gM         = tonumber(Hcfg.grazeSatedMul) or 1.0
        local graze      = ((not mounted) and idle) and (gP * (dt / 60.0) * gM) or 0

        -- sated multiplier
        local now        = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local mul        = (((tonumber(S.satedUntil or 0) or 0) > now) and C.satedMul) or 1.0

        -- By design, sated does NOT change grazing by default → apply mul to drains only
        local totalDrain = (timeDrain + distDrain) * mul + graze

        local before     = tonumber(S.hunger or 0) or 0
        local after      = clamp(before + totalDrain, 0, CuraEqui.HorseCfg.hungerMax or 100)
        S.hunger         = after

        -- optional telemetry
        S._lastTimeDrain = timeDrain
        S._lastDistDrain = distDrain
        S._lastDrainMul  = mul
        S._lastSpeedMps  = speed
        S._lastGraze     = graze

        -- dev console trace (compact)
        do
            local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
            if D.hungerTrace then
                S._dbgHungerTick = (S._dbgHungerTick or 0) + 1
                local N = tonumber(D.hungerTraceEvery) or 1
                if (S._dbgHungerTick % N) == 0 then
                    local state = idle and "idle" or "mounted"
                    local now   = (Script and Script.GetTime and Script.GetTime()) or os.clock()
                    local remS  = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                    System.LogAlways(("[CuraEqui][Hunger] %s m=%s spd=%.2f m/s dt=%.1fs dist=%.1fm time=+%.2f dist=+%.2f graze=%.2f mul=%.2f total=+%.2f → %d→%d (sated %.0fs)")
                        :format(state, mounted and "1" or "0", speed, dt, distM, timeDrain, distDrain, graze, mul,
                            totalDrain,
                            math.floor(before), math.floor(after), remS))
                end
            end
        end

        -- consume this tick's distance so next tick doesn't double-count
        S.dist = 0
    end

    do
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
            CuraEqui.Buffs.SyncAll(h, S)
        end
    end

    do
        local D = CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud
        if D and D.enabled and CuraEqui.UI and CuraEqui.UI.Toast then
            local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
            local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h)
            if S then
                local now    = (Script and Script.GetTime and Script.GetTime()) or os.clock()
                local tier   = (CuraEqui.Buffs and CuraEqui.Buffs._pickTierName)
                    and CuraEqui.Buffs._pickTierName(tonumber(S.hunger or 0) or 0, S.satedUntil) or "?"
                local line   = string.format("Horse: %d%% · Sated %.0fs · %s",
                    math.floor(tonumber(S.hunger or 0) or 0),
                    math.max(0, (tonumber(S.satedUntil or 0) or 0) - now),
                    tier)

                S._hudNextAt = S._hudNextAt or 0
                if now >= S._hudNextAt then
                    CuraEqui.UI.Toast(line, D.refresh or 1200, 0, "CuraEqui_Status", D.lane or "notification")
                    S._hudNextAt = now + ((D.refresh or 1200) / 1000)
                end
            end
        end
    end

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
    if not ok then System.LogAlways("[CuraEqui][Tick][ERROR] " .. tostring(err)) end

    local hasHorse = (CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) and true or false
    if not hasHorse then
        CuraEqui._noHorseStrikes = (CuraEqui._noHorseStrikes or 0) + 1
    else
        CuraEqui._noHorseStrikes = 0
    end
    if (CuraEqui._noHorseStrikes or 0) >= 3 then
        CuraEqui.StopWatching()
        return CuraEqui.StartProbing()
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

-- Apply a consumed item’s nutrition to the tracked horse.
-- diet = { nutrition:number, token?:string, source?: "guid"|"token"|"keyword", guid?:string }
function CuraEqui._ApplyNutrition(diet, label)
    if not diet then return false end
    local n = tonumber(diet.nutrition) or 0
    if n <= 0 then return false end

    local horse = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    local S     = horse and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(horse)
    if not S then return false end

    -- 1) hunger drop
    local before = tonumber(S.hunger or 0) or 0
    local after  = math.max(0, before - n)
    S.hunger     = after

    -- 2) sated timing
    local H      = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
    local now    = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local perSec = tonumber(H.satedSecPerNutrition or 6) -- dial
    local capSec = tonumber(H.satedCapSec or 600)        -- dial
    local addSec = n * perSec
    local base   = math.max(now, tonumber(S.satedUntil or 0) or 0)
    S.satedUntil = math.min(base + addSec, now + capSec)

    -- 3) immediate buff refresh so the HUD flips right away
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
        pcall(CuraEqui.Buffs.SyncAll, horse, S)
    end

    -- 4) log (nil-safe)
    CuraEqui.Log("diet",
        "consume %s src=%s n=%d → hunger %d→%d | sated +%ds (cap %ds)",
        tostring(label or diet.token or "?"),
        tostring(diet.source or "?"),
        n, before, after, addSec, capSec
    )
    return true
end
