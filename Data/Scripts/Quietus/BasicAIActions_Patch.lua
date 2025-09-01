-- Scripts/Quietus/BasicAIActions_Patch.lua
-- Quietus: add "Finish off" for corpses via chat-route; disable carry for 5s; native-or-fallback handler.
-- Lua 5.1 compatible. Minimal logs unless Quietus.DEBUG = true.

Quietus = Quietus or {}
if Quietus.DEBUG == nil then Quietus.DEBUG = true end

local function Q(fmt, ...)
    if Quietus.DEBUG then System.LogAlways(("[Quietus] " .. fmt):format(...)) end
end

-- ---------- State & helpers ----------
Quietus.RecentDead = Quietus.RecentDead or {} -- eid -> { inCombat=true/false }
Quietus.__finishedCorpse = Quietus.__finishedCorpse or {}

local function isFinished(eid) return eid and Quietus.__finishedCorpse[eid] == true end
local function markFinished(eid) if eid then Quietus.__finishedCorpse[eid] = true end end

local function isRecentDeath(eid)
    return eid and Quietus.RecentDead[eid] ~= nil
end

-- Enhanced: mark recent death, block Grab Body for 5s using vanilla's exact flag.
local function markRecentDeath(eid, inCombat, targetSoul)
    if not eid then return end
    Quietus.RecentDead[eid] = { inCombat = inCombat and true or false }

    -- Vanilla BasicAIActions checks this to enable/disable carry:
    --   local canBeGrabbed = not self.soul:HasScriptContext("crime_greyOutGrabBody")
    if targetSoul and targetSoul.AddScriptContext then
        pcall(function() targetSoul:AddScriptContext("crime_greyOutGrabBody") end)
    end

    Script.SetTimer(5000, function()
        Quietus.RecentDead[eid] = nil
        if targetSoul and targetSoul.RemoveScriptContext then
            pcall(function() targetSoul:RemoveScriptContext("crime_greyOutGrabBody") end)
        end
    end)
end

-- Optional: RP fallback (stub). Replace with emote/FX/UI as you like.
function Quietus.DoFallbackFinish(user, target)
    local tname = (EntityUtils and target and EntityUtils.GetName and EntityUtils.GetName(target)) or "target"
    Q("FallbackFinish: %s", tname)
    markFinished(target and target.id)
end

-- Dead-target handler: try native if ever enabled; otherwise fallback ritual.
function Quietus.OnMercyKill_Dead(self, user, slotId)
    System.LogAlways("[Quietus] OnMercyKill_Dead fired")
    local can = (user and user.actor and user.actor.CanDoMercyKill and user.actor:CanDoMercyKill(self.id)) or "nil"
    if can == MKS_Enabled and user and user.actor and user.actor.RequestMercyKill then
        user.actor:RequestMercyKill(self.id) -- unlikely on corpses; harmless try
        return
    end
    Quietus.DoFallbackFinish(user, self)
end

-- ---------- Utility ----------
local function hasMercyAction(out, host)
    if type(out) ~= "table" then return false end
    for i = 1, #out do
        local a = out[i]
        if a then
            if a.action == "mercy_kill" then return true end
            if a.interaction == inr_mercyKill then return true end
            if a.hint == "@ui_hud_mercy_kill" or a.hint == "@ui_hud_mercy_kill_unconscious" then return true end
            if host and a.func == host.OnMercyKill then return true end
            if a.func == Quietus.OnMercyKill_Dead then return true end
        end
    end
    return false
end

-- Core injector used by all wrapped hosts
local function injectMercy(self, user, firstFast, out, host)
    local actor = self and self.actor
    local isDead = actor and actor.IsDead and (actor:IsDead() == true)
    if not isDead then return out end
    if hasMercyAction(out, host) then return out end

    -- First time we see this corpse → start 5s window & block carry
    local eid = self and self.id
    if not isRecentDeath(eid) then
        local inCombat = (player and player.soul and player.soul.IsInCombatDanger and (player.soul:IsInCombatDanger() == 1 or player.soul:IsInCombatDanger() == true)) or
            false
        markRecentDeath(eid, inCombat, self and self.soul)
        Q("Marked recent death: eid=%s inCombat=%s (grab blocked 5s)", tostring(eid), tostring(inCombat))
    end

    -- Only show within the 5s window. Remove this check if you want it always visible.
    if not isRecentDeath(eid) then return out end

    if not (Action and AddInteractorAction and AHT_PRESS and inr_chatFollow and AHC_CHAT) then
        return out
    end

    local canMercy = (user and user.actor and user.actor.CanDoMercyKill and user.actor:CanDoMercyKill(self.id)) or "nil"
    local name = (EntityUtils and EntityUtils.GetName and EntityUtils.GetName(self)) or (self and self.class) or
        "unknown"
    Q("Injecting Mercy (chat-route) via %s: %s (canMercy=%s)", tostring(host and host.__quietus_name or "unknown"),
        tostring(name), tostring(canMercy))

    -- Visible chat-style hint
    AddInteractorAction(out, firstFast,
        Action()
        :hint("@ui_hud_mercy_kill") -- or your Quietus loc key
        :action("chat_init_with_focus")
        :actionMap("chat_init_interactor")
        :hintType(AHT_PRESS)
        :func(Quietus.OnMercyKill_Dead)
        :interaction(inr_chatFollow)
        :hintClass(AHC_CHAT)
        :uiOrder(5)
        :enabled(true)
    )

    -- Hidden catcher (vanilla chat pattern)
    AddInteractorAction(out, firstFast,
        Action()
        :action("chat_init_interactor_press")
        :actionMap("chat_init_interactor")
        :hintType(AHT_PRESS)
        :func(Quietus.OnMercyKill_Dead)
        :interaction(inr_chatFollow)
        :hintClass(AHC_CHAT)
        :uiVisible(false)
        :uiOrder(5)
        :enabled(true)
    )

    return out
end

-- --- Add this near your other wrappers (outside injectMercy) ---

local function wrapOnLoot()
    local B = _G.BasicAIActions
    if not B or B.__quietus_patched_onloot then return end

    local _OnLoot = B.OnLoot
    if type(_OnLoot) ~= "function" then return end

    function B:OnLoot(user, slotId)
        -- Only intercept fresh corpses (within our 5s window)
        local eid = self and self.id
        local dead = self and self.actor and self.actor.IsDead and self.actor:IsDead() == true

        if dead and eid and isRecentDeath(eid) and not isFinished(eid) then
            System.LogAlways("[Quietus] OnLoot intercepted → doing Quietus finish first")
            Quietus.DoFallbackFinish(user, self)
            -- optional: tiny delay to let FX/emote start before loot UI
            Script.SetTimer(100, function()
                _OnLoot(self, user, slotId)
            end)
            return
        end

        -- Regular path
        return _OnLoot(self, user, slotId)
    end

    B.__quietus_patched_onloot = true
    System.LogAlways("[Quietus] ✅ Wrapped BasicAIActions.OnLoot")
end

-- ---------- Generic wrapping (covers BasicAIActions & other hosts with GetActions) ----------
local function patchHost(host, name)
    if type(host) ~= "table" then return false end
    if host.__quietus_patched_getactions then return false end
    local GA = host.GetActions
    if type(GA) ~= "function" then return false end

    host.__quietus_name = name or "unknown"

    host.GetActions = function(self, user, firstFast)
        local out = GA(self, user, firstFast) or {}
        local actor = self and self.actor
        if actor and actor.IsDead and actor:IsDead() == true then
            local nm = (EntityUtils and EntityUtils.GetName and EntityUtils.GetName(self)) or (self and self.class) or
                "unknown"
            Q("GetActions(hit): %s via %s (dead=true)", tostring(nm), tostring(host.__quietus_name))
        end
        return injectMercy(self, user, firstFast, out, host)
    end

    host.__quietus_patched_getactions = true
    Q("✅ Wrapped GetActions on %s", tostring(name))
    return true
end

local function scanAndPatch(label)
    local cnt = 0
    for k, v in pairs(_G) do
        if k ~= "Quietus" and type(v) == "table" and type(rawget(v, "GetActions")) == "function" then
            if patchHost(v, k) then cnt = cnt + 1 end
        end
    end
    if cnt > 0 then Q("scan(%s): wrapped %d tables", tostring(label), cnt) end
    return cnt
end

-- ---------- Loop / monitor ----------
local attempts = 0
local function loop(label, interval, settle)
    attempts = attempts + 1
    if attempts == 1 or attempts % 5 == 0 then Q("Patch loop (%s) attempt %d", tostring(label), attempts) end
    scanAndPatch(label)
    if attempts < (settle or 40) then
        Script.SetTimer(interval or 500, function() loop(label, interval, settle) end)
    else
        Q("Patch loop (%s) settling; slow monitor on", tostring(label))
        Script.SetTimer(5000, function() loop("monitor", 5000, 999999) end)
    end
end

-- Kick off immediately; quietus_init.lua may also trigger a pass on OnGameplayStarted
loop("init", 500, 40)

Quietus.BasicAIActions_StartPatchLoop = function()
    attempts = 0
    loop("OnGameplayStarted", 500, 40)
end
