-- === CuraEqui / BuffLogic.lua ===
CuraEqui              = CuraEqui or {}
CuraEqui.Buffs        = CuraEqui.Buffs or {}
local M               = CuraEqui and CuraEqui.Buffs or {}
local buffsCfg        = CuraEqui and CuraEqui.Config or {}
-- module locals
M._lastPlayerUuid     = M._lastPlayerUuid or nil
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false
M._playerGen          = M._playerGen or 0
M._syncBusy           = false -- ensure exists

M.BUFF_UUID_SATED     = buffsCfg.satedUuid or "29264074-7154-4831-92c4-f132bf96f60b"

-- pick tier name from hunger/sated (HUD thresholds)
local function _now()
    if CuraEqui and CuraEqui.Now then
        return CuraEqui.Now()
    end
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end

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

-- module locals for debouncing
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false

-- Return: bucketSec, bucketUuid
function M.DebugPickSatedBucket(remS)
    local b = (_pick_sated_bucket or _pick_bucket_floor)(remS)
    if not b then return 0, nil end
    return b.sec, b.uuid
end

function M.SyncPlayerStatus(horseEnt, S)
    local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers
    if not S or not list then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
        end
        return
    end

    do
        local ST = CuraEqui.state or {}
        local untilTs = tonumber(ST.suppressStatusUntil or 0) or 0
        if untilTs > ((CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()) then
            if M._lastPlayerUuid then
                CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
            end
            return
        end
    end

    -- If Sated timer is active, don't show any status-tier (OK/min/mod/crit)
    do
        local now  = _now()
        local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

        CuraEqui.DebugLogSated("SyncPlayerStatus", S, ("remS=%.1f"):format(remS))

        if remS > 0 then
            -- This clears only status-tier buffs; make sure your ClearPlayerStatus() does NOT remove the sated timer UUIDs
            CuraEqui.Effects.ClearPlayerStatus()
            M._lastPlayerUuid = nil
            return
        end
    end

    -- Extra safety: if a sated timer buff was applied and hasn't been cleared yet,
    -- keep status tiers hidden until it’s gone (prevents OK appearing under the timer icon)
    do
        if M._lastSatedUuid then
            -- We assume SyncSatedTimer will clear this when the internal timer elapses.
            -- With the clamp sync in Horse.lua, internal/end-of-buff now align.
            if M._lastPlayerUuid then
                CuraEqui.Effects.ClearPlayerStatus()
                M._lastPlayerUuid = nil
            end
            return
        end
    end

    local hval = tonumber(S.hunger or 0) or 0
    local tier = _pickTierName(hval, S.satedUntil)

    -- (Optional guard: if your picker can return 'sated', map to 'ok' here)
    if tier == "sated" then tier = "ok" end

    local uuid = _uuidFromList(list, tier)

    -- decision crumb (quiet unless Debug.enabled)
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    local wantPickLog = D and D.buffPickTrace and (uuid ~= M._lastPlayerUuid)

    if wantPickLog then
        local now = _now()
        local rem = math.max(0, (S.satedUntil or 0) - now)
        CuraEqui.Log("buff",
            "PlayerStatus pick tier=%s hunger=%d remSated=%.1f uuid=%s",
            tier, hval, rem, uuid and (#uuid > 8 and (uuid:sub(1, 8) .. "…") or (uuid or "-"))
        )
    end

    if not uuid or uuid == "" then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
        end
        return
    end

    -- debounced clear→apply
    if uuid == M._lastPlayerUuid then return end
    if M._playerApplyPending and uuid == M._desiredPlayerUuid then return end

    M._desiredPlayerUuid = uuid
    if not M._playerApplyPending then
        M._playerApplyPending = true
        CuraEqui.Effects.ClearPlayerStatus()
        local want   = uuid
        local delay  = _delay_ms()
        M._playerGen = (M._playerGen or 0) + 1
        local myGen  = M._playerGen

        -- clear immediately (pcall for safety)
        pcall(CuraEqui.Effects.ClearPlayerStatus)

        _schedule(delay, function()
            -- still current, and we weren't superseded?
            if M._desiredPlayerUuid == want and myGen == M._playerGen then
                pcall(CuraEqui.Effects.ApplyPlayer, want)
                M._lastPlayerUuid = want
            end
            M._playerApplyPending = false
        end)
    end
end

-- function M.SyncPlayerStatus(h, S, opts)
--     local C = CuraEqui
--     if not (C and S) then return end

--     opts             = opts or {}
--     local D          = C.Config and C.Config.Debug or {}
--     local now        = (C.Now and C.Now()) or os.clock()

--     -- 1) What does our clock say?
--     local satedUntil = tonumber(S.satedUntil or 0) or 0
--     local remS       = math.max(0, satedUntil - now)

--     -- 2) Decide if we consider the horse "sated" for UI
--     local isSated    = remS > 0.5 -- small epsilon so 0.1s doesn’t flicker

--     -- If we’re in sated mode, hide hunger tiers completely
--     if isSated then
--         if C.Effects and C.Effects.ClearPlayerStatus then
--             pcall(C.Effects.ClearPlayerStatus)
--         end
--         -- still update the sated buff above; then bail before status tiers
--         if D.satedTrace then
--             System.LogAlways("[CuraEqui][SatedTrace] SyncPlayerStatus: hide hunger tiers (sated)")
--         end
--         return
--     end

--     -- 3) Drive the static sated buff **only** from remS
--     local E = C.Effects
--     if E and E.SetSatedStatic then
--         pcall(E.SetSatedStatic, isSated, {
--             cause = opts.cause or "status",
--             rem   = remS,
--         })
--     end

--     -- 4) Normal hunger status tiers (ok / minor / moderate / critical)
--     --    This part should ignore any satedRemainSec, only look at S.hunger.
--     if E and E.SyncStatusTier then
--         pcall(E.SyncStatusTier, h, S, opts) -- whatever you already had here
--     end

--     -- 5) Optional logging – here it’s safe to *log* state.satedRemainSec
--     if D.satedTrace then
--         local raw = tonumber(C.state and C.state.satedRemainSec or 0) or 0
--         System.LogAlways((
--             "[CuraEqui][SatedTrace] SyncPlayerStatus hunger=%.2f satedUntil=%.2f rem=%.2fs satedRemainSec=%.2fs extra=%s"
--         ):format(
--             tonumber(S.hunger or 0) or 0,
--             satedUntil,
--             remS,
--             raw,
--             opts.extra or "-"
--         ))
--     end
-- end

function M.SyncHorseDebuff(horseEnt, S)
    -- if sated is active, keep horse strip empty (no 'sated' in horseDebuffTiers)

    CuraEqui.DebugLogSated("SyncHorseDebuff", S)

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
        CuraEqui.Effects.ClearHorseDebuffs(horseEnt)
        CuraEqui.Effects.ApplyHorse(horseEnt, uuid)
        S._lastHorseDebuffUuid = uuid
        if D and D.enabled then
            CuraEqui.Log("buff", "HorseDebuff → %s (%s)", tier, uuid)
        end
    end
end

function M.SyncAll(horseEnt, S)
    M.SyncHorseDebuff(horseEnt, S)
    M.SyncPlayerStatus(horseEnt, S)
end

-- Static Sated synchronisation:
--  - S.satedRemainSec > 0 → ensure static Sated buff is active
--  - S.satedRemainSec == 0 → ensure static Sated buff is removed
-- NOTE: not wired to callsites yet; behaviour still driven by SyncSatedTimer.
function M.SyncSatedStatic(horseEnt, S, opts)
    if not S then return end

    opts = opts or {}

    CuraEqui.DebugLogSated("SyncSatedStatic", S, ("cause=%s"):format(opts.cause or "static"))

    local D          = CuraEqui.Config and CuraEqui.Config.Debug or {}
    local cause      = opts.cause or "static"
    local remSec     = math.max(0, tonumber(S.satedRemainSec or 0) or 0)

    local prevActive = not not S._satedStaticActive
    local active     = (remSec > 0)

    -- Only toggle when something actually changes
    if active ~= prevActive then
        S._satedStaticActive = active

        if CuraEqui.Effects and CuraEqui.Effects.SetSatedStatic then
            pcall(CuraEqui.Effects.SetSatedStatic, active, {
                cause = cause,
                rem   = remSec,
            })
        end

        if D.buffTraceVerbose then
            System.LogAlways(("[CuraEqui][SatedStatic] cause=%s rem=%.0fs active=%s (toggle)")
                :format(cause, remSec, tostring(active)))
        end
    else
        -- Optional: per-tick noise if you want it
        if D.buffTraceTick then
            System.LogAlways(("[CuraEqui][SatedStatic] cause=%s rem=%.0fs active=%s (no-change)")
                :format(cause, remSec, tostring(active)))
        end
    end
end

-- Predict which tier (seconds) would be displayed if addSec extra were granted now
function CuraEqui.Buffs.PredictBucketSecAfterAdd(S, addSec)
    if not S then return 0 end

    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
    addSec    = math.max(0, tonumber(addSec or 0) or 0)

    -- What do we already have left?
    local rem = 0
    if S.satedUntil and tonumber(S.satedUntil) and S.satedUntil > now then
        rem = S.satedUntil - now
    elseif S.satedRemainSec and tonumber(S.satedRemainSec) and S.satedRemainSec > 0 then
        rem = S.satedRemainSec
    end

    local target = rem + addSec

    CuraEqui.DebugLogSated("PredictBucketSecAfterAdd", S, ("addSec=%.1f target=%.1f"):format(addSec, target))

    -- Optional sanity clamp (24h cap to avoid silly values)
    local MAX = 24 * 3600
    if target > MAX then
        target = MAX
    end

    return target
end

function M.ClearSatedTimers()
    local C = CuraEqui
    if not C then return end

    local uuid = C.Config.HUD.playerStatusTiersByName.sated.uidd
    if not uuid then return end

    pcall(CuraEqui.Effects.PlayerRemove, uuid)

    if C.Config.Debug.buffTraceVerbose then
        System.LogAlways("[CuraEqui][Effects] Removed static SATED buff " .. tostring(uuid))
    end

    M._lastSatedUuid = nil
end

-- opts.force=true → re-apply even if bucket unchanged (used after feeding/load/diet)
function CuraEqui.Buffs.SyncSatedTimer(h, S, opts)
    opts = opts or {}
    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local untilTs = tonumber(S and S.satedUntil or 0) or 0
    local rem = math.max(0, untilTs - now)

    CuraEqui.DebugLogSated("SyncSatedTimer:pre", S, ("cause=%s"):format(opts.cause or "tick"))

    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if D.buffTraceTick then
        System.LogAlways(("[CuraEqui][SatedSync] cause=%s force=%s rem=%.0fs")
            :format(opts.cause or "tick", tostring(opts.force or false), rem))
    end

    -- Expired → clear buff + clear timer
    if rem <= 0 then
        if S then S.satedUntil = 0 end
        if CuraEqui.Effects and CuraEqui.Effects.SetSatedStatic then
            pcall(CuraEqui.Effects.SetSatedStatic, false, {
                cause = "expire",
                rem   = 0,
            })
        end

        CuraEqui.DebugLogSated("SyncSatedTimer:post-expire", S, "after-clear")

        return
    end

    CuraEqui.DebugLogSated("SyncSatedTimer:active", S, ("rem=%.1f"):format(rem))

    -- Apply static sated buff to player
    if CuraEqui.Effects and CuraEqui.Effects.SetSatedStatic then
        pcall(CuraEqui.Effects.SetSatedStatic, true, {
            cause = opts.cause or "timer",
            rem   = rem,
        })
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
    local hud = CuraEqui.Config and CuraEqui.Config.HUD or {}

    -- player hunger statuses (ok / minor / moderate / critical)
    for _, r in ipairs(hud.playerStatusTiers or {}) do
        if r.uidd and CuraEqui.Effects and CuraEqui.Effects.RemovePlayer then
            pcall(CuraEqui.Effects.RemovePlayer, r.uidd)
        end
    end

    -- horse debuffs
    for _, r in ipairs(hud.horseDebuffTiers or {}) do
        if r.uidd and horse and CuraEqui.Effects and CuraEqui.Effects.RemoveHorse then
            pcall(CuraEqui.Effects.RemoveHorse, horse, r.uidd)
        end
    end

    -- static sated buff
    local uuid = CuraEqui.Buffs and CuraEqui.Buffs.BUFF_UUID_SATED
    if uuid and CuraEqui.Effects and CuraEqui.Effects.RemovePlayer then
        pcall(CuraEqui.Effects.RemovePlayer, uuid)
    end

    CuraEqui.Buffs._lastSatedUuid = nil
end

function CuraEqui.Buffs.SweepPlayerSatedEffects(tag)
    local uuid = CuraEqui.Buffs and CuraEqui.Buffs.BUFF_UUID_SATED
    if uuid and CuraEqui.Effects and CuraEqui.Effects.PlayerRemove then
        pcall(CuraEqui.Effects.PlayerRemove, uuid)
    end
    CuraEqui.Buffs._lastSatedUuid = nil
end
