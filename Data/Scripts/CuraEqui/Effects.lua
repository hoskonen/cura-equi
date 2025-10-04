-- Scripts/CuraEqui/Effects.lua
System.LogAlways("[CuraEqui][Buff] Effects loaded")

CuraEqui.Effects = CuraEqui.Effects or {}
local E = CuraEqui.Effects

E._satedGen = E._satedGen or 0

local function _playerSoul()
    local p = g_localActor or player
    return p and p.soul or nil
end

local function _has(s) return s and s ~= "" end
local function log(fmt, ...) System.LogAlways(("[CuraEqui][Buff] " .. fmt):format(...)) end

-- Player: remove by GUID (unchanged)
function CuraEqui.Effects.RemovePlayer(guid)
    if not _has(guid) then return false end
    local s = _playerSoul(); if not (s and s.RemoveAllBuffsByGuid) then
        log("player remove: no soul/api"); return false
    end
    local ok = pcall(function() s:RemoveAllBuffsByGuid(guid) end)
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    if D and D.buffTraceVerbose then
        CuraEqui.Log("Buff", "player remove %s ok=%s", uuid, tostring(ok))
    end
    return ok and true or false
end

-- Player: APPLY by GUID (this is the important fix)
function CuraEqui.Effects.ApplyPlayer(guid)
    if not _has(guid) then
        log("player apply: empty guid"); return false
    end
    local s = _playerSoul(); if not (s and s.AddBuff) then
        log("player apply: no soul/api"); return false
    end
    local ok, inst = pcall(function() return s:AddBuff(guid) end)
    -- NOTE: inst may be nil even on success in this engine; don't treat as failure
    log("player apply %s ok=%s inst=%s", guid, tostring(ok), tostring(inst))
    return ok and true or false
end

-- Horse: remove/apply by GUID
function CuraEqui.Effects.RemoveHorse(ent, guid)
    if not (ent and _has(guid)) then return false end
    local s = ent.soul; if not (s and s.RemoveAllBuffsByGuid) then
        log("horse remove: no soul/api"); return false
    end
    local ok = pcall(function() s:RemoveAllBuffsByGuid(guid) end)
    log("horse remove %s ok=%s", guid, tostring(ok))
    return ok and true or false
end

function CuraEqui.Effects.ApplyHorse(ent, guid)
    if not (ent and _has(guid)) then
        log("horse apply: missing ent/guid"); return false
    end
    local s = ent.soul; if not (s and s.AddBuff) then
        log("horse apply: no soul/api"); return false
    end
    local ok, inst = pcall(function() return s:AddBuff(guid) end)
    log("horse apply %s ok=%s inst=%s", guid, tostring(ok), tostring(inst))
    return ok and true or false
end

-- Clear helpers (iterate our tier GUIDs)
function CuraEqui.Effects.ClearPlayerStatus()
    local list = CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers or {}
    for i = 1, #list do
        local g = list[i].uidd; if _has(g) then CuraEqui.Effects.RemovePlayer(g) end
    end
end

function CuraEqui.Effects.ClearHorseDebuffs(ent)
    local list = CuraEqui.Config.HUD and CuraEqui.Config.HUD.horseDebuffTiers or {}
    for i = 1, #list do
        local g = list[i].uidd; if _has(g) then CuraEqui.Effects.RemoveHorse(ent, g) end
    end
end

-- Apply a player buff and auto-remove after durationSec (fallback if engine lacks native duration)
function E.ApplyPlayerTimed(uuid, durationSec)
    if not (uuid and durationSec and durationSec > 0) then return false end
    local ok = pcall(E.ApplyPlayer, uuid) -- you already have ApplyPlayer()
    if not ok then return false end

    E._satedGen = (E._satedGen or 0) + 1
    local myGen = E._satedGen
    local ms    = math.floor(durationSec * 1000 + 0.5)

    Script.SetTimer(ms, function()
        if myGen == E._satedGen then
            pcall(E.Remove, "player", uuid) -- you already have Remove(target, uuid)
        end
    end)
    return true
end

function E.ClearPlayerSatedTimers(uuids)
    if not uuids then return end
    for _, u in ipairs(uuids) do pcall(E.Remove, "player", u) end
end
