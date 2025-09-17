-- Scripts/CuraEqui/Horse.lua
local QH = function(fmt, ...) CuraEqui.Log("Horse", fmt, ...) end
CuraEqui.Horse = CuraEqui.Horse or { playerHorseId = nil }
CuraEqui.HorseState = CuraEqui.HorseState or {}
CuraEqui.HorseCfg = CuraEqui.HorseCfg or
    { hungerMax = 100, hungerStart = 30, tickSec = 10, debuffAt = 70 }

function CuraEqui.Horse.Debug_LogPlayerHorseHandles()
    local function log(label, ok, val)
        local t = type(val)
        System.LogAlways(("[CuraEqui][Horse][dbg] %s -> ok=%s type=%s val=%s")
            :format(label, tostring(ok), t, tostring(val)))
    end

    -- Try all likely bindings (dot/colon/legacy) + the player form
    local ok, v

    if Game and Game.GetPlayerHorse then
        ok, v = pcall(Game.GetPlayerHorse, Game); log("Game:GetPlayerHorse(dot)", ok, v)
    end
    if Game and Game.GetPlayerHorse then
        ok, v = pcall(Game.GetPlayerHorse, Game); log("Game:GetPlayerHorse(colon)", ok, v)
    end
    if g_gameRules and g_gameRules.game and g_gameRules.game.GetPlayerHorse then
        ok, v = pcall(g_gameRules.game.GetPlayerHorse, g_gameRules.game); log("g_gameRules.game:GetPlayerHorse", ok, v)
    end
    if player and player.player and player.player.GetPlayerHorse then
        ok, v = pcall(player.player.GetPlayerHorse, player.player); log("player.player:GetPlayerHorse (WUID expected)",
            ok, v)
    end

    -- Player->HorseId fallback
    if player and player.actor and player.actor.GetHorseId then
        ok, v = pcall(player.actor.GetHorseId, player.actor); log("player.actor:GetHorseId (entityId)", ok, v)
    end
end

function CuraEqui.Horse.Has()
    local h = CuraEqui.Horse.Resolve()
    if h and h.id and System.GetEntity(h.id) then
        return true, h
    end
    return false
end

-- Returns the player's horse entity or nil. Caches id when found.
function CuraEqui.Horse.Resolve()
    local ent

    -- 0) cached
    if CuraEqui.Horse.playerHorseId then ent = System.GetEntity(CuraEqui.Horse.playerHorseId) end
    if ent then return ent end

    -- helper: coerce various handles into an entity
    local function asEnt(handle)
        if not handle then return nil end
        local ty = type(handle)
        if ty == "number" then return System.GetEntity(handle) end
        if ty == "table" and handle.id then return handle end
        -- WUID path (string/userdata depending on binding)
        if XGenAIModule and (ty == "string" or ty == "userdata") then
            local id = XGenAIModule.GetEntityIdByWUID(handle)
            if id and id ~= 0 then return System.GetEntity(id) end
            local e = XGenAIModule.GetEntityByWUID(handle)
            if e and e.id then return e end
        end
        return nil
    end

    -- 1) prefer player.player:GetPlayerHorse() → WUID (as in NoHorseTeleport)
    if player and player.player and player.player.GetPlayerHorse then
        local ok, wuid = pcall(player.player.GetPlayerHorse, player.player)
        if ok then ent = asEnt(wuid) end
    end

    -- 2) engine helpers (dot/colon/legacy variants)
    if not ent and Game and Game.GetPlayerHorse then
        local ok, h = pcall(Game.GetPlayerHorse, Game); if ok then ent = asEnt(h) end
        if not ent then
            ok, h = pcall(Game.GetPlayerHorse, Game); if ok then ent = asEnt(h) end
        end
    end
    if not ent and g_gameRules and g_gameRules.game and g_gameRules.game.GetPlayerHorse then
        local ok, h = pcall(g_gameRules.game.GetPlayerHorse, g_gameRules.game); if ok then ent = asEnt(h) end
    end

    -- 3) fallback: player.actor:GetHorseId() → entity id
    if not ent and player and player.actor and player.actor.GetHorseId then
        local ok, hid = pcall(player.actor.GetHorseId, player.actor)
        if ok then ent = asEnt(hid) end
    end

    if ent and ent.id then
        CuraEqui.Horse.playerHorseId = ent.id
        return ent
    end
    return nil
end

-- Logs what the various helpers return at this moment (WUID vs id vs nil)

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

function CuraEqui.Horse.IsMounted()
    local ok, v = pcall(function()
        if player and player.human and player.human.IsMounted then
            return player.human:IsMounted()
        end
        -- fallback if needed
        if player and player.actor and player.actor.IsMounted then
            return player.actor:IsMounted()
        end
        return false
    end)
    return (ok and v) and true or false
end

-- 1) collect picks
function Horse:OnInventoryItemUsed(id)
    self._feedSel = self._feedSel or {}
    table.insert(self._feedSel, id)

    -- optional debug: print a readable name if available
    local readable = nil
    pcall(function() readable = Framework and Framework.WUIDToMsg and Framework.WUIDToMsg(id) or nil end)
    System.LogAlways(("[CuraEqui][Feed] OnInventoryItemUsed id=%s name=%s")
        :format(tostring(id), tostring(readable)))
end

-- 2) finalize on close (vanilla simulation)
function Horse:OnInventoryClosed()
    local picks   = self._feedSel or {}
    self._feedSel = nil

    local CFG     = CuraEqui.Config or {}
    local FCFG    = CFG.Feeding or {}
    local DCFG    = CFG.Diet or {}

    -- only run the vanilla path when selected
    if (FCFG.style or "vanilla") ~= "vanilla" then
        -- keep your existing post-close scan path for other styles
        if CuraEqui._InvClose_Disarm then CuraEqui._InvClose_Disarm("picker_used") end
        if CuraEqui.Feed_StartScan then
            local post = (CFG.FeedScan and CFG.FeedScan.postCloseWindowSec) or 10.0
            CuraEqui.Feed_StartScan(post)
        end
        return
    end

    local hS = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(self)
    if not hS then
        System.LogAlways("[CuraEqui][Feed] OnInventoryClosed: no horse state")
        return
    end

    local hungerMax = CuraEqui.HorseCfg and (CuraEqui.HorseCfg.hungerMax or 100) or 100
    local hungerNow = tonumber(hS.hunger or 0) or 0
    local cap       = tonumber(FCFG.needCapPerFeed or 25) or 25
    local need      = math.max(0, math.min(cap, hungerMax - hungerNow))
    if need <= 0 then
        if FCFG.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast then
            CuraEqui.UI.Toast("Horse is full.", 1800, 0, "CuraEqui_Status", "center")
        end
        return
    end

    -- simple nutrition from Diet keywords using the readable WUID string
    local kws     = DCFG.allowKeywords or { "apple", "bread", "carrot" }
    local perKW   = tonumber(DCFG.keywordNutrition or 10) or 10
    local used    = 0
    local fedFrom = {}

    local function nutrition_from_wuid(wuid)
        local name = ""
        pcall(function()
            name = Framework and Framework.WUIDToMsg and (Framework.WUIDToMsg(wuid) or "") or ""
        end)
        name = tostring(name):lower()
        for _, kw in ipairs(kws) do
            kw = tostring(kw):lower()
            if kw ~= "" and name:find(kw, 1, true) then
                return perKW, kw
            end
        end
        return 0, nil
    end

    -- Iterate selected items in order (no removal yet, just simulate)
    local overPolicy = (FCFG.overfeedPolicy or "allow")
    for _, wuid in ipairs(picks) do
        if need <= 0 then break end
        local gain, tag = nutrition_from_wuid(wuid)
        if gain > 0 then
            if gain > need and overPolicy == "skip" then
                -- skip too-strong single items if policy demands
            else
                local take          = math.min(gain, need)
                used                = used + take
                need                = need - take
                fedFrom[#fedFrom + 1] = { kw = tag or "food", val = take }
            end
        end
    end

    if used > 0 then
        local newH  = math.min(hungerMax, hungerNow + used)
        hS.hunger   = newH

        -- toast + log
        local parts = {}
        for i, f in ipairs(fedFrom) do parts[#parts + 1] = string.format("%s +%d", f.kw, f.val) end
        local msg = string.format("Fed %d item(s) (+%d).", #fedFrom, used)
        if FCFG.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast then
            CuraEqui.UI.Toast(msg, 2000, 0, "CuraEqui_Status", "center")
        end
        System.LogAlways("[CuraEqui][Feed] " .. msg .. " details: " .. table.concat(parts, ", "))
    else
        if FCFG.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast then
            CuraEqui.UI.Toast("No edible items in selection.", 1800, 0, "CuraEqui_Status", "center")
        end
    end

    -- NOTE: we did NOT remove items yet. That’s Phase 2 once we confirm removal API.
end
