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

-- Player: apply
function CuraEqui.Effects.ApplyPlayer(guid)
    if not _has(guid) then
        vlog("n", "player apply: empty guid"); return false
    end
    local s = _playerSoul(); if not (s and s.AddBuff) then
        vlog("n", "player apply: no soul/api"); return false
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
    local ok, inst = pcall(function() return s:AddBuff(guid) end)
    vlog("n", "horse apply %s ok=%s inst=%s", guid, tostring(ok), tostring(inst))
    return ok and true or false
end

-- Clear helpers (iterate our tier GUIDs) – use 'quiet' removals and 1 summary line
function CuraEqui.Effects.ClearPlayerStatus()
    local list = CuraEqui.Config.HUD and CuraEqui.Config.HUD.playerStatusTiers or {}
    local n = 0
    for i = 1, #list do
        local g = list[i].uidd
        if _has(g) then
            pcall(CuraEqui.Effects.RemovePlayer, g, true); n = n + 1
        end
    end
    if n > 0 then vlog("n", "player cleared %d status tiers", n) end
end

function CuraEqui.Effects.ClearHorseDebuffs(ent)
    local list = CuraEqui.Config.HUD and CuraEqui.Config.HUD.horseDebuffTiers or {}
    local n = 0
    for i = 1, #list do
        local g = list[i].uidd
        if _has(g) then
            pcall(CuraEqui.Effects.RemoveHorse, ent, g); n = n + 1
        end
    end
    if n > 0 then vlog("n", "horse cleared %d debuff tiers", n) end
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

-- Static Sated buff entrypoint.
E._satedActive = E._satedActive or false

E.SetSatedStatic = function(active, opts)
    opts           = opts or {}
    local C        = CuraEqui
    local B        = C.Buffs or {}
    local id       = B.BUFF_UUID_SATED
    local D        = C.Config and C.Config.Debug or {}

    local cause    = opts.cause or "static"
    local duration = tonumber(opts.rem or 0) or 0

    -- no GUID → nothing to do
    if not id or id == "" then
        return
    end

    -- No change? Don’t spam apply/remove or timers.
    if active == E._satedActive then
        return
    end

    if active then
        -- Transition: OFF → ON
        if duration > 0 and E.ApplyPlayerTimed then
            pcall(E.ApplyPlayerTimed, id, duration)
        else
            pcall(E.ApplyPlayer, id)
        end
        E._satedActive = true

        if D.buffTraceVerbose then
            System.LogAlways(("[CuraEqui][Effects][SatedStatic] ADD cause=%s duration=%.1fs uuid=%s")
                :format(cause, duration, id))
        end
    else
        -- Transition: ON → OFF
        if E.PlayerRemove then
            pcall(E.PlayerRemove, id)
        end
        E._satedActive = false

        if D.buffTraceVerbose then
            System.LogAlways(("[CuraEqui][Effects][SatedStatic] REMOVE cause=%s uuid=%s")
                :format(cause, id))
        end
    end
end
