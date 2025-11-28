-- Scripts/CuraEqui/Core.lua
CuraEqui                        = CuraEqui or {}
CuraEqui.VERSION                = "0.2.0"
CuraEqui.state                  = CuraEqui.state or {
    hungerTimer              = nil,
    pausedForSleep           = false,
    started                  = false,

    -- (horse identity + probing/watch glue)
    hasHorse                 = false, -- single source of truth
    lastHorseId              = nil,   -- GUID we think we’re riding
    lastHorseEnt             = nil,
    probeTimer               = nil,   -- lazy probe timer id (horseless only)
    _noHorseLogAt            = 0,     -- rate-limit for “no horse” logs
    _revalNextAt             = 0,     -- next time we may revalidate identity
    _lastHorseSwapAt         = nil,   -- debounce for swaps

    -- (owned-horse tracking – not used yet)
    currentOwnedHorseId      = nil,   -- entity id / GUID of main owned horse
    currentOwnedHorseGuid    = nil,   -- strong GUID if available
    hasMountedOwnedHorseOnce = false, -- true after first mount of owned horse this session
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
    return CuraEqui.state and CuraEqui.state.hasHorse == true
end

-- Replace old ResolveHorse with this
function CuraEqui.ResolveHorse()
    local H = CuraEqui.Horse
    if not (H and H.Resolve) then return nil end

    local h = H.Resolve()
    if not h then return nil end

    -- If we have an ownership helper, enforce it here
    if CuraEqui.PlayerOwnsHorse then
        local ok, owns = pcall(CuraEqui.PlayerOwnsHorse, h)
        if ok and not owns then
            -- optional debug:
            -- System.LogAlways(("[CuraEqui][Horse] ResolveHorse→ non-owned id=%s → nil")
            --     :format(tostring(h.id)))
            return nil
        end
    end

    return h
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

function CuraEqui.DebugLogHorseIdentity(h, opts)
    local ST         = CuraEqui.state or {}
    local tag        = opts and opts.tag or "mount"

    local mountedId  = h and h.id or nil
    local mountedGid = nil
    if CuraEqui._HorseGuid and h then
        local ok, g = pcall(CuraEqui._HorseGuid, h)
        if ok then mountedGid = g end
    end

    -- What does our "official" resolver think the player horse is?
    local resolved    = nil
    local resolvedId  = nil
    local resolvedGid = nil
    if CuraEqui.ResolveHorse then
        local ok, rh = pcall(CuraEqui.ResolveHorse)
        if ok then
            resolved   = rh
            resolvedId = rh and rh.id or nil
            if CuraEqui._HorseGuid and rh then
                local ok2, g2 = pcall(CuraEqui._HorseGuid, rh)
                if ok2 then resolvedGid = g2 end
            end
        end
    end

    System.LogAlways(("[CuraEqui][OWNDBG][%s] mountedId=%s mountedGid=%s  "
            .. "resolvedId=%s resolvedGid=%s  sessionOwnedId=%s")
        :format(
            tag,
            tostring(mountedId),
            tostring(mountedGid),
            tostring(resolvedId),
            tostring(resolvedGid),
            tostring(ST.currentOwnedHorseId)
        ))
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
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnQuickLoadingStart", "OnQuickLoadingStart")
    CuraEqui.__eventsBound = true
end

-- Call this whenever we think gameplay (re)started or a save was loaded.
function CuraEqui.Bootstrap(reason)
    CuraEqui.Log("init", "Bootstrap (%s)", tostring(reason or ""))

    CuraEqui.state = CuraEqui.state or {}
    if reason == "ogs" then
        CuraEqui.state.loadingSave = true -- mark: this was called from OnGameplayStarted
    end

    -- 0) Always reopen DB for the new playline/save
    if CuraEqui.Persist and CuraEqui.Persist.Reopen then
        pcall(CuraEqui.Persist.Reopen)
    end

    pcall(function()
        if CuraEqui and CuraEqui.Buffs and CuraEqui.Buffs.SweepPlayerSatedEffects then
            CuraEqui.Buffs.SweepPlayerSatedEffects("bootstrap")
        end
    end)

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
    ST._giftedFor               = {}
    ST._giftedSessionId         = (ST._giftedSessionId or 0) + 1
    ST.noHorseStrikes           = 0
    ST.justLoaded               = true

    -- Owned-horse tracking (Step 5 – fields only, no behavior yet)
    ST.currentOwnedHorseId      = nil
    ST.currentOwnedHorseGuid    = nil
    ST.hasMountedOwnedHorseOnce = false

    CuraEqui.SetOwnedHorse(nil, { reason = "load-reset" })

    -- 5) Force a clean buff recompute (icons/state) next time we sync
    if CuraEqui.Buffs then
        CuraEqui.Buffs._lastPlayerUuid      = nil
        CuraEqui.Buffs._lastHorseDebuffUuid = nil
        CuraEqui.Buffs._syncBusy            = false
    end

    -- 6) FULL INIT (hydrates from DB, clears tiers, and starts probe/watcher)
    if CuraEqui.Initialize then pcall(CuraEqui.Initialize, true) end

    -- 7) Two-phase settle (each pass: clear → apply)
    if Script and Script.SetTimerForFunction then
        _G["CuraEqui_ResyncPass"] = function()
            xpcall(function()
                local h = CuraEqui.ResolveHorse()
                local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
                local B = CuraEqui.Buffs
                if not (h and S and B) then return end

                -- 🔒 NEW: do not resync on non-owned horses / cross-save ghosts
                if CuraEqui.PlayerOwnsHorse and not CuraEqui.PlayerOwnsHorse(h) then
                    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.buffTraceVerbose then
                        System.LogAlways("[CuraEqui][ResyncPass] abort - non-owned horse")
                    end
                    return
                end

                -- existing SyncSatedTimer / SyncAll calls stay as they were
                if B.SyncSatedTimer then
                    pcall(B.SyncSatedTimer, h, S, { cause = "resync-pass", force = true })
                end
                if B.SyncAll then
                    pcall(B.SyncAll, h, S)
                end
            end, debug.traceback)
        end
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
        local now = (CuraEqui.Now and CuraEqui.Now()) or 0
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
    local ST = CuraEqui.state
    local h  = CuraEqui.ResolveHorse and CuraEqui.ResolveHorse() or nil

    System.LogAlways(("[CuraEqui][Init] ResolveHorse→ id=%s hasHorseState=%s")
        :format(tostring(h and h.id or "nil"), tostring(ST.hasHorse)))

    -- ⚠️ IMPORTANT:
    -- Do *not* gate h by PlayerOwnsHorse here. Ownership scaffolding is
    -- not populated yet on load; the dedicated helper will decide.

    -- If we load into a save while already having an ownable horse present,
    -- try to arm ownership + hunger once for this session.
    if CuraEqui.TryInitOwnedHorseOnLoad then
        CuraEqui.TryInitOwnedHorseOnLoad()
    end

    -- DO NOT trust h ~= nil; horse entities exist even in horse-less saves
    -- Default: horse-less until proven otherwise
    ST.hasHorse = ST.hasHorse or false
    ST.lastHorseId = (h and CuraEqui._HorseGuid(h)) or ST.lastHorseId

    if not h then
        local now = (CuraEqui.Now and CuraEqui.Now()) or 0

        -- 1) Log the horse-less init clearly
        System.LogAlways("[CuraEqui][NoHorse] Initialize in horse-less save → flushing sated state")

        -- 2) Reset in-memory sated state
        ST.satedRemainSec = 0
        ST.satedUntil     = 0

        -- 🔥 Also reset any stray per-horse sated state
        local hAny        = CuraEqui.ResolveHorse and CuraEqui.ResolveHorse() or nil
        if hAny and CuraEqui.HorseStateGet then
            local S = CuraEqui.HorseStateGet(hAny)
            if S then
                S.satedUntil    = 0
                S._lastBuffTier = nil
            end
        end

        -- 3) Hard-clear any Sated buff on the player
        if CuraEqui.Effects and CuraEqui.Effects.ClearSatedTimers then
            System.LogAlways("[CuraEqui][NoHorse] ClearSatedTimers() (no-horse flush)")
            pcall(CuraEqui.Effects.ClearSatedTimers)
        end

        -- 5) Normal logging + probe restart
        if (now - (ST._noHorseLogAt or 0)) > 3.0 then
            System.LogAlways("[CuraEqui][Horse] No horse detected — hunger/buffs are idle until a horse is acquired.")
            ST._noHorseLogAt = now
        end

        if CuraEqui.StartProbing then
            CuraEqui.StartProbing()
        end

        return -- nothing else in Initialize should run in horse-less saves
    end

    ----------------------------------------------------------------
    -- NEW: now that `h` is final and confirmed owned → allow the
    -- "mounted on load" logic to arm ownership + hunger session.
    ----------------------------------------------------------------
    if CuraEqui.HorseOwnership and CuraEqui.HorseOwnership.TryInitOwnedHorseOnLoad then
        CuraEqui.HorseOwnership.TryInitOwnedHorseOnLoad()
    end

    -- 1) If we have a horse, hydrate ONLY hunger from DB.
    --    Sated is *never* re-applied from DB to avoid cross-save leakage.
    do
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        if S and CuraEqui.Persist and CuraEqui.Persist.Load then
            local ph, ps = CuraEqui.Persist.Load()
            if ph or ps then
                -- Clamp hunger into 0..100 if we got something
                if ph then
                    S.hunger = math.max(0, math.min(100, ph))
                end

                -- DO NOT use ps to seed S.satedUntil
                -- DO NOT call SyncSatedTimer here

                System.LogAlways(("[CuraEqui][Persist] Loaded hunger=%s sated=%s (sated ignored on load)")
                    :format(tostring(ph), tostring(ps)))

                local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
                if D and D.buffTraceVerbose then
                    System.LogAlways("[CE][LOAD] sated ignored on load (no buff reapply)")
                end

                -- Clear any lingering sated tiers just in case the engine carried them over
                if CuraEqui.Effects and CuraEqui.Effects.ClearSatedTimers then
                    pcall(CuraEqui.Effects.ClearSatedTimers)
                end

                CuraEqui.state.didInitialSatedApply = false
                CuraEqui.state.satedRemainSec       = 0
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
    if CuraEqui.state then CuraEqui.state._preloadFence = nil end
    CuraEqui.Bootstrap("ogs")
    CuraEqui.ValidateBuffGuids()

    -- Staggered horse resolve attempts: 0ms, 300ms, 1200ms
    local tries = { 0, 300, 1200 }

    local function try(i)
        local ST = CuraEqui.state or {}

        -- Always try to resolve a horse; on horseless saves this just returns nil.
        local h = CuraEqui.ResolveHorse and CuraEqui.ResolveHorse() or nil
        if not h then
            if i < #tries and Script and Script.SetTimer then
                Script.SetTimer(tries[i + 1], function() try(i + 1) end)
            end
            return
        end

        ST.hasHorse       = true
        ST.lastHorseEnt   = h
        ST.lastHorseId    = (CuraEqui._HorseGuid and CuraEqui._HorseGuid(h)) or h.id
        ST.lastHorseFpExt = (CuraEqui._HorseFpExt and CuraEqui._HorseFpExt(h)) or ""
        ST.lastHorseFp    = (CuraEqui._HorseFingerprint and CuraEqui._HorseFingerprint(h)) or ""

        System.LogAlways(("[CuraEqui][Horse] resolved on start id=%s name=%s")
            :format(tostring(h.id), (h.GetName and h:GetName()) or "Horse"))

        -- 🔑 One-shot “mounted on load” bridge
        if CuraEqui.HorseOwnership and CuraEqui.HorseOwnership.TryInitOwnedHorseOnLoad then
            CuraEqui.HorseOwnership.TryInitOwnedHorseOnLoad()
        end

        if CuraEqui.StopProbing then
            CuraEqui.StopProbing()
        end
    end

    try(1)

    -- Post-OGS settle: drop fence and (optionally) force a single apply ~400ms later
    Script.SetTimer(400, function()
        local ST = CuraEqui.state or {}
        ST._preloadFence = nil

        local h = CuraEqui.ResolveHorse and CuraEqui.ResolveHorse() or nil
        local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
        local B = CuraEqui.Buffs

        -- Only sync sated if horse is owned and fingerprint is seeded
        if h
            and CuraEqui.PlayerOwnsHorse
            and CuraEqui.PlayerOwnsHorse(h)
            and ST.lastHorseFp
            and B
            and B.SyncSatedTimer
        then
            pcall(B.SyncSatedTimer, h, S, { cause = "ogs-settle", force = true })
            if B.SyncAll then
                pcall(B.SyncAll, h, S)
            end
        end
    end)

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

function CuraEqui.OnQuickLoadingStart()
    System.LogAlways("[CuraEqui] OnQuickLoadingStart")
    local ST = CuraEqui.state or {}

    -- 🔥 HARD KILL: prevent inherited hunger timers from firing after load
    if ST.hungerTimer then
        Script.KillTimer(ST.hungerTimer)
        ST.hungerTimer = nil
        System.LogAlways("[CuraEqui][Fix] Killed inherited hunger timer on load start")
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

function CuraEqui._GiftOncePerHorse(h, horseKey, cause)
    -- TEMPORARILY DISABLED: welcome sated gift
    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if D and D.giftTrace then
        System.LogAlways("[CuraEqui][Gift] disabled in this build")
    end
    return
end

-- Gift a welcome sated once per horse GUID in this session.
-- function CuraEqui._GiftOncePerHorse(h, horseKey, cause)
--     -- Prevent gifts on game load or probing
--     if CuraEqui.state and CuraEqui.state.loadingSave then
--         if CuraEqui.Config.Debug.giftTrace then
--             System.LogAlways("[CuraEqui][Gift] skipped (loading save)")
--         end
--         return
--     end

--     if not (h and horseKey) then return end
--     local ST = CuraEqui.state or {}; ST._giftedFor = ST._giftedFor or {}
--     if ST._giftedFor[horseKey] then return end
--     ST._giftedFor[horseKey] = true

--     local giftSec =
--         (CuraEqui.Config and CuraEqui.Config.Hunger and
--             (CuraEqui.Config.Hunger.newHorseSatedSec or CuraEqui.Config.Hunger.welcomeSatedSec))
--         or 1200
--     giftSec = math.max(0, tonumber(giftSec) or 0)
--     if giftSec <= 0 then return end

--     local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
--     if not S then return end

--     -- Mark: this save now really has a horse
--     local ST = CuraEqui.state or {}
--     ST.hasHorse = true

--     -- Skip welcome gift if the horse is already sated (prevents double stacking)
--     local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
--     if tonumber(S.satedUntil or 0) > now then
--         return
--     end

--     local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
--     S.satedUntil = now + giftSec

--     -- Ceil to next visible tier so UI = timer
--     local T = CuraEqui.Buffs and CuraEqui.Buffs.SATED_TIERS
--     if T and #T > 0 then
--         local target = giftSec
--         for i = #T, 1, -1 do
--             local s = tonumber(T[i].sec) or 0
--             if s >= giftSec then
--                 target = s; break
--             end
--         end
--         S.satedUntil = now + (target or giftSec)
--     end

--     -- Apply cleanly
--     if CuraEqui.Buffs and CuraEqui.Buffs.ClearSated then pcall(CuraEqui.Buffs.ClearSated, h) end
--     if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
--         pcall(CuraEqui.Buffs.SyncSatedTimer, h, S, { cause = cause or "horse_gain", force = true })
--     end
--     if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then pcall(CuraEqui.Buffs.SyncAll, h, S) end
--     if CuraEqui.Persist and CuraEqui.Persist.Save then
--         pcall(CuraEqui.Persist.Save, S.hunger, S.satedUntil,
--             cause or "gift")
--     end

--     local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
--     if D and D.buffTraceVerbose then
--         System.LogAlways(("[CuraEqui][Gift] welcome sated %ds for key=%s (%s)")
--             :format(giftSec, horseKey, tostring(cause or "?")))
--     end
-- end

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
        pcall(CuraEqui.Buffs.ClearSatedTimers, "TeardownAll")
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

-- Called when the player mounts any horse (hooked from Horse.OnMount)
function CuraEqui.OnPlayerMountedHorse(horse)
    local C  = CuraEqui
    C.state  = C.state or {}
    local ST = C.state

    -- Route identity through ownership scaffolding (no behavior change)
    CuraEqui.SetOwnedHorse(horse, { reason = "mount" })
    -- NEW: Mark that we have mounted our owned horse at least once this session
    ST.hasMountedOwnedHorseOnce = true

    if CuraEqui.DebugLogHorseIdentity then
        CuraEqui.DebugLogHorseIdentity(h, { tag = "mount-external" })
    end


    local name = (horse and horse.GetName and horse:GetName()) or "?"
    System.LogAlways(("[CuraEqui][Horse] Player mounted horse id=%s name=%s → session hasHorse=true")
        :format(tostring(horse and horse.id or "nil"), tostring(name)))

    -- Stop probing, if it was running
    if C.StopProbing then
        C.StopProbing()
    end

    -- Start hunger watcher if not already running
    if C.StartWatching then
        C.StartWatching()
    end
end
