-- Scripts/CuraEqui/Horse.lua
local QH = function(fmt, ...) CuraEqui.Log("Horse", fmt, ...) end
CuraEqui.Horse = CuraEqui.Horse or { playerHorseId = nil }
CuraEqui.HorseState = CuraEqui.HorseState or {}
CuraEqui.HorseCfg = CuraEqui.HorseCfg or
    { hungerMax = 100, hungerStart = 30, tickSec = 10, debuffAt = 70 }

local function FeedLog(fmt, ...)
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    if not (D and D.feedTrace) then return end
    CuraEqui.Log("Feed", fmt, ...)
end

local function _feed_toast_cfg()
    local F = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
    local lane = F.toastLane or "tutorial"
    local ms = math.max(200, math.floor((tonumber(F.toastSec) or 2.0) * 1000))
    return lane, ms
end

-- ——— WUID → item info (classId, names, qty) ———
local function _inv_get_info(wuid)
    local t = nil
    if ItemManager and ItemManager.GetItem then
        local ok, obj = pcall(ItemManager.GetItem, wuid); if ok and type(obj) == "table" then t = obj end
    end
    if not t then return { wuid = tostring(wuid) } end

    local classId = t.classId or t.class or t.class_id or t.type or t.kind
    local ui, db = nil, nil
    if classId and ItemManager then
        pcall(function() ui = ItemManager.GetItemUIName(classId) end)
        pcall(function() db = ItemManager.GetItemName(classId) end)
    end

    -- qty: prefer field 'amount', then method 'GetAmount' (Smith’s Reach pattern)
    local amt = rawget(t, "amount") or rawget(t, "Amount")
    if amt == nil then
        local getter = rawget(t, "GetAmount") or rawget(t, "getAmount")
        if type(getter) == "function" then
            local ok, q = pcall(getter, t); if ok then amt = q end
        end
    end
    if type(amt) ~= "number" then amt = tonumber(amt) or 1 end
    if amt < 1 then amt = 1 end

    return { wuid = tostring(wuid), classId = classId, uiName = ui, dbName = db, qty = amt }
end

-- Per-unit nutrition resolver: DietData.byGuid → keyword map/list → default
local function _per_unit_from_info(info)
    local label  = info.uiName or info.dbName or "food"

    -- 1) exact class match from DietData
    local DD     = CuraEqui.DietData or CuraEqui.Diet or {}
    local byGuid = DD.byGuid or DD.ByGuid or {}
    local rec    = info.classId and byGuid[info.classId] or nil
    if rec then
        local v = tonumber(rec.nutrition or 0) or 0
        if v > 0 then return v, (rec.token or label) end
    end

    -- 2) keywords (supports either a list or a {kw=value} map), only if allowed
    local DCFG = (CuraEqui.Config and CuraEqui.Config.Diet) or {}
    local allowKW = (DCFG.allowKeywordFallback == true)
    if allowKW then
        local kws  = DCFG.allowKeywords or { "apple", "bread", "carrot" }
        local name = tostring(label):lower()

        if #kws > 0 then
            -- list → use keywordNutrition
            local perKW = tonumber(DCFG.keywordNutrition or 10) or 10
            for _, kw in ipairs(kws) do
                kw = tostring(kw):lower()
                if kw ~= "" and name:find(kw, 1, true) then
                    return perKW, kw
                end
            end
        else
            -- map → per-keyword values
            for kw, val in pairs(kws) do
                local kwl = tostring(kw):lower()
                if kwl ~= "" and name:find(kwl, 1, true) then
                    local v = tonumber(val) or 0
                    if v > 0 then return v, kw end
                end
            end
        end
    end

    -- 3) default (nothing matched)
    return 0, label
end

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

-- Collect selected items - store light info for logs & nutrition
function Horse:OnInventoryItemUsed(id)
    self._feedSel = self._feedSel or {}
    local info    = _inv_get_info(id)
    info._wuid    = id           -- keep the real handle for DeleteItem
    info.wuidStr  = tostring(id) -- for logs
    table.insert(self._feedSel, info)
    FeedLog(("[CuraEqui][Feed] Picked: %s (class=%s, qty=%s)")
        :format(tostring(info.uiName or info.dbName or info.wuidStr), tostring(info.classId), tostring(info.qty)))
end

-- Vanilla-style: simulate feeding on close (no removal yet)
function Horse:OnInventoryClosed()
    local picks   = self._feedSel or {}
    self._feedSel = nil

    local CFG     = CuraEqui.Config or {}
    local FCFG    = CFG.Feeding or {}
    local over    = (FCFG.overfeedPolicy or "allow")

    -- fall back to your old path if not in "vanilla" mode
    if (FCFG.style or "vanilla") ~= "vanilla" then
        if CuraEqui._InvClose_Disarm then CuraEqui._InvClose_Disarm("picker_used") end
        if CuraEqui.Feed_StartScan then
            local post = (CFG.FeedScan and CFG.FeedScan.postCloseWindowSec) or 10.0
            CuraEqui.Feed_StartScan(post)
        end
        return
    end

    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(self)
    if not S then
        System.LogAlways("[CuraEqui][Feed] close: no horse state"); return
    end

    local curH = tonumber(S.hunger or 0) or 0
    local cap  = tonumber(FCFG.needCapPerFeed or 25) or 25
    local need = math.max(0, math.min(cap, curH)) -- you can only reduce what you have

    if need <= 0 then
        if FCFG.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast then
            CuraEqui.UI.Toast("@curaequi_horse_full", 300, 0, "CuraEquiFeed", "infotext")
        end
        return
    end

    -- plan how many UNITS to take per WUID
    local removePlan, used = {}, 0 -- removePlan[key] = { wuid, units, label, per }

    for _, info in ipairs(picks) do
        if need <= 0 then break end
        local per, label = _per_unit_from_info(info)
        if per > 0 then
            local maxUnits = tonumber(info.qty or 1) or 1
            local want     = math.floor(need / per)
            if (want * per) < need and over == "allow" then want = want + 1 end
            want = math.max(0, math.min(want, maxUnits))
            if want > 0 then
                local key = info.wuidStr or tostring(info._wuid)
                local rec = removePlan[key]
                if not rec then
                    rec = { wuid = info._wuid, units = 0, label = label, per = per }
                    removePlan[key] = rec
                end
                rec.units = rec.units + want
                local gain = want * per
                used = used + gain
                need = math.max(0, need - gain)
            end
        end
    end

    -- apply hunger & report
    if used <= 0 then
        -- No summary; just the full message (already shown above if triggered)
        if FCFG.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast then
            CuraEqui.UI.Toast("@curaequi_horse_full", 3, 0, "CuraEquiFeed", "infotext")
        end
        FeedLog("Nothing applicable selected → no consumption")
        return
    end

    local newH = math.max(0, curH - used)
    S.hunger   = newH

    -- (optional) immediate buff sync so HUD updates now
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
        CuraEqui.Buffs.SyncAll(self, S)
    end

    local parts = {}
    for _, rec in pairs(removePlan) do
        parts[#parts + 1] = { label = rec.label, units = rec.units, total = rec.units * rec.per }
    end

    -- right-corner dev toasts per type, then a compact summary
    do
        local lane, ms = _feed_toast_cfg()
        if FCFG.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast then
            -- per-type lines: "carrot x2 (-24)"
            for i = 1, #parts do
                local p = parts[i]
                CuraEqui.UI.Toast(string.format("%s x%d (-%d)", p.label, p.units, p.total),
                    ms, 0, "CuraEqui_FeedType", lane)
            end
            -- summary: "Fed 3 type(s) (-36) → 12%"
            local msg = string.format("Fed %d type(s) (-%d) → %d%%", #parts, used, math.floor(newH))
            CuraEqui.UI.Toast(msg, ms, 0, "CuraEqui_FeedSummary", lane)
        end
    end

    -- quieter console unless feedTrace=true
    do
        local details = {}
        for i = 1, #parts do
            local p = parts[i]
            details[#details + 1] = string.format("%s x%d (-%d)", p.label, p.units, p.total)
        end
        FeedLog("Fed %d type(s) (-%d) → %d%% | %s",
            #parts, used, math.floor(newH), table.concat(details, ", "))
    end

    -- delete planned units (one call per WUID)
    if FCFG.removeItems then
        local inv = (player and (player.inventory or (player.actor and player.actor.inventory))) or nil
        if not inv or not inv.DeleteItem then
            System.LogAlways("[CuraEqui][Feed][WARN] inventory:DeleteItem not available; keeping items.")
            return
        end
        local removed, failed = 0, 0
        for _, rec in pairs(removePlan) do
            if rec.units and rec.units > 0 then
                local ok = pcall(inv.DeleteItem, inv, rec.wuid, rec.units)
                if ok then removed = removed + rec.units else failed = failed + rec.units end
            end
        end
        if failed > 0 then
            System.LogAlways(("[CuraEqui][Feed][WARN] Remove: %d ok, %d fail via inventory:DeleteItem"):format(removed,
                failed))
        else
            FeedLog("Remove: %d unit(s) ok via inventory:DeleteItem", removed)
        end
    end
end
