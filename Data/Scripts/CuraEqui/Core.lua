-- Scripts/CuraEqui/Core.lua
CuraEqui                        = CuraEqui or {}
CuraEqui.VERSION                = "0.2.0"
CuraEqui.state                  = CuraEqui.state or {
    hungerTimer      = nil,
    pausedForSleep   = false,
    started          = false,

    -- (horse identity + probing/watch glue)
    hasHorse         = false, -- single source of truth
    lastHorseId      = nil,   -- GUID we think we’re riding
    lastHorseEnt     = nil,
    _probeTimer      = nil,   -- lazy probe timer id (horseless only)
    _noHorseLogAt    = 0,     -- rate-limit for “no horse” logs
    _revalNextAt     = 0,     -- next time we may revalidate identity
    _lastHorseSwapAt = nil,   -- debounce for swaps
}
-- debounce + session flags
CuraEqui.state._skipLastInitAt  = 0
CuraEqui.state._skipSessionOpen = false

-- Use live config; fill only absolutely critical holes if mod loader races
local C                         = CuraEqui.Config or {}
C.Debug                         = C.Debug or
    { enabled = true, distanceTrace = false, hud = { enabled = false, refresh = 1200 } }
C.Hunger                        = C.Hunger or { hungerMax = 100, hungerStart = 30, tickSec = 10, debuffAt = 70 }
C.Diet                          = C.Diet or
    { strict = "guid+token", allowKeywordFallback = false, keywordNutrition = 10 }

-- Wire flags/tunables
CuraEqui.DEBUG                  = C.Debug.enabled
CuraEqui.DEBUG_DISTANCE         = C.Debug.distanceTrace
CuraEqui.DEBUG_DISTANCE_STEP    = C.Debug.distanceTraceStepM

-- Keep HorseCfg minimal (only what scheduler/clamp needs)
CuraEqui.HorseCfg               = {
    hungerMax   = C.Hunger.hungerMax,
    hungerStart = C.Hunger.hungerStart,
    tickSec     = C.Hunger.tickSec,
    debuffAt    = C.Hunger.debuffAt,
}

function CuraEqui.HasHorse()
    return CuraEqui.state.hasHorse == true
end

function CuraEqui.ResolveHorse()
    return (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
end

function CuraEqui._HorseGuid(ent)
    if not ent then return nil end

    -- Prefer engine GUID if present
    local guid = nil
    local ok, v = pcall(function() return ent.GetGUID and ent:GetGUID() end)
    if ok and v ~= nil then
        -- SmartScriptTable? numbers? tables? -> flatten to a stable string
        local t = type(v)
        if t == "string" or t == "number" then
            guid = tostring(v)
        elseif t == "table" or t == "userdata" then
            -- try common fields; fall back to tostring()
            local s = rawget(v, "value") or rawget(v, "id") or rawget(v, "guid")
            guid = tostring(s or v)
        else
            guid = tostring(v)
        end
    end

    -- Fallback to entity id (string) — also stable
    if not guid or guid == "" then guid = tostring(ent.id) end
    return guid
end

function CuraEqui._HorseName(ent)
    if not ent then return "" end
    local ok, v = pcall(function() return ent.GetName and ent:GetName() end)
    local name = (ok and v and v ~= "" and v) or ent.name or ""
    return tostring(name or "")
end

function CuraEqui._HorseClass(ent)
    if not ent then return "" end
    local cls = ent.class or ent.className or ""
    if (not cls or cls == "") and ent.GetClassName then
        local ok, v = pcall(function() return ent:GetClassName() end)
        if ok and v then cls = v end
    end
    return tostring(cls or "")
end

function CuraEqui._HorseFpExt(ent)
    if not ent then return "" end
    local nm   = CuraEqui._HorseName(ent)
    local cls  = CuraEqui._HorseClass(ent)
    local guid = (CuraEqui._HorseGuid and CuraEqui._HorseGuid(ent)) or ""
    local id   = tostring(ent.id or "")
    -- Prefer GUID; include id + name/class to make logs human-readable, but GUID drives uniqueness
    return table.concat({ guid, id, nm, cls }, "|")
end

function CuraEqui._HorseFingerprint(ent)
    -- Stable identity string independent of pointer/SmartScriptTable GUIDs.
    -- Use unique name primarily; add class + numeric id as extra spice.
    local name  = CuraEqui._HorseName(ent)
    local class = CuraEqui._HorseClass(ent)
    local id    = tostring(ent and ent.id or "")
    return table.concat({ name, class, id }, "|")
end

-- Call this after a save is loaded / gameplay starts.
function CuraEqui.EnsureBuffsResynced()
    local B = CuraEqui.Buffs
    local h = CuraEqui.ResolveHorse()
    local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
    if not (h and S and B and B.SyncAll) then return end

    -- hard clear everything we own (no-op if none)
    if B.RemoveAllOurs then
        pcall(B.RemoveAllOurs) -- if you have a convenience; else loop GUIDs
    else
        if B._ALL_HORSE_GUIDS then for _, gid in ipairs(B._ALL_HORSE_GUIDS) do pcall(B.Remove, "horse", gid) end end
        if B._ALL_PLAYER_GUIDS then for _, gid in ipairs(B._ALL_PLAYER_GUIDS) do pcall(B.Remove, "player", gid) end end
    end

    -- force recompute once
    S._lastBuffTier = nil

    -- schedule apply next tick (0 ms), and a second pass shortly after
    local function _apply()
        pcall(B.SyncAll, h, S, { hard = true })
    end
    Script.SetTimer(0, _apply)
    Script.SetTimer(150, _apply) -- catches HUDs that initialize a hair late
end

-- Time helpers (0..24 hours) — expose on CuraEqui to avoid scope issues across files
function CuraEqui._get_player_hour()
    local U = CuraEqui.Utils
    local p = (U and U.GetPlayer and U.GetPlayer())
        or (System and System.GetLocalPlayer and System.GetLocalPlayer())
        or (Game and Game.GetPlayer and Game.GetPlayer())
        or nil
    if p and p.GetTimeOfDayHour then
        local h = p:GetTimeOfDayHour()
        if type(h) == "number" and h >= 0 and h < 24 then return h end
    end
    return nil
end

function CuraEqui._minutes_between_hours(startHour, endHour)
    if not startHour or not endHour then return 0 end
    local d = endHour - startHour
    if d < 0 then d = d + 24 end -- wrap midnight
    return d * 60
end

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
    -- UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnSetFaderState", "OnSetFaderState")
    CuraEqui.__eventsBound = true
end

-- Call this whenever we think gameplay (re)started or a save was loaded.
function CuraEqui.Bootstrap(reason)
    CuraEqui.Log("init", "Bootstrap (%s)", tostring(reason or ""))

    -- 0) Always reopen DB for the new playline/save
    if CuraEqui.Persist and CuraEqui.Persist.Reopen then
        pcall(CuraEqui.Persist.Reopen)
    end

    -- 1) Hard teardown first
    CuraEqui.TeardownAll("bootstrap")

    -- 2) Create a short 'don’t-save' window immediately
    CuraEqui.state = CuraEqui.state or {}
    do
        local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
        CuraEqui.state.persistMuteUntil = now + 5.0
    end

    -- 3) TEARDOWN once: stop timers / watcher / probe
    local ST = CuraEqui.state
    if ST.hungerTimer then
        Script.KillTimer(ST.hungerTimer); ST.hungerTimer = nil
    end
    if ST.probeTimer then
        Script.KillTimer(ST.probeTimer); ST.probeTimer = nil
    end
    if CuraEqui.StopWatching then pcall(CuraEqui.StopWatching) end

    -- 4) RESET per-session mirrors/flags (single source of truth)
    ST._giftedFor       = {}
    ST._giftedSessionId = (ST._giftedSessionId or 0) + 1
    ST.noHorseStrikes   = 0
    ST.hasHorse         = false
    ST.lastHorseEnt     = nil
    ST.lastHorseId      = nil
    ST.lastHorseName    = nil
    ST.lastHorseFp      = nil
    ST.lastHorseFpExt   = nil
    ST.justLoaded       = true

    -- 5) Force a clean buff recompute (icons/state) next time we sync
    if CuraEqui.Buffs then
        CuraEqui.Buffs._lastPlayerUuid      = nil
        CuraEqui.Buffs._lastHorseDebuffUuid = nil
        CuraEqui.Buffs._syncBusy            = false
    end

    -- 6) FULL INIT (hydrates from DB, clears tiers, and starts probe/watcher)
    if CuraEqui.Initialize then pcall(CuraEqui.Initialize, true) end

    -- 7) Two-phase “settle” resync (HUD/souls race-proof)
    if Script and Script.SetTimerForFunction then
        _G["CuraEqui_Resync0"] = function()
            xpcall(function()
                local h = CuraEqui.ResolveHorse()
                local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
                local B = CuraEqui.Buffs
                if h and S and B then
                    if B.SyncSatedTimer then B.SyncSatedTimer(h, S, { cause = "bootstrap", force = false }) end
                    if B.SyncHorseDebuff then B.SyncHorseDebuff(h, S, { cause = "bootstrap" }) end
                    if B.SyncAll then B.SyncAll(h, S) end
                end
            end, function(err) System.LogAlways("[CuraEqui][Resync0][ERROR] " .. tostring(err)) end)
        end
        Script.SetTimerForFunction(1, "CuraEqui_Resync0")
        Script.SetTimerForFunction(150, "CuraEqui_Resync0")
    end
end

-- Idempotent init that (re)starts polling
function CuraEqui.Initialize(fullInit)
    -- In Initialize(fullInit)
    do
        CuraEqui.state                    = CuraEqui.state or {}
        CuraEqui.state._giftedThisSession = nil
        CuraEqui.state.lastHorseId        = nil
        CuraEqui.state.lastHorseEnt       = nil
        CuraEqui.state.hasHorse           = false
    end

    -- Mute persistence for a short window during boot/load
    do
        CuraEqui.state = CuraEqui.state or {}
        local now = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
        CuraEqui.state.persistMuteUntil = now + 5.0 -- 5s grace on boot
    end

    if fullInit and CuraEqui.state.started then
        CuraEqui.Log("init", "Already initialized → skipping reload")
    else
        CuraEqui.state.started = true
    end

    -- Fallback: if we still have a sleep start timestamp, run catch-up once here.
    if CuraEqui.state and CuraEqui.state._sleepStartHour and CuraEqui.Hunger_CatchUpAfterSleep then
        local ok, minutes, delta, before, after = pcall(CuraEqui.Hunger_CatchUpAfterSleep)
        if ok and minutes and minutes > 0 then
            System.LogAlways(("[CuraEqui][Hunger][catchup] +%.1f min → Δ=%.2f → %d→%d")
                :format(minutes, delta or 0, math.floor(before or 0), math.floor(after or 0)))
        end
        CuraEqui.state._sleepStartHour = nil
    end

    -- Seed previous hour so SkipTime OPEN doesn't log "hour=nil"
    if not CuraEqui.state._prevHour then
        CuraEqui.state._prevHour = CuraEqui._get_player_hour()
    end

    -- seed the state and start probing if horseless
    local ST       = CuraEqui.state
    local h        = CuraEqui.ResolveHorse()

    ST.hasHorse    = (h ~= nil)
    ST.lastHorseId = (h and CuraEqui._HorseGuid(h)) or ST.lastHorseId

    if not h then
        local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
        if (now - (ST._noHorseLogAt or 0)) > 3.0 then
            System.LogAlways("[CuraEqui][Horse] No horse detected — hunger/buffs are idle until a horse is acquired.")
            ST._noHorseLogAt = now
        end
        if CuraEqui.StartProbing then CuraEqui.StartProbing() end
    end

    -- 1) If we have a horse, hydrate hunger/sated from DB first
    do
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if S and CuraEqui.Persist and CuraEqui.Persist.Load then
            local ph, ps = CuraEqui.Persist.Load()
            if ph or ps then
                if ph then S.hunger = math.max(0, math.min(100, ph)) end
                if ps then S.satedUntil = tonumber(ps) or 0 end

                -- 1) Hard wipe ALL player sated tiers (belts & suspenders against engine residue)
                if CuraEqui.Effects and CuraEqui.Effects.ClearSatedTimers then
                    pcall(CuraEqui.Effects.ClearSatedTimers) -- this must remove every known sated UUID
                end

                S._lastBuffTier = nil

                System.LogAlways(("[CuraEqui][Persist] Loaded hunger=%s sated=%s"):format(tostring(ph), tostring(ps)))

                local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
                if D and D.buffTraceVerbose then
                    System.LogAlways("[CE][LOAD] clear: horse debuffs, player sated tiers")
                end

                -- clean slate → apply exactly one sated tier for S.satedUntil, then status
                pcall(CuraEqui.Effects.ClearHorseDebuffs, h) -- one-off horse strip clear
                pcall(CuraEqui.Buffs.ClearSatedTimers)       -- ← removes all sated timers (player)

                if D and D.buffTraceVerbose then
                    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
                    local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                    System.LogAlways(("[CE][LOAD] apply: sated player (rem≈%ds)"):format(rem))
                end

                -- 2) Apply exactly one sated bucket based on persisted remain
                if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
                    -- 'force=true' prevents "mid-run skip" and bypasses the reentry fence
                    pcall(CuraEqui.Buffs.SyncSatedTimer, h, S, { cause = "load-apply", force = true })
                end

                -- 3) Mark that we seeded sated on load so StartWatching won't re-touch it
                CuraEqui.state.didInitialSatedApply = true

                -- 4) Defer status (horse hunger) icon to the first tick for stability
                local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
                CuraEqui.state.deferStatusUntilTick = now + 0.2 -- ~1 tick; cosmetic

                CuraEqui.state.suppressStatusUntil = ((CuraEqui.Now and CuraEqui.Now()) or os.clock()) + 0.5

                do
                    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
                    local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                    System.LogAlways(("[CuraEqui][LoadApply] post-apply satedRemain=%.0fs"):format(rem))
                end
            end
        end
    end
end

-- ===========================================================================
-- System fader listener (fallback / parallel to element listener)
-- Registered with:
--   UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnSetFaderState", "OnSetFaderState")
-- ===========================================================================
function CuraEqui.OnSetFaderState(elementName, instanceId, eventName, argTable)
    local Dbg = (CuraEqui.Config and CuraEqui.Config.Debug) or {}
    if Dbg.skipTraceVerbose then
        System.LogAlways(("[CuraEqui][Fader] %s %s a1=%s a2=%s")
            :format(tostring(elementName), tostring(eventName),
                tostring(argTable and argTable[1] or "nil"),
                tostring(argTable and argTable[2] or "nil")))
    end

    local a1        = argTable and tostring(argTable[1]) or "nil"
    local a2        = argTable and tostring(argTable[2]) or "nil"

    -- phase words sometimes carried in args
    local phaseWord = (a1 == "sleep" or a1 == "wait") and a1
        or (a2 == "sleep" or a2 == "wait") and a2
        or ""

    -- treat explicit sleep/wait fader, or plain OnShow as entry
    local isEntry   =
        (eventName == "OnShow") or
        (eventName == "OnSetFaderState" and phaseWord ~= "")

    -- treat OnHide or arg-carried hide as exit
    local isExit    =
        (eventName == "OnHide") or
        (eventName == "OnSetFaderState" and (a1 == "OnHide" or a2 == "OnHide" or a1 == "hide" or a2 == "hide"))

    CuraEqui.state  = CuraEqui.state or {}
    local st        = CuraEqui.state

    -- OPEN on first seen event (robust even if no OnShow)

    if isEntry and not st._skipSessionOpen then
        st._skipSessionOpen    = true
        st._skipHandled        = false
        st._skipMinutesPlanned = nil

        local hourNow          = CuraEqui._get_player_hour() or st._prevHour
        if hourNow then
            st._sleepStartHour = hourNow

            if Dbg.skipTrace then
                System.LogAlways(("[CuraEqui][SkipTime] OPEN hour=%.2f"):format(hourNow))
            end
        else
            st._sleepStartHour = nil
            st._sleepNeedSeed  = true

            if Dbg.skipTrace then
                System.LogAlways("[CuraEqui][SkipTime] OPEN hour=deferred")
            end
        end

        if CuraEqui.StopWatching then pcall(CuraEqui.StopWatching) end
    end

    -- CLOSE (one-shot)
    if isExit and st._skipSessionOpen and not st._skipHandled then
        do
            local st = CuraEqui.state or {}
            if st._skipSessionOpen and not st._skipHandled then
                st._skipHandled = true

                if Dbg.skipTrace then
                    local startHour = st._sleepStartHour
                    local endHour   = CuraEqui._get_player_hour() or st._prevHour
                    local planned   = tonumber(st._skipMinutesPlanned or 0) or 0
                    local mins      = planned > 0 and planned
                        or (startHour and endHour and CuraEqui._minutes_between_hours(startHour, endHour))
                        or 0
                    System.LogAlways(("[CuraEqui][SkipTime] CLOSE minutes=%d (planned=%d, start=%.2f, end=%.2f) → catch-up")
                        :format(math.floor(mins or 0), math.floor(planned or 0), tonumber(startHour or -1),
                            tonumber(endHour or -1)))
                end
                if CuraEqui.Hunger_CatchUpAfterSleep then pcall(CuraEqui.Hunger_CatchUpAfterSleep) end

                -- refresh HUD/buffs
                local h = CuraEqui.ResolveHorse()
                local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
                if h and S and CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
                    S._lastBuffTier = nil
                    pcall(CuraEqui.Buffs.SyncAll, h, S)
                end

                -- only restart the periodic watcher (no DB reload)
                if CuraEqui.StartWatching then pcall(CuraEqui.StartWatching) end

                st._sleepStartHour     = nil
                st._skipMinutesPlanned = nil
                st._skipSessionOpen    = false
            end
        end
    end
end

-- ===========================================================================
-- SkipTime (element) listener
-- Registered with:
--   UIAction.RegisterElementListener(CuraEqui, "SkipTime", -1, "", "onSkipTimeEvent")
-- ===========================================================================
function CuraEqui:onSkipTimeEvent(elementName, instanceId, eventName, argTable)
    local Dbg = (CuraEqui.Config and CuraEqui.Config.Debug) or {}
    if Dbg.skipTraceVerbose then
        System.LogAlways(("[CuraEqui][Fader] %s %s a1=%s a2=%s")
            :format(tostring(elementName), tostring(eventName),
                tostring(argTable and argTable[1] or "nil"),
                tostring(argTable and argTable[2] or "nil")))
    end

    -- noisy trace so we see what this build emits
    local a1 = argTable and tostring(argTable[1]) or "nil"
    local a2 = argTable and tostring(argTable[2]) or "nil"

    -- Capture planned hours e.g. OnConfirm a1=3 → 180 minutes
    local plannedHours = tonumber(argTable and argTable[1]) or nil
    if eventName == "OnConfirm" and plannedHours and plannedHours > 0 then
        CuraEqui.state._skipMinutesPlanned = math.floor(plannedHours * 60 + 0.5)

        if Dbg.skipTrace then
            System.LogAlways(("[CuraEqui][SkipTime] PLAN minutes=%d"):format(CuraEqui.state._skipMinutesPlanned))
        end
    end

    -- normalize phase words some skins send via args
    local phaseWord = (a1 == "sleep" or a1 == "wait") and a1
        or (a2 == "sleep" or a2 == "wait") and a2
        or ""

    -- exit signals we accept on this bus
    local isExit =
        (eventName == "OnHide") or
        (eventName == "OnSetFaderState" and (a1 == "OnHide" or a2 == "OnHide" or a1 == "hide" or a2 == "hide")) or
        (eventName == "OnUnload") or
        (eventName == "OnDispose") or
        (eventName == "OnClose") or
        (eventName == "OnHideComplete")

    -- ---------------------------
    -- OPEN (first sight of SkipTime)
    -- ---------------------------

    CuraEqui.state = CuraEqui.state or {}
    local st = CuraEqui.state

    -- OPEN on first seen event (robust even if no OnShow)
    if not st._skipSessionOpen then
        st._skipSessionOpen    = true
        st._skipHandled        = false
        st._skipMinutesPlanned = nil

        local hourNow          = CuraEqui._get_player_hour() or st._prevHour
        if hourNow then
            st._sleepStartHour = hourNow

            if Dbg.skipTrace then
                System.LogAlways(("[CuraEqui][SkipTime] OPEN hour=%.2f"):format(hourNow))
            end
        else
            st._sleepStartHour = nil
            st._sleepNeedSeed  = true

            if Dbg.skipTrace then
                System.LogAlways("[CuraEqui][SkipTime] OPEN hour=deferred")
            end
        end

        if CuraEqui.StopWatching then pcall(CuraEqui.StopWatching) end
    end

    -- ---------------------------
    -- CLOSE (one-shot)
    -- ---------------------------
    if isExit and st._skipSessionOpen and not st._skipHandled then
        do
            local st = CuraEqui.state or {}
            if st._skipSessionOpen and not st._skipHandled then
                st._skipHandled = true

                if Dbg.skipTrace then
                    local startHour = st._sleepStartHour
                    local endHour   = CuraEqui._get_player_hour() or st._prevHour
                    local planned   = tonumber(st._skipMinutesPlanned or 0) or 0
                    local mins      = planned > 0 and planned
                        or (startHour and endHour and CuraEqui._minutes_between_hours(startHour, endHour))
                        or 0
                    System.LogAlways(("[CuraEqui][SkipTime] CLOSE minutes=%d (planned=%d, start=%.2f, end=%.2f) → catch-up")
                        :format(math.floor(mins or 0), math.floor(planned or 0), tonumber(startHour or -1),
                            tonumber(endHour or -1)))
                end
                if CuraEqui.Hunger_CatchUpAfterSleep then pcall(CuraEqui.Hunger_CatchUpAfterSleep) end

                -- refresh HUD/buffs
                local h = CuraEqui.ResolveHorse()
                local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
                if h and S and CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
                    S._lastBuffTier = nil
                    pcall(CuraEqui.Buffs.SyncAll, h, S)
                end

                -- only restart the periodic watcher (no DB reload)
                if CuraEqui.StartWatching then pcall(CuraEqui.StartWatching) end

                st._sleepStartHour     = nil
                st._skipSessionOpen    = false
                st._skipMinutesPlanned = nil
            end
        end
    end
end

-- Gameplay start entry
function CuraEqui.OnGameplayStarted()
    System.LogAlways("[CuraEqui] OnGameplayStarted")
    -- Always treat OGS as a fresh runtime session
    CuraEqui.Bootstrap("ogs")
    CuraEqui.ValidateBuffGuids()
    --CuraEqui.Initialize(true)

    -- Staggered horse resolve attempts: 0ms, 300ms, 1200ms
    local tries = { 0, 300, 1200 }
    local function try(i)
        local h = CuraEqui.ResolveHorse()
        if h then
            System.LogAlways(("[CuraEqui][Horse] resolved on start id=%s name=%s")
                :format(tostring(h.id), (h.GetName and h:GetName()) or "Horse"))

            CuraEqui.state.lastHorseFpExt = (CuraEqui._HorseFpExt and CuraEqui._HorseFpExt(h)) or ""


            -- Seed the fingerprint so the first tick doesn't look like a swap
            CuraEqui.state.lastHorseFp = (CuraEqui._HorseFingerprint and CuraEqui._HorseFingerprint(h)) or ""
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

    if UIAction and UIAction.RegisterEventSystemListener and not CuraEqui.__eventsBound then
        UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnSetFaderState", "OnSetFaderState")
        CuraEqui.__eventsBound = true
    end

    if UIAction and UIAction.RegisterElementListener and not CuraEqui.__skipBound then
        UIAction.RegisterElementListener(CuraEqui, "SkipTime", -1, "", "onSkipTimeEvent")
        CuraEqui.__skipBound = true
        System.LogAlways("[CuraEqui] Bound SkipTime element listener")
    end
end

function CuraEqui.RevalidateHorseIdentity(now)
    local ST = CuraEqui.state or {}
    local h  = CuraEqui.ResolveHorse and CuraEqui.ResolveHorse() or nil
    if not h then
        ST.hasHorse = false; return
    end

    if now < (ST._revalNextAt or 0) then return end
    ST._revalNextAt = now + 2.0

    local curFp     = (CuraEqui._HorseFingerprint and CuraEqui._HorseFingerprint(h)) or ""
    local curFpExt  = (CuraEqui._HorseFpExt and CuraEqui._HorseFpExt(h)) or ""

    if ST.lastHorseFp == curFp then
        ST.hasHorse     = true
        ST.lastHorseEnt = h
        local D         = CuraEqui.Config and CuraEqui.Config.Debug or {}
        if D.buffTraceVerbose and (not ST._fpTraceNext or now >= ST._fpTraceNext) then
            System.LogAlways(("[CuraEqui][HorseId] same fp=%s"):format(curFp))
            ST._fpTraceNext = now + 3.0
        end
        return
    end

    -- NEW horse detected
    ST.hasHorse       = true
    ST.lastHorseEnt   = h
    ST.lastHorseFp    = curFp
    ST.lastHorseFpExt = curFpExt

    local D           = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if D.buffTraceVerbose then
        System.LogAlways(("[CuraEqui][HorseId] swap %s → %s"):format(tostring(ST.lastHorseFpExt or "∅"), curFp))
    end
end

-- Gift a welcome sated once per horse GUID in this session.
function CuraEqui._GiftOncePerHorse(h, horseKey, cause)
    if not (h and horseKey) then return end
    local ST = CuraEqui.state or {}; ST._giftedFor = ST._giftedFor or {}
    if ST._giftedFor[horseKey] then return end
    ST._giftedFor[horseKey] = true

    local giftSec =
        (CuraEqui.Config and CuraEqui.Config.Hunger and
            (CuraEqui.Config.Hunger.newHorseSatedSec or CuraEqui.Config.Hunger.welcomeSatedSec))
        or 1200
    giftSec = math.max(0, tonumber(giftSec) or 0)
    if giftSec <= 0 then return end

    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
    if not S then return end

    -- Skip welcome gift if the horse is already sated (prevents double stacking)
    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
    if tonumber(S.satedUntil or 0) > now then
        return
    end

    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
    S.satedUntil = now + giftSec

    -- Ceil to next visible tier so UI = timer
    local T = CuraEqui.Buffs and CuraEqui.Buffs.SATED_TIERS
    if T and #T > 0 then
        local target = giftSec
        for i = #T, 1, -1 do
            local s = tonumber(T[i].sec) or 0
            if s >= giftSec then
                target = s; break
            end
        end
        S.satedUntil = now + (target or giftSec)
    end

    -- Apply cleanly
    if CuraEqui.Buffs and CuraEqui.Buffs.ClearSated then pcall(CuraEqui.Buffs.ClearSated, h) end
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
        pcall(CuraEqui.Buffs.SyncSatedTimer, h, S, { cause = cause or "horse_gain", force = true })
    end
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then pcall(CuraEqui.Buffs.SyncAll, h, S) end
    if CuraEqui.Persist and CuraEqui.Persist.Save then
        pcall(CuraEqui.Persist.Save, S.hunger, S.satedUntil,
            cause or "gift")
    end

    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if D and D.buffTraceVerbose then
        System.LogAlways(("[CuraEqui][Gift] welcome sated %ds for key=%s (%s)")
            :format(giftSec, horseKey, tostring(cause or "?")))
    end
end

function CuraEqui.TeardownAll(reason)
    local ST = CuraEqui.state or {}
    -- Kill timers
    if ST.hungerTimer then
        Script.KillTimer(ST.hungerTimer); ST.hungerTimer = nil
    end
    if ST.probeTimer then
        Script.KillTimer(ST.probeTimer); ST.probeTimer = nil
    end

    -- Unregister any UI listeners you installed (map, fader, item selection…)
    -- (Only if you registered them via UIAction.RegisterElementListener earlier)
    if UIAction and CuraEqui._uiRegs then
        for _, reg in ipairs(CuraEqui._uiRegs) do
            pcall(UIAction.UnregisterElementListener, table.unpack(reg))
        end
        CuraEqui._uiRegs = nil
    end

    -- Nuke all our tier buffs defensively (player sated tiers + horse debuffs)
    if CuraEqui.Buffs and CuraEqui.Buffs.ClearSatedTimers then
        pcall(CuraEqui.Buffs.ClearSatedTimers)
    end
    if CuraEqui.Buffs and CuraEqui.Buffs.ClearHorseDebuffs then
        local h = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
        pcall(CuraEqui.Buffs.ClearHorseDebuffs, h)
    end

    -- Reset “last applied” sentinels so Sync won’t skip
    if CuraEqui.Buffs then
        CuraEqui.Buffs._lastPlayerUuid      = nil
        CuraEqui.Buffs._lastHorseDebuffUuid = nil
    end
end
