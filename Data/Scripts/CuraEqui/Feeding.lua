-- Scripts/CuraEqui/Feeding.lua
-- Cura Equi · Feeding (player drops → scanner eats)
-- ---------------------------------------------------------------------------

CuraEqui = CuraEqui or {}
CuraEqui.Config = CuraEqui.Config or {}
CuraEqui.Config.FeedScan = CuraEqui.Config.FeedScan or {
    radius         = 2.0,                        -- meters around horse mouth
    windowSec      = 6.0,                        -- how long we scan after action
    tickMs         = 150,                        -- scan cadence
    toastOnStart   = "@curaequi_feed_drop_hint", -- shown when scan starts (optional)
    _invArmActive  = false,
    _invArmExpires = 0
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function _now()
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end

local function CE_Log(fmt, ...)
    System.LogAlways("[CuraEqui][Scan] " .. string.format(fmt, ...))
end

local function _vec_add(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
local function _vec_scale(a, s) return { x = a.x * s, y = a.y * s, z = a.z * s } end

local function CE_GetHorseAndMouthPos()
    local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h or not h.GetWorldPos then return nil end
    local hp    = h:GetWorldPos()
    local f     = (h.GetDirectionVector and h:GetDirectionVector(1)) or { x = 1, y = 0, z = 0 }
    -- ~0.9m forward, ~1.3m up; tweak for your model
    local mouth = _vec_add(hp, _vec_add(_vec_scale(f, 0.9), { x = 0, y = 0, z = 1.3 }))
    return h, mouth
end

local function CE_ListNearbyEntities(pos, radius)
    local list = {}
    local ok, ids = pcall(function()
        return System.GetEntitiesInSphere and System.GetEntitiesInSphere(pos, radius) or {}
    end)
    if not ok or not ids then return list end
    for i = 1, #ids do
        local eid = ids[i]
        local okE, ent = pcall(function() return System.GetEntity(eid) end)
        if okE and ent then list[#list + 1] = ent end
    end
    return list
end

local function CE_DeleteEntity(ent)
    return pcall(function()
        if ent.DeleteThis then
            ent:DeleteThis()
        elseif System.RemoveEntity then
            System.RemoveEntity(ent.id)
        end
    end)
end

-- Try to read class/template guid + a UI-ish name from an item entity
local function CE_SniffGuidAndName(ent)
    if not ent then return nil, nil end
    local t = rawget(ent, "item") or rawget(ent, "Item") or ent
    local guid = (t and (t.classGuid or t.templateGuid or t.guid or t.ClassGuid or t.TemplateGuid))
        or ent.classGuid or ent.templateGuid
    local name = (t and ((t.GetUIName and t:GetUIName()) or t.uiName or t.name or t.displayName or t.templateName))
        or ent.szName or ent.name or ent.class
    return guid, name
end

-- Nutrition applier (expects DietData to be required elsewhere like before)
function CuraEqui._ApplyNutrition(diet, label)
    local n = diet and diet.nutrition or 0
    System.LogAlways(("[CuraEqui][Horse] Fed '%s' → -%s hunger"):format(tostring(label or "?"), tostring(n)))
    if CuraEqui.Hunger and CuraEqui.Hunger.AddNutrition then
        pcall(function() CuraEqui.Hunger.AddNutrition(n) end)
    end
    if CuraEqui.UI and CuraEqui.UI.ShowInfo then
        pcall(function() CuraEqui.UI.ShowInfo("@curaequi_horse_feed_ok", 1.5) end)
    end
end

function CuraEqui._InvClose_ArmOnce(durationSec)
    CuraEqui._invArmActive  = true
    CuraEqui._invArmExpires = _now() + (durationSec or CuraEqui.Config.FeedScan.armTimeoutSec or 25)
    CE_Log("armed for inventory close (%.1fs)", CuraEqui._invArmExpires - _now())

    if not (UIAction and UIAction.RegisterElementListener) then return end
    local function reg(elem, ev, cb)
        pcall(function() UIAction.RegisterElementListener(CuraEqui, elem, -1, ev, cb) end)
    end

    -- Try a few likely movies/events used by vanilla inventory stack.
    -- (Harmless if an element/event doesn’t exist.)
    reg("ApseInventoryList", "OnClose", "OnInvClosed")
    reg("ApseInventoryList", "OnHide", "OnInvClosed")
    reg("ApseInventoryInfo", "OnClose", "OnInvClosed")
    reg("ApseInventoryInfo", "OnHide", "OnInvClosed")
    reg("ApseModalDialog", "OnClose", "OnInvClosed")
    reg("ApsePlayerList", "OnClose", "OnInvClosed")
    reg("ApsePlayerInfo", "OnClose", "OnInvClosed")
    reg("ApseCharacter", "OnClose", "OnInvClosed")
end

function CuraEqui._InvClose_Disarm()
    CuraEqui._invArmActive  = false
    CuraEqui._invArmExpires = 0
end

-- Listener target (called by any of the above UI events)
function CuraEqui:OnInvClosed(elementName, _instanceId, eventName, _args)
    if not CuraEqui._invArmActive then return end
    if _now() > CuraEqui._invArmExpires then
        CE_Log("ignored close (arm expired)")
        return
    end
    CE_Log("inventory closed via %s.%s → starting post-close scan", tostring(elementName), tostring(eventName))
    CuraEqui._InvClose_Disarm()
    CuraEqui.Feed_StartScan(CuraEqui.Config.FeedScan.postCloseWindowSec or 8.0)
end

-- ---------------------------------------------------------------------------
-- Scanner: runs for a short window after the action; eats first edible thing
-- ---------------------------------------------------------------------------
CuraEqui._scanUntil = nil
CuraEqui._scanActive = false

local function CE_FeedScan_Tick()
    if not CuraEqui._scanActive then return end
    if _now() > (CuraEqui._scanUntil or 0) then
        CuraEqui._scanActive = false
        System.LogAlways("[CuraEqui][Scan] window ended")
        return
    end

    local horse, mouth = CE_GetHorseAndMouthPos()
    if not horse then
        Script.SetTimerForFunction(CuraEqui.Config.FeedScan.tickMs, "CuraEqui_FeedScan_Tick")
        return
    end

    local ents = CE_ListNearbyEntities(mouth, CuraEqui.Config.FeedScan.radius)
    for _, ent in ipairs(ents) do
        -- Try to detect item-like entities
        local guid, name = CE_SniffGuidAndName(ent)
        if guid or (ent.item ~= nil) then
            System.LogAlways(("[CuraEqui][Scan] found '%s' guid=%s eid=%s")
                :format(tostring(name or ent.class), tostring(guid), tostring(ent.id)))
            -- Decide edibility
            local diet = (guid and CuraEqui.Diet and CuraEqui.Diet.byGuid and CuraEqui.Diet.byGuid[guid]) or nil
            if diet then
                -- Eat it: delete entity, apply nutrition, stop scan
                CE_DeleteEntity(ent)
                CuraEqui._scanActive = false
                return CuraEqui._ApplyNutrition(diet, diet.token or name or "?")
            else
                -- Not edible → leave it on the ground
                System.LogAlways("[CuraEqui][Scan] not edible → leaving")
            end
        end
    end

    -- keep scanning
    Script.SetTimerForFunction(CuraEqui.Config.FeedScan.tickMs, "CuraEqui_FeedScan_Tick")
end
_G["CuraEqui_FeedScan_Tick"] = CE_FeedScan_Tick

function CuraEqui.Feed_StartScan(seconds)
    local s = tonumber(seconds) or CuraEqui.Config.FeedScan.windowSec
    CuraEqui._scanUntil = _now() + s
    CuraEqui._scanActive = true
    System.LogAlways(("[CuraEqui][Scan] started (%.1fs, r=%.1fm)")
        :format(s, CuraEqui.Config.FeedScan.radius))
    -- Optional toast to instruct the player
    if CuraEqui.UI and CuraEqui.UI.ShowInfo and CuraEqui.Config.FeedScan.toastOnStart then
        pcall(function() CuraEqui.UI.ShowInfo(CuraEqui.Config.FeedScan.toastOnStart, 2.2) end)
    end
    CE_FeedScan_Tick()
end

-- ---------------------------------------------------------------------------
-- Entrypoint: action opens a picker if available, then starts the scanner
-- ---------------------------------------------------------------------------
function Horse:OnFeedHorse(user)
    System.LogAlways("[CuraEqui][Feed] OnFeedHorse")

    if CuraEqui.Config.FeedScan.armOnInventoryClose then
        -- Arm a one-shot “scan after inventory closes”.
        CuraEqui._InvClose_ArmOnce(CuraEqui.Config.FeedScan.armTimeoutSec or 25.0)
        -- Optional hint: tell the player what to do
        if CuraEqui.UI and CuraEqui.UI.ShowInfo and CuraEqui.Config.FeedScan.toastOnStart then
            pcall(function() CuraEqui.UI.ShowInfo(CuraEqui.Config.FeedScan.toastOnStart, 2.2) end)
        end
    else
        -- Classic v0 behavior: start scanning immediately.
        CuraEqui.Feed_StartScan()
    end
end

-- ---------------------------------------------------------------------------
-- Action injection (kept identical in behavior to your working version)
-- ---------------------------------------------------------------------------
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
                :hint("@curaequi_drop_food")
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
