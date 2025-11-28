CuraEqui                = CuraEqui or {}
CuraEqui.HorseOwnership = CuraEqui.HorseOwnership or {}

local HorseOwnership    = CuraEqui.HorseOwnership
local HorseList         = CuraEqui.HorseList or {}

-- Simple helper: check by Storm name via HorseList
function HorseOwnership.IsHorseStormNameOwnable(name)
    if not name then return false end
    name = tostring(name)

    -- Hard blocklist
    if HorseList.NeverOwned and HorseList.NeverOwned[name] then
        return false
    end

    -- Allowed list
    if HorseList.Ownable and HorseList.Ownable[name] then
        return true
    end

    return false
end

function CuraEqui.SetOwnedHorse(h, opts)
    CuraEqui.state = CuraEqui.state or {}
    local ST       = CuraEqui.state
    local C        = CuraEqui
    local D        = C.Config and C.Config.Debug or {}
    opts           = opts or {}

    local reason   = tostring(opts.reason or "?")

    ---------------------------------------------------------
    -- 1) CLEAR CASE: nil horse → forget identity and exit
    ---------------------------------------------------------
    if not h then
        local oldEnt                = ST.lastHorseEnt

        ST.hasHorse                 = false
        ST.lastHorseEnt             = nil
        ST.lastHorseId              = nil
        ST.lastHorseName            = nil
        ST.lastHorseFp              = nil
        ST.lastHorseFpExt           = nil
        ST.currentOwnedHorseId      = nil
        ST.currentOwnedHorseGuid    = nil
        ST.hasMountedOwnedHorseOnce = false
        ST._hungerLoadedFromDB      = nil

        -- Also clear any old debuffs on the previous horse entity
        if oldEnt and C.Effects and C.Effects.ClearHorseDebuffs then
            pcall(C.Effects.ClearHorseDebuffs, oldEnt) -- pcall: never hard-crash if Effects is missing  <https://www.lua.org/manual/5.1/manual.html#pdf-pcall>
        end

        C.Log("HorseId", "SetOwnedHorse[%s]: cleared identity", reason)
        return
    end

    ---------------------------------------------------------
    -- 2) OPTIONAL DEBUG: name snapshot BEFORE whitelist
    ---------------------------------------------------------
    local nm = C._HorseName and C._HorseName(h) or nil
    if D.horseIdentityTrace then
        System.LogAlways(("[CuraEqui][OWNDBG] _HorseName(h)=%s lastHorseName=%s"):
        format(
            tostring(nm or "nil"),
            tostring(ST.lastHorseName)
        ))
    end

    ---------------------------------------------------------
    -- 3) WHITELIST CHECK (use current horse name)
    ---------------------------------------------------------
    if nm and HorseOwnership.IsHorseStormNameOwnable then
        local ownable = HorseOwnership.IsHorseStormNameOwnable(nm)

        -- If this horse is NOT ownable, never treat it as the player's mount.
        if not ownable then
            -- FULL REJECTION: clear identity
            ST.hasHorse                 = false
            ST.lastHorseEnt             = nil
            ST.lastHorseId              = nil
            ST.lastHorseName            = nil
            ST.lastHorseFp              = nil
            ST.lastHorseFpExt           = nil
            ST.currentOwnedHorseId      = nil
            ST.currentOwnedHorseGuid    = nil
            ST.hasMountedOwnedHorseOnce = false
            ST._hungerLoadedFromDB      = nil

            -- Also wipe any existing CuraEqui debuffs from this horse
            if C.Effects and C.Effects.ClearHorseDebuffs then
                pcall(C.Effects.ClearHorseDebuffs, h)
            end

            C.Log("HorseId",
                "SetOwnedHorse[%s]: rejected non-ownable horse (%s)",
                reason, tostring(nm))

            return
        end
    end

    ---------------------------------------------------------
    -- 4) LAZY HUNGER HYDRATION – ONLY ONCE PER SESSION
    --    (only for accepted / ownable horses)
    ---------------------------------------------------------
    if not ST._hungerLoadedFromDB
        and C.Persist and C.Persist.Load
        and C.HorseStateGet then
        local S = C.HorseStateGet(h)
        if S then
            local ph, ps = C.Persist.Load()
            if ph ~= nil then
                -- clamp into 0..100 just in case
                S.hunger = math.max(0, math.min(100, ph))
            end

            ST._hungerLoadedFromDB = true

            C.Log("Persist",
                "Hydrated hunger on SetOwnedHorse[%s]: hunger=%s (sated ignored)",
                reason,
                tostring(ph))
        end
    end

    ---------------------------------------------------------
    -- 5) ACCEPT OWNABLE HORSE (original snapshot logic)
    ---------------------------------------------------------
    local gid                = (C._HorseGuid and C._HorseGuid(h)) or tostring(h.id)
    local fp                 = (C._HorseFingerprint and C._HorseFingerprint(h)) or ""
    local fpExt              = (C._HorseFpExt and C._HorseFpExt(h)) or ""

    ST.hasHorse              = true
    ST.lastHorseEnt          = h
    ST.lastHorseId           = gid
    ST.lastHorseName         = nm or ""
    ST.lastHorseFp           = fp
    ST.lastHorseFpExt        = fpExt

    ST.currentOwnedHorseId   = h.id -- raw entity id (fast path)
    ST.currentOwnedHorseGuid = gid  -- strong GUID / table/string

    if D.ownershipTrace then
        C.Log("HorseId",
            "Owned snapshot: currentOwnedHorseId=%s guid=%s",
            tostring(ST.currentOwnedHorseId),
            tostring(ST.currentOwnedHorseGuid))
    end
end

----------------------------------------------------------------
-- Does the player own *this* horse (or any horse if h==nil)?
----------------------------------------------------------------
function CuraEqui.PlayerOwnsHorse(h)
    local ST         = CuraEqui.state or {}
    CuraEqui.state   = ST

    -- Canonical ownership fields written by SetOwnedHorse
    local ownedEntId = ST.currentOwnedHorseId or ST.lastHorseId
    local ownedGuid  = ST.currentOwnedHorseGuid

    -- No ownership known at all
    if not (ownedEntId or ownedGuid) then
        return false
    end

    -- No specific horse → “player owns some horse”
    if not h then
        return true
    end

    -- 1) Fast path: entity id match
    local hid = h.id
    if hid and ownedEntId and hid == ownedEntId then
        return true
    end

    -- 2) Slow path: GUID match (if we have helper + stored guid)
    if ownedGuid and CuraEqui._HorseGuid then
        local ok, gid = pcall(CuraEqui._HorseGuid, h)
        if ok and gid and gid == ownedGuid then
            return true
        end
    end

    return false
end

-- Try to arm hunger + ownership when loading into a save
-- where the player already has an owned horse present.
-- Try to re-establish ownership + hunger if player loads while mounted
function CuraEqui.HorseOwnership.TryInitOwnedHorseOnLoad()
    local C  = CuraEqui
    C.state  = C.state or {}
    local ST = C.state

    ----------------------------------------------------------------
    -- 1) Only run once, and only directly after a load.
    ----------------------------------------------------------------
    if not ST.justLoaded then
        return
    end

    -- If we already had a proper mount this session, nothing to do.
    if ST.hasMountedOwnedHorseOnce then
        return
    end

    ----------------------------------------------------------------
    -- 2) Resolve the current horse (whatever the game thinks is active)
    ----------------------------------------------------------------
    local h = C.ResolveHorse and C.ResolveHorse() or nil
    if not h then
        return
    end

    ----------------------------------------------------------------
    -- 3) Whitelist check: only auto-own horses marked as ownable
    ----------------------------------------------------------------
    local nm = C._HorseName and C._HorseName(h) or nil
    if not nm then
        return
    end

    local ownable = false
    if C.HorseOwnership and C.HorseOwnership.IsHorseStormNameOwnable then
        ownable = C.HorseOwnership.IsHorseStormNameOwnable(nm)
    end
    if not ownable then
        -- e.g. dummyWanderer_horse_1, tsem_horse_7 → ignore
        return
    end

    ----------------------------------------------------------------
    -- 4) Treat this as the owned horse + mark "mounted once".
    ----------------------------------------------------------------
    if C.SetOwnedHorse then
        C.SetOwnedHorse(h, { reason = "load-mounted" })
    end

    ST.hasHorse                 = true
    ST.lastHorseEnt             = h
    ST.lastHorseId              = (C._HorseGuid and C._HorseGuid(h)) or h.id
    ST.hasMountedOwnedHorseOnce = true -- 🔑 unblocks StartWatching / HungerTick

    ----------------------------------------------------------------
    -- 5) Arm hunger watcher if not already running.
    ----------------------------------------------------------------
    if C.StartWatching then
        local ok, err = pcall(C.StartWatching)
        if not ok then
            C.Log("Hunger", "TryInitOwnedHorseOnLoad: StartWatching failed: %s", tostring(err))
        end
    end

    ST.justLoaded = false -- don’t run again this session
    local prettyName = (h.GetName and h:GetName()) or "Horse"
    System.LogAlways(("[CuraEqui][HorseOwn] mounted-on-load init for id=%s name=%s")
        :format(tostring(h.id), tostring(prettyName)))
end
