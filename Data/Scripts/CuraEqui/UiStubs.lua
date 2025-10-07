-- Scripts/CuraEqui/UiStubs.lua (clean + safe)
CuraEqui                 = CuraEqui or {}
CuraEqui.UI              = CuraEqui.UI or {}
local UI                 = CuraEqui.UI

-- ── dedupe (avoid spam) ─────────────────────────────────────────────────────
local _lastText, _lastAt = nil, 0
local function _dedupe(text)
    local nowMs = ((CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()) * 1000
    if text == _lastText and (nowMs - _lastAt) < 800 then return true end
    _lastText, _lastAt = text, nowMs
    return false
end

-- ── config helpers ──────────────────────────────────────────────────────────
local function _cfg()
    local D        = (CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud) or {}
    local CU       = (CuraEqui.Config and CuraEqui.Config.UI) or {}
    local toastSec = tonumber(CU.toastSec)
    if not toastSec then
        local r = tonumber(D.refresh)
        if r then toastSec = (r > 60) and (r / 1000) or r end -- ms→s for legacy
    end
    toastSec = toastSec or 3

    return {
        laneDefault            = (D.lane or "notification"),
        defaultTimeoutS        = toastSec,
        defaultPriority        = 0,
        hudElement             = (CU.hudElement or "HUD"),
        fallbackToNotification = (CU.fallbackToNotification ~= false),
        tagId                  = (D.id or "CuraEqui_Toast"),
    }
end

local function _hud() return _cfg().hudElement end

local function _call(func, ...)
    if not (UIAction and UIAction.CallFunction) then return false end
    return pcall(UIAction.CallFunction, _hud(), -1, func, ...)
end

-- ── lanes impl ──────────────────────────────────────────────────────────────
-- Center InfoText (Game API expects seconds)
function CuraEqui.UI.SendInfoText(text, ms, forceClear, category)
    if not (Game and Game.SendInfoText) then return false end
    local durSec = math.max(0.1, ((tonumber(ms) or (_cfg().defaultTimeoutS * 1000)) / 1000.0))
    local clear  = (forceClear ~= false)
    local ok     = pcall(Game.SendInfoText, tostring(text or ""), clear, category or 0, durSec)
    return ok and true or false
end

-- Tutorial lane (right overlay). Engine expects seconds here in our build.
-- HUD.ShowTutorial(Id, Text, DurationMS, InDialogue, Priority, Layout, ActionHintEnable, OverlayLink)
function CuraEqui.UI.SendTutorial(text, seconds, prio, id)
    text        = tostring(text or "")
    local Id    = tostring(id or _cfg().tagId)
    local Ssec  = tonumber(seconds or _cfg().defaultTimeoutS) or 3
    local DurMs = math.max(100, math.floor(Ssec * 1000))
    local Prio  = tonumber(prio or _cfg().defaultPriority) or 0
    return _call("ShowTutorial", Id, text, DurMs, false, Prio, 0, false, "")
end

-- Put near SendInfoText / SendTutorial
function CuraEqui.UI.SendNotification(text)
    if not (UIAction and UIAction.CallFunction) then return false end
    -- Most builds accept a single string arg. Guard with pcall.
    local ok = pcall(UIAction.CallFunction, _cfg().hudElement, -1, "ShowNotification", tostring(text or ""))
    return ok and true or false
end

-- ── public unified Toast ────────────────────────────────────────────────────

-- Toast(text, ms, prio, id, lane)
function CuraEqui.UI.Toast(text, ms, prio, id, lane)
    text = tostring(text or "")
    if _dedupe(text) then return true end

    -- normalize lanes
    local which =
        (lane == "center" or lane == "info" or lane == "infotext") and "infotext"
        or (lane == "notification" and "notification")
        or "tutorial"

    if which == "infotext" then
        -- center (expects seconds)
        if CuraEqui.UI.SendInfoText(text, ms, true) then return true end
        -- center failed → one fallback to tutorial
        local sec = math.max(0.1, ((tonumber(ms) or (_cfg().defaultTimeoutS * 1000)) / 1000.0))
        return CuraEqui.UI.SendTutorial(text, sec, prio, id)
    end

    if which == "notification" then
        -- try native right-corner once
        local ok = CuraEqui.UI.SendNotification and CuraEqui.UI.SendNotification(text)
        if ok then return true end
        -- native not available → single fallback to tutorial (seconds)
        local sec = math.max(0.1, ((tonumber(ms) or (_cfg().defaultTimeoutS * 1000)) / 1000.0))
        return CuraEqui.UI.SendTutorial(text, sec, prio, id)
    end

    -- tutorial (seconds)
    local sec = math.max(0.1, ((tonumber(ms) or (_cfg().defaultTimeoutS * 1000)) / 1000.0))
    if CuraEqui.UI.SendTutorial(text, sec, prio, id) then return true end

    -- last resort: center
    return CuraEqui.UI.SendInfoText(text, ms, true)
end
