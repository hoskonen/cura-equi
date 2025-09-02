-- Scripts/Quietus/HorseItemSelection_UI.lua
-- Minimal ItemSelection.gfx bridge using UIAction.CallFunction
Quietus                    = Quietus or {}; Quietus.UI = Quietus.UI or {}

Quietus.UI.ItemSelElement  = "ItemSelection"      -- .gfx element name
Quietus.UI.ItemSelInstance = "Quietus_ItemSelect" -- instance id

-- enums (if your gfx honors them)
local MODE_FILTER          = 5
local FILTER_FOOD          = 3

local function L(fmt, ...) if Quietus.DEBUG then System.LogAlways(("[Quietus][HorseUI] " .. fmt):format(...)) end end

-- Open ItemSelection with a heading; then try to set FOOD filter
-- Open ItemSelection with a heading; try multiple instance-id/activate sequences
-- Open ItemSelection with a heading; try activate + open across a few instance ids
function Quietus.UI.OpenFoodPicker(heading)
    heading = heading or "@ui_hud_feed_heading"

    local Elem = Quietus.UI.ItemSelElement or "ItemSelection"
    local instances = {
        Quietus.UI.ItemSelInstance, -- your custom id
        "",                     -- empty id (works on some builds)
        nil,                    -- nil (works on some builds)
    }

    local opened = false

    for i = 1, #instances do
        local inst = instances[i]

        -- 1) activate (XML: funcname="fc_activate")
        pcall(function()
            UIAction.CallFunction(Elem, inst, "fc_activate", true)
        end)

        -- 2) open (XML: funcname="fc_open", params: Mode:int, Heading:string)
        local ok = pcall(function()
            -- 5 = MODE_FILTER
            UIAction.CallFunction(Elem, inst, "fc_open", 5, heading)
        end)

        if ok then
            System.LogAlways(("[Quietus][HorseUI] fc_open ok (elem=%s inst=%s)"):format(tostring(Elem), tostring(inst)))
            opened = true

            -- 3) optional: set food filter if the gfx exports it
            pcall(function()
                -- 3 = FILTER_FOOD
                UIAction.CallFunction(Elem, inst, "fc_setFilter", 3)
            end)

            -- 4) optional: nudge to player tab so it doesn’t land on horse first
            pcall(function()
                UIAction.CallFunction(Elem, inst, "fc_tabNext")
            end)

            -- 5) optional: force controller hint set if supported (2=xbox, 4=ps)
            pcall(function()
                UIAction.CallFunction(Elem, inst, "fc_setInputId", 2)
            end)

            break
        else
            System.LogAlways(("[Quietus][HorseUI] fc_open failed (elem=%s inst=%s)"):format(tostring(Elem),
                tostring(inst)))
        end
    end

    if not opened then
        System.LogAlways("[Quietus][HorseUI] ItemSelection did not open via fc_open (all variants tried)")
    end
end

-- Optional helpers if your gfx supports them
function Quietus.UI.CloseItemPicker()
    UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_close")
end

function Quietus.UI.ConfirmItemPicker()
    UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_confirm")
end

-- ---------- FSCommand event stubs from ItemSelection.gfx ----------
-- Note: the XML shows events named: onOpened, onClosed, onFocusChanged, onDoubleClicked

local function _Q(fmt, ...) if Quietus and Quietus.DEBUG then System.LogAlways(("[Quietus][HorseUI] " .. fmt):format(...)) end end

-- Keep minimal but helpful logging; forward into Quietus.UI callbacks if present.
function onOpened()
    _Q("onOpened (ItemSelection.gfx)")
    if Quietus and Quietus.UI and Quietus.UI.onOpened then pcall(Quietus.UI.onOpened) end
end

function onClosed()
    _Q("onClosed (ItemSelection.gfx)")
    if Quietus and Quietus.UI and Quietus.UI.onClosed then pcall(Quietus.UI.onClosed) end
end

-- ids is often "12345" or "12345,67890" as a string
local function _parseIds(ids)
    local out = {}
    for n in tostring(ids or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
end

function onDoubleClicked(ids, clientId)
    _Q("onDoubleClicked ids=%s client=%s", tostring(ids), tostring(clientId))
    local arr = _parseIds(ids)
    if Quietus and Quietus.UI and Quietus.UI.onDoubleClicked then pcall(Quietus.UI.onDoubleClicked, arr, clientId) end
end

-- Optional: observe focus changes while navigating with controller
function onFocusChanged(ids, isExpandable, isExpand, clientId)
    _Q("onFocusChanged ids=%s expandable=%s expand=%s client=%s", tostring(ids), tostring(isExpandable),
        tostring(isExpand), tostring(clientId))
    if Quietus and Quietus.UI and Quietus.UI.onFocusChanged then
        pcall(Quietus.UI.onFocusChanged, ids, isExpandable,
            isExpand, clientId)
    end
end

-- ---------- Session helpers (who opened the picker) ----------
Quietus.UI.Active = Quietus.UI.Active or { horseId = nil, userId = nil }

function Quietus.UI.BeginSession(horseId, userId)
    Quietus.UI.Active.horseId = horseId
    Quietus.UI.Active.userId  = userId
end

function Quietus.UI.EndSession()
    Quietus.UI.Active.horseId, Quietus.UI.Active.userId = nil, nil
end

-- Forwarded callbacks from the FSCommand stubs above
function Quietus.UI.onOpened()
    -- You can poke the UI further here (e.g., set controller input id) if your .gfx exposes it:
    -- UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_setInputId", 2) -- 2=xbox, 4=ps (if present)
end

function Quietus.UI.onClosed()
    -- clear our per-horse guard if we set one:
    if Quietus.__uiOpenByHorse and Quietus.UI.Active.horseId then
        Quietus.__uiOpenByHorse[Quietus.UI.Active.horseId] = nil
    end
    Quietus.UI.EndSession()
end

function Quietus.UI.onDoubleClicked(idArray, clientId)
    -- For now: just log what the movie gave us. Later, we can consume one or more ids.
    System.LogAlways(("[Quietus][HorseUI] picked %d id(s)"):format(#idArray))
end
