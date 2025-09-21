-- Scripts/CuraEqui/Debug.lua
CuraEqui.Debug = CuraEqui.Debug or {}
-- Enable/disable distance milestone logs and set step size (meters).
CuraEqui.DEBUG_DISTANCE = CuraEqui.DEBUG_DISTANCE or false
function CuraEqui.Debug_EnableDistanceTrace(enabled, stepMeters)
    CuraEqui.DEBUG_DISTANCE = (enabled ~= false)
    CuraEqui.DEBUG_DISTANCE_STEP = tonumber(stepMeters) or CuraEqui.DEBUG_DISTANCE_STEP or 100.0
    if CuraEqui.Config and CuraEqui.Config.Debug then
        CuraEqui.Config.Debug.distanceTrace      = CuraEqui.DEBUG_DISTANCE
        CuraEqui.Config.Debug.distanceTraceStepM = CuraEqui.DEBUG_DISTANCE_STEP
    end
    for _, S in pairs(CuraEqui.HorseState or {}) do
        local step      = CuraEqui.DEBUG_DISTANCE and CuraEqui.DEBUG_DISTANCE_STEP or math.huge
        local base      = (S.totalDist or 0)
        S._dbgNextLogAt = base + step
        S.__dbgSamples  = 10 -- also reset short sampler window
    end
    System.LogAlways(("[CuraEqui][Debug] distance trace %s (step=%.0fm)")
        :format(CuraEqui.DEBUG_DISTANCE and "ON" or "OFF", CuraEqui.DEBUG_DISTANCE_STEP))
end

-- Snapshot ping
function CuraEqui.Debug_PingTick()
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    local S = h and CuraEqui.HorseState[h.id] or nil
    System.LogAlways(("[CuraEqui][Debug] tick ping: horse=%s hunger=%s dist=%.1fm total=%.1fm")
        :format(tostring(h and (h.GetName and h:GetName() or "Horse") or "nil"),
            tostring(S and S.hunger or "nil"),
            tonumber(S and S.dist or 0.0),
            tonumber(S and S.totalDist or 0.0)))
end

-- Central HUD emitter: respects Config.Debug.hud.{lane,refresh,id}
CuraEqui.Debug = CuraEqui.Debug or {}
function CuraEqui.Debug.ShowHUDLine(text, ms, lane, prio, id)
    local t   = tostring(text or "")
    local H   = (CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hud) or {}
    local dur = math.max(1, tonumber(ms or H.refresh or 1200) or 1200)
    local ln  = lane or H.lane or "notification" -- "notification" | "tutorial" | "infotext"
    local tag = tostring(id or H.id or "CuraEqui_DebugHUD")
    local pr  = tonumber(prio or 0) or 0

    -- Special: engine center text
    if ln == "infotext" and Game and Game.SendInfoText then
        pcall(Game.SendInfoText, t, false, tag, dur)
        return true
    end

    -- Preferred: Scaleform lanes via our UI shim
    if CuraEqui.UI and CuraEqui.UI.Toast then
        local ok = pcall(function() CuraEqui.UI.Toast(t, dur, pr, tag, ln) end)
        if ok then return true end
    end

    -- Fallback: engine info text
    if Game and Game.SendInfoText then
        pcall(Game.SendInfoText, t, false, tag, dur)
        return true
    end

    System.LogAlways("[CuraEqui][HUD] " .. t)
    return false
end

function CuraEqui.Debug.SetHorseHunger(n)
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve(); if not h then return end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h); if not S then return end
    S.hunger = math.max(0, math.min(100, tonumber(n) or 0))
    System.LogAlways("[CuraEqui][DBG] hunger set to " .. tostring(S.hunger))
end

function CuraEqui.Debug.SetSated(sec)
    local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve(); if not h then return end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h); if not S then return end
    local now = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local add = math.max(0, tonumber(sec) or 0)
    S.satedUntil = now + add
    System.LogAlways("[CuraEqui][DBG] sated set to +" .. tostring(add) .. "s")
end

function CuraEqui.Debug.DietBind(key, nutrition)
    local D = CuraEqui.Diet or {}; if not D then return end
    nutrition = tonumber(nutrition) or 10
    key = tostring(key or "")
    if key:find("%-") then
        -- looks like a GUID
        D.byGuid[key] = D.byGuid[key] or { token = "dev" }
        D.byGuid[key].nutrition = nutrition
        System.LogAlways(("[CuraEqui][Diet][DEV] bind GUID %s → %d"):format(key, nutrition))
    else
        local token = string.lower(key)
        D.byToken[token] = D.byToken[token] or { guid = nil }
        D.byToken[token].nutrition = nutrition
        System.LogAlways(("[CuraEqui][Diet][DEV] bind token %s → %d"):format(token, nutrition))
    end
end

function CuraEqui.Debug.DietLookup(entOrKey)
    local D = CuraEqui.Diet or {}; if not D then return end
    if type(entOrKey) == "userdata" then
        local diet = pcall and (CE_ResolveDiet and CE_ResolveDiet(entOrKey))
        System.LogAlways("[CuraEqui][Diet] resolve → " ..
            tostring(diet and
                (diet.source .. " " .. (diet.token or "?") .. " " .. (diet.guid or "-") .. " n=" .. diet.nutrition) or
                "nil"))
    else
        local key = tostring(entOrKey or "")
        local row = D.byGuid[key] or D.byToken[string.lower(key)]
        if row then
            System.LogAlways(("[CuraEqui][Diet] lookup %s → n=%s"):format(key, tostring(row.nutrition)))
        else
            System.LogAlways(("[CuraEqui][Diet] lookup %s → nil"):format(key))
        end
    end
end

function CuraEqui.Debug_EnableHungerTrace(enabled, everyNTicks)
    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    D.hungerTrace = (enabled ~= false)
    D.hungerTraceEvery = tonumber(everyNTicks) or D.hungerTraceEvery or 1
    -- reset per-horse counters so schedules align immediately
    for _, S in pairs(CuraEqui.HorseState or {}) do
        S._dbgHungerTick = 0
    end
    System.LogAlways(("[CuraEqui][Debug] hunger trace %s (every=%d ticks)")
        :format(D.hungerTrace and "ON" or "OFF", D.hungerTraceEvery or 1))
end

-- ==== CuraEqui: Horse debugging stats ======================================
CuraEqui.Debug = CuraEqui.Debug or {}

local function _now()
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end
local function _log(fmt, ...) System.LogAlways(("[CuraEqui][Debug] " .. fmt):format(...)) end

local function _horse()
    return CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
end
local function _state(h)
    return CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or {}
end

local function _soul(h)
    if not h then return nil end
    if h.soul then return h.soul end
    local ok, st = pcall(function() return h.GetScriptTable and h:GetScriptTable() end)
    if ok and st and st.soul then return st.soul end
    ok, st = pcall(function() return h.GetAI and h:GetAI() end)
    if ok and st and st.soul then return st.soul end
    ok, st = pcall(function() return h.GetSoul and h:GetSoul() end)
    if ok and st then return st end
    return nil
end

local function _get_state(soul, name)
    if not (soul and soul.GetState) then return nil end
    local ok, val = pcall(function() return soul:GetState(name) end)
    return ok and val or nil
end
local function _get_level(soul, name)
    if not (soul and soul.GetStatLevel) then return nil end
    local ok, val = pcall(function() return soul:GetStatLevel(name) end)
    return ok and val or nil
end

-- pretty tier name via your Buffs helper (falls back safely)
local function _tier_name(hunger, satedUntil)
    if CuraEqui.Buffs and CuraEqui.Buffs._pickTierName then
        return CuraEqui.Buffs._pickTierName(hunger, satedUntil)
    end
    return "?"
end

-- Public: dump a compact snapshot to console
function CuraEqui.Debug.DumpHorseSoul()
    local h = _horse()
    if not h then
        _log("No horse entity found."); return false
    end
    local S = _state(h)
    local now = _now()
    local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
    local hunger = math.floor(tonumber(S.hunger or 0) or 0)
    local tier = _tier_name(hunger, S.satedUntil)

    _log("Horse: hunger=%d%% tier=%s sated=%.0fs", hunger, tostring(tier), rem)

    local soul = _soul(h)
    if not soul then
        _log("No soul on horse."); return true
    end

    -- States
    local st_health  = _get_state(soul, "health")
    local st_stamina = _get_state(soul, "stamina")
    local st_courage = _get_state(soul, "courage") -- may be nil if not exposed

    -- Levels (base stats)
    local lv         = {
        str = _get_level(soul, "str"),
        agi = _get_level(soul, "agi"),
        spc = _get_level(soul, "spc"),
        vit = _get_level(soul, "vit"),
        hea = _get_level(soul, "hea"),
        bar = _get_level(soul, "bar"),
    }

    -- Print only what exists
    if st_health ~= nil then _log(" state.health  = %.3f", st_health) end
    if st_stamina ~= nil then _log(" state.stamina = %.3f", st_stamina) end
    if st_courage ~= nil then _log(" state.courage = %.3f", st_courage) end

    local line = {}
    for k, v in pairs(lv) do if v ~= nil then line[#line + 1] = k .. "=" .. string.format("%.3f", v) end end
    if #line > 0 then _log(" levels: %s", table.concat(line, "  ")) end

    return true
end

-- Console command convenience
if System and System.AddCCommand then
    System.AddCCommand("curaequi_dump_horse", "CuraEqui.Debug.DumpHorseSoul()", "Dump horse hunger/tier and soul stats")
end

-- Optional: right-corner dev toast (throttled) — enable via Debug.hudStats.enabled = true
do
    local function _throttle(key, sec)
        CuraEqui._dbgTh = CuraEqui._dbgTh or {}
        local t = CuraEqui._dbgTh
        local now = _now()
        local nextAt = t[key] or 0
        if now < nextAt then return false end
        t[key] = now + (sec or 5)
        return true
    end

    function CuraEqui.Debug.HUDStatsToast()
        local DH = CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.hudStats
        if not (DH and DH.enabled and CuraEqui.UI and CuraEqui.UI.Toast) then return end

        local h = _horse(); if not h then return end
        local S = _state(h)
        local soul = _soul(h)
        if not soul then return end

        local hunger  = math.floor(tonumber(S.hunger or 0) or 0)
        local tier    = _tier_name(hunger, S.satedUntil)
        local stam    = _get_state(soul, "stamina")
        local courage = _get_state(soul, "courage")

        local parts   = { ("Hunger %s (%d%%)"):format(tier, hunger) }
        if stam ~= nil then parts[#parts + 1] = ("Stamina %.0f"):format(stam) end
        if courage ~= nil then parts[#parts + 1] = ("Courage %.0f"):format(courage) end
        local line = table.concat(parts, " · ")

        local refreshSec = (DH.refreshSec or 10)
        if _throttle("hud-stats", refreshSec) then
            CuraEqui.UI.Toast(line, refreshSec * 1000, 0, "CuraEqui_Stats", DH.lane or "notification")
        end
    end
end

-- === Tutorial card: Horse stats ============================================
function CuraEqui.Debug.ShowHorseStatsTutorial()
    local UI = CuraEqui.UI
    if not (UI and (UI.SendTutorial or UI.Toast)) then return end

    local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h then return end
    local S    = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or {}
    local soul = (CuraEqui.Debug and CuraEqui.Debug._soul and CuraEqui.Debug._soul(h))
        or (h.soul or (h.GetScriptTable and h:GetScriptTable() and h:GetScriptTable().soul))
    -- hunger/tier/sated
    local now  = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local hval = math.floor(tonumber(S.hunger or 0) or 0)
    local rem  = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
    local tier = (CuraEqui.Buffs and CuraEqui.Buffs._pickTierName)
        and CuraEqui.Buffs._pickTierName(hval, S.satedUntil) or "?"

    -- soul states/levels (guard everything)
    local function _gs(name)
        if soul and soul.GetState then
            local ok, v = pcall(function() return soul:GetState(name) end); if ok then return v end
        end
    end
    local function _gl(name)
        if soul and soul.GetStatLevel then
            local ok, v = pcall(function() return soul:GetStatLevel(name) end); if ok then return v end
        end
    end
    local st_hp       = _gs("health")
    local st_sta      = _gs("stamina")
    local st_cour     = _gs("courage") -- may be nil
    local lv_str      = _gl("str"); local lv_agi = _gl("agi"); local lv_spc = _gl("spc")
    local lv_vit      = _gl("vit"); local lv_hea = _gl("hea"); local lv_bar = _gl("bar")

    -- build text
    local lines       = {}
    lines[#lines + 1] = string.format("Hunger: %s (%d%%)", tostring(tier), hval)
    lines[#lines + 1] = string.format("Sated: %.0fs", rem)
    if st_sta then lines[#lines + 1] = string.format("Stamina: %.0f", st_sta) end
    if st_cour then lines[#lines + 1] = string.format("Courage: %.0f", st_cour) end
    if st_hp then lines[#lines + 1] = string.format("Health: %.0f", st_hp) end

    local baseStats = {}
    if lv_str then baseStats[#baseStats + 1] = ("STR %.0f"):format(lv_str) end
    if lv_agi then baseStats[#baseStats + 1] = ("AGI %.0f"):format(lv_agi) end
    if lv_spc then baseStats[#baseStats + 1] = ("SPC %.0f"):format(lv_spc) end
    if lv_vit then baseStats[#baseStats + 1] = ("VIT %.0f"):format(lv_vit) end
    if lv_hea then baseStats[#baseStats + 1] = ("HEA %.0f"):format(lv_hea) end
    if lv_bar then baseStats[#baseStats + 1] = ("BAR %.0f"):format(lv_bar) end
    if #baseStats > 0 then lines[#lines + 1] = table.concat(baseStats, "  ") end

    local text = table.concat(lines, "\n")

    -- throttle + dedupe so it doesn’t spam
    CuraEqui._dbg = CuraEqui._dbg or {}; local gate = CuraEqui._dbg
    local nowS = now; gate.lastStatsTut = gate.lastStatsTut or 0
    if (nowS - gate.lastStatsTut) < 10 then return end
    gate.lastStatsTut = nowS

    if UI.SendTutorial then
        -- (key, text, seconds, forceClear)
        UI.SendTutorial("CuraEqui_HorseStats", text, 6, true)
    else
        UI.Toast(text, 6000, 0, "CuraEqui_Stats", "tutorial")
    end
end

if System and System.AddCCommand then
    System.AddCCommand("curaequi_stats_tutorial", "CuraEqui.Debug.ShowHorseStatsTutorial()", "Show horse stats card")
end
