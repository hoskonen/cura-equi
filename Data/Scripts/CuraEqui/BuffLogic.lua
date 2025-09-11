-- === CuraEqui / BuffLogic.lua ===
CuraEqui = CuraEqui or {}
CuraEqui.Buffs = CuraEqui.Buffs or {}
local M = CuraEqui.Buffs

-- helpers
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

-- EXPORT for HUD/debug callers
M._pickTierName = _pickTierName

local function _uuidFromList(list, name)
    if not list then return "" end
    for i = 1, #list do
        local r = list[i]; if r and r.name == name then return r.uidd or "" end
    end
    return ""
end

local function _short(u)
    if not u or u == "" then return "-" end
    return (#u > 8) and (u:sub(1, 8) .. "…") or u
end

-- state
M._lastPlayerUuid = nil -- last player status GUID

-- Player status (icon/text on player)
function M.SyncPlayerStatus(horseEnt, S)
    local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers
    if not horseEnt or not S or not list then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
        end
        return
    end

    local hval = tonumber(S.hunger or 0) or 0
    local tier = _pickTierName(hval, S.satedUntil)
    local uuid = _uuidFromList(list, tier)

    -- decision log (runs even when uuid = "")
    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.enabled then
        local now = (Script and Script.GetTime and Script.GetTime()) or os.clock()
        local rem = math.max(0, (S.satedUntil or 0) - now)
        CuraEqui.Log("buff", "PlayerStatus pick tier=%s hunger=%d remSated=%.1f uuid=%s",
            tier, hval, rem, _short(uuid))
    end

    if not uuid or uuid == "" then
        if M._lastPlayerUuid then
            CuraEqui.Effects.ClearPlayerStatus(); M._lastPlayerUuid = nil
        end
        return
    end

    if uuid ~= M._lastPlayerUuid then
        CuraEqui.Effects.ClearPlayerStatus()
        CuraEqui.Effects.ApplyPlayer(uuid)
        M._lastPlayerUuid = uuid
        CuraEqui.Log("buff", "PlayerStatus → %s (%s)", tier, uuid)
    end
end

-- Horse invisible debuff/bonus (mechanics)
function M.SyncHorseDebuff(horseEnt, S)
    local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.horseDebuffTiers
    if not horseEnt or not S or not list then return end

    local hval = tonumber(S.hunger or 0) or 0
    local tier = _pickTierName(hval, S.satedUntil)
    local uuid = _uuidFromList(list, tier)
    local last = S._lastHorseDebuffUuid

    -- decision log
    if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.enabled then
        CuraEqui.Log("buff", "HorseDebuff pick tier=%s hunger=%d uuid=%s last=%s",
            tier, hval, _short(uuid), _short(last))
    end

    if not uuid or uuid == "" then
        if last then
            CuraEqui.Effects.ClearHorseDebuffs(horseEnt); S._lastHorseDebuffUuid = nil
        end
        return
    end

    -- get the player row for same tier
    local plist = CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers
    local pGuid = ""
    if plist then
        for i = 1, #plist do
            local r = plist[i]; if r.name == tier then
                pGuid = r.uidd or ""
                break
            end
        end
    end

    if pGuid ~= "" and uuid == pGuid then
        if CuraEqui.Config.Debug and CuraEqui.Config.Debug.enabled then
            CuraEqui.Log("buff", "HorseDebuff skipped: GUID clashes with player tier (%s)", uuid)
        end
        return
    end


    if uuid ~= last then
        CuraEqui.Effects.ClearHorseDebuffs(horseEnt)
        CuraEqui.Effects.ApplyHorse(horseEnt, uuid)
        S._lastHorseDebuffUuid = uuid
        if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.enabled then
            CuraEqui.Log("buff", "HorseDebuff → %s (%s)", tier, uuid)
        end
    end
end

function M.SyncAll(horseEnt, S)
    M.SyncHorseDebuff(horseEnt, S)
    M.SyncPlayerStatus(horseEnt, S)
end
