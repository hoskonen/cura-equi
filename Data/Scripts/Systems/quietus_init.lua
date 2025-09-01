-- Scripts/Quietus/quietus_init.lua
Quietus = Quietus or {}
Quietus.DEBUG = true -- flip off later

local function Q(fmt, ...)
    if Quietus.DEBUG then System.LogAlways(("[Quietus] " .. fmt):format(...)) end
end

Q("init")

-- Load modules
Script.ReloadScript("Scripts/Quietus/Quietus.lua")
Script.ReloadScript("Scripts/Quietus/BasicAIActions_Patch.lua")

-- Also hook gameplay start to retry later (many core scripts load around then)
UIAction.RegisterEventSystemListener(Quietus, "System", "OnGameplayStarted", "OnGameplayStarted")

function Quietus.OnGameplayStarted()
    if Quietus.BasicAIActions_StartPatchLoop then
        Q("OnGameplayStarted → (re)starting patch loop")
        Quietus.BasicAIActions_StartPatchLoop(true) -- signal “late stage” start
    end
end
