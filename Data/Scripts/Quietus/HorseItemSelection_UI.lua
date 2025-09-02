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
function Quietus.UI.OpenFoodPicker(heading)
    heading = heading or "@quietus_feed_heading"
    UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_open", MODE_FILTER, heading)
    -- If the gfx exposes filter setters, one of these will work; harmless if not present:
    UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_setFilter", FILTER_FOOD)
    -- UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "SetFilter", FILTER_FOOD)
    -- UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "SetFilters", tostring(FILTER_FOOD))
    L("Opened ItemSelection (heading=%s)", tostring(heading))
end

-- Optional helpers if your gfx supports them
function Quietus.UI.CloseItemPicker()
    UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_close")
end

function Quietus.UI.ConfirmItemPicker()
    UIAction.CallFunction(Quietus.UI.ItemSelElement, Quietus.UI.ItemSelInstance, "fc_confirm")
end
