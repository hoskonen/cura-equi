-- Scripts/CuraEqui/Hunger.lua
local function Q(...) CuraEqui.Log("Horse", ...) end
-- Fallbacks so throttled logs/toasts work even if Utils.lua is missing pieces
CuraEqui.Utils = CuraEqui.Utils or {}
do
    local U = CuraEqui.Utils

    U.ms_to_s = U.ms_to_s or function(v)
        local n = tonumber(v or 0) or 0
        if n <= 60 then return math.max(0.1, n) end
        return math.max(0.1, n / 1000.0)
    end

    local _next = {}
    U.throttle = U.throttle or function(key, intervalSec)
        local now = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local t   = tonumber(intervalSec or 1) or 1
        local nxt = _next[key] or 0
        if now >= nxt then
            _next[key] = now + t; return true
        end
        return false
    end
end

do
    local U = CuraEqui.Utils
    U.hunger_label = U.hunger_label or function(hungerPct, satedUntil)
        local HUD   = CuraEqui.Config and CuraEqui.Config.HUD or {}
        local th    = HUD.thresholds or { minor = 20, moderate = 50, critical = 80 }
        local names = HUD.hungerNames or {
            ok = "OK",
            minor = "Mild",
            moderate = "Hungry",
            critical = "Starving",
            sated =
            "Sated"
        }

        local now   = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local rem   = math.max(0, (tonumber(satedUntil or 0) or 0) - now)
        if rem > 0 then return names.sated, "sated" end

        local h = tonumber(hungerPct or 0) or 0
        local tier = (h >= (th.critical or 80)) and "critical"
            or (h >= (th.moderate or 50)) and "moderate"
            or (h >= (th.minor or 20)) and "minor"
            or "ok"
        return names[tier] or tier, tier
    end
end

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

-- Apply a small hunger catch-up for "sleep/wait" time-skip.
function CuraEqui.Hunger_CatchUpAfterSleep()
    System.LogAlways("[CuraEqui][Hunger][catchup] entered")

    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
    if not S then return end

    -- Need a valid start & current world time-of-day (0..1)
    local startTOD = CuraEqui.state and CuraEqui.state._sleepStartTOD
    local nowTOD   = (Calendar and Calendar.GetTimeOfDay and Calendar.GetTimeOfDay()) or nil
    if not startTOD or not nowTOD then return end

    -- minutes elapsed in world time (wrap across midnight)
    local dFrac = nowTOD - startTOD
    if dFrac < 0 then dFrac = dFrac + 1.0 end
    local minutes = dFrac * 24.0 * 60.0
    if minutes <= 0.1 then return end

    -- Optional guardrails (configurable)
    local WCFG   = (CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.waitCatchup) or {}
    local maxMin = math.max(0, tonumber(WCFG.maxCatchupSec or (6 * 3600)) / 60.0) -- default cap ~6h
    if maxMin > 0 and minutes > maxMin then minutes = maxMin end

    -- Read dials
    local H          = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
    local NC         = H.night or {}
    local perMin     = (tonumber(H.ratePerMinIdle) or 0) -- time drain per minute (idle)
    local gPM        = (tonumber(H.grazePerMinIdleUnmtd) or 0)
    local gMul       = (tonumber(H.grazeSatedMul) or 1.0)

    -- Day vs Night now (approximation): we don’t slice here; keep it simple.
    local isNightNow = (Calendar and Calendar.IsNightTimeOfDay and Calendar.IsNightTimeOfDay()) or false

    -- Compose a per-minute delta:
    --   Night  : (perMin * nightTimeMul), grazing OFF
    --   Day    : (perMin) + grazing (scaled by sated mul)
    local timeMul    = isNightNow and (tonumber(NC.timeDrainMul) or 1.0) or 1.0
    local perMinute  = perMin * timeMul
    if not isNightNow then
        -- unmounted idle assumption during sleep
        perMinute = perMinute + (gPM * gMul)
    end

    -- total delta (points) across skipped minutes
    local delta = perMinute * minutes

    -- Night cap: if we woke up at night and delta is positive (getting hungrier), clamp by remaining cap.
    if isNightNow and delta > 0 then
        local cap = tonumber(NC.maxDeltaPerNight or 0) or 0
        if cap > 0 then
            local used = tonumber(S._nightAdded or 0) or 0
            local remain = math.max(0, cap - used)
            if delta > remain then delta = remain end
            S._nightAdded = used + math.max(0, delta)
        end
    end

    -- Apply
    local before = tonumber(S.hunger or 0) or 0
    local after  = math.max(0, math.min(100, before + delta))
    S.hunger     = after

    -- Keep buffs/UI coherent
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
        pcall(CuraEqui.Buffs.SyncAll, CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve(), S)
    end

    -- Persist immediately after sleep catch-up
    if CuraEqui.Persist and CuraEqui.Persist.Save then
        CuraEqui.Persist.Save(S.hunger, S.satedUntil)
        if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
            System.LogAlways(("[CuraEqui][Persist] Saved (sleep) hunger=%d sated=%s")
                :format(math.floor(tonumber(S.hunger or 0) or 0), tostring(S.satedUntil)))
        end
    end

    -- Optional quiet debug
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    if D and D.hungerTrace then
        System.LogAlways(("[CuraEqui][Hunger][catchup] +%.1f min → Δ=%.2f → %d→%d")
            :format(minutes, delta, math.floor(before), math.floor(after)))
    end

    return minutes, delta, before, after
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
            local tickS = (CuraEqui.HorseCfg and CuraEqui.HorseCfg.tickSec)
                or ((CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.tickSec) or 10)
            local d     = speed * tickS

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
        local timePerMin = (idle and C.rateIdle) or C.rateMounted
        local timeDrain  = timePerMin * (dt / 60.0)

        -- per-km only when mounted-moving
        local distDrain  = (mounted and not idle) and (C.rateKmMounted * (distM / 1000.0)) or 0

        -- NIGHT STATE (detect + reset per-night accumulator at dusk/dawn)
        local HcfgAll    = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
        local NC         = HcfgAll.night or {}
        local isNight    = (Calendar and Calendar.IsNightTimeOfDay and Calendar.IsNightTimeOfDay()) or false
        S._wasNight      = S._wasNight or false
        S._nightAdded    = S._nightAdded or 0

        if isNight and not S._wasNight then
            -- night just started
            S._nightAdded = 0
        elseif (not isNight) and S._wasNight then
            -- dawn
            S._nightAdded = 0
        end
        S._wasNight = isNight

        -- grazing recovery when unmounted & idle (negative reduces hunger)
        local gP    = tonumber(HcfgAll.grazePerMinIdleUnmtd) or 0
        gP          = -math.abs(gP) -- safety: grazing always recovers (negative delta)
        local gM    = tonumber(Hcfg.grazeSatedMul) or 1.0
        local graze = ((not mounted) and idle) and (gP * (dt / 60.0) * gM) or 0

        -- Optional: soft ramp by hunger
        do
            local ramp = HcfgAll.grazeRamp or {} -- e.g. { start=10, full=35 }
            local h    = tonumber(S.hunger or 0) or 0
            local h0   = tonumber(ramp.start or 0) or 0
            local h1   = tonumber(ramp.full or 0) or 0
            if h1 > h0 then
                local t = (h - h0) / (h1 - h0)
                local k = math.max(0, math.min(1, t))
                graze = graze * k
            else
                -- Or use a hard threshold instead:
                local threshold = tonumber(HcfgAll.grazeStartThreshold or 0) or 0
                if threshold > 0 and (tonumber(S.hunger or 0) or 0) < threshold then
                    graze = 0
                end
            end
        end

        -- Session cap
        local cap = tonumber(HcfgAll.grazeCapPerSession or 0) or 0
        if cap > 0 then
            if mounted then
                S._grazeBudget = cap -- reset budget on mount
            elseif S._grazeBudget == nil then
                S._grazeBudget = cap -- first unmounted idle tick
            end
            if graze < 0 and (not mounted) and idle then
                local budget = tonumber(S._grazeBudget or 0) or 0
                if budget <= 0 then
                    graze = 0
                else
                    local maxRecover = math.min(budget, math.abs(graze))
                    graze = -maxRecover
                    S._grazeBudget = budget - maxRecover
                end
            end
        end

        -- Night rules
        if isNight and (NC.disableGrazing ~= false) then
            graze = 0.0
        end
        local nightTimeMul = (isNight and (tonumber(NC.timeDrainMul) or 1.0) or 1.0)
        timeDrain          = timeDrain * nightTimeMul

        -- sated multiplier
        local now          = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local mul          = (((tonumber(S.satedUntil or 0) or 0) > now) and C.satedMul) or 1.0

        -- By design, sated does NOT change grazing by default → apply mul to drains only
        local passive      = (timeDrain * mul) + graze -- “just existing” at night
        local active       = (distDrain * mul)         -- movement penalty (never capped)

        if isNight and passive > 0 then
            local cap = tonumber(NC.maxDeltaPerNight or 0) or 0
            if cap > 0 then
                local remaining = math.max(0, cap - (S._nightAdded or 0))
                if remaining <= 0 then
                    if CuraEqui.Config.Debug and CuraEqui.Config.Debug.hungerTrace then
                        System.LogAlways("[CuraEqui][Hunger] night cap reached; passive gain suppressed")
                    end
                    passive = 0
                else
                    if passive > remaining then passive = remaining end
                    S._nightAdded = (S._nightAdded or 0) + passive
                end
            end
        end

        local totalDrain = passive + active

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
            local U = CuraEqui.Utils
            if D.hungerTrace and U and U.throttle("hunger-trace", U.ms_to_s(D.hungerTraceEvery or 5000)) then
                local state = idle and "idle" or "mounted"
                local remS  = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                System.LogAlways(("[CuraEqui][Hunger] %s m=%s spd=%.2f m/s dt=%.1fs dist=%.1fm time=+%.2f dist=+%.2f graze=%.2f mul=%.2f total=+%.2f → %d→%d (sated %.0fs)")
                    :format(state, mounted and "1" or "0", speed, dt, distM, timeDrain, distDrain, graze, mul,
                        totalDrain, math.floor(before), math.floor(after), remS))
            end
        end

        -- consume this tick's distance so next tick doesn't double-count
        S.dist = 0
    end

    do
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if not (h and S) then return end

        if CuraEqui.Buffs and CuraEqui.Buffs._pickTierName then
            local pick = CuraEqui.Buffs._pickTierName
            local tier = pick(tonumber(S.hunger or 0) or 0, S.satedUntil)

            -- Only re-sync when tier actually changes
            if tier ~= S._lastBuffTier then
                if CuraEqui.Buffs.SyncAll then pcall(CuraEqui.Buffs.SyncAll, h, S) end
                S._lastBuffTier = tier

                -- Optional: dev HUD/tutorial only on real change
                if CuraEqui.Debug and CuraEqui.Debug.MaybeResnapStamina then
                    CuraEqui.Debug.MaybeResnapStamina(h)
                end
                if CuraEqui.Debug and CuraEqui.Debug.ShowHorseStatsTutorial then
                    CuraEqui.Debug.ShowHorseStatsTutorial()
                end
            end
        end
    end

    do
        local DH = CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud
        if DH and DH.enabled and CuraEqui.UI and CuraEqui.UI.Toast and S then
            local preset = (CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.preset) or "custom"
            local U      = CuraEqui.Utils
            local h      = math.floor(tonumber(S.hunger or 0) or 0)
            local now    = (Script and Script.GetTime and Script.GetTime()) or os.clock()
            local rem    = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
            local pretty = (U and U.hunger_label) and select(1, U.hunger_label(h, S.satedUntil))
                or ((rem > 0) and "Sated" or "OK")
            local line   = string.format("Hunger %s (%d%%) · Sated %.0fs · %s", pretty, h, rem, preset)
            local r      = (U and U.ms_to_s and U.ms_to_s(DH.refresh or 1200)) or 1.2
            if U and U.throttle("hud-dev-toast", r) then
                CuraEqui.UI.Toast(line, r * 1000, 0, "CuraEqui_Status", DH.lane or "notification")
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

    -- Persist (throttled) after applying this tick
    do
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if S and CuraEqui.Persist and CuraEqui.Persist.MaybeSave then
            CuraEqui.Persist.MaybeSave(S.hunger, S.satedUntil, 1, 20) -- ≥1% or every 20s
        end
    end
end

-- ---------- TIMER WRAPPER (ALWAYS REARMS) ----------
function CuraEqui_HungerTick()
    do
        local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
        local U = CuraEqui.Utils
        if D.tickTrace and U and U.throttle("tick-fired", U.ms_to_s(D.hungerTraceEvery or 10000)) then
            System.LogAlways("[CuraEqui][Tick] fired")
        end
    end

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

    -- Safety save when watcher stops (eg, horse vanished, scene change)
    do
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if S and CuraEqui.Persist and CuraEqui.Persist.Save then
            CuraEqui.Persist.Save(S.hunger, S.satedUntil)
            if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
                System.LogAlways(("[CuraEqui][Persist] Saved (stop) hunger=%d sated=%s")
                    :format(math.floor(tonumber(S.hunger or 0) or 0), tostring(S.satedUntil)))
            end
        end
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
