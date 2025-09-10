-- Scripts/CuraEqui/Feeding.lua
-- Cura Equi · Feeding & UI bridge (clean)
-- ---------------------------------------------------------------------------

local DEBUG_PROBE    = false
CuraEqui._lastFeedAt = 0
-- Shorthands
local Q              = function(fmt, ...) CuraEqui.Log("Feed", fmt, ...) end
local HGetState      = CuraEqui.HorseStateGet
local _unpack        = (table and table.unpack) or _G.unpack

-- Toggle which picker UI to open:
--   false = ItemSelection (simple)
--   true  = ItemTransfer  (two-pane)
local USE_TRANSFER   = false

-- ===========================================================================
-- Lua → GFx helpers
-- ===========================================================================
local function ce_ui_call(elem, inst, fname, args)
    local ok, res = pcall(function()
        if args and #args > 0 then
            return UIAction.CallFunction(elem, inst, fname, _unpack(args))
        else
            return UIAction.CallFunction(elem, inst, fname)
        end
    end)

    local s = ""
    if args and #args > 0 then
        local tmp = {}; for i = 1, #args do tmp[i] = tostring(args[i]) end
        s = table.concat(tmp, ",")
    end

    System.LogAlways(("[CuraEqui][UI] %s.%s(%s) → %s")
        :format(tostring(elem), tostring(fname), s, (ok and res ~= false) and "ok" or "fail"))
    return ok and (res ~= false)
end

-- ===========================================================================
-- ItemManager resolvers (name/GUID) + delete helpers
-- ===========================================================================
local function IM() return _G.ItemManager or _G.Items or _G.ItemSystem end

local function CE_GetItemHandle(wuid)
    local m = IM(); if not (m and m.GetItem) then return nil end
    local ok, h = pcall(function() return m:GetItem(wuid) end)
    return (ok and h) or nil
end

local function CE_ResolveNameViaItemManager(wuid)
    local m = IM(); if not m then return nil end

    -- some builds accept WUID directly
    for _, f in ipairs({ "GetItemUIName", "GetItemName" }) do
        if type(m[f]) == "function" then
            local ok, s = pcall(function() return m[f](m, wuid) end)
            if ok and s and s ~= "" then return s end
        end
    end

    -- else: resolve via handle
    local h = CE_GetItemHandle(wuid); if not h then return nil end
    for _, f in ipairs({ "GetItemUIName", "GetItemName" }) do
        if type(m[f]) == "function" then
            local ok, s = pcall(function() return m[f](m, h) end)
            if ok and s and s ~= "" then return s end
        end
    end

    if type(h) == "table" then
        for _, k in ipairs({ "uiName", "name", "displayName", "templateName" }) do
            local v = h[k]; if type(v) == "string" and v ~= "" then return v end
        end
    end
    return nil
end

local function CE_ResolveGuidViaItemManager(wuid)
    local m = IM(); if not m then return nil end

    -- WUID direct (if supported)
    for _, f in ipairs({ "GetClassGuid", "GetTemplateGuid" }) do
        if type(m[f]) == "function" then
            local ok, g = pcall(function() return m[f](m, wuid) end)
            if ok and type(g) == "string" and #g >= 32 then return g end
        end
    end

    -- handle path
    local h = CE_GetItemHandle(wuid); if not h then return nil end
    for _, f in ipairs({ "GetClassGuid", "GetTemplateGuid", "GetGuid" }) do
        if type(m[f]) == "function" then
            local ok, g = pcall(function() return m[f](m, h) end)
            if ok and type(g) == "string" and #g >= 32 then return g end
        end
    end
    if type(h) == "table" then
        for _, k in ipairs({ "classGuid", "templateGuid", "guid", "classGUID", "templateGUID" }) do
            local v = h[k]; if type(v) == "string" and #v >= 32 then return v end
        end
    end
    return nil
end

local function _shouldProcessNow()
    local now = _G.Script and Script.GetTime() or os.clock()
    if now - (CuraEqui._lastFeedAt or 0) < 0.2 then return false end
    CuraEqui._lastFeedAt = now
    return true
end

-- put near the UI helpers
local function CE_UI_RefreshAfterFeed()
    -- Best effort: nudge the movie to hide stale info and/or close it.
    -- These calls are safe even if the function doesn’t exist.
    pcall(function() UIAction.CallFunction("ItemSelection", -1, "fc_clearItemInfo") end)
    pcall(function() UIAction.CallFunction("ItemSelection", -1, "fc_setItemInfoVisibility", false) end)
    -- Easiest reliable refresh: close the picker so it reopens clean next time.
    pcall(function() UIAction.CallFunction("ItemSelection", -1, "fc_close") end)
end


-- Diet maps (filled by DietData.lua)
CuraEqui.Diet        = CuraEqui.Diet or {}
CuraEqui.Diet.byGuid = CuraEqui.Diet.byGuid or {}

-- Delete by template/class GUID (global inventory, then player)
local function CE_DeleteClassOne(guid)
    local ok = false
    pcall(function()
        if Inventory and Inventory.DeleteItemOfClass then
            ok = (Inventory.DeleteItemOfClass(guid, 1) ~= false)
        end
    end)
    if (not ok) and player and player.inventory then
        pcall(function()
            if player.inventory.DeleteItemOfClass then
                ok = (player.inventory:DeleteItemOfClass(guid, 1) ~= false)
            end
        end)
    end
    return ok
end

-- ===========================================================================
-- GFx → Lua bridge (element listeners)
-- ===========================================================================
CuraEqui = CuraEqui or {}
CuraEqui._feedBridgeListenersReady = CuraEqui._feedBridgeListenersReady or false

local function _arg(args, key)
    return (args and (args[0] or args[1] or args[key] or args[string.upper(key)] or args[string.lower(key)] or "")) or ""
end

function CuraEqui.Feed_RegisterBridgeListeners()
    if CuraEqui._feedBridgeListenersReady then return end
    if not (UIAction and UIAction.RegisterElementListener) then
        System.LogAlways("[CuraEqui][Bridge] UIAction not available; cannot register listeners")
        return
    end
    local function reg(elem, ev, cb)
        local ok = pcall(function() UIAction.RegisterElementListener(CuraEqui, elem, -1, ev, cb) end)
        System.LogAlways(("[CuraEqui][Bridge] listen %s.%s → %s (%s)")
            :format(elem, ev, ok and "ok" or "fail", tostring(cb)))
        return ok
    end

    -- our custom XML events
    reg("ItemSelection", "CuraEquiOnItemInfo", "OnCuraEquiItemInfoEvent")
    reg("ItemSelection", "CuraEquiOnItemUsed", "OnCuraEquiItemUsedEvent")
    reg("ItemTransfer", "CuraEquiOnItemInfo", "OnCuraEquiItemInfoEvent")
    reg("ItemTransfer", "CuraEquiOnItemUsed", "OnCuraEquiItemUsedEvent")
    -- focus (for WUID)
    reg("ItemSelection", "OnFocusChanged", "OnItemSelectionFocusChanged")
    reg("ItemTransfer", "OnFocusChanged", "OnItemSelectionFocusChanged")

    reg("ItemSelection", "OnDoubleClicked", "OnItemSelectionDoubleClicked")
    reg("ItemTransfer", "OnDoubleClicked", "OnItemSelectionDoubleClicked")

    CuraEqui._feedBridgeListenersReady = true
end

function CuraEqui:OnCuraEquiItemInfoEvent(elementName, instanceId, eventName, args)
    local id, guid, name = tostring(_arg(args, "Id")), tostring(_arg(args, "Guid")), tostring(_arg(args, "Name"))
    System.LogAlways(("[CuraEqui][Bridge][evt] %s from %s id=%s guid=%s name=%s")
        :format(eventName, tostring(elementName), id, guid, name))
    if _G.CuraEqui_onItemInfo then _G.CuraEqui_onItemInfo(id, guid, name) end
end

function CuraEqui:OnCuraEquiItemUsedEvent(elementName, instanceId, eventName, args)
    local id, guid, name = tostring(_arg(args, "Id")), tostring(_arg(args, "Guid")), tostring(_arg(args, "Name"))
    System.LogAlways(("[CuraEqui][Bridge][evt] %s from %s id=%s guid=%s name=%s")
        :format(eventName, tostring(elementName), id, guid, name))
    if _G.CuraEqui_onItemUsed then _G.CuraEqui_onItemUsed(id, guid, name) end
end

-- Focus state (for WUID/WUID→name)
CuraEqui._lastFocusWUID = CuraEqui._lastFocusWUID or nil
CuraEqui._lastFocusName = CuraEqui._lastFocusName or "?"

function CuraEqui:OnItemSelectionFocusChanged(elementName, instanceId, eventName, args)
    local idsStr = tostring(_arg(args, "Ids"))
    local wuid   = idsStr:match("([^,;%s]+)") or idsStr
    if wuid == "" then wuid = nil end
    CuraEqui._lastFocusWUID = wuid

    if DEBUG_PROBE and wuid then
        local h = CE_GetItemHandle(wuid)
        if type(h) == "table" and not CuraEqui.__loggedIMOnce then
            CuraEqui.__loggedIMOnce = true
            local keys = {}; for k, _ in pairs(h) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            System.LogAlways("[CuraEqui][Probe][ItemHandle] keys={" .. table.concat(keys, ", ") .. "}")
        end
    end

    CuraEqui._lastFocusName = (wuid and CE_ResolveNameViaItemManager(wuid)) or "?"
    System.LogAlways(("[CuraEqui][Bridge][focus] %s id=%s name=%s")
        :format(tostring(elementName), tostring(CuraEqui._lastFocusWUID), tostring(CuraEqui._lastFocusName)))
end

function CuraEqui:OnItemSelectionDoubleClicked(elementName, instanceId, eventName, args)
    System.LogAlways(("[CuraEqui][Bridge][evt] %s from %s"):format(eventName, tostring(elementName)))
    CuraEqui.Feed_FocusedNow("doubleclick")
end

-- ===========================================================================
-- Nutrition apply
-- ===========================================================================
function CuraEqui._ApplyNutrition(diet, tokenForLog)
    local h = CuraEqui._currentHorse
        or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
        or nil
    if not h then
        System.LogAlways("[CuraEqui][Feed] used: no player horse resolved")
        return
    end
    local Hunger = CuraEqui.Hunger or {}
    if Hunger.GetState and Hunger.SetHunger then
        local S    = Hunger.GetState(h, true)
        local max  = (CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.hungerMax) or 100
        local n    = tonumber(diet.nutrition or 10)
        local newH = math.max(0, math.min(max, (S.hunger or 0) - n))
        Hunger.SetHunger(h, newH)
        System.LogAlways(("[CuraEqui][Horse] Fed '%s' → -%d hunger (now=%d)")
            :format(tostring(tokenForLog or "?"), n, newH))
        if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_ok", 1.8) end
    end
end

-- ===========================================================================
-- Global receivers (single source)
-- ===========================================================================
function CuraEqui_onItemInfo(id, guid, name)
    System.LogAlways(("[CuraEqui][Bridge] onItemInfo id=%s guid=%s name=%s")
        :format(tostring(id), tostring(guid), tostring(name)))
end

-- Consume the currently focused item (GUID route if possible, else WUID) and apply nutrition.
function CuraEqui.Feed_FocusedNow(reason)
    local wuid = CuraEqui._lastFocusWUID
    System.LogAlways(("[CuraEqui][Feed] Feed_FocusedNow(%s) wuid=%s"):format(tostring(reason or "?"), tostring(wuid)))
    if not wuid then
        System.LogAlways("[CuraEqui][Feed] no focused WUID -> abort")
        if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_reject", 1.2) end
        return
    end

    -- Prefer class/template GUID via ItemManager -> DietData
    local guid = CE_ResolveGuidViaItemManager and CE_ResolveGuidViaItemManager(wuid) or nil
    if guid and CuraEqui.Diet and CuraEqui.Diet.byGuid and CuraEqui.Diet.byGuid[guid] then
        local diet    = CuraEqui.Diet.byGuid[guid]
        local deleted = CE_DeleteClassOne(guid)
        System.LogAlways(("[CuraEqui][Feed] class delete %s → %s"):format(guid, tostring(deleted)))
        if not deleted then
            if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_delete_fail", 1.3) end
            return
        end
        CuraEqui._ApplyNutrition(diet,
            diet.token or (CE_ResolveNameViaItemManager and CE_ResolveNameViaItemManager(wuid) or "?"))
        CuraEqui._currentHorse = nil
        return
    end

    -- Fallback: delete this exact instance by WUID, apply default nutrition
    local ok = false
    pcall(function()
        if player and player.inventory and player.inventory.DeleteItem then
            ok = (player.inventory:DeleteItem(wuid, 1) ~= false)
        end
    end)
    System.LogAlways(("[CuraEqui][Feed] wuid delete %s → %s"):format(tostring(wuid), tostring(ok)))
    if not ok then
        if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_delete_fail", 1.3) end
        return
    end

    local n    = (CuraEqui.Config and CuraEqui.Config.Diet and CuraEqui.Config.Diet.defaultNutrition) or 10
    local diet = { nutrition = n, token = (CE_ResolveNameViaItemManager and CE_ResolveNameViaItemManager(wuid)) or "?" }
    CuraEqui._ApplyNutrition(diet, diet.token)
    CuraEqui._currentHorse = nil
end

function CuraEqui_onItemUsed(id, guid, name)
    if not _shouldProcessNow() then
        System.LogAlways("[CuraEqui][Feed] debounce: ignoring duplicate fire")
        return
    end
    -- ignore the movie’s self-test / no-focus pings
    if id == "no_focus" or guid == "no_focus" or name == "no_focus" or id == "selftest" then
        System.LogAlways("[CuraEqui][Feed] ignoring synthetic/no_focus emit")
        return
    end
    System.LogAlways(("[CuraEqui][Bridge] onItemUsed id=%s guid=%s name=%s")
        :format(tostring(id), tostring(guid or ""), tostring(name)))

    -- 1) If GUID arrived and is in DietData → delete by class + apply item nutrition
    guid = tostring(guid or "")
    if guid ~= "" then
        local diet = CuraEqui.Diet.byGuid[guid]
        if not diet then
            System.LogAlways(("[CuraEqui][Feed] used: guid %s not in DietData → reject"):format(guid))
            if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_reject", 1.8) end
            return
        end
        local deleted = CE_DeleteClassOne(guid)
        System.LogAlways(("[CuraEqui][Feed] class delete %s → %s"):format(guid, tostring(deleted)))
        if not deleted then
            if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_delete_fail", 1.8) end
            return
        end
        return CuraEqui._ApplyNutrition(diet, diet.token or name)
    end

    -- 2) No GUID in params: recover via ItemManager; if mapped, take class route
    local wuid = CuraEqui._lastFocusWUID
    if not wuid then
        System.LogAlways("[CuraEqui][Feed] used: no guid and no focused WUID → ignoring")
        if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_reject", 1.5) end
        return
    end

    local recGuid = CE_ResolveGuidViaItemManager(wuid)
    if recGuid and CuraEqui.Diet.byGuid[recGuid] then
        local diet    = CuraEqui.Diet.byGuid[recGuid]
        local deleted = CE_DeleteClassOne(recGuid)
        System.LogAlways(("[CuraEqui][Feed] class delete %s → %s"):format(recGuid, tostring(deleted)))
        if not deleted then
            if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_delete_fail", 1.8) end
            return
        end
        return CuraEqui._ApplyNutrition(diet, diet.token or (CE_ResolveNameViaItemManager(wuid) or "?"))
    end

    -- 3) Still no class mapping: delete the exact focused instance (WUID) and apply default nutrition
    local ok = false
    pcall(function()
        if player and player.inventory and player.inventory.DeleteItem then
            ok = (player.inventory:DeleteItem(wuid, 1) ~= false)
        end
    end)
    System.LogAlways(("[CuraEqui][Feed] wuid delete %s → %s"):format(tostring(wuid), tostring(ok)))
    if not ok then
        if CuraEqui.UI and CuraEqui.UI.ShowInfo then CuraEqui.UI.ShowInfo("@curaequi_feed_delete_fail", 1.8) end
        return
    end

    local defaultN = (CuraEqui.Config and CuraEqui.Config.Diet and CuraEqui.Config.Diet.defaultNutrition) or 10
    local diet     = { nutrition = defaultN, token = CE_ResolveNameViaItemManager(wuid) or "?" }
    return CuraEqui._ApplyNutrition(diet, diet.token)
end

_G.CuraEqui_onItemInfo = CuraEqui_onItemInfo
_G.CuraEqui_onItemUsed = CuraEqui_onItemUsed

-- ===========================================================================
-- Entrypoint: open picker + prime bridge
-- ===========================================================================
function Horse:OnFeedHorse(user)
    CuraEqui._currentHorse = self
    CuraEqui._currentHorseSetAt = os.time()

    if CuraEqui and CuraEqui.Feed_RegisterBridgeListeners then
        CuraEqui.Feed_RegisterBridgeListeners()
    end

    System.LogAlways("[CuraEqui][Feed] OnFeedHorse → " ..
        tostring(self.GetName and self:GetName() or self.class or "horse"))



    if USE_TRANSFER then
        -- ItemTransfer (two-pane)
        if self.actor and self.actor.RequestItemExchange then
            local ok = pcall(function() self.actor:RequestItemExchange(user.id) end)
            System.LogAlways("[CuraEqui][Feed] RequestItemExchange → " .. (ok and "ok" or "fail"))
        else
            System.LogAlways("[CuraEqui][Feed] No ItemTransfer available"); return
        end

        -- (Optional) nudge categories; left here for future use
        if DEBUG_PROBE then
            local function call(fname, arg)
                local ok = pcall(function()
                    if arg ~= nil then
                        UIAction.CallFunction("ItemTransfer", nil, fname, arg)
                    else
                        UIAction.CallFunction("ItemTransfer", nil, fname)
                    end
                end)
                System.LogAlways(("[CuraEqui][UI] %s(%s) → %s"):format(fname, tostring(arg or ""), ok and "ok" or "fail"))
                return ok
            end
            call("fc_focusLeft")
            call("fc_setLeftFilter", 3)
        end
    else
        -- ItemSelection (simple)
        if user and user.actor and user.actor.OpenItemSelectionFilter then
            local ok = pcall(function() user.actor:OpenItemSelectionFilter(self.id, "") end)
            System.LogAlways("[CuraEqui][Feed] OpenItemSelectionFilter('') → " .. (ok and "ok" or "fail"))
            if ok then
                -- harmless liveness pings
                local tries, maxTries = 0, 4
                local function tryPing()
                    tries = tries + 1
                    ce_ui_call("ItemSelection", nil, "fc_ping", { "hello from CuraEqui START" })
                    ce_ui_call("ItemSelection", nil, "fc_emitFocusedInfo", {})
                    ce_ui_call("ItemSelection", nil, "fc_ping", { "hello from CuraEqui END" })
                    if tries < maxTries then Script.SetTimerForFunction(150, "CuraEqui_PickerBridgeTick") end
                end
                _G["CuraEqui_PickerBridgeTick"] = tryPing
                Script.SetTimerForFunction(150, "CuraEqui_PickerBridgeTick")
            end
        else
            System.LogAlways("[CuraEqui][Feed] No ItemSelection available")
        end
    end
end

-- ===========================================================================
-- Action injection (unchanged semantics)
-- ===========================================================================
do
    local H = _G.Horse
    if H and type(H.GetActions) == "function" and not H.__curaequi_feed_wrapped then
        local _Get = H.GetActions
        function H.GetActions(self, user, firstFast)
            local actions = _Get(self, user, firstFast) or {}
            local alive = self and self.actor and self.actor.GetHealth and (self.actor:GetHealth() > 0) or false
            if not alive then return actions end

            for i = 1, #actions do
                local a = actions[i]
                if a and a.func == H.OnFeedHorse then return actions end
            end

            local maxOrder = 0
            for i = 1, #actions do maxOrder = math.max(maxOrder, actions[i].uiOrder or 0) end

            local lane = rawget(_G, "inr_horseInspect") or rawget(_G, "inr_horseMount")
            if not lane then return actions end

            local A = Action()
                :hint("@ui_hud_feed_horse")
                :action("use_horse")
                :hintType(AHT_PRESS)
                :func(H.OnFeedHorse)
                :interaction(lane)
                :uiOrder(maxOrder + 1)
                :enabled(true)

            AddInteractorAction(actions, firstFast, A)

            if not self.__curaequi_feed_logged then
                CuraEqui.Log("Feed", "Injected (lane=%s order=%d)", tostring(lane), maxOrder + 1)
                self.__curaequi_feed_logged = true
            end
            return actions
        end

        H.__curaequi_feed_wrapped = true
        System.LogAlways("[CuraEqui][Feed] ✅ Wrapped Horse.GetActions")
    end
end
