-- Scripts/CuraEqui/CuraEqui_init.lua
CuraEqui = CuraEqui or {}
CuraEqui.DEBUG = true

local function Q(fmt, ...) if CuraEqui.DEBUG then System.LogAlways(("[CuraEqui] " .. fmt):format(...)) end end
Q("init")

-- Config first (Core reads it)
Script.ReloadScript("Scripts/CuraEqui/Presets.lua")
Script.ReloadScript("Scripts/CuraEqui/Config.lua")
Script.ReloadScript("Scripts/CuraEqui/Audio.lua")
Script.ReloadScript("Scripts/CuraEqui/DietData.lua")
Script.ReloadScript("Scripts/CuraEqui/HorseOwnership.lua")
Script.ReloadScript("Scripts/CuraEqui/Persist.lua")
Script.ReloadScript("Scripts/CuraEqui/Core.lua")

-- Foundation
Script.ReloadScript("Scripts/CuraEqui/Utils.lua")
Script.ReloadScript("Scripts/CuraEqui/Debug.lua")

-- UI bridge (optional earlier if you want toasts available everywhere)
Script.ReloadScript("Scripts/CuraEqui/UiStubs.lua")

-- NEW: effects bridge + buff logic (must be before Hunger)
Script.ReloadScript("Scripts/CuraEqui/Effects.lua")
Script.ReloadScript("Scripts/CuraEqui/BuffLogic.lua")

-- Game-facing modules
Script.ReloadScript("Scripts/CuraEqui/Horse.lua")
Script.ReloadScript("Scripts/CuraEqui/Feeding.lua")
Script.ReloadScript("Scripts/CuraEqui/Hunger.lua")

-- CuraEqui_init.lua (after loading Config & Core)
if CuraEqui.ValidateBuffGuids then CuraEqui.ValidateBuffGuids() end
