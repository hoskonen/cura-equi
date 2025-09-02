-- Scripts/Quietus/HorseFeed_Patch.lua
-- Goal: show Feed on horse, log player-horse info, and open item transfer/filter UI from feed

Quietus = Quietus or {}
if Quietus.DEBUG == nil then Quietus.DEBUG = true end
local function Q(fmt, ...) if Quietus.DEBUG then System.LogAlways(("[Quietus][HorseFeed] " .. fmt):format(...)) end end
local function QH(fmt, ...) if Quietus.DEBUG then System.LogAlways(("[Quietus][HorseInfo] " .. fmt):format(...)) end end

-- ===== Config =====
local FORCE_LANE        = "inspect" -- "inspect" | "mount"
local FEED_LOC          = "@ui_hud_feed_horse"

-- inventory modes/filters (from ApseInventoryList)
local MODE_FILTER       = 5
local MODE_MULTISELECT  = 6
local FILTER_FOOD       = 3
local FILTER_QUEST      = 6

-- ===== Player horse resolution / ownership =====
Quietus.Horse           = Quietus.Horse or { playerHorseId = nil }

-- per-horse UI-open guard (top-level once)
Quietus.__uiOpenByHorse = Quietus.__uiOpenByHorse or {}

function Quietus.Horse.Resolve()
    local ent
    -- A) direct engine helper
    pcall(function() if Game and Game.GetPlayerHorse then ent = Game:GetPlayerHorse() end end)
    -- B) via player horse id
    if not ent then
        pcall(function()
            if player and player.actor and player.actor.GetHorseId then
                local hid = player.actor:GetHorseId()
                if hid then ent = System.GetEntity(hid) end
            end
        end)
    end
    -- C) nearby fallback
    if not ent then
        pcall(function()
            if System and System.GetEntitiesInSphere and player and player.GetWorldPos then
                local pos = player:GetWorldPos()
                local list = System.GetEntitiesInSphere(pos, 15.0) or {}
                local best, bd
                for _, e in ipairs(list) do
                    if e and (e.class == "Horse" or e.horse ~= nil) and e.GetWorldPos then
                        local ep = e:GetWorldPos(); local dx, dy, dz = ep.x - pos.x, ep.y - pos.y, ep.z - pos.z
                        local dsq = dx * dx + dy * dy + dz * dz; if not best or dsq < bd then best, bd = e, dsq end
                    end
                end
                ent = best
            end
        end)
    end

    if ent and ent.id then
        Quietus.Horse.playerHorseId = ent.id
        QH("Resolved player horse: %s (id=%s)", tostring(ent.GetName and ent:GetName() or "Horse"), tostring(ent.id))
    else
        QH("Player horse not resolved")
    end
    return ent
end

function Quietus.Horse.IsPlayerHorse(ent)
    return ent and ent.id and Quietus.Horse.playerHorseId and ent.id == Quietus.Horse.playerHorseId
end

-- keep freshest id on mount
do
    local H = _G.Horse
    if H and type(H.OnMount) == "function" and not H.__quietus_mount then
        local base = H.OnMount
        function H:OnMount(user, ...)
            local r = base(self, user, ...)
            if player and user and user.id == player.id then
                Quietus.Horse.playerHorseId = self.id
                QH("OnMount → playerHorseId=%s", tostring(self.id))
            end
            return r
        end

        H.__quietus_mount = true
    end
end

-- seed once after load
Script.SetTimer(1000, function() Quietus.Horse.Resolve() end)

-- ===== Feed handler: open UI (filtered if possible) or exchange =====
local function tryOpenFiltered(user, targetId)
    if not (user and user.actor and user.actor.OpenInventory) then return false end
    local variants = { FILTER_FOOD, tostring(FILTER_FOOD), "FOOD", "food", "3", ("3|%s"):format(tostring(FILTER_QUEST)) }
    for _, flt in ipairs(variants) do
        local ok = pcall(function() user.actor:OpenInventory(targetId, MODE_FILTER, nil, flt) end)
        if ok then
            Q("OpenInventory MODE_FILTER ok filter=%s", tostring(flt)); return true
        end
    end
    return false
end

-- HorseFeed_Patch.lua — engine-driven ItemSelection open
function Horse:OnFeedHorse(user, slot)
    System.LogAlways("[Quietus][HorseFeed] OnFeedHorse → " ..
        tostring(self.GetName and self:GetName() or self.class or "horse"))

    -- Prefer the engine helper that drives ItemSelection internally (pad-friendly)
    local ok = false
    if user and user.actor and user.actor.OpenItemSelectionFilter then
        ok = pcall(function()
            -- "food" token is sample; if your build wants numeric, pass "3" or 3 (FILTER_FOOD)
            user.actor:OpenItemSelectionFilter(self.id, "food")
        end)
    end
    if not ok and user and user.actor and user.actor.OpenItemMultiselectionFilter then
        ok = pcall(function()
            user.actor:OpenItemMultiselectionFilter(self.id, "") -- empty = all; we can filter on close
        end)
    end

    System.LogAlways("[Quietus][HorseFeed] OpenItemSelectionFilter: " .. (ok and "ok" or "failed"))
end

-- Keep these; the engine calls them after the UI is closed
function Horse:OnInventoryItemUsed(id, count)
    System.LogAlways(("[Quietus][HorseFeed] ItemUsed id=%s x%s"):format(tostring(id), tostring(count or 1)))
end

function Horse:OnInventoryClosed()
    System.LogAlways("[Quietus][HorseFeed] InventoryClosed (horse)")
    -- TODO next step: consume only food, return non-food, apply horse buff, etc.
end

-- ===== Inventory callbacks (log-only for now; consume later) =====

function Horse:OnItemExchangeClosed()
    System.LogAlways("[Quietus][HorseFeed] ItemExchangeClosed (horse)")
    self.__quietus_feed_active, self.__quietus_feed_user = nil, nil
end

-- ===== Quick horse debug =====
function Horse:QuietusDebugDump()
    local name = self.GetName and self:GetName() or self.class or "horse"
    local isMine = Quietus.Horse.IsPlayerHorse(self)
    local hp = (self.actor and self.actor.GetHealth and self.actor:GetHealth()) or "n/a"
    System.LogAlways(("[Quietus][HorseInfo] === %s id=%s (playerHorse=%s) ==="):format(name, tostring(self.id),
        tostring(isMine)))
    pcall(function()
        if self.horse and self.horse.IsMountable then
            System.LogAlways("[Quietus][HorseInfo] IsMountable=" ..
                tostring(self.horse:IsMountable()))
        end
        if self.horse and self.horse.IsMounted then
            System.LogAlways("[Quietus][HorseInfo] IsMounted=" ..
                tostring(self.horse:IsMounted()))
        end
    end)
end

-- ===== Inject Feed into Horse.GetActions (force lane, compute order) =====
do
    local H = _G.Horse
    if H and type(H.GetActions) == "function" and not H.__quietus_feed_wrapped then
        local _Get = H.GetActions
        function H.GetActions(self, user, firstFast)
            local actions = _Get(self, user, firstFast) or {}
            local alive = self and self.actor and self.actor.GetHealth and (self.actor:GetHealth() > 0) or false
            if not alive then return actions end

            -- avoid duplicates
            for i = 1, #actions do
                local a = actions[i]; if a and a.func == H.OnFeedHorse then return actions end
            end

            -- ui order → after existing
            local maxOrder = 0; for i = 1, #actions do maxOrder = math.max(maxOrder, actions[i].uiOrder or 0) end
            local uiOrder = maxOrder + 1

            -- forced lane (engine doesn't expose it on horse rows in this build)
            local lane = nil
            if FORCE_LANE == "inspect" and rawget(_G, "inr_horseInspect") then
                lane = inr_horseInspect
            elseif FORCE_LANE == "mount" and rawget(_G, "inr_horseMount") then
                lane = inr_horseMount
            end
            if not lane then
                Q("No lane available; skipping inject"); return actions
            end

            local A = Action()
                :hint(FEED_LOC)
                :action("use_horse")
                :hintType(AHT_PRESS)
                :func(H.OnFeedHorse)
                :interaction(lane)
                :uiOrder(uiOrder)
                :enabled(true)

            AddInteractorAction(actions, firstFast, A)
            Q("Injected Feed (lane=%s uiOrder=%d) count_before=%d", tostring(lane), uiOrder, #actions)
            return actions
        end

        H.__quietus_feed_wrapped = true
        System.LogAlways("[Quietus][HorseFeed] ✅ Wrapped Horse.GetActions")
    end
end
