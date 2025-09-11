CuraEqui.UI = CuraEqui.UI or {}

local function _hud() return "hud" end

local function _call(func, ...)
    if not (UIAction and UIAction.CallFunction) then return false end
    return pcall(UIAction.CallFunction, _hud(), -1, func, ...)
end

function CuraEqui.UI.SendInfoText(text, ms, forceClear, category)
    if not (Game and Game.SendInfoText) then return false end
    local durSec = (tonumber(ms) or 1800) / 1000.0
    local ok = pcall(Game.SendInfoText, tostring(text or ""), forceClear or false, category or 0, durSec)
    return ok and true or false
end

-- Center-lane notification (big, fades)
function CuraEqui.UI.SendNotification(text)
    text = tostring(text or "")
    local ok = _call("ShowNotification", text)
    if not ok then System.LogAlways(("[CuraEqui][UI] %s(-1).ShowNotification fail"):format(_hud())) end
    return ok
end

-- Tiny right-corner tutorial/toast lane
-- HUD.ShowTutorial(Id, Text, DurationMS, InDialogue, Priority, Layout, ActionHintEnable, OverlayLink)
function CuraEqui.UI.SendTutorial(text, ms, prio, id)
    local Id   = id or "CuraEqui_Toast"
    local Dur  = math.max(1, tonumber(ms or 0) or 0)
    local Prio = tonumber(prio or 0) or 0
    text       = tostring(text or "")
    local ok   = _call("ShowTutorial", Id, text, Dur, false, Prio, 0, false, "")
    if not ok then System.LogAlways(("[CuraEqui][UI] %s(-1).ShowTutorial fail"):format(_hud())) end
    return ok
end

local _lastText, _lastAt = nil, 0
local function _dedupe(text)
    local now = (System.GetCurrTime and System.GetCurrTime() * 1000) or (os.clock() * 1000)
    if text == _lastText and (now - _lastAt) < 800 then return true end
    _lastText, _lastAt = text, now
    return false
end

-- Convenience: choose lane; fall back to the other; then to log.
-- Unified toast with lane preference + de-dupe
function CuraEqui.UI.Toast(text, ms, prio, id, lane)
    text = tostring(text or "")
    if _dedupe(text) then return true end

    local which = lane or "tutorial" -- "infotext" | "tutorial" | "notification"

    -- primary
    if which == "infotext" and CuraEqui.UI.SendInfoText(text, ms) then return true end
    if which == "tutorial" and CuraEqui.UI.SendTutorial(text, ms, prio, id) then return true end
    if which == "notification" and CuraEqui.UI.SendNotification(text) then return true end

    -- fallbacks (don’t worry, dedupe still guards)
    if which ~= "infotext" and CuraEqui.UI.SendInfoText(text, ms) then return true end
    if which ~= "tutorial" and CuraEqui.UI.SendTutorial(text, ms, prio, id) then return true end
    if which ~= "notification" and CuraEqui.UI.SendNotification(text) then return true end

    System.LogAlways("[CuraEqui][UI] " .. text)
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
