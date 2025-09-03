-- Scripts/CuraEqui/CuraEqui_init.lua
CuraEqui = CuraEqui or {}
CuraEqui.DEBUG = true

local function Q(fmt, ...) if CuraEqui.DEBUG then System.LogAlways(("[CuraEqui] " .. fmt):format(...)) end end
Q("init")

Script.ReloadScript("Scripts/CuraEqui/Core.lua")
Script.ReloadScript("Scripts/CuraEqui/Utils.lua")
Script.ReloadScript("Scripts/CuraEqui/Config.lua")
Script.ReloadScript("Scripts/CuraEqui/Debug.lua")
Script.ReloadScript("Scripts/CuraEqui/Horse.lua")
Script.ReloadScript("Scripts/CuraEqui/Feeding.lua")
Script.ReloadScript("Scripts/CuraEqui/Hunger.lua")
Script.ReloadScript("Scripts/CuraEqui/UiStubs.lua")
-- Core.lua already registers event listeners and calls Initialize on gameplay start
