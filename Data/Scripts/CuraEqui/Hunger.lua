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
        local now = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
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

        local now   = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
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

-- Pause-aware gameplay clock (fallback if Utils.lua didn’t define it yet)
if not CuraEqui.Now then
    function CuraEqui.Now()
        if GetCurrTime then return GetCurrTime() end
        if System and System.GetCurrTime then return System.GetCurrTime() end
        if Calendar and Calendar.GetGameTime then return Calendar.GetGameTime() end
        return (Script and Script.GetTime and Script.GetTime()) or os.clock()
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

local function is_night()
    return (Calendar and Calendar.IsNightTimeOfDay and Calendar.IsNightTimeOfDay()) or false
end

local function graze_compute(S, mounted, idle, dt, H)
    -- H is (CuraEqui.Config.Hunger)
    local gP = tonumber(H.grazePerMinIdleUnmtd) or 0
    gP = -math.abs(gP) -- safety: grazing always recovers
    local gM = tonumber(H.grazeSatedMul) or 1.0

    local graze = ((not mounted) and idle) and (gP * (dt / 60.0) * gM) or 0

    -- Soft ramp / threshold
    do
        local ramp       = H.grazeRamp or {}
        local h          = tonumber(S.hunger or 0) or 0
        local h0         = tonumber(ramp.start or 0) or 0
        local h1         = tonumber(ramp.full or 0) or 0
        S._dbgGrazeRampK = nil
        if h1 > h0 then
            local t = (h - h0) / (h1 - h0)
            local k = math.max(0, math.min(1, t))
            graze = graze * k
            S._dbgGrazeRampK = k
        else
            local threshold = tonumber(H.grazeStartThreshold or 0) or 0
            if threshold > 0 and h < threshold then
                graze = 0
                S._dbgGrazeRampK = 0
            end
        end
    end

    -- Session cap
    local cap = tonumber(H.grazingPerSession or 0) or 0
    if cap > 0 then
        if mounted then
            S._grazeBudget = cap
            S._grazeCapLogged = nil
        elseif S._grazeBudget == nil then
            S._grazeBudget = cap
            S._grazeCapLogged = nil
        end
        if graze < 0 and (not mounted) and idle then
            local budget = tonumber(S._grazeBudget or 0) or 0
            if budget <= 0 then
                graze = 0
            else
                local maxRecover = math.min(budget, math.abs(graze))
                graze = -maxRecover
                S._grazeBudget = budget - maxRecover

                -- One-time log when budget runs out
                local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
                if cap > 0 and S._grazeBudget and S._grazeBudget <= 0 and not S._grazeCapLogged then
                    S._grazeCapLogged = true
                    if D and D.hungerTrace then
                        System.LogAlways("[CuraEqui][Hunger] grazing budget exhausted")
                    end
                end
            end
        end
    end

    return graze
end

local function apply_night_rules(S, passive, H)
    local NC    = H.night or {}
    local night = is_night()

    -- grazing off at night (handled by caller before)
    -- timeDrain mul handled by caller before

    if night and passive > 0 then
        local cap = tonumber(NC.maxDeltaPerNight or 0) or 0
        if cap > 0 then
            local remaining = math.max(0, cap - (S._nightAdded or 0))
            if remaining <= 0 then
                return 0
            else
                if passive > remaining then passive = remaining end
                S._nightAdded = (S._nightAdded or 0) + passive
            end
        end
    end
    return passive
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
    CuraEqui.Log("poll", "Probe started (waiting for horse…).")
end

function CuraEqui.StopProbing()
    if CuraEqui.state.probeTimer then Script.KillTimer(CuraEqui.state.probeTimer) end
    CuraEqui.state.probeTimer = nil
    CuraEqui.Log("poll", "Probe stopped.")
end

-- Apply a small hunger catch-up for "sleep/wait" time-skip (hour-based).
function CuraEqui.Hunger_CatchUpAfterSleep()
    System.LogAlways("[CuraEqui][Hunger][catchup] entered")

    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
    if not (h and S) then return end

    CuraEqui.state = CuraEqui.state or {}
    local st = CuraEqui.state

    -- 1) Determine minutes skipped (priority: explicit UI minutes → hour math → bail)
    local minutes = tonumber(st._skipMinutesPlanned or 0) or 0

    -- open close guard
    if minutes <= 0 then
        local startHour = st._sleepStartHour
        local endHour   = CuraEqui._get_player_hour() or st._prevHour
        if startHour and endHour then
            minutes = CuraEqui._minutes_between_hours(startHour, endHour)
        end
    end

    if not minutes or minutes <= 0.1 then
        System.LogAlways("[CuraEqui][CatchUp] minutes≈0 or missing → skip")
        return
    end

    -- 2) Clamp by config (cap total compensated time)
    local WCFG   = (CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.waitCatchup) or {}
    local maxMin = math.max(0, tonumber(WCFG.maxCatchupSec or (6 * 3600)) / 60.0) -- default ~6h
    if maxMin > 0 and minutes > maxMin then minutes = maxMin end

    -- Snapshot before
    local now       = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local beforeH   = tonumber(S.hunger or 0) or 0
    local remBefore = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

    -- 3) Reduce sated by the skipped time
    do
        local skippedS = minutes * 60.0
        if skippedS > 0 and remBefore > 0 then
            local newRem = math.max(0, remBefore - skippedS)
            S.satedUntil = (newRem > 0) and (now + newRem) or 0
        end
    end

    -- 4) Compose hunger delta per-minute (match tick semantics)
    local H          = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
    local NC         = H.night or {}
    local perMin     = tonumber(H.ratePerMinIdle) or 0       -- base idle drift
    local gPM        = tonumber(H.grazePerMinIdleUnmtd) or 0 -- idle grazing per minute
    local gMul       = tonumber(H.grazeSatedMul) or 1.0

    -- Night vs Day at wake (simple "now" context)
    local isNightNow = (Calendar and Calendar.IsNightTimeOfDay and Calendar.IsNightTimeOfDay()) or false

    -- Sated multiplier (same as tick)
    local now        = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local mul        = (((tonumber(S.satedUntil or 0) or 0) > now) and (tonumber(H.satedDrainMul) or 0.75)) or 1.0

    local timeMul    = isNightNow and (tonumber(NC.timeDrainMul) or 1.0) or 1.0
    local perMinute  = (perMin * timeMul)
    if not isNightNow then
        -- assume unmounted+idle during wait → allow day grazing
        perMinute = perMinute + (gPM * gMul)
    end

    local delta = (perMinute * minutes) * mul

    -- 5) Night cap enforcement (if gaining at night)
    if isNightNow and delta > 0 then
        local cap = tonumber(NC.maxDeltaPerNight or 0) or 0
        if cap > 0 then
            local used   = tonumber(S._nightAdded or 0) or 0
            local remain = math.max(0, cap - used)
            if delta > remain then delta = remain end
            S._nightAdded = used + math.max(0, delta)
        end
    end

    -- 6) Apply & sync
    local afterH = math.max(0, math.min(100, beforeH + delta))
    S.hunger     = afterH

    -- No force: only switches bucket or clears if needed. Won’t reset countdown.
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
        pcall(CuraEqui.Buffs.SyncSatedTimer, h, S) -- no force
    end

    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
        pcall(CuraEqui.Buffs.SyncAll, h, S)
    end

    -- 7) Persist (safe)
    if CuraEqui.Persist and CuraEqui.Persist.Save then
        pcall(CuraEqui.Persist.Save, S.hunger, S.satedUntil)
        if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
            local h   = math.floor(tonumber(S.hunger or 0) or 0)
            local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
            System.LogAlways(("[CuraEqui][Persist] Saved (sleep) hunger=%d satedRemain=%.0f"):format(h, rem))
        end
    end

    -- 8) Clear log
    local remAfter = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
    System.LogAlways(("[CuraEqui][CatchUp] minutes=%.1f sated=%d→%d hunger=%d→%d (Δ=%.2f)")
        :format(minutes, remBefore, remAfter, math.floor(beforeH), math.floor(afterH), delta))

    return minutes, delta, beforeH, afterH
end

-- ---------- TICK BODY (MAY THROW) ----------
function CuraEqui._HungerTickBody()
    CuraEqui.state = CuraEqui.state or {}
    local st       = CuraEqui.state
    local now      = (Calendar and Calendar.GetGameTime and Calendar.GetGameTime()) or 0

    local h        = (CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil

    if not h then
        -- log at most once every 5s while horseless
        if not st._noHorseLogAt or (now - st._noHorseLogAt) > 5.0 then
            System.LogAlways("[CuraEqui][Horse] Player does not have a horse — skipping hunger tick.")
            st._noHorseLogAt = now
        end
        return
    end

    ProbeOnce(h)

    local S = (CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h)) or nil

    -- Track player time every tick (for fallbacks & jump detection)
    do
        CuraEqui.state = CuraEqui.state or {}
        local nowHour = CuraEqui._get_player_hour()

        -- Pause-aware seconds: only advance when world hour advances
        do
            CuraEqui.Clock = CuraEqui.Clock or { t = 0, lastHour = nil }
            if nowHour then
                local C = CuraEqui.Clock
                if C.lastHour ~= nil then
                    local mins = CuraEqui._minutes_between_hours(C.lastHour, nowHour) or 0
                    if mins > 0 then C.t = (C.t or 0) + mins * 60 end
                end
                C.lastHour = nowHour
            end
        end

        if nowHour then
            -- optional safety net: detect large jumps between 10s ticks (e.g., Wait 1h+)
            local prev = CuraEqui.state._prevHour
            CuraEqui.state._prevHour = nowHour
            if prev then
                local minutes = CuraEqui._minutes_between_hours(prev, nowHour)

                -- disable timebased catchup logic
                local Hcfg = CuraEqui.Config and CuraEqui.Config.Hunger or {}
                local enableFallback = (Hcfg.EnableFallbackCatchUp == true)

                if enableFallback and minutes > 2.0 and not (CuraEqui.state and CuraEqui.state._skipSessionOpen) then
                    -- UI events didn’t arrive: run catch-up using prev as start
                    CuraEqui.state._sleepStartHour = CuraEqui.state._sleepStartHour or prev
                    System.LogAlways(("[CuraEqui][SkipTime][fallback] jump %.1f min → catch-up"):format(minutes))
                    if CuraEqui.Hunger_CatchUpAfterSleep then pcall(CuraEqui.Hunger_CatchUpAfterSleep) end
                    CuraEqui.state._sleepStartHour = nil
                end
            end
        end
    end

    do
        local st = CuraEqui.state
        if st and st._skipSessionOpen and st._sleepNeedSeed and st._prevHour then
            st._sleepStartHour = st._prevHour
            st._sleepNeedSeed  = false
            System.LogAlways(("[CuraEqui][SkipTime] OPEN (late) → mark hour=%.2f"):format(st._sleepStartHour))
        end
    end

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

        -- NIGHT STATE (detect + reset per-night accumulator at dusk/dawn)

        local HcfgAll = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}

        -- Night state flip (keep your counters)
        local night   = is_night()
        S._wasNight   = S._wasNight or false
        S._nightAdded = S._nightAdded or 0
        if night ~= S._wasNight then
            S._nightAdded     = 0;
            S._wasNight       = night
            -- also reset graze session at dusk/dawn
            S._grazeBudget    = tonumber(HcfgAll.grazingPerSession or 0) or 0
            S._grazeCapLogged = nil
        end

        -- Time drain (idle/mounted) + per-km drain
        local timeBase  = ((idle and C.rateIdle) or C.rateMounted) * (dt / 60.0)
        local distDrain = (mounted and not idle) and (C.rateKmMounted * (distM / 1000.0)) or 0

        -- Night time mul
        local timeMul   = night and (tonumber((HcfgAll.night or {}).timeDrainMul) or 1.0) or 1.0
        local timeDrain = timeBase * timeMul

        -- Grazing (may ramp & cap)
        local graze     = graze_compute(S, mounted, idle, dt, HcfgAll)

        -- Night: optionally disable grazing
        if night and ((HcfgAll.night or {}).disableGrazing ~= false) then
            graze = 0
        end

        -- Sated multiplier (by design, only drains)
        local now        = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
        local mul        = (((tonumber(S.satedUntil or 0) or 0) > now) and C.satedMul) or 1.0

        local passive    = (timeDrain * mul) + graze
        local active     = (distDrain * mul)

        -- Night cap for passive gain
        passive          = apply_night_rules(S, passive, HcfgAll)

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

        -- Compute a simple "minutes until cap exhausted" estimate
        local minsLeft   = nil
        do
            local capLocal = tonumber(HcfgAll.grazingPerSession or 0) or 0
            local NC       = HcfgAll.night or {}
            if capLocal > 0 and (not mounted) and idle and (not (night and (NC.disableGrazing ~= false))) then
                local gPerMin   = math.abs((tonumber(HcfgAll.grazePerMinIdleUnmtd) or 0) *
                    (tonumber(HcfgAll.grazeSatedMul) or 1.0))
                local kEff      = tonumber(S._dbgGrazeRampK or 1.0) or 1.0
                local effPerMin = gPerMin * kEff
                local budget    = tonumber(S._grazeBudget or 0) or 0
                if effPerMin > 0 and budget > 0 then
                    minsLeft = budget / effPerMin
                end
            end
        end

        -- Extend ginfo
        local ginfo = ""
        do
            local capLocal = tonumber(HcfgAll.grazingPerSession or 0) or 0
            local NC       = HcfgAll.night or {}
            local budget   = tonumber(S._grazeBudget or 0) or 0
            local k        = tonumber(S._dbgGrazeRampK or 1.0) or 1.0
            if night and (NC.disableGrazing ~= false) then
                ginfo = " (night-off)"
            elseif capLocal > 0 then
                if budget <= 0 and (not mounted) and idle then
                    ginfo = " (cap exhausted)"
                elseif minsLeft then
                    ginfo = string.format(" (cap=%d, ~%dm)", budget, math.max(0, math.floor(minsLeft + 0.5)))
                else
                    ginfo = string.format(" (cap=%d)", budget)
                end
            elseif k < 0.999 then
                ginfo = string.format(" (ramp=%.2f)", k)
            end
        end

        -- dev console trace (compact)
        do
            local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
            local U = CuraEqui.Utils
            if D.hungerTrace and U and U.throttle("hunger-trace", U.ms_to_s(D.hungerTraceEvery or 5000)) then
                local state = idle and "idle" or "mounted"
                local remS  = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

                System.LogAlways(("[CuraEqui][Hunger] %s m=%s spd=%.2f m/s dt=%.1fs dist=%.1fm time=+%.2f dist=+%.2f graze=%.3f%s mul=%.2f total=+%.2f → %d→%d (sated %.0fs)")
                    :format(state, mounted and "1" or "0", speed, dt, distM, timeDrain, distDrain, graze, ginfo, mul,
                        totalDrain, math.floor(before), math.floor(after), remS))
            end
        end

        if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
            pcall(CuraEqui.Buffs.SyncSatedTimer, h, S) -- no force
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
            local now    = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
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

    -- apply the sated timed buff immediately on start
    do
        local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if h and S and CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
            pcall(CuraEqui.Buffs.SyncSatedTimer, h, S, { cause = "load", force = false })
            if CuraEqui.Buffs.SyncAll then pcall(CuraEqui.Buffs.SyncAll, h, S) end
        end
    end
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
                local now = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
                local h   = math.floor(tonumber(S.hunger or 0) or 0)
                local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                System.LogAlways(("[CuraEqui][Persist] Saved (stop) hunger=%d satedRemain=%.0f"):format(h, rem))
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
    local now    = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local perSec = tonumber(H.satedSecPerNutrition or 6) -- dial
    local capSec = tonumber(H.satedCapSec or 600)        -- dial
    local addSec = n * perSec
    local base   = math.max(now, tonumber(S.satedUntil or 0) or 0)
    S.satedUntil = math.min(base + addSec, now + capSec)

    -- Ceil to the next visible bucket so internal == buff duration
    do
        local now = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
        local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
        local BL  = CuraEqui.Buffs and CuraEqui.Buffs.SATED_TIERS
        if BL and #BL > 0 then
            local target = nil
            for i = #BL, 1, -1 do
                local sec = tonumber(BL[i].sec) or 0
                if sec >= rem then
                    target = sec; break
                end
            end
            if not target then target = tonumber(BL[1].sec) or rem end
            if target and target > 0 then
                S.satedUntil = now + target
            end
        end
    end
    -- then force-apply
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
        pcall(CuraEqui.Buffs.SyncSatedTimer, horse, S, { cause = "diet", force = true })
    end

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
