-- Scripts/CuraEqui/Core.lua
CuraEqui = CuraEqui or {}
CuraEqui.VERSION = "0.1.0"
CuraEqui.DEBUG = CuraEqui.DEBUG ~= false
CuraEqui.state = CuraEqui.state or {
    hungerTimer = nil,
    pausedForSleep = false,
    started = false,
}

function CuraEqui.Log(tag, fmt, ...)
    if CuraEqui.DEBUG then
        System.LogAlways(("[CuraEqui]%s %s"):format(tag and ("[" .. tag .. "]") or "", fmt:format(...)))
    end
end

-- Event glue (register once in init file or here)
if UIAction and UIAction.RegisterEventSystemListener and not CuraEqui.__eventsBound then
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnGameplayStarted", "OnGameplayStarted")
    UIAction.RegisterEventSystemListener(CuraEqui, "System", "OnSetFaderState", "OnSetFaderState")
    CuraEqui.__eventsBound = true
end

function CuraEqui.OnGameplayStarted()
    CuraEqui.Log("init", "OnGameplayStarted")
    -- one-time init bits go here if needed
    CuraEqui.Initialize(true)
end

-- Sleep / fade handling (same idea as your UWH example)
function CuraEqui.OnSetFaderState(_actionName, eventName, argTable)
    -- argTable[1] usually "sleep" when starting sleep fade
    if eventName == "OnSetFaderState" and argTable and argTable[1] == "sleep" then
        CuraEqui.Log("poll", "Sleep starting → stopping hunger watcher")
        CuraEqui.StopWatching()
        CuraEqui.state.pausedForSleep = true
    elseif eventName == "OnHide" then
        -- UI fade finished (covers post-load and wake-up)
        CuraEqui.Log("poll", "UI resumed → ensuring hunger watcher is running")
        CuraEqui.Initialize(false)
        CuraEqui.state.pausedForSleep = false
    end
end

-- Idempotent init that (re)starts polling
function CuraEqui.Initialize(fullInit)
    if fullInit and CuraEqui.state.started then
        CuraEqui.Log("init", "Already initialized → skipping reload")
    else
        CuraEqui.state.started = true
    end
    CuraEqui.StartWatching()
end
