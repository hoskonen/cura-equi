-- Feeding.lua (Cura Equi) — player-centered post-inventory scan & feed
-- Single-source config lives in Config.lua (CuraEqui.Config.*). This file only reads it.

CuraEqui                = CuraEqui or {}

-- ------------------------------------------------------------
-- Read-only config view (+ light fallbacks)
-- ------------------------------------------------------------
local FC                = (CuraEqui.Config and CuraEqui.Config.FeedScan) or {}
local DC                = (CuraEqui.Config and CuraEqui.Config.Diet) or {}

local FEED_RADIUS       = tonumber(FC.radius) or 3.0
local FEED_TICK_MS      = tonumber(FC.tickMs) or 150
local FEED_WINDOW_SEC   = tonumber(FC.windowSec) or 6.0
local FEED_POST_SEC     = tonumber(FC.postCloseWindowSec) or 10.0
local FEED_DELAY_MS     = tonumber(FC.postCloseDelayMs) or 400
local FEED_TOAST        = FC.toastOnStart
local FEED_ARM_ON_CLOSE = (FC.armOnInventoryClose ~= false)
local FEED_ARM_TIMEOUT  = tonumber(FC.armTimeoutSec) or 25.0

local ALLOW_KWS         = DC.allowKeywords or { "ui_nm_", "apple", "bread", "carrot" }
local KW_NUTRITION      = tonumber(DC.keywordNutrition) or 10

-- runtime state (not in config)
CuraEqui._invArmActive  = CuraEqui._invArmActive or false
CuraEqui._invArmExpires = CuraEqui._invArmExpires or 0
CuraEqui._scanUntil     = CuraEqui._scanUntil or nil
CuraEqui._scanActive    = CuraEqui._scanActive or false
CuraEqui._armToken      = CuraEqui._armToken or 0  -- bumps to invalidate stale scans
CuraEqui._scanToken     = CuraEqui._scanToken or 0 -- snapshot of token for the current scan

-- ------------------------------------------------------------
-- Small utils
-- ------------------------------------------------------------
local function _now()
    if _G.Script and type(Script.GetTime) == "function" then return Script.GetTime() end
    return os.clock()
end

local function CE_Log(fmt, ...)
    if System and System.LogAlways then
        System.LogAlways(("[CuraEqui][Feed] " .. tostring(fmt)):format(...))
    end
end

-- ------------------------------------------------------------
-- Inventory close arming (one removal window)
-- ------------------------------------------------------------
function CuraEqui._InvClose_ArmOnce(timeoutSec)
    CuraEqui._invArmActive        = true
    CuraEqui._invArmExpires       = _now() + (tonumber(timeoutSec) or FEED_ARM_TIMEOUT)
    CuraEqui._armToken            = (CuraEqui._armToken or 0) + 1 -- NEW
    CuraEqui._windowEndedNotified = false                         -- optional: for one-shot end toast
    System.LogAlways(("[CuraEqui][Scan] armed for inventory close (%.1fs)"):format(timeoutSec or FEED_ARM_TIMEOUT))
end

function CuraEqui._InvClose_Disarm(reason)
    CuraEqui._invArmActive  = false
    CuraEqui._invArmExpires = 0
    CuraEqui._scanActive    = false
    CuraEqui._armToken      = (CuraEqui._armToken or 0) + 1

    if reason == "timeout" then
        System.LogAlways("[CuraEqui][Scan] window ended")
        local D = CuraEqui.Config and CuraEqui.Config.Debug
        if D and D.enabled and not CuraEqui._windowEndedNotified and CuraEqui.UI then
            CuraEqui._windowEndedNotified = true
            pcall(function()
                local F = CuraEqui.Config.FeedScan
                CuraEqui.UI.Toast("@curaequi_feed_window_ended", (F and F.toastMs) or 1200, 0, "CuraEquiFeed",
                    (F and F.toastLane) or "infotext")
            end)
        end
    end
end

-- ------------------------------------------------------------
-- Inventory close listeners (Scaleform movies)
-- ------------------------------------------------------------
local _reg_done = false
local function _reg(elem, ev, cb)
    pcall(function() UIAction.RegisterElementListener(CuraEqui, elem, -1, ev, cb) end)
end

local function RegisterInventoryCloseHooks()
    if _reg_done then return end
    _reg("ApseInventoryInfo", "OnHide", "OnInvClosed")
    _reg("ApseInventoryList", "OnHide", "OnInvClosed")
    _reg("ApseCharacter", "OnHide", "OnInvClosed")
    _reg("ApsePlayerList", "OnHide", "OnInvClosed")
    _reg("ApsePlayerInfo", "OnHide", "OnInvClosed")
    _reg("ApseModalDialog", "OnHide", "OnInvClosed")
    _reg_done = true
end

function CuraEqui:OnInvClosed(elementName, _instanceId, eventName, _args)
    if not CuraEqui._invArmActive then return end
    local now = _now()
    if now > (CuraEqui._invArmExpires or 0) then
        System.LogAlways("[CuraEqui][Scan] ignored close (arm expired)")
        return
    end
    System.LogAlways(("[CuraEqui][Scan] inventory closed via %s.%s → starting post-close scan")
        :format(tostring(elementName), tostring(eventName)))
    CuraEqui._InvClose_Disarm("arm_used")

    if FEED_DELAY_MS > 0 and Script and Script.SetTimerForFunction then
        _G["CuraEqui_Feed_StartScanDelayed"] = function()
            CuraEqui.Feed_StartScan(FEED_POST_SEC)
        end
        Script.SetTimerForFunction(FEED_DELAY_MS, "CuraEqui_Feed_StartScanDelayed")
    else
        CuraEqui.Feed_StartScan(FEED_POST_SEC)
    end
end

-- ------------------------------------------------------------
-- Centers for scanning (player-first, optional horse mouth)
-- ------------------------------------------------------------
local function CE_GetScanCenters()
    local centers = {}

    -- Player feet + slight ground offset
    if player and type(player.GetWorldPos) == "function" then
        local p = player:GetWorldPos()
        if p then
            centers[#centers + 1] = { x = p.x, y = p.y, z = p.z }
            centers[#centers + 1] = { x = p.x, y = p.y, z = p.z - 0.6 }
        else
            System.LogAlways("[CuraEqui][Scan] ⚠ player:GetWorldPos() returned nil")
        end
    else
        System.LogAlways("[CuraEqui][Scan] ⚠ no player or player:GetWorldPos missing")
    end

    -- (Optional) also include horse mouth if resolvable
    local h = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    if h and h.GetWorldPos then
        local hp = h:GetWorldPos()
        if hp then
            local f = (h.GetDirectionVector and h:GetDirectionVector(1)) or { x = 1, y = 0, z = 0 }
            centers[#centers + 1] = { x = hp.x + f.x * 0.9, y = hp.y + f.y * 0.9, z = hp.z + 1.3 }
        end
    end

    if #centers == 0 then
        centers[#centers + 1] = { x = 0, y = 0, z = 0 }
        System.LogAlways("[CuraEqui][Scan] ⚠ no valid centers; using (0,0,0) fallback")
    end

    return centers, "player+horse"
end

-- ------------------------------------------------------------
-- Entity query: PickableItem first; fallback to generic sphere
-- ------------------------------------------------------------
local function CE_ListNearbyPickables(pos, radius)
    local out = {}

    -- Prefer class-filtered query
    local okC, arr = pcall(function()
        return System.GetEntitiesInSphereByClass and System.GetEntitiesInSphereByClass(pos, radius, "PickableItem")
    end)
    if okC and arr and #arr > 0 then
        for _, e in ipairs(arr) do
            local ent = (type(e) == "table") and e or (System.GetEntity and System.GetEntity(e))
            if ent then out[#out + 1] = ent end
        end
        return out
    end

    -- Fallback: generic sphere + manual filter
    local ok, all = pcall(function()
        return System.GetEntitiesInSphere and System.GetEntitiesInSphere(pos, radius)
    end)
    if ok and all then
        for _, e in ipairs(all) do
            local ent = (type(e) == "table") and e or (System.GetEntity and System.GetEntity(e))
            if ent and ent.class == "PickableItem" then
                out[#out + 1] = ent
            end
        end
    else
        System.LogAlways("[CuraEqui][Scan] ⚠ sphere query returned empty/nil at this moment")
    end

    return out
end

-- ------------------------------------------------------------
-- Sniff name / guid / class using getters you confirmed exist
-- ------------------------------------------------------------
local function CE_SniffGuidAndName(ent)
    local t = rawget(ent, "item") or rawget(ent, "Item") or ent

    -- NAME
    local name
    if type(t.GetUIName) == "function" then
        pcall(function() name = t:GetUIName() end)
    end
    name = name or t.uiName or t.name or ent.name or "?"

    -- GUID
    local guid
    if type(t.GetGuid) == "function" then
        pcall(function() guid = t:GetGuid() end)
    end
    guid = guid or t.guid or ent.guid or nil

    -- CLASS (useful for byClass fallback)
    local className
    if type(t.GetClassName) == "function" then
        pcall(function() className = t:GetClassName() end)
    end
    className = className or t.className or ent.className or ent.class

    return guid, name, className
end

-- ------------------------------------------------------------
-- Robust world entity deletion (DeleteThis → Remove → System.RemoveEntity)
-- ------------------------------------------------------------
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
    if type(ent.DeleteThis) == "function" then
        deleted = try("ent:DeleteThis()", function() return ent:DeleteThis() end) or deleted
    end
    if not deleted and type(ent.Remove) == "function" then
        deleted = try("ent:Remove()", function() return ent:Remove() end) or deleted
    end
    if not deleted and System and type(System.RemoveEntity) == "function" and id then
        deleted = try("System.RemoveEntity(id)", function() return System.RemoveEntity(id) end) or deleted
    end

    local still = (System and System.GetEntity) and System.GetEntity(id) or nil
    System.LogAlways(("[CuraEqui][Delete] verify-now id=%s → %s")
        :format(tag, still and "STILL THERE" or "gone"))

    -- Optional delayed verify (engine sometimes removes next frame)
    if Script and type(Script.SetTimer) == "function" then
        local verifyId = id
        Script.SetTimer(250, function()
            local again = (System and System.GetEntity) and System.GetEntity(verifyId) or nil
            System.LogAlways(("[CuraEqui][Delete] verify-250ms id=%s → %s")
                :format(tostring(verifyId), again and "STILL THERE" or "gone"))
        end)
    end

    return deleted and not still
end

-- expects FC = CuraEqui.Config.FeedScan (alias defined near top of file)
local function CE_ConsumeAfterDelay(ent, diet, label)
    local F         = CuraEqui.Config and CuraEqui.Config.FeedScan or nil
    local delay     = tonumber(FC and FC.landDelayMs) or 0
    local msg       = (F and F.toastOnEat) or "@curaequi_horse_munch"
    local toastMs   = (F and F.toastMs) or 1800
    local toastPrio = (F and F.toastPrio) or 0
    local toastLane = (F and F.toastLane) or "tutorial"      -- "tutorial" (tiny right) | "notification" (center)
    local sfxId     = F and F.munchSfx

    -- single place that actually consumes + feedback
    local function doConsume()
        -- delete the world drop
        CE_DeleteEntity(ent)

        if CuraEqui.UI then
            pcall(function()
                CuraEqui.UI.Toast(msg, toastMs, toastPrio, "CuraEquiFeed", toastLane)
            end)
        end
        -- Prefer playing at the horse (moves with it); fallback to player; finally the food's last pos
        if sfxId and sfxId ~= "" and CuraEqui.Audio then
            local horse = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
            local ok = false
            if horse then ok = CuraEqui.Audio.PlayAtEntity(sfxId, horse) end
            if not ok and g_localActor then ok = CuraEqui.Audio.PlayAtEntity(sfxId, g_localActor) end
            if not ok and ent then ok = CuraEqui.Audio.PlayAtEntity(sfxId, ent) end
        end
        return CuraEqui._ApplyNutrition and CuraEqui._ApplyNutrition(diet, diet.token or label or "?")
    end

    if CuraEqui._InvClose_Disarm then
        pcall(CuraEqui._InvClose_Disarm, "success")
    else
        CuraEqui._scanActive = false
        CuraEqui._armToken = (CuraEqui._armToken or 0) + 1
    end

    if delay > 0 and Script and Script.SetTimerForFunction then
        -- optional visual: hide while "landing"
        if ent and type(ent.Hide) == "function" then pcall(function() ent:Hide(1) end) end
        _G["CuraEqui_Feed_DoConsume"] = doConsume
        Script.SetTimerForFunction(delay, "CuraEqui_Feed_DoConsume")
        return true        -- scheduled
    else
        return doConsume() -- immediate
    end
end

-- ------------------------------------------------------------
-- Scanner pass: look for first edible PickableItem near the centers
-- ------------------------------------------------------------
local function _scan_once()
    local centers, origin = CE_GetScanCenters()
    System.LogAlways(("[CuraEqui][Scan] origin=%s centers=%d"):format(origin, #centers))

    local now    = _now()
    local total  = FEED_POST_SEC
    local left   = math.max(0, (CuraEqui._scanUntil or 0) - now)
    local baseR  = FEED_RADIUS
    local grow   = 1.0 + (1.0 - (left / math.max(0.001, total))) * 0.4 -- up to +40%
    local radius = math.min(baseR * grow, 4.0)

    for _, c in ipairs(centers) do
        local ents = CE_ListNearbyPickables(c, radius)
        System.LogAlways(("[CuraEqui][Scan] center=(%.2f,%.2f,%.2f) r=%.2f → pickables=%d")
            :format(c.x, c.y, c.z, radius, #ents))

        for _, ent in ipairs(ents) do
            local guid, name, className = CE_SniffGuidAndName(ent)
            System.LogAlways(("[CuraEqui][Scan] Pickable eid=%s name=%s guid=%s class=%s")
                :format(tostring(ent.id), tostring(name), tostring(guid), tostring(className)))

            -- Diet: prefer GUID, then byClass table (if provided), then keyword fallback (test)
            local diet = (guid and CuraEqui.Diet and CuraEqui.Diet.byGuid and CuraEqui.Diet.byGuid[guid])
                or (className and CuraEqui.Diet and CuraEqui.Diet.byClass and CuraEqui.Diet.byClass[className])
                or nil

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
                if CuraEqui._scanToken ~= CuraEqui._armToken or not CuraEqui._scanActive then
                    return -- stale or stopped
                end
                return CE_ConsumeAfterDelay(ent, diet, name)
            end
        end
    end
end

-- ------------------------------------------------------------
-- Scan lifecycle
-- ------------------------------------------------------------
function CuraEqui.Feed_StartScan(seconds)
    local s              = tonumber(seconds) or FEED_WINDOW_SEC
    CuraEqui._scanUntil  = _now() + s
    CuraEqui._scanActive = true
    CuraEqui._scanToken  = CuraEqui._armToken -- NEW: bind this scan to current window
    System.LogAlways(("[CuraEqui][Scan] started (%.1fs, r=%.1fm)"):format(s, FEED_RADIUS))

    if Script and type(Script.SetTimerForFunction) == "function" then
        Script.SetTimerForFunction(FEED_TICK_MS, "CuraEqui_FeedScan_Tick")
    end
end

function CuraEqui_FeedScan_Tick()
    if not CuraEqui._scanActive then return end
    if CuraEqui._scanToken ~= CuraEqui._armToken then return end
    if _now() > (CuraEqui._scanUntil or 0) then
        if CuraEqui._InvClose_Disarm then
            CuraEqui._InvClose_Disarm("timeout")
        else
            CuraEqui._scanActive = false
        end
        return
    end
    _scan_once()
    if Script and type(Script.SetTimerForFunction) == "function" then
        Script.SetTimerForFunction(FEED_TICK_MS, "CuraEqui_FeedScan_Tick")
    end
end

_G["CuraEqui_FeedScan_Tick"] = CuraEqui_FeedScan_Tick

-- ------------------------------------------------------------
-- Action entry point (keeps your action button behavior intact)
-- ------------------------------------------------------------
function Horse:OnFeedHorse(user)
    local my = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    if my and self and my.id == self.id then
        System.LogAlways("[CuraEqui][Feed] OnFeedHorse")
        RegisterInventoryCloseHooks()
        if FEED_ARM_ON_CLOSE then
            CuraEqui._InvClose_ArmOnce(FEED_ARM_TIMEOUT)
            if CuraEqui.UI and CuraEqui.UI.ShowInfo and FEED_TOAST then
                pcall(function() CuraEqui.UI.ShowInfo(FEED_TOAST, 2.2) end)
            end
        else
            -- alternative mode: start scan immediately (no inv-close arm)
            CuraEqui.Feed_StartScan(FEED_WINDOW_SEC)
        end
    else
        System.LogAlways("[CuraEqui][Feed] blocked: not your horse")
    end
end

-- ------------------------------------------------------------
-- Optional: console helpers for debugging (safe to keep)
-- ------------------------------------------------------------
function CuraEqui.Debug_ScanLikeSanitas(r)
    local radius = tonumber(r) or 4.0
    local ply = (player and player.GetWorldPos and player) or (Utils and Utils.GetPlayer and Utils.GetPlayer()) or nil
    if not ply then
        System.LogAlways("[CuraEqui][DbgScan] no player"); return
    end
    local pos = ply:GetWorldPos() or (ply.GetPos and ply:GetPos()) or { x = 0, y = 0, z = 0 }
    System.LogAlways(("[CuraEqui][DbgScan] pos=(%.2f, %.2f, %.2f) r=%.2f"):format(pos.x, pos.y, pos.z, radius))
    local ok, ents = pcall(function() return System.GetEntitiesInSphere(pos, radius) end)
    if not ok or not ents then
        System.LogAlways("[CuraEqui][DbgScan] GetEntitiesInSphere → nil"); return
    end
    System.LogAlways(("[CuraEqui][DbgScan] scanning %d entities"):format(#ents))
    for _, e in ipairs(ents) do
        local ent = (type(e) == "table") and e or (System.GetEntity and System.GetEntity(e))
        if ent then
            local name = (ent.GetName and ent:GetName()) or ent.name or "no-name"
            local class = ent.class or "no-class"
            System.LogAlways(("[CuraEqui][DbgScan] • class=%s name=%s"):format(tostring(class), tostring(name)))
        end
    end
end

do
    local H = _G.Horse
    if H and type(H.GetActions) == "function" and not H.__curaequi_feed_wrapped then
        local _Get = H.GetActions
        function H.GetActions(self, user, firstFast)
            local actions = _Get(self, user, firstFast) or {}

            -- only on living horses
            local alive = self and self.actor and self.actor.GetHealth and (self.actor:GetHealth() > 0) or false
            if not alive then return actions end

            -- don’t double-inject
            for i = 1, #actions do
                local a = actions[i]
                if a and a.func == H.OnFeedHorse then return actions end
            end

            local allowAny = CuraEqui.Config and CuraEqui.Config.FeedScan and CuraEqui.Config.FeedScan.allowAnyHorse
            if not allowAny then
                local mine = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
                if not (mine and self and mine.id == self.id) then
                    return actions
                end
            end

            -- compute max uiOrder to append after existing actions
            local maxOrder = 0
            for i = 1, #actions do
                local o = actions[i] and actions[i].uiOrder or 0
                if o and o > maxOrder then maxOrder = o end
            end

            -- find the correct interaction lane (vanilla horse lanes)
            local lane = rawget(_G, "inr_horseInspect") or rawget(_G, "inr_horseMount")
            if not lane then return actions end

            -- build the action (press)
            local A = Action()
                :hint("@curaequi_drop_food") -- your string table key
                :action("use_horse")         -- keep identical to vanilla mappings
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
