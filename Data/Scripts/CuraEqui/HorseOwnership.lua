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

        CuraEqui.Log("HorseId", "SetOwnedHorse[%s]: cleared identity", reason)
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
        if not ownable then
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
    ST.currentOwnedHorseGuid = gid -- strong GUID / table/string

    CuraEqui.Log("HorseId",
        "SetOwnedHorse[%s]: id=%s fpExt=%s name=%s",
        reason,
        tostring(gid),
        tostring(fpExt),
        tostring(ST.lastHorseName))

    CuraEqui.Log("HorseId",
        "Owned snapshot: currentOwnedHorseId=%s guid=%s",
        tostring(ST.currentOwnedHorseId),
        tostring(ST.currentOwnedHorseGuid))
end

function CuraEqui.PlayerOwnsHorse(h)
    local ST = CuraEqui.state or {}

    -- Primary identity: the horse id we captured via SetOwnedHorse
    local ownedId = ST.currentOwnedHorseId

    -- If we never captured any owned horse id this session, we own nothing
    if not ownedId then
        return false
    end

    -- No specific handle → "do we have some active owned horse this session?"
    if not h then
        return true
    end

    -- First, compare raw engine id (most reliable)
    if h.id == ownedId then
        return true
    end

    -- Optional fallback: compare GUID/fingerprint if we have one
    local guid = nil
    if CuraEqui._HorseGuid then
        local ok, g = pcall(CuraEqui._HorseGuid, h)
        if ok then guid = g end
    end

    if guid and ST.lastHorseId and guid == ST.lastHorseId then
        return true
    end

    return false
end
