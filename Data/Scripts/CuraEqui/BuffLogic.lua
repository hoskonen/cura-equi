-- === CuraEqui / BuffLogic.lua ===
CuraEqui              = CuraEqui or {}
CuraEqui.Buffs        = CuraEqui.Buffs or {}
local M               = CuraEqui and CuraEqui.Buffs or {}

-- module locals
M._lastPlayerUuid     = M._lastPlayerUuid or nil
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false
M._playerGen          = M._playerGen or 0
M._syncBusy           = false -- ensure exists

-- Timed "Sated" tiers (descending). UUIDs must match buff__curaequi.xml
M.SATED_TIERS         = {
    { sec = 2000, uuid = "e1800331-3a2f-4cc5-a8c9-841b6951a82e" },
    { sec = 1900, uuid = "aa532dd1-403e-4625-9e87-e9a6899e4f1a" },
    { sec = 1800, uuid = "0ed41cfb-f810-4b41-a5c4-cce1dd4c74f0" },
    { sec = 1700, uuid = "46e6dfcc-6a64-453b-8dae-d8a1f89734c6" },
    { sec = 1600, uuid = "d8e2b38b-e91f-4d23-8571-d79b9e5f6353" },
    { sec = 1500, uuid = "f3db020a-9959-4d50-b185-85d40aef2ae0" },
    { sec = 1400, uuid = "53ddadd1-1f84-42d9-b05e-8f16101267cc" },
    { sec = 1300, uuid = "c4056d88-ab66-4c6c-bd18-b476b112c298" },
    { sec = 1200, uuid = "98c04f72-da28-4075-8d85-a7069c73ff9e" },
    { sec = 1100, uuid = "2b3b7af9-bcd9-4cb0-a0ee-ad983667ac47" },
    { sec = 1000, uuid = "62eb98ef-51f5-408e-bcad-aefd2a670560" },
    { sec = 900,  uuid = "32b562de-5229-49d7-82ae-62412dd019ce" },
    { sec = 800,  uuid = "ea9d92a0-01d6-41a5-9640-287e154db37f" },
    { sec = 700,  uuid = "cf6a7c47-e122-4de8-9a57-92a47aceaa7a" },
    { sec = 600,  uuid = "d513eaca-20c2-45aa-bbf3-ea4d5094e40b" },
    { sec = 500,  uuid = "5232c9a1-e46b-4d18-9cae-d41e585cb22f" },
    { sec = 400,  uuid = "f4438e13-03c5-49d7-88d6-cdd81839da79" },
    { sec = 300,  uuid = "29371153-9ff7-42b9-8cfb-b1f8391f0119" },
    { sec = 200,  uuid = "6da20913-8537-4ab9-963d-e310e9afd313" },
    { sec = 100,  uuid = "29264074-7154-4831-92c4-f132bf96f60b" },
}

M.SATED_TOMBSTONES    = {
    -- old 300s that got stuck earlier:
    "2d8939b7-8af5-40b7-a1fb-1f937a3a6afc",
    -- old 500s you just replaced:
    "7a0a5c5c-5c9c-44ed-9b46-9184b75e3c3c",
}

-- pick tier name from hunger/sated (HUD thresholds)
local function _now() return (CuraEqui.Now and CuraEqui.Now()) or 0 end
local function _pickTierName(hunger, satedUntil)
    if (satedUntil or 0) > _now() then return "sated" end
    local hud      = CuraEqui.Config and CuraEqui.Config.HUD or {}
    local th       = hud.thresholds or {}
    local minor    = tonumber(th.minor) or 50
    local moderate = tonumber(th.moderate) or 70
    local critical = tonumber(th.critical) or 90
    if hunger >= critical then
        return "critical"
    elseif hunger >= moderate then
        return "moderate"
    elseif hunger >= minor then
        return "minor"
    else
        return "ok"
    end
end
M._pickTierName = _pickTierName -- exported for HUD/debug

local function _uuidFromList(list, name)
    if not list then return "" end
    for i = 1, #list do
        local r = list[i]
        if r and r.name == name then return r.uidd or r.uuid or "" end
    end
    return ""
end

local function _delay_ms()
    local ms = 1000
    local C  = CuraEqui.Config and CuraEqui.Config.Buffs
    if C and C.applyDelaySec then
        ms = math.max(0, math.floor((tonumber(C.applyDelaySec) or 0) * 1000))
    end
    return ms
end

local function _schedule(ms, fn)
    if (Script and Script.SetTimer and type(fn) == "function" and ms > 0) then
        Script.SetTimer(ms, fn)
    else
        fn()
    end
end

local function _dbgStatus(fmt, ...)
    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if not (D and D.buffTrace) then
        return
    end
    CuraEqui.Log("Buff", fmt, ...)
end

-- module locals for debouncing
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false

-- Return: bucketSec, bucketUuid
function M.DebugPickSatedBucket(remS)
    local b = (_pick_sated_bucket or _pick_bucket_floor)(remS)
    if not b then return 0, nil end
    return b.sec, b.uuid
end

-- function M.SyncPlayerStatus(horseEnt, S)
--     local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers
--     if not S or not list then
--         if M._lastPlayerUuid then
--             CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
--         end
--         return
--     end

--     do
--         local ST = CuraEqui.state or {}
--         local untilTs = tonumber(ST.suppressStatusUntil or 0) or 0
--         if untilTs > (CuraEqui.Now and CuraEqui.Now()) or 0 then
--             if M._lastPlayerUuid then
--                 CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
--             end
--             return
--         end
--     end

--     -- Previously: if sated is active, we hid all status tiers.
--     -- Now: only log it; status tiers are still allowed.
--     do
--         local now  = _now()
--         local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
--         if remS > 0 then
--             _dbgStatus("PlayerStatus: sated active rem=%.1fs (hunger=%.1f) – status allowed",
--                 remS, tonumber(S.hunger or -1) or -1)
--             -- no ClearPlayerStatus, no return
--         end
--     end

--     -- Previously: a live sated timer completely hid the status tiers.
--     -- Now: we just log it; hunger status is still allowed.
--     do
--         if M._lastSatedUuid then
--             _dbgStatus("PlayerStatus: _lastSatedUuid=%s present (hunger=%.1f) – status allowed",
--                 tostring(M._lastSatedUuid), tonumber(S.hunger or -1) or -1)
--             -- no ClearPlayerStatus, no return
--         end
--     end

--     local hval = tonumber(S.hunger or 0) or 0
--     local tier = _pickTierName(hval, S.satedUntil)

--     -- (Optional guard: if your picker can return 'sated', map to 'ok' here)
--     if tier == "sated" then tier = "ok" end

--     local uuid = _uuidFromList(list, tier)

--     _dbgStatus("PlayerStatus: hunger=%.1f → tier=%s uuid=%s lastUuid=%s lastSated=%s",
--         hval,
--         tostring(tier),
--         tostring(uuid),
--         tostring(M._lastPlayerUuid),
--         tostring(M._lastSatedUuid))

--     -- decision crumb (quiet unless Debug.enabled)
--     local D = CuraEqui.Config and CuraEqui.Config.Debug
--     local wantPickLog = D and D.buffPickTrace and (uuid ~= M._lastPlayerUuid)

--     if wantPickLog then
--         local now = _now()
--         local rem = math.max(0, (S.satedUntil or 0) - now)
--         CuraEqui.Log("buff",
--             "PlayerStatus pick tier=%s hunger=%d remSated=%.1f uuid=%s",
--             tier, hval, rem, uuid and (#uuid > 8 and (uuid:sub(1, 8) .. "…") or (uuid or "-"))
--         )
--     end

--     if not uuid or uuid == "" then
--         _dbgStatus("PlayerStatus: no uuid for tier=%s hunger=%.1f → clear",
--             tostring(tier), hval)

--         if M._lastPlayerUuid then
--             CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
--         end
--         return
--     end

--     -- debounced clear→apply
--     if uuid == M._lastPlayerUuid then return end
--     if M._playerApplyPending and uuid == M._desiredPlayerUuid then return end

--     M._desiredPlayerUuid = uuid
--     if not M._playerApplyPending then
--         M._playerApplyPending = true
--         CuraEqui.Effects.ClearPlayerStatus()
--         local want   = uuid
--         local delay  = _delay_ms()
--         M._playerGen = (M._playerGen or 0) + 1
--         local myGen  = M._playerGen

--         -- clear immediately (pcall for safety)
--         pcall(CuraEqui.Effects.ClearPlayerStatus)

--         _schedule(delay, function()
--             -- still current, and we weren't superseded?
--             if M._desiredPlayerUuid == want and myGen == M._playerGen then
--                 _dbgStatus("PlayerStatus: apply uuid=%s (tier=%s hunger=%.1f)",
--                     tostring(want),
--                     tostring(tier), -- optional, you can stash tier in closure if you like
--                     hval)
--                 pcall(CuraEqui.Effects.ApplyPlayer, want)
--                 M._lastPlayerUuid = want
--             end
--             M._playerApplyPending = false
--         end)
--     end
-- end

function M.SyncPlayerStatus(horseEnt, S)
    local C    = CuraEqui
    local list = C.Config and C.Config.HUD and C.Config.HUD.playerStatusTiers

    -- No state or no config → clear and bail
    if not S or not list then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus()
            M._lastPlayerUuid = nil
        end
        return
    end

    ----------------------------------------------------------------
    -- 0) If sated is active, suppress hunger status tiers entirely.
    --    This avoids buff-class conflicts with timed Sated buffs
    --    (engine exclusivity=3) and keeps the icon strip showing
    --    the "fed" state instead of flipping back to OK/moderate.
    ----------------------------------------------------------------
    local now  = _now()
    local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

    if remS > 0 then
        -- We DO have a running sated timer -> no hunger status icon.
        if M._lastPlayerUuid then
            pcall(CuraEqui.Effects.ClearPlayerStatus)
            M._lastPlayerUuid = nil
        end
        return
    end

    ----------------------------------------------------------------
    -- 1) Decide tier based purely on hunger + satedUntil
    ----------------------------------------------------------------
    local hval = tonumber(S.hunger or 0) or 0
    local tier = _pickTierName(hval, S.satedUntil)

    -- Treat "sated" tier as "ok" for status icon purposes
    if tier == "sated" then
        tier = "ok"
    end

    local uuid = _uuidFromList(list, tier)

    _dbgStatus("PlayerStatus: hunger=%.1f tier=%s uuid=%s last=%s",
        hval,
        tostring(tier),
        tostring(uuid),
        tostring(M._lastPlayerUuid))

    ----------------------------------------------------------------
    -- 2) No UUID for this tier → clear and bail
    ----------------------------------------------------------------
    if not uuid or uuid == "" then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus()
            M._lastPlayerUuid = nil
        end
        return
    end

    ----------------------------------------------------------------
    -- 3) Debounced clear → apply
    ----------------------------------------------------------------
    if uuid == M._lastPlayerUuid then
        -- Already showing this tier; nothing to do
        return
    end

    M._desiredPlayerUuid = uuid

    if not M._playerApplyPending then
        M._playerApplyPending = true
        local want            = uuid
        local delay           = _delay_ms()
        M._playerGen          = (M._playerGen or 0) + 1
        local myGen           = M._playerGen

        -- Clear current status immediately (safely)
        pcall(CuraEqui.Effects.ClearPlayerStatus)

        _schedule(delay, function()
            -- still current, and we weren't superseded?
            if M._desiredPlayerUuid == want and myGen == M._playerGen then
                _dbgStatus("PlayerStatus: apply uuid=%s (tier=%s hunger=%.1f)",
                    tostring(want),
                    tostring(tier),
                    hval)
                pcall(CuraEqui.Effects.ApplyPlayer, want) -- safe AddBuff call
                M._lastPlayerUuid = want
            end
            M._playerApplyPending = false
        end)
    end
end

function M.SyncHorseDebuff(horseEnt, S)
    -- if sated is active, keep horse strip empty (no 'sated' in horseDebuffTiers)
    if (tonumber(S.satedUntil or 0) or 0) > _now() then
        CuraEqui.Effects.ClearHorseDebuffs(horseEnt)
        S._lastHorseDebuffUuid = nil
        return
    end
    local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.horseDebuffTiers
    if not horseEnt or not S or not list then return end

    local hval = tonumber(S.hunger or 0) or 0
    local tier = _pickTierName(hval, S.satedUntil)
    local uuid = _uuidFromList(list, tier)
    local last = S._lastHorseDebuffUuid

    local D = CuraEqui.Config and CuraEqui.Config.Debug
    local wantPickLog = D and D.buffPickTrace and (uuid ~= last)

    if wantPickLog then
        CuraEqui.Log("buff",
            "HorseDebuff pick tier=%s hunger=%d uuid=%s last=%s",
            tier, hval,
            uuid and (#uuid > 8 and (uuid:sub(1, 8) .. "…") or (uuid or "-")),
            last and (#last > 8 and (last:sub(1, 8) .. "…") or (last or "-"))
        )
    end

    -- no GUID → clear if something was set
    if not uuid or uuid == "" then
        if last then
            CuraEqui.Effects.ClearHorseDebuffs(horseEnt); S._lastHorseDebuffUuid = nil
        end
        return
    end

    -- safety: forbid clashing GUID with player tier of the same name
    local plist = CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers
    if plist then
        for i = 1, #plist do
            local r = plist[i]
            if r and r.name == tier and r.uidd == uuid then
                if D and D.enabled then
                    CuraEqui.Log("buff", "HorseDebuff skipped: GUID clashes with player tier (%s)", uuid)
                end
                return
            end
        end
    end

    if uuid ~= last then
        local cleared = CuraEqui.Effects.ClearHorseDebuffs(horseEnt)

        -- If we cannot reliably clear (common during load), do NOT apply.
        -- Schedule a short retry instead to prevent duplicate stacking.
        if not cleared then
            if not S._horseDebuffRetryPending then
                S._horseDebuffRetryPending = true
                S.horseDebuffRetryTimer = Script.SetTimer(250, function()
                    S._horseDebuffRetryPending = false
                    S.horseDebuffRetryTimer = nil
                    pcall(M.SyncHorseDebuff, horseEnt, S)
                end)
            end
            return
        end

        CuraEqui.Effects.ApplyHorse(horseEnt, uuid)
        S._lastHorseDebuffUuid = uuid

        if D and D.enabled then
            CuraEqui.Log("buff", "HorseDebuff → %s (%s)", tier, uuid)
        end
    end
end

function M.SyncAll(horseEnt, S)
    _dbgStatus("SyncAll: hunger=%.1f satedUntil=%.1f",
        tonumber(S and S.hunger or -1) or -1,
        tonumber(S and S.satedUntil or 0) or 0)

    M.SyncHorseDebuff(horseEnt, S)
    M.SyncPlayerStatus(horseEnt, S)
end

local function _pick_bucket_floor(remS)
    remS = math.max(0, tonumber(remS or 0) or 0)
    for _, t in ipairs(M.SATED_TIERS) do
        if remS >= t.sec then return t end
    end
    if remS > 0 then return M.SATED_TIERS[#M.SATED_TIERS] end -- show 100 for tiny remainders
    return nil
end

local function _find_bucket_by_uuid(uuid)
    if not uuid then return nil end
    local T = M.SATED_TIERS
    for i = 1, #T do
        if T[i].uuid == uuid then
            return T[i]
        end
    end
    return nil
end


local function _pick_bucket_ceil(remS)
    remS = math.max(0, tonumber(remS or 0) or 0)
    local T = M.SATED_TIERS
    for i = #T, 1, -1 do
        if remS <= T[i].sec then return T[i] end
    end
    return T[1]
end

-- Public wrapper: choose ceil or floor rounding for sated tier selection
function CuraEqui.Buffs.PickSatedBucket(remS, opts)
    if not remS then return nil end
    if opts and opts.ceil then
        return _pick_bucket_ceil(remS)
    else
        return _pick_bucket_floor(remS)
    end
end

-- Predict which tier (seconds) would be displayed if addSec extra were granted now
function CuraEqui.Buffs.PredictBucketSecAfterAdd(S, addSec)
    local now  = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local rem  = math.max(0, (tonumber(S and S.satedUntil or 0) or 0) - now)
    local want = rem + math.max(0, tonumber(addSec or 0) or 0)
    local b    = CuraEqui.Buffs.PickSatedBucket(want, { ceil = true })
    return (b and b.sec) or 0
end

function M.ClearSatedTimers()
    local C = CuraEqui
    if not C then return end

    local L = (C.Config and C.Config.Sated and C.Config.Sated.TIERS) or M.SATED_TIERS or {}
    local E = C.Effects

    if not (E and E.PlayerRemove) then return end

    local D = C.Config and C.Config.Debug or {}
    local removed = 0

    for i = 1, #L do
        local uuid = L[i] and L[i].uuid
        if uuid then
            local ok = E.PlayerRemove(uuid)
            removed = removed + 1
            if D.buffTraceVerbose then
                System.LogAlways(("[CuraEqui][Effects] ClearSatedTimers: remove %s ok=%s")
                    :format(tostring(uuid), tostring(ok)))
            end
        end
    end

    M._lastSatedUuid = nil

    if D.buffTraceVerbose then
        System.LogAlways(("[CuraEqui][Effects] ClearSatedTimers: %d uuids processed"):format(removed))
    end
end

-- opts.force=true → re-apply even if bucket unchanged (used after feeding/load/diet)
function CuraEqui.Buffs.SyncSatedTimer(h, S, opts)
    local C         = CuraEqui
    local D         = (C.Config and C.Config.Debug) or {}
    local U         = C.Utils
    opts            = opts or {}

    local now       = (C.Now and C.Now()) or 0
    local oldUntil  = tonumber(S and S.satedUntil or 0) or 0
    local oldRem    = math.max(0, oldUntil - now)
    local oldGuid   = S and S.satedBuffGuid or nil
    local cause     = tostring(opts.cause or "?")
    local force     = (opts.force == true)

    -- Optional throttle so we don't spam every tick when nothing changes
    local shouldLog = false
    if D.enabled then
        shouldLog = D.satedTraceVerbose
            or (U and U.throttle and U.throttle("sated-sync-" .. cause, 0.5))
            or false
    end

    -- EXISTING EARLY-EXIT: no tiers configured
    local BL = CuraEqui.Buffs.SATED_TIERS or {}
    if not (BL and #BL > 0) then
        if shouldLog then
            System.LogAlways(("[CuraEqui][Buff] SatedSync skip – no tiers (cause=%s, rem=%ds, force=%s, guid=%s)")
                :format(cause, math.floor(oldRem + 0.5), tostring(force), tostring(oldGuid)))
        end
        return
    end


    local ST = CuraEqui.state or {}
    if ST._preloadFence and not (opts and opts.force) then
        if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.buffTraceVerbose then
            System.LogAlways("[CuraEqui][SatedSync] fenced (preload)")
        end
        return
    end

    -- Reentry fence (quiet unless verbose)
    if M._syncBusy and not opts.force then
        local D = CuraEqui.Config and CuraEqui.Config.Debug
        if D and D.buffTraceVerbose then
            System.LogAlways("[CuraEqui][SatedSync] fenced (drop reentry)")
        end
        return
    end

    -- Early guard: if we somehow lost the horse entity or state, wipe timers
    if (not h) or (not S) then
        if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.buffTraceVerbose then
            System.LogAlways("[CuraEqui][SatedSync] early-clear: missing horse or state")
        end
        M.ClearSatedTimers()
        M._lastSatedUuid = nil
        return
    end

    M._syncBusy    = true
    local ok, err  = xpcall(function()
        local D    = CuraEqui.Config and CuraEqui.Config.Debug or {}
        local now  = _now()
        local remS = math.max(0, (tonumber(S and S.satedUntil or 0) or 0) - now)

        if D.buffTraceVerbose then
            local cause = tostring(opts.cause or "tick")
            if (cause ~= "tick") or D.buffTraceTick then
                System.LogAlways(("[CuraEqui][SatedSync] cause=%s force=%s rem=%.0fs")
                    :format(cause, tostring(opts.force or false), remS))
            end
        end

        -- No state? ensure no lingering timer, then bail
        if not S then
            if M._lastSatedUuid then
                M.ClearSatedTimers(); M._lastSatedUuid = nil
            end
            return
        end

        -- Small debounce window to avoid rapid re-entries (startup races)
        if M._satedFence and now < M._satedFence and not opts.force then
            if D.buffTraceVerbose then System.LogAlways("[CuraEqui][SatedSync] fenced (debounce)") end
            return
        end

        -- Expired → clear all sated tiers and do a one-off status resync
        if remS <= 0 then
            local rawUntil = tonumber(S and S.satedUntil or 0) or 0

            if rawUntil <= 0 then
                M._lastSatedUuid = nil
                S.satedBuffGuid  = nil
                return
            end

            M.ClearSatedTimers()
            M._lastSatedUuid  = nil
            S.satedUntil      = 0
            S.satedBuffGuid   = nil

            M._lastPlayerUuid = nil

            if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll and h and S then
                pcall(CuraEqui.Buffs.SyncAll, h, S)
            end

            return
        end

        -- ----------------------------------------------------------------
        -- MID-RUN LOCK:
        -- If we still have time remaining AND we know which bucket we're
        -- using (either via _lastSatedUuid or S.satedBuffGuid), DO NOT
        -- clear/reapply the buff unless this is a real extension event.
        -- ----------------------------------------------------------------
        local causeStr         = tostring(opts.cause or "tick")
        local forcing          = (opts.force == true)
        local existingUuid     = M._lastSatedUuid or (S and S.satedBuffGuid) or nil
        local isExtensionCause =
            (causeStr == "feed") or
            (causeStr == "catchup") or
            (causeStr == "catchup-extend") or
            (causeStr == "ogs-settle") -- keep/adjust as needed

        if existingUuid and remS > 0 and not isExtensionCause then
            -- Recover _lastSatedUuid if it was lost, but NEVER re-apply.
            M._lastSatedUuid = existingUuid

            if D.buffTraceVerbose and ((causeStr ~= "tick") or D.buffTraceTick) then
                System.LogAlways(("[CuraEqui][Buff] Sated mid-run lock cause=%s rem=%.0fs guid=%s")
                    :format(causeStr, remS, existingUuid))
            end

            return
        end

        -- Decide desired bucket

        local bucket

        if not forcing and M._lastSatedUuid then
            -- 🔒 Freeze bucket for this run: reuse the existing tier
            bucket = _find_bucket_by_uuid(M._lastSatedUuid) or _pick_bucket_ceil(remS)
        else
            -- First apply or forced resync (e.g. after feeding)
            bucket = _pick_bucket_ceil(remS)
        end

        if not bucket or not bucket.uuid then return end

        -- memo for throttling identical skip logs
        M._lastSkipLog = M._lastSkipLog or { uuid = nil, rem = -1 }

        -- Mid-run, already on desired bucket → no-op
        if (not forcing) and (M._lastSatedUuid == bucket.uuid) then
            -- Always preserve the active UUID
            M._lastSatedUuid = bucket.uuid

            -- compute a rounded remain for logging
            local remRounded = math.floor(remS + 0.5)

            -- throttled debug
            if D.buffTraceVerbose and (not M._nextSkipLogAt or now >= M._nextSkipLogAt) then
                System.LogAlways(
                    ("[CuraEqui][Buff] Sated: skip mid-run (1) cause=%s rem=%ds guid=%s")
                    :format(tostring(opts.cause), remRounded, bucket.uuid)
                )
                M._nextSkipLogAt = now + 2
            end

            return
        end

        -- (Re)apply: clear all sated tiers, then apply exactly one
        M.ClearSatedTimers()
        local applied = false
        if CuraEqui.Effects and CuraEqui.Effects.ApplyPlayer then
            applied = pcall(CuraEqui.Effects.ApplyPlayer, bucket.uuid)
        end

        if applied then
            -- record the buff tier in runtime memory
            S.satedBuffGuid = bucket.uuid

            -- record the tracker UUID
            M._lastSatedUuid = bucket.uuid

            -- minimal debounce
            M._satedFence = now + 0.30
        else
            -- apply failed -> clear state
            S.satedBuffGuid = nil
            M._lastSatedUuid = nil
        end
    end, debug.traceback)

    -- ALWAYS release the fence
    M._syncBusy    = false

    -- At this point the function has decided to (re)sync the timer/buff
    local newUntil = tonumber(S and S.satedUntil or 0) or 0
    local newRem   = math.max(0, newUntil - now)
    local newGuid  = S and S.satedBuffGuid or nil

    if shouldLog or D.satedTraceVerbose then
        System.LogAlways(("[CuraEqui][Buff] SatedSync apply cause=%s force=%s rem %ds→%ds guid %s→%s")
            :format(
                cause,
                tostring(force),
                math.floor(oldRem + 0.5),
                math.floor(newRem + 0.5),
                tostring(oldGuid),
                tostring(newGuid)
            ))
    end

    if not ok then
        System.LogAlways("[CuraEqui][SatedSync][ERROR] " .. tostring(err))
    end
end

function CuraEqui.Buffs.Remove(target, guid, horse)
    if target == "player" then
        return CuraEqui.Effects.RemovePlayer and CuraEqui.Effects.RemovePlayer(guid)
    elseif target == "horse" then
        return CuraEqui.Effects.RemoveHorse and CuraEqui.Effects.RemoveHorse(horse, guid)
    end
end

function CuraEqui.Buffs.RemoveAllOurs(horse)
    -- player status
    local hud = CuraEqui.Config and CuraEqui.Config.HUD or {}
    for _, r in ipairs(hud.playerStatusTiers or {}) do
        if r.uidd then pcall(CuraEqui.Effects.RemovePlayer, r.uidd) end
    end
    -- horse debuffs
    for _, r in ipairs(hud.horseDebuffTiers or {}) do
        if r.uidd and horse then pcall(CuraEqui.Effects.RemoveHorse, horse, r.uidd) end
    end
    -- all sated timed tiers (player)
    for _, t in ipairs(CuraEqui.Buffs.SATED_TIERS or {}) do
        if t.uuid then pcall(CuraEqui.Effects.RemovePlayer, t.uuid) end
    end
    CuraEqui.Buffs._lastSatedUuid = nil
end

-- Nukes every known sated-tier effect from the player, defensively.
function CuraEqui.Buffs.SweepPlayerSatedEffects(tag)
    local T = CuraEqui.Buffs.SATED_TIERS or {}
    local dead = CuraEqui.Buffs.SATED_TOMBSTONES or {}
    if CuraEqui.Effects and CuraEqui.Effects.PlayerRemove then
        for i = 1, #T do pcall(CuraEqui.Effects.PlayerRemove, T[i].uuid) end
        for i = 1, #dead do pcall(CuraEqui.Effects.PlayerRemove, dead[i]) end
    end
    CuraEqui.Buffs._lastSatedUuid = nil
end
