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
    -- CLEAR CASE: nil horse → forget identity
    ---------------------------------------------------------
    if not h then
        ST.hasHorse                 = false
        ST.lastHorseEnt             = nil
        ST.lastHorseId              = nil
        ST.lastHorseName            = nil
        ST.lastHorseFp              = nil
        ST.lastHorseFpExt           = nil

        ST.currentOwnedHorseId      = nil
        ST.currentOwnedHorseGuid    = nil
        ST.hasMountedOwnedHorseOnce = false

        if D.ownershipTrace then
            C.Log("HorseId",
                "SetOwnedHorse[%s]: id=%s fpExt=%s name=%s",
                tostring(opts.reason or "?"),
                tostring(gid),
                tostring(fpExt),
                tostring(ST.lastHorseName or "?"))
        end

        return
    end

    ---------------------------------------------------------
    -- OPTIONAL DEBUG: name snapshot
    ---------------------------------------------------------
    do
        local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
        if D.horseIdentityTrace then
            System.LogAlways(("[CuraEqui][OWNDBG] _HorseName(h)=%s lastHorseName=%s"):
            format(
                tostring(CuraEqui._HorseName and CuraEqui._HorseName(h) or "nil"),
                tostring(ST.lastHorseName)
            ))
        end
    end

    ---------------------------------------------------------
    -- WHITELIST CHECK (use current horse name)
    ---------------------------------------------------------
    local nm = CuraEqui._HorseName and CuraEqui._HorseName(h) or nil
    if nm and HorseOwnership.IsHorseStormNameOwnable then
        local ownable = HorseOwnership.IsHorseStormNameOwnable(nm)

        -- If this horse is NOT ownable AND it's not the already-owned horse,
        -- THEN block. Otherwise allow.
        local ST = CuraEqui.state or {}
        local alreadyOwned = false
        if ST.currentOwnedHorseId and h.id == ST.currentOwnedHorseId then
            alreadyOwned = true
        end

        if (not ownable) and (not alreadyOwned) then
            CuraEqui.Log("HorseId",
                "SetOwnedHorse[%s]: rejected non-ownable horse (%s)",
                reason,
                tostring(nm))
            return
        end
    end

    ---------------------------------------------------------
    -- ACCEPT OWNABLE HORSE (original logic)
    ---------------------------------------------------------
    local gid                = (CuraEqui._HorseGuid and CuraEqui._HorseGuid(h)) or tostring(h.id)
    local fp                 = (CuraEqui._HorseFingerprint and CuraEqui._HorseFingerprint(h)) or ""
    local fpExt              = (CuraEqui._HorseFpExt and CuraEqui._HorseFpExt(h)) or ""

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

    -- If we already have an owned horse + have mounted it at least once,
    -- no need to do anything.
    if ST.currentOwnedHorseId and ST.hasMountedOwnedHorseOnce then
        return
    end

    -- Best-effort: ask the game which horse we should treat as "current"
    local h = C.ResolveHorse and C.ResolveHorse() or nil
    if not h then
        return
    end

    -- Derive storm name for whitelist check
    local nm = C._HorseName and C._HorseName(h) or nil
    if not nm then
        return
    end

    -- Only auto-own horses that the whitelist says are ownable
    local ownable = false
    if CuraEqui.HorseOwnership.IsHorseStormNameOwnable then
        ownable = CuraEqui.HorseOwnership.IsHorseStormNameOwnable(nm)
    end
    if not ownable then
        -- e.g. dummyWanderer_horse_1, tsem_horse_7 → ignore
        return
    end

    -- At this point: we loaded into a save where ResolveHorse()
    -- points to an ownable template (e.g. tsem_sedivka).
    -- Treat this as the owned horse for this session.
    C.SetOwnedHorse(h, { reason = "load-mounted" })

    -- Mark "mounted at least once" so hunger logic is allowed to run
    ST.hasMountedOwnedHorseOnce = true

    -- Arm hunger if not already running; StartWatching is idempotent
    if C.StartWatching then
        local ok, err = pcall(C.StartWatching)
        if not ok then
            C.Log("Hunger", "TryInitOwnedHorseOnLoad: StartWatching failed: %s", tostring(err))
        end
    end
end
