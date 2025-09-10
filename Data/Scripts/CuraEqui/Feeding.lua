-- Scripts/CuraEqui/Feeding.lua
-- Cura Equi · Feeding (player drops → scanner eats)
-- ---------------------------------------------------------------------------

CuraEqui                 = CuraEqui or {}
CuraEqui.Config          = CuraEqui.Config or {}
CuraEqui.Config.FeedScan = CuraEqui.Config.FeedScan or {
    radius = 2.5,
    windowSec = 6.0,
    postCloseWindowSec = 8.0,
    postCloseDelayMs = 250,
    tickMs = 150,
    toastOnStart = "@curaequi_feed_drop_hint",
    armOnInventoryClose = true,
    armTimeoutSec = 25.0, -- ← add this
    groundProbe = true,
    groundOffsetDown = 1.2,
    debugDraw = false,
}


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

-- Return a list of entity *tables* near pos within radius.
-- Tries GetEntitiesInSphere; if empty or missing, falls back to GetEntities() + distance filter.
local function CE_ListNearbyEntities(pos, radius)
    local list = {}

    -- A) Preferred: direct sphere query → ids
    local okSphere, ids = pcall(function()
        return System.GetEntitiesInSphere and System.GetEntitiesInSphere(pos, radius) or nil
    end)

    if okSphere and ids and #ids > 0 then
        for i = 1, #ids do
            local okEnt, ent = pcall(function() return System.GetEntity(ids[i]) end)
            if okEnt and ent then list[#list + 1] = ent end
        end
        return list
    end

    -- B) Fallback: enumerate all entities then distance-filter in Lua
    local okAll, all = pcall(function()
        return System.GetEntities and System.GetEntities() or nil
    end)
    if not (okAll and all) then
        return list
    end

    local px, py, pz = pos.x or 0, pos.y or 0, pos.z or 0
    local r2 = (radius or 0) ^ 2
    local n = #all
    -- Some builds return ids, others return entity tables; handle both
    for i = 1, n do
        local ent = all[i]
        if type(ent) ~= "table" then
            local okE, got = pcall(function() return System.GetEntity(ent) end)
            ent = okE and got or nil
        end
        if ent and ent.GetWorldPos then
            local ep = ent:GetWorldPos()
            local dx, dy, dz = (ep.x - px), (ep.y - py), (ep.z - pz)
            if (dx * dx + dy * dy + dz * dz) <= r2 then
                list[#list + 1] = ent
            end
        end
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

local function CE_GetScanCenters()
    local centers = {}
    local horse, mouth = CE_GetHorseAndMouthPos()
    if horse and mouth then
        centers[#centers + 1] = mouth
        if CuraEqui.Config.FeedScan.groundProbe then
            local gz = (CuraEqui.Config.FeedScan.groundOffsetDown or 1.2)
            centers[#centers + 1] = { x = mouth.x, y = mouth.y, z = mouth.z - gz }
        end
        return centers, "horse"
    end

    -- Fallback: in front of PLAYER
    if player and player.GetWorldPos then
        local p = player:GetWorldPos()
        local f = (player.GetDirectionVector and player:GetDirectionVector(1)) or { x = 1, y = 0, z = 0 }
        centers[#centers + 1] = { x = p.x + f.x * 1.0, y = p.y + f.y * 1.0, z = p.z - 0.4 }
        return centers, "player"
    end

    return centers, "none"
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
            local guid, name = CE_SniffGuidAndName(ent)
            if guid or (rawget(ent, "item") ~= nil) then
                System.LogAlways(("[CuraEqui][Scan] found '%s' guid=%s eid=%s")
                    :format(tostring(name or ent.class), tostring(guid), tostring(ent.id)))

                local diet = (guid and CuraEqui.Diet and CuraEqui.Diet.byGuid and CuraEqui.Diet.byGuid[guid]) or nil
                -- TEMP keyword fallback for testing; remove when GUID map is ready
                if not diet and name then
                    local s = string.lower(tostring(name))
                    if s:find("apple", 1, true) or s:find("@ui_nm_", 1, true) or s:find("bread", 1, true) then
                        System.LogAlways("[CuraEqui][Scan] keyword-allow → edible (test)")
                        diet = {
                            nutrition = (CuraEqui.Config.Diet and CuraEqui.Config.Diet.defaultNutrition) or 10,
                            token =
                                name
                        }
                    end
                end

                if diet then
                    CE_DeleteEntity(ent)
                    CuraEqui._scanActive = false
                    return CuraEqui._ApplyNutrition(diet, diet.token or name or "?")
                else
                    System.LogAlways("[CuraEqui][Scan] not edible → leaving")
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
