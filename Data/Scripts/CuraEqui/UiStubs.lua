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

-- ── config helpers ──────────────────────────────────────────────────────────
local function _cfg()
    local D        = (CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud) or {}
    local CU       = (CuraEqui.Config and CuraEqui.Config.UI) or {}

    -- prefer an explicit UI.toastSec; else try to auto-convert legacy ms 'refresh'
    local toastSec = tonumber(CU.toastSec)
    if not toastSec then
        local r = tonumber(D.refresh)
        if r then toastSec = (r > 60) and (r / 1000) or r end
    end
    toastSec = toastSec or 3

    return {
        enabled                = (D.enabled ~= false),
        laneDefault            = D.lane or "notification",
        defaultTimeoutS        = toastSec,
        defaultPriority        = 0,
        hudElement             = CU.hudElement or "HUD",
        fallbackToNotification = (CU.fallbackToNotification ~= false),
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
local function _sendTutorial(text, s, prio, id)
    text       = tostring(text or "")
    local Id   = tostring(id or _cfg().tagId)
    local Ssec = tonumber(s or _cfg().defaultTimeoutS) or 3 -- seconds
    local Dur  = math.max(100, math.floor(Ssec * 1000))     -- ms (min 100ms)
    local Prio = tonumber(prio or _cfg().defaultPriority) or 0
    return _call("ShowTutorial", Id, text, Dur, false, Prio, 0, false, "")
end

-- ── public API ──────────────────────────────────────────────────────────────
-- Toast(text, s, prio, id, lane) → true/false
function CuraEqui.UI.Toast(text, ms, prio, id, lane)
    text = tostring(text or "")
    if _dedupe(text) then return true end

    local which = (lane == "center" or lane == "info" or lane == "infotext") and "infotext"
        or (lane or "tutorial")

    -- primary
    if which == "infotext" and CuraEqui.UI.SendInfoText(text, ms, true) then return true end
    if which == "tutorial" and CuraEqui.UI.SendTutorial(text, ms, prio, id) then return true end
    if which == "notification" and CuraEqui.UI.SendNotification(text) then return true end

    -- fallbacks
    if which ~= "infotext" and CuraEqui.UI.SendInfoText(text, ms, true) then return true end
    if which ~= "tutorial" and CuraEqui.UI.SendTutorial(text, ms, prio, id) then return true end
    if which ~= "notification" and CuraEqui.UI.SendNotification(text) then return true end

    System.LogAlways("[CuraEqui][UI] " .. text)
end

function CuraEqui.UI.SendInfoText(text, ms, forceClear, category)
    if not (Game and Game.SendInfoText) then return false end
    local durSec = (tonumber(ms) or 1800) / 1000.0 -- ms → seconds
    local clear  = (forceClear ~= false)           -- default: true
    local ok     = pcall(Game.SendInfoText, tostring(text or ""), clear, category or 0, durSec)
    return ok and true or false
end

-- Convenience testers (optional)
function UI.DebugToast(text, lane)
    return UI.Toast(text or "CuraEqui toast test", _cfg().defaultTimeoutS, 0, "CuraEqui_Debug",
        lane or _cfg().laneDefault)
end

function UI.AnnounceInit()
    return UI.Toast("Cura Equi initialized", 1800, 0, "CuraEqui_Init", _cfg().laneDefault)
end

-- Open inventory using the Actor API:
--   Actor:OpenInventory(entityId, mode, otherInventoryId, filter)
-- We try Human first, then Actor, and probe a couple of common modes.
function CuraEqui.UI.OpenInventoryActorAPI()
    local function openWith(actor, entityId, mode, otherId, filter)
        return pcall(function()
            return actor:OpenInventory(entityId, mode, otherId, filter)
        end)
    end

    local actor = (player and (player.human or player.actor)) or nil
    local pid   = player and player.id
    if not (actor and pid) then
        System.LogAlways("[CuraEqui][UI] OpenInventoryActorAPI: no player/actor")
        return false
    end

    -- Heuristics:
    --  - mode 0: "default" (most builds)
    --  - mode 1: alternate view (seen in some mods)
    --  - otherInventoryId: 0 (none) for “just player inventory”
    --  - filter: nil (no filter)
    local modesToTry = { 0, 1 }
    for i = 1, #modesToTry do
        local m = modesToTry[i]
        local ok, res = openWith(actor, pid, m, 0, nil)
        if ok then
            System.LogAlways(("[CuraEqui][UI] Actor:OpenInventory(pid=%s, mode=%d) → ok"):format(tostring(pid), m))
            return true
        end
    end

    -- As a last resort, try with a permissive filter (some builds expect it)
    local ok, res = openWith(actor, pid, 0, 0, "*.*.*")
    if ok then
        System.LogAlways("[CuraEqui][UI] Actor:OpenInventory(..., mode=0, filter='*.*.*') → ok")
        return true
    end

    System.LogAlways("[CuraEqui][UI] OpenInventoryActorAPI: all attempts failed")
    return false
end
