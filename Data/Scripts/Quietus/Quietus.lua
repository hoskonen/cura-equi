-- Scripts/Quietus/Quietus.lua
-- Namespace + tiny logging helper (shared)
Quietus = Quietus or {}
if Quietus.DEBUG == nil then Quietus.DEBUG = true end

function Quietus.Log(tag, fmt, ...)
    if Quietus.DEBUG then
        System.LogAlways(("[Quietus]%s %s"):format(tag and ("[" .. tag .. "]") or "", fmt:format(...)))
    end
end
