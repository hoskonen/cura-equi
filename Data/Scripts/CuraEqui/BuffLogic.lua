-- === CuraEqui / BuffLogic.lua ===
CuraEqui              = CuraEqui or {}
CuraEqui.Buffs        = CuraEqui.Buffs or {}
local M               = CuraEqui.Buffs

-- module locals
M._lastPlayerUuid     = M._lastPlayerUuid or nil
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false
M._playerGen          = M._playerGen or 0

-- Timed "Sated" tiers (descending). UUIDs must match buff__curaequi.xml
M.SATED_TIERS         = {
    { sec = 2000, uuid = "f5a6b7c8-9d0e-4be4-9a8b-9f0a1b2c3d4e" },
    { sec = 1900, uuid = "e4f5a6b7-8c9d-4ad3-8b9a-8e9f0a1b2c3d" },
    { sec = 1800, uuid = "d3e4f5a6-7b8c-4fc2-9a8b-7d8e9f0a1b2c" },
    { sec = 1700, uuid = "c2d3e4f5-6a7b-4eb1-8b9c-6c7d8e9f0a1b" },
    { sec = 1600, uuid = "b1c2d3e4-5f6a-4da0-9a8c-5b6c7d8e9f0a" },
    { sec = 1500, uuid = "a0b1c2d3-4e5f-4b99-8c9b-4a5b6c7d8e9f" },
    { sec = 1400, uuid = "9d3f5b7c-2e4a-4a88-b8a9-3f4a5b6c7d8e" },
    { sec = 1300, uuid = "7c2e4a6b-1d3f-4f77-8b9c-2e3f4a5b6c7d" },
    { sec = 1200, uuid = "6b1d3f5a-9c2e-4e66-9a8c-1d2e3f4a5b6c" },
    { sec = 1100, uuid = "5a3c1e7d-2b8f-4d55-8b9a-0c1d2e3f4a5b" },
    { sec = 1000, uuid = "4f1a2b3c-8d7e-4c44-9a8b-7c0d1e2f3a4b" },
    { sec = 900,  uuid = "3e5a7c19-5d2b-4a33-a8b9-6f1e2d3c4b5a" },
    { sec = 800,  uuid = "2c7e5a91-6b3d-4f22-8c9d-5e1a3b7c0d2f" },
    { sec = 700,  uuid = "1a9c3e5b-7d2f-4e10-9b8a-3c1d5e7f0a2b" },
    { sec = 600,  uuid = "8f6d7a21-3c5e-4b2a-8a6f-2f19b7e3c4d1" },
    { sec = 500,  uuid = "7b3e1a6a-23f4-41af-b892-205d8340d6ee" },
    { sec = 400,  uuid = "6eecf4fa-9b5e-48bb-9b02-3875f9f609b7" },
    { sec = 300,  uuid = "7a0a5c5c-5c9c-44ed-9b46-9184b75e3c3c" },
    { sec = 200,  uuid = "f9ad23a8-7d3d-4e43-96f2-1d5cc84f2d40" },
    { sec = 100,  uuid = "c5b2d9f6-12f1-44d4-b04c-46f6b3e5c711" },
}

-- pick tier name from hunger/sated (HUD thresholds)
local function _now() return (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock() end
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

    -- 🔹 if Sated timer is active, don't show any status-tier (OK/min/mod/crit)
    do
        local now  = _now()
        local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
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

local function _pick_bucket_floor(remS)
    remS = math.max(0, tonumber(remS or 0) or 0)
    for _, t in ipairs(M.SATED_TIERS) do
        if remS >= t.sec then return t end
    end
    if remS > 0 then return M.SATED_TIERS[#M.SATED_TIERS] end -- show 100 for tiny remainders
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

-- remove all sated timed-buffs (player channel), using the tier table
function CuraEqui.Buffs.ClearSatedTimers()
    local M = CuraEqui.Buffs
    if not (M and M.SATED_TIERS) then return end
    for _, t in ipairs(M.SATED_TIERS) do
        local uid = t.uid or t.uuid or t.uidd
        if uid and CuraEqui.Effects and CuraEqui.Effects.RemovePlayer then
            pcall(CuraEqui.Effects.RemovePlayer, uid)
        end
    end
    M._lastSatedUuid = nil
end

-- opts.force=true → re-apply even if bucket unchanged (used after feeding/load/diet)
function CuraEqui.Buffs.SyncSatedTimer(h, S, opts)
    local D    = CuraEqui.Config and CuraEqui.Config.Debug or {}
    local now  = _now()
    local remS = math.max(0, (tonumber(S and S.satedUntil or 0) or 0) - now)

    if D and D.buffTraceVerbose then
        System.LogAlways(("[CuraEqui][SatedSync] cause=%s force=%s rem=%.0fs")
            :format(tostring(opts and opts.cause or "tick"), tostring(opts and opts.force or false), remS))
    end

    -- nothing tracked → make sure no timed tier lingers
    if not S then
        if M._lastSatedUuid then
            M.ClearSatedTimers(); M._lastSatedUuid = nil
        end
        return
    end

    -- block re-entrant force bursts (startup races)
    if M._satedFence and now < M._satedFence then
        if D and D.buffTraceVerbose then System.LogAlways("[CuraEqui][SatedSync] fenced (drop reentry)") end
        return
    end

    -- expired → clear once and leave
    if remS <= 0 then
        if M._lastSatedUuid then
            M.ClearSatedTimers(); M._lastSatedUuid = nil
        end
        return
    end

    -- compute desired bucket (ceil so UI shows full tier)
    local bucket = _pick_bucket_ceil(remS)
    if not bucket or not bucket.uuid then return end

    local forcing = (opts and opts.force) == true

    -- mid-run (no force) and already on this bucket → do nothing
    if (not forcing) and M._lastSatedUuid == bucket.uuid then
        if D and D.buffTraceVerbose then
            System.LogAlways(("[CuraEqui][Buff] Sated: skip mid-run (rem=%.0fs, last=%s)")
                :format(remS, tostring(M._lastSatedUuid)))
        end
        return
    end

    -- mid-run (no force) but bucket would change (e.g., we grew/rounded) → DO NOT switch mid-run
    if (not forcing) and M._lastSatedUuid and M._lastSatedUuid ~= bucket.uuid then
        if D and D.buffTraceVerbose then
            System.LogAlways(("[CuraEqui][Buff] Sated: hold bucket mid-run (rem=%.0fs, last=%s, want=%s)")
                :format(remS, tostring(M._lastSatedUuid), tostring(bucket.uuid)))
        end
        return
    end

    -- (re)apply path: clear all timed sated tiers, then apply exactly one
    M.ClearSatedTimers()
    local ok = false
    if CuraEqui.Effects and CuraEqui.Effects.ApplyPlayer then
        ok = pcall(CuraEqui.Effects.ApplyPlayer, bucket.uuid)
    end

    if ok then
        M._lastSatedUuid = bucket.uuid
        M._satedFence    = now + 0.30 -- small debounce window
    else
        M._lastSatedUuid = nil
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
