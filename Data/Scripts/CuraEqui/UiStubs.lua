CuraEqui                 = CuraEqui or {}
CuraEqui.UI              = CuraEqui.UI or {}
local UI                 = CuraEqui.UI

local _lastText, _lastAt = nil, 0
local function _dedupe(text)
    local now = (System.GetCurrTime and System.GetCurrTime() * 1000) or (os.clock() * 1000)
    if text == _lastText and (now - _lastAt) < 800 then return true end
    _lastText, _lastAt = text, now
    return false
end

-- SFX helper (unchanged concept)
function CuraEqui.UI.PlaySfx(sfxEnum)
    if not sfxId or sfxId == "" then return end
    local pos = ent and ent:GetWorldPos() or System.GetEntityPos(g_localActor.id)
    XGenAIModule.ProduceSound(sfxEnum, pos, 1.0)
end

-- === Audio (ATL + fallback) ===
CuraEqui.Audio = CuraEqui.Audio or {}
local _trigCache = {}

local function _lookupTriggerId(name)
    if not name or name == "" then return 0 end
    if _trigCache[name] then return _trigCache[name] end
    local id = 0
    if AudioUtils and AudioUtils.LookupTriggerID then
        id = AudioUtils.LookupTriggerID(name) or 0
    end
    _trigCache[name] = id
    if id == 0 then
        System.LogAlways("[CuraEqui][Audio] trigger not found: " .. tostring(name))
    end
    return id
end

-- Prefer ATL: attach to entity’s default proxy so sound follows it.
function CuraEqui.Audio.PlayAtEntity(triggerOrEventName, ent)
    if not ent then return false end

    -- 1) ATL trigger route
    local trigId = _lookupTriggerId(triggerOrEventName)
    if trigId ~= 0 and ent.ExecuteAudioTrigger and ent.GetDefaultAuxAudioProxyID then
        local ok = pcall(function()
            ent:ExecuteAudioTrigger(trigId, ent:GetDefaultAuxAudioProxyID())
        end)
        if ok then return true end
    end

    -- 2) Fallback: legacy PlaySoundEvent (as seen in Lockpickable)
    if ent.PlaySoundEvent then
        local sndFlags = _G.SOUND_DEFAULT_3D or 0
        local fwd = (ent.GetDirectionVector and ent:GetDirectionVector(1)) or g_Vectors.v010 or { x = 0, y = 1, z = 0 }
        local ok = pcall(function()
            ent:PlaySoundEvent(tostring(triggerOrEventName), g_Vectors.v000 or { x = 0, y = 0, z = 0 }, fwd, sndFlags,
                _G.SOUND_SEMANTIC_MECHANIC_ENTITY or 0)
        end)
        if ok then return true end
    end

    return false
end

-- Optional: AI hearing ping (not guaranteed audible to player)
function CuraEqui.Audio.ProduceAIsound(soundEnum, pos, mult)
    if not (XGenAIModule and XGenAIModule.ProduceSound) then return false end
    local p = pos or (g_localActor and g_localActor:GetWorldPos()) or { x = 0, y = 0, z = 0 }
    local m = tonumber(mult or 1.0) or 1.0
    local ok = pcall(function() XGenAIModule.ProduceSound(soundEnum, p, m) end)
    return ok and true or false
end

-- Debug helpers: try names on the fly
function CuraEqui.Audio.TestOnHorse(name)
    local horse = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    return CuraEqui.Audio.PlayAtEntity(name, horse or g_localActor)
end

function CuraEqui.Audio.TestOnPlayer(name)
    return CuraEqui.Audio.PlayAtEntity(name, g_localActor)
end

-- ── config helpers ──────────────────────────────────────────────────────────
local function _cfg()
    local D  = (CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud) or {}
    local CU = (CuraEqui.Config and CuraEqui.Config.UI) or {}
    return {
        enabled                = (D.enabled ~= false),
        laneDefault            = D.lane or "notification", -- "notification"|"tutorial"|"infotext"
        defaultTimeoutMs       = tonumber(D.refresh or 1200) or 1200,
        defaultPriority        = 0,
        hudElement             = CU.hudElement or "HUD",               -- <- match your game HUD movie name here
        fallbackToNotification = (CU.fallbackToNotification ~= false), -- true by default
        tagId                  = D.id or "CuraEqui_Toast",
    }
end

-- ── low-level Scaleform call ────────────────────────────────────────────────
local function _hud() -- returns chosen HUD element name (same as Unworthy)
    return _cfg().hudElement
end

local function _call(func, ...)
    if not (UIAction and UIAction.CallFunction) then return false end
    return pcall(UIAction.CallFunction, _hud(), -1, func, ...)
end

-- ── lanes ───────────────────────────────────────────────────────────────────
local function _sendNotification(text)
    text = tostring(text or "")
    return _call("ShowNotification", text) -- center popup
end

-- HUD.ShowTutorial(Id, Text, DurationMS, InDialogue, Priority, Layout, ActionHintEnable, OverlayLink)
local function _sendTutorial(text, ms, prio, id)
    text       = tostring(text or "")
    local Id   = tostring(id or _cfg().tagId)
    local Dur  = math.max(1, tonumber(ms or _cfg().defaultTimeoutMs) or 0)
    local Prio = tonumber(prio or _cfg().defaultPriority) or 0
    return _call("ShowTutorial", Id, text, Dur, false, Prio, 0, false, "")
end

-- ── public API ──────────────────────────────────────────────────────────────
-- Toast(text, ms, prio, id, lane) → true/false
function UI.Toast(text, ms, prio, id, lane)
    local C = _cfg()
    if not C.enabled then return false end

    local ln = lane or C.laneDefault
    local ok = false

    if ln == "tutorial" then
        ok = _sendTutorial(text, ms, prio, id)
        if (not ok) and C.fallbackToNotification then
            ok = _sendNotification(text)
        end
        if not ok and Game and Game.SendInfoText then
            pcall(Game.SendInfoText, tostring(text or ""), false, (id or C.tagId),
                tonumber(ms or C.defaultTimeoutMs) or 1500)
            ok = true
        end
        return ok
    elseif ln == "notification" then
        ok = _sendNotification(text)
        if not ok and Game and Game.SendInfoText then
            pcall(Game.SendInfoText, tostring(text or ""), false, (id or C.tagId),
                tonumber(ms or C.defaultTimeoutMs) or 1500)
            ok = true
        end
        return ok
    elseif ln == "infotext" then
        if Game and Game.SendInfoText then
            pcall(Game.SendInfoText, tostring(text or ""), false, (id or C.tagId),
                tonumber(ms or C.defaultTimeoutMs) or 1500)
            return true
        end
        -- fallback to notification if engine infotekst not available
        return _sendNotification(text)
    else
        -- unknown lane → try notification, then engine
        ok = _sendNotification(text)
        if not ok and Game and Game.SendInfoText then
            pcall(Game.SendInfoText, tostring(text or ""), false, (id or C.tagId),
                tonumber(ms or C.defaultTimeoutMs) or 1500)
            ok = true
        end
        return ok
    end
end

-- Convenience testers (optional)
function UI.DebugToast(text, lane)
    return UI.Toast(text or "CuraEqui toast test", _cfg().defaultTimeoutMs, 0, "CuraEqui_Debug",
        lane or _cfg().laneDefault)
end

function UI.AnnounceInit()
    return UI.Toast("Cura Equi initialized", 1800, 0, "CuraEqui_Init", _cfg().laneDefault)
end
