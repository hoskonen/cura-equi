-- Scripts/CuraEqui/Feeding.lua
local Q = function(fmt, ...) CuraEqui.Log("Feed", fmt, ...) end
local HGetState = CuraEqui.HorseStateGet

-- Feed entrypoint
function Horse:OnFeedHorse(user, _slot)
    System.LogAlways("[CuraEqui][Feed] OnFeedHorse → " ..
    tostring(self.GetName and self:GetName() or self.class or "horse"))
    self.__curaequi_used, self.__curaequi_single, self.__curaequi_consumed = {}, true, false

    local hasSel                                                           = user and user.actor and
    (user.actor.OpenItemSelectionFilter ~= nil)
    local hasMulti                                                         = user and user.actor and
    (user.actor.OpenItemMultiselectionFilter ~= nil)
    local hasXfer                                                          = self and self.actor and
    (self.actor.RequestItemExchange ~= nil)
    Q("caps: selection=%s multiselect=%s exchange=%s", tostring(hasSel), tostring(hasMulti), tostring(hasXfer))

    if hasSel then
        local ok = pcall(function() user.actor:OpenItemSelectionFilter(self.id, "") end); Q(
        "OpenItemSelectionFilter(\"\") → %s", ok and "ok" or "fail"); if ok then return end
    end
    if hasMulti then
        local ok = pcall(function() user.actor:OpenItemMultiselectionFilter(self.id, "") end); Q(
        "OpenItemMultiselectionFilter(\"\") → %s", ok and "ok" or "fail"); if ok then return end
    end
    if hasXfer then
        local ok = pcall(function() self.actor:RequestItemExchange(user.id) end); Q("RequestItemExchange → %s",
            ok and "ok" or "fail")
    else Q("No UI path available") end
end

function Horse:OnInventoryItemUsed(id, count)
    if not self.__curaequi_used then self.__curaequi_used = {} end
    if self.__curaequi_single and self.__curaequi_used[0] ~= nil then return end
    local name = "?"
    pcall(function() if Framework and Framework.WUIDToMsg then name = tostring(Framework.WUIDToMsg(id)) end end)
    self.__curaequi_used[0] = { id = id, count = count or 1, name = name }
    System.LogAlways(("[CuraEqui][Feed] Selected id=%s x%s name=%s"):format(tostring(id), tostring(count or 1),
        tostring(name)))
end

function Horse:OnInventoryClosed()
    local used = self.__curaequi_used or {}; self.__curaequi_used = {}
    if self.__curaequi_consumed then
        Q("already consumed; ignoring"); self.__curaequi_single, self.__curaequi_consumed = nil, nil; return
    end

    local consumed, fedEntry = 0, nil
    if self.__curaequi_single and used[0] and used[0].id then
        pcall(function() if player and player.inventory then player.inventory:DeleteItem(used[0].id, 1) end end)
        consumed, fedEntry = 1, used[0]
    end

    self.__curaequi_consumed, self.__curaequi_single = true, nil
    Q("InventoryClosed → consumed %d item(s)", consumed)

    local S = HGetState(self)
    if S and fedEntry then
        table.insert(S.feedHistory, { time = os.time(), id = fedEntry.id, name = fedEntry.name, tags = fedEntry.tags })
        S.hunger = CuraEqui.Utils.clamp((S.hunger or 0) - 30, 0, CuraEqui.HorseCfg.hungerMax)
        S.lastFedAt = os.time()
        System.LogAlways(("[CuraEqui][Horse] Fed '%s' → hunger=%d"):format(tostring(fedEntry.name),
            tonumber(S.hunger or 0)))
    end
end

-- Inject “Feed horse” (inspect lane) without spam
do
    local H = _G.Horse
    if H and type(H.GetActions) == "function" and not H.__curaequi_feed_wrapped then
        local _Get = H.GetActions
        function H.GetActions(self, user, firstFast)
            local actions = _Get(self, user, firstFast) or {}
            local alive = self and self.actor and self.actor.GetHealth and (self.actor:GetHealth() > 0) or false
            if not alive then return actions end
            for i = 1, #actions do
                local a = actions[i]; if a and a.func == H.OnFeedHorse then return actions end
            end
            local maxOrder = 0; for i = 1, #actions do maxOrder = math.max(maxOrder, actions[i].uiOrder or 0) end
            local lane = rawget(_G, "inr_horseInspect") or rawget(_G, "inr_horseMount"); if not lane then return actions end
            local A = Action():hint("@ui_hud_feed_horse"):action("use_horse"):hintType(AHT_PRESS):func(H.OnFeedHorse)
            :interaction(lane):uiOrder(maxOrder + 1):enabled(true)
            AddInteractorAction(actions, firstFast, A)
            if not self.__curaequi_feed_logged then
                CuraEqui.Log("Feed", "Injected (lane=%s order=%d)", tostring(lane), maxOrder + 1); self.__curaequi_feed_logged = true
            end
            return actions
        end

        H.__curaequi_feed_wrapped = true
        System.LogAlways("[CuraEqui][Feed] ✅ Wrapped Horse.GetActions")
    end
end
