-- Scripts/CuraEqui/Audio.lua
CuraEqui = CuraEqui or {}
CuraEqui.Audio = CuraEqui.Audio or {}

local A = CuraEqui.Audio
local _cache = {}

local function _cfg()
    return (CuraEqui.Config and CuraEqui.Config.Audio) or {}
end

local function _log(fmt, ...)
    if CuraEqui and CuraEqui.DEBUG then
        System.LogAlways(("[CuraEqui][Audio] " .. fmt):format(...))
    end
end

-- STRICT resolver: uses only engine-exposed functions you can verify.
-- It logs the function used, return type, and value. No path mangling.
local function _resolveTriggerId_strict(name)
    if not name or name == "" then return 0 end

    -- 1) Sound.GetAudioTriggerID (you confirmed this exists)
    if Sound and type(Sound.GetAudioTriggerID) == "function" then
        local ok, v = pcall(Sound.GetAudioTriggerID, name)
        System.LogAlways(("[CuraEqui][Audio] Sound.GetAudioTriggerID(%s) -> ok=%s type=%s val=%s")
            :format(tostring(name), tostring(ok), type(v), tostring(v)))
        if ok and v and v ~= 0 then
            return v -- may be a number or an engine handle; we pass it through unchanged
        end
    else
        System.LogAlways("[CuraEqui][Audio] Sound.GetAudioTriggerID not available")
    end

    -- 2) AudioUtils.LookupTriggerID (if present in your build)
    if AudioUtils and type(AudioUtils.LookupTriggerID) == "function" then
        local ok, v = pcall(AudioUtils.LookupTriggerID, name)
        System.LogAlways(("[CuraEqui][Audio] AudioUtils.LookupTriggerID(%s) -> ok=%s type=%s val=%s")
            :format(tostring(name), tostring(ok), type(v), tostring(v)))
        if ok and v and v ~= 0 then
            return v
        end
    else
        System.LogAlways("[CuraEqui][Audio] AudioUtils.LookupTriggerID not available")
    end

    return 0
end

-- Find a usable audio proxy getter on an entity
local function _getProxyId(ent)
    if not ent then return nil end
    local getters = {
        "GetDefaultAuxAudioProxyID",
        "GetDefaultAudioProxyID",
        "GetAuxAudioProxyID",
        "GetAudioProxyID",
    }
    for _, g in ipairs(getters) do
        local fn = ent[g]
        if type(fn) == "function" then
            local ok, proxy = pcall(fn, ent)
            if ok and proxy then return proxy end
        end
    end
    return nil
end

function CuraEqui.Audio.PlayAtEntity(triggerName, ent)
    local C = (CuraEqui.Config and CuraEqui.Config.Audio) or {}
    if C.enabled == false then return false end
    if not ent then return false end

    local trigId = _resolveTriggerId_strict(triggerName)
    if not trigId or trigId == 0 then
        System.LogAlways(("[CuraEqui][Audio] trigger unresolved: %s"):format(tostring(triggerName)))
        return false
    end

    -- get proxy (no guessing: try the canonical one first, then alternate by name if present)
    local proxy = nil
    if type(ent.GetDefaultAuxAudioProxyID) == "function" then
        local ok, p = pcall(ent.GetDefaultAuxAudioProxyID, ent)
        proxy = ok and p or nil
    elseif type(ent.GetDefaultAudioProxyID) == "function" then
        local ok, p = pcall(ent.GetDefaultAudioProxyID, ent)
        proxy = ok and p or nil
    end
    System.LogAlways(("[CuraEqui][Audio] exec trig=%s id=%s proxyType=%s proxyVal=%s")
        :format(tostring(triggerName), tostring(trigId), type(proxy), tostring(proxy)))

    if type(ent.ExecuteAudioTrigger) == "function" and proxy ~= nil then
        local ok = pcall(ent.ExecuteAudioTrigger, ent, trigId, proxy)
        System.LogAlways("[CuraEqui][Audio] ExecuteAudioTrigger -> " .. tostring(ok))
        return ok and true or false
    end

    System.LogAlways("[CuraEqui][Audio] missing ExecuteAudioTrigger or proxy")
    return false
end

function A.PlayOnHorse(triggerName)
    local horse = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    return A.PlayAtEntity(triggerName, horse or g_localActor)
end

function A.PlayOnPlayer(triggerName)
    return A.PlayAtEntity(triggerName, g_localActor)
end

-- ---- Debug helpers (console) ----
function A.Debug_LogCaps(ent)
    ent = ent or g_localActor
    local has = function(m) return ent and type(ent[m]) == "function" end
    System.LogAlways(("[CuraEqui][Audio] caps: ExecuteAudioTrigger=%s, GetDefaultAuxAudioProxyID=%s, GetDefaultAudioProxyID=%s")
        :format(tostring(has("ExecuteAudioTrigger")), tostring(has("GetDefaultAuxAudioProxyID")),
            tostring(has("GetDefaultAudioProxyID"))))
end

-- lua CuraEqui.Audio.Test("a_o_horse_eating", "horse")
function A.Test(trigger, who)
    local ent = (who == "player") and g_localActor or
        (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
    ent = ent or g_localActor
    local id = _lookupTriggerId(trigger)
    local proxy = _getProxyId(ent)
    System.LogAlways(("[CuraEqui][Audio] test trig=%s id=%s ent=%s proxy=%s"):format(tostring(trigger), tostring(id),
        tostring(ent and ent.id), tostring(proxy)))
    local ok = A.PlayAtEntity(trigger, ent)
    System.LogAlways(("[CuraEqui][Audio] test result=%s"):format(tostring(ok)))
    return ok
end

-- lua CuraEqui.Audio.Debug_ResolveTrigger("a_o_horse_eating")
function CuraEqui.Audio.Debug_ResolveTrigger(name)
    System.LogAlways("=== [CuraEqui][Audio] Debug_ResolveTrigger START ===")
    System.LogAlways("Have Sound.GetAudioTriggerID? " .. tostring(Sound and type(Sound.GetAudioTriggerID) == "function"))
    System.LogAlways("Have AudioUtils.LookupTriggerID? " ..
        tostring(AudioUtils and type(AudioUtils.LookupTriggerID) == "function"))

    local id = _resolveTriggerId_strict(name)
    System.LogAlways(("[CuraEqui][Audio] RESOLVED id=%s (type=%s) for %s")
        :format(tostring(id), type(id), tostring(name)))

    local ent = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or g_localActor
    local proxy = nil
    if ent and type(ent.GetDefaultAuxAudioProxyID) == "function" then
        local ok, p = pcall(ent.GetDefaultAuxAudioProxyID, ent); proxy = ok and p or nil
    elseif ent and type(ent.GetDefaultAudioProxyID) == "function" then
        local ok, p = pcall(ent.GetDefaultAudioProxyID, ent); proxy = ok and p or nil
    end
    System.LogAlways(("[CuraEqui][Audio] entity=%s proxyType=%s proxyVal=%s")
        :format(tostring(ent and ent.id), type(proxy), tostring(proxy)))

    if id ~= 0 and ent and proxy and type(ent.ExecuteAudioTrigger) == "function" then
        local ok = pcall(ent.ExecuteAudioTrigger, ent, id, proxy)
        System.LogAlways("[CuraEqui][Audio] ExecuteAudioTrigger test -> " .. tostring(ok))
    end
    System.LogAlways("=== [CuraEqui][Audio] Debug_ResolveTrigger END ===")
end

function CuraEqui.Audio.PreloadAndPlayAtEntity(name, ent)
    if not (Sound and Sound.GetAudioTriggerID) then return false end
    local id = Sound.GetAudioTriggerID(name)
    if not id or id == 0 then return false end
    if Sound.PreloadAudioTrigger then pcall(Sound.PreloadAudioTrigger, id) end
    ent = ent or g_localActor
    if not ent then return false end
    local proxy = nil
    if type(ent.GetDefaultAuxAudioProxyID) == "function" then
        local ok, p = pcall(ent.GetDefaultAuxAudioProxyID, ent); proxy = ok and p or nil
    elseif type(ent.GetDefaultAudioProxyID) == "function" then
        local ok, p = pcall(ent.GetDefaultAudioProxyID, ent); proxy = ok and p or nil
    end
    if not proxy or type(ent.ExecuteAudioTrigger) ~= "function" then return false end
    local ok = pcall(ent.ExecuteAudioTrigger, ent, id, proxy)
    return ok and true or false
end
