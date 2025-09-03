-- Scripts/CuraEqui/Horse.lua
local QH = function(fmt, ...) CuraEqui.Log("Horse", fmt, ...) end
CuraEqui.Horse = CuraEqui.Horse or { playerHorseId = nil }
CuraEqui.HorseState = CuraEqui.HorseState or {}
CuraEqui.HorseCfg = CuraEqui.HorseCfg or
    { hungerMax = 100, hungerStart = 30, tickSec = 10, ratePerMin = 1.0, ratePerKm = 15.0, debuffAt = 70 }

function CuraEqui.Horse.Resolve()
    local ent

    -- 1) fastest: stored id from our OnMount hook
    if CuraEqui.Horse.playerHorseId then
        ent = System.GetEntity(CuraEqui.Horse.playerHorseId)
    end

    -- 2) engine helper
    if not ent then
        pcall(function()
            if Game and Game.GetPlayerHorse then ent = Game:GetPlayerHorse() end
        end)
    end

    -- 3) player->horse id fallback
    if not ent and player and player.actor and player.actor.GetHorseId then
        local hid = player.actor:GetHorseId()
        if hid then ent = System.GetEntity(hid) end
    end

    if ent and ent.id then
        CuraEqui.Horse.playerHorseId = ent.id -- keep it fresh
    end
    return ent
end

do
    local H = _G.Horse
    if H and type(H.OnMount) == "function" and not H.__curaequi_mount then
        local base = H.OnMount
        function H:OnMount(user, ...)
            local r = base(self, user, ...); if player and user and user.id == player.id then
                CuraEqui.Horse.playerHorseId = self.id; QH("OnMount → %s", tostring(self.id))
            end; return r
        end

        H.__curaequi_mount = true
    end
end
Script.SetTimer(1000, function() CuraEqui.Horse.Resolve() end)

function CuraEqui.HorseStateGet(horse)
    if not (horse and horse.id) then return nil end
    local S = CuraEqui.HorseState[horse.id]
    if not S then
        S = {
            hunger        = CuraEqui.HorseCfg.hungerStart,
            lastFedAt     = os.time(),
            dist          = 0.0, -- meters within current km
            totalDist     = 0.0, -- meters total (debug/UX)
            feedHistory   = {},
            _lastPos      = nil,
            _warned       = nil,
            _dbgNextLogAt = 100.0,
        }
        CuraEqui.HorseState[horse.id] = S
    end
    return S
end
