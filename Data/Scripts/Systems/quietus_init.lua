-- Scripts/Quietus/quietus_init.lua
Quietus = Quietus or {}
Quietus.DEBUG = true -- flip false for release

local function Q(fmt, ...) if Quietus.DEBUG then System.LogAlways(("[Quietus] " .. fmt):format(...)) end end
Q("init")

-- Load modules (order matters)
Script.ReloadScript("Scripts/Quietus/Quietus.lua")
Script.ReloadScript("Scripts/Quietus/HorseItemSelection_UI.lua")
Script.ReloadScript("Scripts/Quietus/HorseFeed_Patch.lua")

-- optional: late hooks if you want
UIAction.RegisterEventSystemListener(Quietus, "System", "OnGameplayStarted", "OnGameplayStarted")
function Quietus.OnGameplayStarted()
    Q("OnGameplayStarted")
    -- if you later add other patch loops, kick them here
end
