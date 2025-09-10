-- Scripts/CuraEqui/Feeding.lua
-- Cura Equi · Feeding (drop-only) & UI bridge
-- ---------------------------------------------------------------------------

-- Keep logs small & clear for this test iteration
local _unpack = (table and table.unpack) or _G.unpack

-- Toggle which picker UI to open:
--   false = ItemSelection (simple)
--   true  = ItemTransfer  (two-pane)
local USE_TRANSFER = false

-- ===========================================================================
-- Lua → GFx helpers (for harmless pings/close)
-- ===========================================================================
local function ce_ui_call(elem, inst, fname, args)
    local ok = pcall(function()
        if args and #args > 0 then
            return UIAction.CallFunction(elem, inst, fname, _unpack(args))
        else
            return UIAction.CallFunction(elem, inst, fname)
        end
    end)
    System.LogAlways(("[CuraEqui][UI] %s.%s → %s"):format(tostring(elem), tostring(fname), ok and "ok" or "fail"))
    return ok
end

-- ===========================================================================
-- GFx → Lua bridge (element listeners)
-- ===========================================================================
CuraEqui = CuraEqui or {}
CuraEqui._feedBridgeListenersReady = CuraEqui._feedBridgeListenersReady or false

-- Focus state (WUID cached from UI focus changes)
CuraEqui._lastFocusWUID = CuraEqui._lastFocusWUID or nil

local function _arg(args, key)
    return (args and (args[0] or args[1] or args[key] or args[string.upper(key)] or args[string.lower(key)] or "")) or ""
end

function CuraEqui.Feed_RegisterBridgeListeners()
    if CuraEqui._feedBridgeListenersReady then return end
    if not (UIAction and UIAction.RegisterElementListener) then
        System.LogAlways("[CuraEqui][Bridge] UIAction not available; cannot register listeners"); return
    end

    local function reg(elem, ev, cb)
        local ok = pcall(function() UIAction.RegisterElementListener(CuraEqui, elem, -1, ev, cb) end)
        System.LogAlways(("[CuraEqui][Bridge] listen %s.%s → %s (%s)")
            :format(elem, ev, ok and "ok" or "fail", tostring(cb)))
    end

    -- Our custom XML events (params may be empty on your build; that's fine)
    reg("ItemSelection", "CuraEquiOnItemInfo", "OnCuraEquiItemInfoEvent")
    reg("ItemSelection", "CuraEquiOnItemUsed", "OnCuraEquiItemUsedEvent")
    reg("ItemTransfer", "CuraEquiOnItemInfo", "OnCuraEquiItemInfoEvent")
    reg("ItemTransfer", "CuraEquiOnItemUsed", "OnCuraEquiItemUsedEvent")

    -- Focus tracking (gives us WUIDs)
    reg("ItemSelection", "OnFocusChanged", "OnItemSelectionFocusChanged")
    reg("ItemTransfer", "OnFocusChanged", "OnItemSelectionFocusChanged")

    -- Also react to double-click (mouse path)
    reg("ItemSelection", "OnDoubleClicked", "OnItemSelectionDoubleClicked")
    reg("ItemTransfer", "OnDoubleClicked", "OnItemSelectionDoubleClicked")

    CuraEqui._feedBridgeListenersReady = true
end

function CuraEqui:OnItemSelectionFocusChanged(_elementName, _instanceId, _eventName, args)
    local idsStr = tostring(_arg(args, "Ids"))
    local wuid   = idsStr:match("([^,;%s]+)") or idsStr
    if wuid == "" then wuid = nil end
    CuraEqui._lastFocusWUID = wuid
    System.LogAlways(("[CuraEqui][Focus] WUID=%s"):format(tostring(wuid)))
end

function CuraEqui:OnItemSelectionDoubleClicked(_elementName, _instanceId, _eventName, _args)
    System.LogAlways("[CuraEqui][Evt] OnDoubleClicked → dropping focused")
    CuraEqui.Feed_DropFocused("doubleclick")
end

function CuraEqui:OnCuraEquiItemInfoEvent(elementName, instanceId, eventName, args)
    local id, guid, name = tostring(_arg(args, "Id")), tostring(_arg(args, "Guid")), tostring(_arg(args, "Name"))
    System.LogAlways(("[CuraEqui][Evt] %s from %s id=%s guid=%s name=%s")
        :format(eventName, tostring(elementName), id, guid, name))
end

function CuraEqui:OnCuraEquiItemUsedEvent(_elementName, _instanceId, _eventName, _args)
    System.LogAlways("[CuraEqui][Evt] CuraEquiOnItemUsed → dropping focused")
    CuraEqui.Feed_DropFocused("event")
end

-- ===========================================================================
-- Drop-only feed: just spawn the selected item instance to the world
-- ===========================================================================
local function CE_DropOneFromPlayer(wuid)
    if not (player and player.inventory and player.inventory.DropItem) then return false end
    local ok, res = pcall(function() return player.inventory:DropItem(wuid, 1) end)
    System.LogAlways(("[CuraEqui][Drop] DropItem(%s,1) → %s (%s)")
        :format(tostring(wuid), ok and "ok" or "fail", tostring(res)))
    return ok and true or false
end

local function CE_EntityFromWUID(wuid)
    if Framework and Framework.GetEntityIdByWUID then
        local ok, eid = pcall(function() return Framework.GetEntityIdByWUID(wuid) end)
        if ok and eid then
            local ok2, ent = pcall(function() return System.GetEntity(eid) end)
            if ok2 and ent then return ent, eid end
        end
    end
    return nil, nil
end

-- Tiny debounce (UI sometimes fires twice)
local _lastFireAt = 0
local function _debounce()
    local now = _G.Script and Script.GetTime() or os.clock()
    if now - _lastFireAt < 0.2 then return false end
    _lastFireAt = now
    return true
end

function CuraEqui.Feed_DropFocused(reason)
    if not _debounce() then
        System.LogAlways("[CuraEqui][Drop] debounce → ignore"); return
    end

    local wuid = CuraEqui._lastFocusWUID
    System.LogAlways(("[CuraEqui][Drop] Feed_DropFocused(%s) wuid=%s")
        :format(tostring(reason or "?"), tostring(wuid)))
    if not wuid then
        System.LogAlways("[CuraEqui][Drop] no focused WUID → abort")
        return
    end

    -- Optional: close the picker so the drop is less visible
    pcall(function() UIAction.CallFunction("ItemSelection", -1, "fc_close") end)

    -- Drop exactly one instance of the selected item
    local ok = CE_DropOneFromPlayer(wuid)
    if not ok then
        System.LogAlways("[CuraEqui][Drop] DropItem failed"); return
    end

    -- Probe for a spawned entity (up to 3 quick retries). Purely for logging.
    local tries, ent, eid = 0, nil, nil
    local function tick()
        tries = tries + 1
        ent, eid = ent or CE_EntityFromWUID(wuid)
        if ent or tries >= 3 then
            System.LogAlways(("[CuraEqui][Drop] spawned eid=%s ent=%s tries=%d")
                :format(tostring(eid), tostring(ent), tries))
            return
        end
        Script.SetTimerForFunction(80, "CuraEqui_DropProbeTick")
    end
    _G["CuraEqui_DropProbeTick"] = tick
    return tick()
end

-- Back-compat global handler (not used for params, just to keep hook alive)
function CuraEqui_onItemUsed(id, guid, name)
    System.LogAlways(("[CuraEqui][Bridge] onItemUsed id=%s guid=%s name=%s")
        :format(tostring(id), tostring(guid or ""), tostring(name or "")))
    return CuraEqui.Feed_DropFocused("global")
end

_G.CuraEqui_onItemUsed = CuraEqui_onItemUsed

-- ===========================================================================
-- Entrypoint: open picker & prime bridge
-- ===========================================================================
function Horse:OnFeedHorse(user)
    if CuraEqui and CuraEqui.Feed_RegisterBridgeListeners then
        CuraEqui.Feed_RegisterBridgeListeners()
    end

    System.LogAlways("[CuraEqui][Feed] OnFeedHorse → " ..
        tostring(self.GetName and self:GetName() or self.class or "horse"))

    if USE_TRANSFER then
        -- Two-pane
        if self.actor and self.actor.RequestItemExchange then
            local ok = pcall(function() self.actor:RequestItemExchange(user.id) end)
            System.LogAlways("[CuraEqui][Feed] RequestItemExchange → " .. (ok and "ok" or "fail"))
        else
            System.LogAlways("[CuraEqui][Feed] No ItemTransfer available")
        end
    else
        -- Simple picker
        if user and user.actor and user.actor.OpenItemSelectionFilter then
            local ok = pcall(function() user.actor:OpenItemSelectionFilter(self.id, "") end)
            System.LogAlways("[CuraEqui][Feed] OpenItemSelectionFilter('') → " .. (ok and "ok" or "fail"))
            if ok then
                -- harmless pings (helps AS2 warm up)
                local tries, maxTries = 0, 3
                local function tryPing()
                    tries = tries + 1
                    ce_ui_call("ItemSelection", nil, "fc_ping", { "hello from CuraEqui" })
                    ce_ui_call("ItemSelection", nil, "fc_emitFocusedInfo", {})
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
-- Action injection (kept identical in behavior)
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
