-- Scripts/CuraEqui/Feeding.lua
-- Cura Equi · Feeding (player drops → scanner eats)
-- ---------------------------------------------------------------------------

CuraEqui                = CuraEqui or {}
local FC                = (CuraEqui.Config and CuraEqui.Config.FeedScan) or {}
local DC                = (CuraEqui.Config and CuraEqui.Config.Diet) or {}

-- lightweight fallbacks only (used if Config.lua omitted a field)
local FEED_RADIUS       = tonumber(FC.radius) or 3.0
local FEED_TICK_MS      = tonumber(FC.tickMs) or 150
local FEED_WINDOW_SEC   = tonumber(FC.windowSec) or 6.0
local FEED_POST_SEC     = tonumber(FC.postCloseWindowSec) or 10.0
local FEED_DELAY_MS     = tonumber(FC.postCloseDelayMs) or 400
local FEED_TOAST        = FC.toastOnStart
local FEED_ARM_ON_CLOSE = (FC.armOnInventoryClose ~= false)

local ALLOW_KWS         = (DC.allowKeywords) or { "ui_nm_", "apple", "bread", "carrot" }
local KW_NUTRITION      = tonumber(DC.keywordNutrition) or 10

-- runtime state (keep outside config)
CuraEqui._invArmActive  = false
CuraEqui._invArmExpires = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function _now()
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end

local function CE_Log(fmt, ...)
    System.LogAlways("[CuraEqui][Scan] " .. string.format(fmt, ...))
end

-- Return a list of entity *tables* near pos within radius.
-- Tries GetEntitiesInSphere; if empty or missing, falls back to GetEntities() + distance filter.
local function CE_ListNearbyEntities(pos, radius)
    local out = {}
    local ok, arr = pcall(function() return System.GetEntitiesInSphere(pos, radius) end)
    if not ok or not arr then return out end
    for _, e in ipairs(arr) do
        local ent = (type(e) == "table") and e or (System.GetEntity and System.GetEntity(e))
        if ent then out[#out + 1] = ent end
    end
    return out
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
-- ent is a PickableItem (we gate by class before this)
local function CE_SniffGuidAndName(ent)
    -- prefer item subtable if present
    local t = rawget(ent, "item") or rawget(ent, "Item") or ent

    -- NAME
    local name = nil
    if type(t.GetUIName) == "function" then
        pcall(function() name = t:GetUIName() end)
    end
    name = name or t.uiName or t.name or ent.name or "?"

    -- GUID
    local guid = nil
    if type(t.GetGuid) == "function" then
        pcall(function() guid = t:GetGuid() end)
    end
    guid = guid or t.guid or ent.guid or nil

    -- CLASS NAME (can be useful for diet maps keyed by class)
    local className = nil
    if type(t.GetClassName) == "function" then
        pcall(function() className = t:GetClassName() end)
    end
    className = className or t.className or ent.className or ent.class

    return guid, name, className
end


-- Replace CE_GetScanCenters with a player-first variant
-- Player-first centers (match the probe)
local function CE_GetScanCenters()
    local centers = {}
    if player and player.GetWorldPos then
        local p = player:GetWorldPos()
        centers[#centers + 1] = { x = p.x, y = p.y, z = p.z }       -- player feet
        centers[#centers + 1] = { x = p.x, y = p.y, z = p.z - 0.6 } -- ground just below
    end
    -- (Optional) also include horse mouth as *extra* center, not primary
    local horse = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    if horse and horse.GetWorldPos then
        local hp              = horse:GetWorldPos()
        local f               = (horse.GetDirectionVector and horse:GetDirectionVector(1)) or { x = 1, y = 0, z = 0 }
        centers[#centers + 1] = { x = hp.x + f.x * 0.9, y = hp.y + f.y * 0.9, z = hp.z + 1.3 }
    end
    return centers, "player+horse"
end

-- Try multiple delete paths; verify immediately; log a follow-up verdict.
local function CE_DeleteEntity(ent)
    if not ent then return false end
    local id  = ent.id
    local tag = tostring(id)

    local function try(label, fn)
        local ok, res = pcall(fn)
        System.LogAlways(("[CuraEqui][Delete] %s → %s (%s)")
            :format(label, ok and "ok" or "fail", tostring(res)))
        return ok and (res ~= false)
    end

    local deleted = false
    -- Common Cry paths
    if type(ent.DeleteThis) == "function" then
        deleted = try("ent:DeleteThis()", function() return ent:DeleteThis() end) or deleted
    end
    if not deleted and type(ent.Remove) == "function" then
        deleted = try("ent:Remove()", function() return ent:Remove() end) or deleted
    end
    if not deleted and System and type(System.RemoveEntity) == "function" and id then
        deleted = try("System.RemoveEntity(id)", function() return System.RemoveEntity(id) end) or deleted
    end

    -- Immediate verification
    local still = (System and System.GetEntity) and System.GetEntity(id) or nil
    System.LogAlways(("[CuraEqui][Delete] verify-now id=%s → %s")
        :format(tag, still and "STILL THERE" or "gone"))

    -- Optional delayed verification (some engines remove next frame)
    if Script and type(Script.SetTimer) == "function" then
        Script.SetTimer(250, function()
            local again = (System and System.GetEntity) and System.GetEntity(id) or nil
            System.LogAlways(("[CuraEqui][Delete] verify-250ms id=%s → %s")
                :format(tag, again and "STILL THERE" or "gone"))
        end)
    elseif Script and type(Script.SetTimerForFunction) == "function" then
        -- Fallback if only SetTimerForFunction exists (no args)
        CuraEqui._deleteVerifyId = id
        _G.CuraEqui_DeleteVerify = function()
            local v = (System and System.GetEntity) and System.GetEntity(CuraEqui._deleteVerifyId) or nil
            System.LogAlways(("[CuraEqui][Delete] verify-250ms id=%s → %s")
                :format(tostring(CuraEqui._deleteVerifyId), v and "STILL THERE" or "gone"))
            CuraEqui._deleteVerifyId = nil
        end
        Script.SetTimerForFunction(250, "CuraEqui_DeleteVerify")
    end

    return deleted and not still
end


function CuraEqui.Feed_ScanOnce(r)
    local centers = { player and player:GetWorldPos() or { x = 0, y = 0, z = 0 } }
    local radius  = tonumber(r) or (CuraEqui.Config.FeedScan.radius or 3.0)
    for _, c in ipairs(centers) do
        local ents = CE_ListNearbyEntities(c, radius)
        System.LogAlways(("[CuraEqui][FeedScanOnce] center=(%.2f,%.2f,%.2f) ents=%d"):format(c.x, c.y, c.z, #ents))
        for _, ent in ipairs(ents) do
            System.LogAlways(("[CuraEqui][FeedScanOnce] • %s %s"):format(tostring(ent.class), tostring(ent.name)))
        end
    end
end

function CuraEqui.Feed_DebugDumpNearby(r)
    local centers, origin = CE_GetScanCenters()
    local radius = tonumber(r) or (CuraEqui.Config.FeedScan.radius or 2.5)
    System.LogAlways(("[CuraEqui][Dbg] origin=%s centers=%d radius=%.2f"):format(origin, #centers, radius))
    for _, c in ipairs(centers) do
        local ents = CE_ListNearbyEntities(c, radius)
        System.LogAlways(("[CuraEqui][Dbg] center=(%.2f,%.2f,%.2f) → %d ents"):format(c.x, c.y, c.z, #ents))
        -- compute and sort by distance
        local rows = {}
        for _, ent in ipairs(ents) do
            local ep = (ent.GetWorldPos and ent:GetWorldPos()) or { x = 0, y = 0, z = 0 }
            local dx, dy, dz = ep.x - c.x, ep.y - c.y, ep.z - c.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            local hasItem = (rawget(ent, "item") ~= nil)
            local guid, nm = CE_SniffGuidAndName(ent)
            rows[#rows + 1] = { dist = dist, id = ent.id, cls = ent.class, hasItem = hasItem, guid = guid, name = nm }
        end
        table.sort(rows, function(a, b) return a.dist < b.dist end)
        for i = 1, math.min(#rows, 10) do
            local r = rows[i]
            System.LogAlways(("[CuraEqui][Dbg] #%02d d=%.2f id=%s cls=%s hasItem=%s guid=%s name=%s")
                :format(i, r.dist, tostring(r.id), tostring(r.cls), tostring(r.hasItem), tostring(r.guid),
                    tostring(r.name)))
        end
    end
end

function CuraEqui:OnDroppedToHorse(elementName, instanceId, eventName, args)
    System.LogAlways(("[CuraEqui][Drop→Horse TEST] element=%s event=%s args=%s")
        :format(tostring(elementName), tostring(eventName),
            Utils and Utils.DumpTable and Utils.DumpTable(args) or tostring(args)))
end

function CuraEqui_Feed_StartScanDelayed()
    return CuraEqui.Feed_StartScan(CuraEqui.Config.FeedScan.postCloseWindowSec or 8.0)
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
    local now = (_G.Script and Script.GetTime and Script.GetTime()) or os.clock()
    if now > (CuraEqui._invArmExpires or 0) then
        CE_Log("ignored close (arm expired)")
        return
    end
    CE_Log("inventory closed via %s.%s → starting post-close scan", tostring(elementName), tostring(eventName))
    CuraEqui._InvClose_Disarm()
    local delay = CuraEqui.Config.FeedScan.postCloseDelayMs or 0
    if delay > 0 then
        Script.SetTimerForFunction(delay, "CuraEqui_Feed_StartScanDelayed")
    else
        CuraEqui.Feed_StartScan(CuraEqui.Config.FeedScan.postCloseWindowSec or 8.0)
    end
end

-- ---------------------------------------------------------------------------
-- Scanner: runs for a short window after the action; eats first edible thing
-- ---------------------------------------------------------------------------
CuraEqui._scanUntil  = CuraEqui._scanUntil or nil
CuraEqui._scanActive = CuraEqui._scanActive or false

local function _scan_once()
    local centers, origin = CE_GetScanCenters()
    System.LogAlways(("[CuraEqui][Scan] origin=%s centers=%d"):format(origin, #centers))

    local now    = _now()
    local total  = (CuraEqui.Config.FeedScan.postCloseWindowSec or CuraEqui.Config.FeedScan.windowSec or 6.0)
    local left   = math.max(0, (CuraEqui._scanUntil or 0) - now)
    local baseR  = CuraEqui.Config.FeedScan.radius or 2.5
    local grow   = 1.0 + (1.0 - (left / math.max(0.001, total))) * 0.4 -- up to +40%
    local radius = math.min(baseR * grow, 4.0)

    for _, c in ipairs(centers) do
        local ents = CE_ListNearbyEntities(c, radius)
        System.LogAlways(("[CuraEqui][Scan] center=(%.2f,%.2f,%.2f) r=%.2f → ents=%d")
            :format(c.x, c.y, c.z, radius, #ents))

        for _, ent in ipairs(ents) do
            if ent.class == "PickableItem" then
                -- name/guid sniff (common fields on PickableItem)
                local t                     = rawget(ent, "item") or rawget(ent, "Item") or ent
                local name                  = (t.GetUIName and t:GetUIName())
                    or t.uiName or t.name or ent.name or "?"
                local guid, name, className = CE_SniffGuidAndName(ent)
                System.LogAlways(("[CuraEqui][Scan] Pickable eid=%s name=%s guid=%s class=%s")
                    :format(tostring(ent.id), tostring(name), tostring(guid), tostring(className)))

                System.LogAlways(("[CuraEqui][Scan] Pickable eid=%s name=%s guid=%s"):format(tostring(ent.id),
                    tostring(name), tostring(guid)))

                local diet = (guid and CuraEqui.Diet and CuraEqui.Diet.byGuid and CuraEqui.Diet.byGuid[guid])
                    or (className and CuraEqui.Diet and CuraEqui.Diet.byClass and CuraEqui.Diet.byClass[className])
                    or nil
                -- TEMP keyword fallback so you can validate the loop today
                if not diet and name then
                    local s = string.lower(name)
                    for i = 1, #ALLOW_KWS do
                        if s:find(ALLOW_KWS[i], 1, true) then
                            System.LogAlways("[CuraEqui][Scan] keyword-allow → edible (test)")
                            diet = { nutrition = KW_NUTRITION, token = name }
                            break
                        end
                    end
                end

                if diet then
                    CE_DeleteEntity(ent) -- remove the world drop immediately
                    CuraEqui._scanActive = false
                    return CuraEqui._ApplyNutrition(diet, diet.token or name or "?")
                end
            end
        end
    end
end

function CuraEqui.Feed_StartScan(seconds)
    local s              = tonumber(seconds) or (CuraEqui.Config.FeedScan.windowSec or 6.0)
    CuraEqui._scanUntil  = _now() + s
    CuraEqui._scanActive = true
    System.LogAlways(("[CuraEqui][Scan] started (%.1fs, r=%.1fm)"):format(s, CuraEqui.Config.FeedScan.radius))
    if CuraEqui.UI and CuraEqui.UI.ShowInfo and CuraEqui.Config.FeedScan.toastOnStart then
        pcall(function() CuraEqui.UI.ShowInfo(CuraEqui.Config.FeedScan.toastOnStart, 2.2) end)
    end
    Script.SetTimerForFunction(CuraEqui.Config.FeedScan.tickMs or 150, "CuraEqui_FeedScan_Tick")
end

function CuraEqui_FeedScan_Tick()
    if not CuraEqui._scanActive then return end
    if _now() > (CuraEqui._scanUntil or 0) then
        CuraEqui._scanActive = false
        System.LogAlways("[CuraEqui][Scan] window ended")
        return
    end
    _scan_once()
    Script.SetTimerForFunction(CuraEqui.Config.FeedScan.tickMs or 150, "CuraEqui_FeedScan_Tick")
end

_G["CuraEqui_FeedScan_Tick"] = CuraEqui_FeedScan_Tick

-- ---------------------------------------------------------------------------
-- Entrypoint: action opens a picker if available, then starts the scanner
-- ---------------------------------------------------------------------------
function Horse:OnFeedHorse(user)
    System.LogAlways("[CuraEqui][Feed] OnFeedHorse")

    if UIAction and UIAction.RegisterElementListener then
        pcall(function()
            UIAction.RegisterElementListener(CuraEqui, "ApseInventoryList", -1, "CuraEquiOnDroppedToHorse",
                "OnDroppedToHorse")
        end)
    end

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
