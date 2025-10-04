-- === CuraEqui / BuffLogic.lua ===
CuraEqui              = CuraEqui or {}
CuraEqui.Buffs        = CuraEqui.Buffs or {}
local M               = CuraEqui.Buffs

-- module locals
M._lastPlayerUuid     = M._lastPlayerUuid or nil
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false
M._playerGen          = M._playerGen or 0

-- pick tier name from hunger/sated (HUD thresholds)
local function _now() return (Script and Script.GetTime and Script.GetTime()) or os.clock() end
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
        if r and r.name == name then return r.uidd or "" end
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

-- state
M._lastPlayerUuid     = nil -- last player status GUID

-- module locals for debouncing
M._lastPlayerUuid     = M._lastPlayerUuid or nil
M._desiredPlayerUuid  = M._desiredPlayerUuid or nil
M._playerApplyPending = M._playerApplyPending or false

function M.SyncPlayerStatus(horseEnt, S)
    -- Legacy one-time cleanup: remove any old non-timer 'sated' status buff
    if not CuraEqui._clearedLegacySated then
        CuraEqui._clearedLegacySated = true
        local LEGACY_SATED_STATUS = {
            "1a638e4c-e931-415d-b3bd-c8402ed836ea", -- <-- legacy 'sated' UUID
        }
        for _, u in ipairs(LEGACY_SATED_STATUS) do
            pcall(CuraEqui.Effects.Remove, "player", u)
        end
    end

    local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers
    if not S or not list then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
        end
        return
    end

    -- 🔹 if Sated timer is active, don't show any status-tier (OK/min/mod/crit)
    do
        local now  = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
        if remS > 0 then
            if M._lastPlayerUuid then
                -- This clears only status-tier buffs; make sure your ClearPlayerStatus() does NOT remove the sated timer UUIDs
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
        local now = (Script and Script.GetTime and Script.GetTime()) or os.clock()
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

-- ===== Visible Sated Timer (player-only; bucketed, fixed-duration buffs) =====
local M = CuraEqui.Buffs or {}
CuraEqui.Buffs = M

-- Map remaining seconds -> fixed-duration Sated buff
M.SATED_TIERS = {
    { sec = 500, uuid = "7b3e1a6a-23f4-41af-b892-205d8340d6ee" },
    { sec = 400, uuid = "6eecf4fa-9b5e-48bb-9b02-3875f9f609b7" },
    { sec = 300, uuid = "2d8939b7-8af5-40b7-a1fb-1f937a3a6afc" },
    { sec = 200, uuid = "f9ad23a8-7d3d-4e43-96f2-1d5cc84f2d40" },
    { sec = 100, uuid = "c5b2d9f6-12f1-44d4-b04c-46f6b3e5c711" },
}

local function _pick_bucket_floor(remS)
    remS = math.max(0, tonumber(remS or 0) or 0)
    for _, t in ipairs(M.SATED_TIERS) do
        if remS >= t.sec then return t end
    end
    if remS > 0 then return M.SATED_TIERS[#M.SATED_TIERS] end -- show 100 for tiny remainders
    return nil
end

function M.ClearSatedTimers()
    if not CuraEqui.Effects then return end
    for _, t in ipairs(M.SATED_TIERS) do
        pcall(CuraEqui.Effects.Remove, "player", t.uuid)
    end
end

-- opts.force=true → re-apply even if bucket unchanged (used after feeding to reset countdown)
function M.SyncSatedTimer(h, S, opts)
    if not (S and S.satedUntil) then
        if M._lastSatedUuid then
            M.ClearSatedTimers(); M._lastSatedUuid = nil
        end
        return
    end

    local now  = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
    if remS <= 0 then
        if M._lastSatedUuid then
            M.ClearSatedTimers(); M._lastSatedUuid = nil
        end
        return
    end

    local bucket = _pick_bucket_floor(remS)
    if not bucket then
        if M._lastSatedUuid then
            M.ClearSatedTimers(); M._lastSatedUuid = nil
        end
        return
    end

    if (not (opts and opts.force)) and M._lastSatedUuid == bucket.uuid then
        return -- same bucket: keep current countdown
    end

    -- Switch (or refresh): clear all, then apply fixed-duration buff (engine counts down)
    M.ClearSatedTimers()
    local ok = false
    if CuraEqui.Effects and CuraEqui.Effects.ApplyPlayer then
        ok = pcall(CuraEqui.Effects.ApplyPlayer, bucket.uuid)
    end
    if ok then M._lastSatedUuid = bucket.uuid end
end
