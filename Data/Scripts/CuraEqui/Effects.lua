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

-- Verbose/normal logger that respects Config.Debug flags
local function vlog(level, fmt, ...)
    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if level == "v" then
        if not (D and D.buffTraceVerbose) then return end
    else -- "n" (normal)
        if not (D and D.buffTrace) then return end
    end
    System.LogAlways(("[CuraEqui][Effects] " .. fmt):format(...))
end

-- Player: remove by GUID  (add 'quiet' param)
function CuraEqui.Effects.RemovePlayer(guid, quiet)
    if not _has(guid) then return false end
    local s = _playerSoul(); if not (s and s.RemoveAllBuffsByGuid) then
        vlog("n", "player remove: no soul/api"); return false
    end
    local ok = pcall(function() s:RemoveAllBuffsByGuid(guid) end)
    if not quiet then
        vlog("v", "player remove %s ok=%s", guid, tostring(ok))
    end
    return ok and true or false
end

function CuraEqui.Effects.ApplyPlayer(guid)
    if not _has(guid) then
        vlog("n", "player apply: empty guid"); return false
    end

    local s = _playerSoul()
    if not (s and s.AddBuff) then
        vlog("n", "player apply: no soul/api"); return false
    end

    -- Idempotent: remove same GUID before adding (only once AddBuff is available)
    if s.RemoveAllBuffsByGuid then
        pcall(function() s:RemoveAllBuffsByGuid(guid) end)
    end

    local ok, inst = pcall(function() return s:AddBuff(guid) end)
    vlog("n", "player apply %s ok=%s inst=%s", guid, tostring(ok), tostring(inst))
    return ok and true or false
end

-- Horse: remove/apply (gate these as 'normal', not always)
function CuraEqui.Effects.RemoveHorse(ent, guid)
    if not (ent and _has(guid)) then return false end
    local s = ent.soul; if not (s and s.RemoveAllBuffsByGuid) then
        vlog("n", "horse remove: no soul/api"); return false
    end
    local ok = pcall(function() s:RemoveAllBuffsByGuid(guid) end)
    vlog("n", "horse remove %s ok=%s", guid, tostring(ok))
    return ok and true or false
end

function CuraEqui.Effects.ApplyHorse(ent, guid)
    if not (ent and _has(guid)) then
        vlog("n", "horse apply: missing ent/guid"); return false
    end
    local s = ent.soul; if not (s and s.AddBuff) then
        vlog("n", "horse apply: no soul/api"); return false
    end

    if s.RemoveAllBuffsByGuid then
        pcall(function() s:RemoveAllBuffsByGuid(guid) end)
    end

    local ok, inst = pcall(function() return s:AddBuff(guid) end)
    vlog("n", "horse apply %s ok=%s inst=%s", guid, tostring(ok), tostring(inst))
    return ok and true or false
end

-- Clear helpers (iterate our tier GUIDs) – use 'quiet' removals and 1 summary line
function CuraEqui.Effects.ClearPlayerStatus()
    local s = _playerSoul()
    if not (s and s.RemoveAllBuffsByGuid) then
        return false
    end

    local hud = CuraEqui.Config and CuraEqui.Config.HUD or {}
    local list = hud.playerStatusTiers or {}

    local removedAny = false
    for i = 1, #list do
        local row  = list[i] or {}
        local guid = row.uuid or row.uidd -- accept both
        if guid and guid ~= "" then
            pcall(function() s:RemoveAllBuffsByGuid(guid) end)
            removedAny = true
        end
    end

    return removedAny
end

function CuraEqui.Effects.ClearHorseDebuffs(ent)
    if not ent then return false end

    local s = ent.soul
    if not (s and s.RemoveAllBuffsByGuid) then
        vlog("n", "horse clear: no soul/api")
        return false
    end

    local list = CuraEqui.Config and CuraEqui.Config.HUD and CuraEqui.Config.HUD.horseDebuffTiers or {}

    for i = 1, #list do
        local g = list[i] and list[i].uidd
        if _has(g) then
            pcall(function() s:RemoveAllBuffsByGuid(g) end)
        end
    end

    -- clear attempt succeeded" == API existed, not "removedAny"
    return true
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
            pcall(E.RemovePlayer, uuid) -- you already have Remove(target, uuid)
        end
    end)
    return true
end

function E.ClearPlayerSatedTimers(uuids)
    if not uuids then return end
    for _, u in ipairs(uuids) do pcall(E.RemovePlayer, u) end
end
