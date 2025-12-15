CuraEqui                = CuraEqui or {}
CuraEqui.HorseOwnership = CuraEqui.HorseOwnership or {}
local D                 = CuraEqui.Config and CuraEqui.Config.Debug or {}

local HorseOwnership    = CuraEqui.HorseOwnership

-- Engine-side ownership check:
--  - returns isOwned, hasAnyEngineOwned
--  - isOwned          → "this specific entity is the engine-owned horse"
--  - hasAnyEngineOwned→ "the engine currently has some PlayerHorse at all"
function HorseOwnership.IsEngineOwnedHorse(h)
    local C = CuraEqui
    local D = C.Config and C.Config.Debug or {}

    if not (h and h.id) then
        return false, false
    end

    local wuid = nil

    -- 1) Ask the engine what it considers the player horse (WUID)
    if player and player.player and player.player.GetPlayerHorse then
        local ok, res = pcall(player.player.GetPlayerHorse, player.player)
        if ok then
            wuid = res
        end
    end

    -- No engine-owned horse at all
    if (not wuid) or (wuid == 0) then
        if D.horseIdentityTrace then
            System.LogAlways("[CuraEqui][HorseDebug] IsEngineOwnedHorse: no engine-owned horse (wuid=nil/0)")
        end
        return false, false
    end

    local horseId = nil

    -- 2) Turn WUID into a concrete entity id
    if XGenAIModule then
        local okId, idFromW = pcall(XGenAIModule.GetEntityIdByWUID, wuid)
        if okId and idFromW and idFromW ~= 0 then
            horseId = idFromW
        else
            local okEnt, entFromW = pcall(XGenAIModule.GetEntityByWUID, wuid)
            if okEnt and entFromW and entFromW.id then
                horseId = entFromW.id
            end
        end
    end

    local wuidStr = nil
    if Framework and Framework.WUIDToString then
        local okStr, s = pcall(Framework.WUIDToString, wuid)
        if okStr then
            wuidStr = s
        end
    end

    local isOwned = (horseId ~= nil and horseId ~= 0 and horseId == h.id)

    if D.horseIdentityTrace then
        System.LogAlways((
            "[CuraEqui][HorseDebug] IsEngineOwnedHorse: wuid=%s id=%s h.id=%s isOwned=%s"
        ):format(
            tostring(wuidStr or wuid or "nil"),
            tostring(horseId or "nil"),
            tostring(h.id),
            tostring(isOwned)
        ))
    end

    return isOwned, true -- true = "engine has *some* PlayerHorse"
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
        local oldEnt             = ST.lastHorseEnt
        local reasonTag          = tostring(opts.reason or "unknown")

        ST.hasHorse              = false
        ST.lastHorseEnt          = nil
        ST.lastHorseId           = nil
        ST.lastHorseName         = nil
        ST.lastHorseFp           = nil
        ST.lastHorseFpExt        = nil
        ST.currentOwnedHorseId   = nil
        ST.currentOwnedHorseGuid = nil
        ST._hungerLoadedFromDB   = nil

        -- Clear cached engine horse id so Resolve() doesn’t return ghosts
        if C.Horse then
            C.Horse.playerHorseId = nil
        end

        -- Also reset mount duplicate filter (new session / identity wipe)
        C._lastMountId   = nil
        C._lastMountTime = nil

        -- Also clear any old debuffs on the previous horse entity
        if oldEnt and C.Effects and C.Effects.ClearHorseDebuffs then
            pcall(C.Effects.ClearHorseDebuffs, oldEnt)
        end

        if reasonTag == "load-reset" then
            if D.ownershipTrace then
                System.LogAlways(("[CuraEqui][HorseId] SetOwnedHorse[%s]: cleared identity"):format(reason or "?"))
            end
        else
            if C.Log then
                C.Log("HorseId", "SetOwnedHorse[%s]: cleared identity", reason)
            end
        end

        return
    end

    ---------------------------------------------------------
    -- 2) OPTIONAL DEBUG: name snapshot before engine gate
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
    -- 3) ENGINE OWNERSHIP GATE (trust the game’s PlayerHorse)
    ---------------------------------------------------------
    local HO = C.HorseOwnership
    local isEngineOwned, hasEngineOwned = false, false

    if HO and HO.IsEngineOwnedHorse then
        local okEO, ownedFlag, anyFlag = pcall(HO.IsEngineOwnedHorse, h)
        if okEO then
            isEngineOwned  = (ownedFlag == true)
            hasEngineOwned = (anyFlag == true)
        else
            if D.ownershipTrace and C.Log then
                C.Log(
                    "HorseId",
                    "IsEngineOwnedHorse failed in SetOwnedHorse[%s]: %s",
                    reason,
                    tostring(ownedFlag)
                )
            end
        end
    end

    -- Not the engine-owned horse → never treat as CuraEqui’s owned horse.
    -- IMPORTANT: we do *not* clear existing owned identity; we just ignore
    -- this mount for hunger purposes.
    if not isEngineOwned then
        if C.Effects and C.Effects.ClearHorseDebuffs then
            pcall(C.Effects.ClearHorseDebuffs, h)
        end

        if D.ownershipTrace and C.Log then
            C.Log(
                "HorseId",
                "SetOwnedHorse[%s]: engine says NOT owned (nm=%s)",
                reason,
                tostring(nm or "?")
            )
        end

        return
    end

    ---------------------------------------------------------
    -- 4) LAZY HUNGER HYDRATION – ONLY ONCE PER SESSION
    --    (only for accepted / engine-owned horses)
    ---------------------------------------------------------

    if (not ST._hungerLoadedFromDB)
        and C.Persist and C.Persist.Load
        and C.HorseStateGet
    then
        local S = C.HorseStateGet(h)
        if S then
            local ph, ps = C.Persist.Load()
            if ph ~= nil then
                S.hunger = math.max(0, math.min(100, ph))
            end

            -- IMPORTANT: these must not persist across saves (prevents “no status icon”)
            S.satedUntil = 0
            S._lastHorseDebuffUuid = nil
            S._horseDebuffRetryPending = nil
            S._horseDebuffRetryCount = nil
            S.horseDebuffRetryTimer = nil

            ST._hungerLoadedFromDB = true

            if C.Log then
                C.Log("Persist",
                    "Hydrated hunger on SetOwnedHorse[%s]: hunger=%s (sated cleared)",
                    reason, tostring(ph))
            end
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

    if D.ownershipTrace and C.Log then
        C.Log(
            "HorseId",
            "Owned snapshot: currentOwnedHorseId=%s guid=%s",
            tostring(ST.currentOwnedHorseId),
            tostring(ST.currentOwnedHorseGuid)
        )
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
-- Try to arm hunger + ownership when loading into a save
-- where the player already has an owned horse present.
-- Safe, defensive, and independent of ResolveHorse gating.
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

    ----------------------------------------------------------------
    -- 2) Resolve the current horse using the raw resolver
    --    (what the ENGINE thinks is the player’s horse).
    --    We avoid C.ResolveHorse here to keep things simple and
    --    avoid any recursion / ownership gating during bootstrap.
    ----------------------------------------------------------------
    local h = nil

    do
        local H = C.Horse
        if H and H.Resolve then
            local ok, ent = pcall(H.Resolve)
            if ok and ent and ent.id then
                h = ent
            end
        end
    end

    if not h or not h.id then
        -- Nothing to promote → we’re effectively horseless.
        ST.justLoaded = false
        return
    end

    ----------------------------------------------------------------
    -- 3) Treat this as the owned horse for this session.
    --    Let SetOwnedHorse do the heavy lifting (engine ownership
    --    gate + snapshots + DB hydration).
    ----------------------------------------------------------------
    if C.SetOwnedHorse then
        local okSet, errSet = pcall(C.SetOwnedHorse, h, { reason = "load-mounted" })

        if not okSet then
            if C.Log then
                C.Log("HorseOwn",
                    "TryInitOwnedHorseOnLoad: SetOwnedHorse failed: %s",
                    tostring(errSet))
            end
            ST.justLoaded = false
            return
        end
    end

    ST.hasHorse     = true
    ST.lastHorseEnt = h
    ST.lastHorseId  = (C._HorseGuid and C._HorseGuid(h)) or h.id

    ----------------------------------------------------------------
    -- 4) Arm hunger watcher if not already running.
    ----------------------------------------------------------------
    if C.StartWatching and not ST.hungerTimer then
        local okSw, errSw = pcall(C.StartWatching)
        if not okSw and C.Log then
            C.Log("Hunger",
                "TryInitOwnedHorseOnLoad: StartWatching failed: %s",
                tostring(errSw))
        end
    end

    ST.justLoaded = false -- don’t run again this session

    local prettyName = (h.GetName and h:GetName()) or "Horse"
    if D.ownershipTrace then
        System.LogAlways(("[CuraEqui][HorseOwn] mounted-on-load init for id=%s name=%s")
            :format(tostring(h.id), tostring(prettyName)))
    end
end
