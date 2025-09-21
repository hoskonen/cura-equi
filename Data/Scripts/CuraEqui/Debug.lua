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

local function _horse()
    return CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
end
local function _state(h)
    return CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or {}
end

local function _get_state(soul, name)
    if not (soul and soul.GetState) then return nil end
    local ok, val = pcall(function() return soul:GetState(name) end)
    return ok and val or nil
end

-- pretty tier name via your Buffs helper (falls back safely)
local function _tier_name(hunger, satedUntil)
    if CuraEqui.Buffs and CuraEqui.Buffs._pickTierName then
        return CuraEqui.Buffs._pickTierName(hunger, satedUntil)
    end
    return "?"
end

-- Common soul helpers
local function _soul(h)
    if not h then return nil end
    if h.soul then return h.soul end
    local ok, st = pcall(function() return h.GetScriptTable and h:GetScriptTable() end)
    if ok and st and st.soul then return st.soul end
    ok, st = pcall(function() return h.GetSoul and h:GetSoul() end)
    if ok and st then return st end
    return nil
end

local function _gs(soul, key)
    if not (soul and soul.GetState) then return nil end
    local ok, v = pcall(function() return soul:GetState(key) end)
    return ok and v or nil
end

local function _gl(soul, key)
    if not (soul and soul.GetStatLevel) then return nil end
    local ok, v = pcall(function() return soul:GetStatLevel(key) end)
    return ok and v or nil
end

local function _gd(soul, key, ctx)
    if not (soul and soul.GetDerivedStat) then return nil end
    local ok, v = pcall(function() return soul:GetDerivedStat(key, ctx or {}, nil) end)
    return ok and v or nil
end

-- === Console dump: compact horse stats =====================================
function CuraEqui.Debug.DumpHorseStats(h)
    h = h or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h then
        System.LogAlways("[CuraEqui][HorseStats] No horse found."); return
    end
    local soul = h.soul or (h.GetSoul and h:GetSoul()) or nil
    if not soul then
        System.LogAlways("[CuraEqui][HorseStats] No soul on horse."); return
    end

    -- Core states
    local hp = (soul.GetState and soul:GetState("health")) or nil

    -- Stamina (cur/max)
    local stamCur, stamMax
    if CuraEqui.Debug and CuraEqui.Debug.ReadHorseStamina then
        stamCur, stamMax = CuraEqui.Debug.ReadHorseStamina(h)
    else
        stamCur = (soul.GetState and soul:GetState("stamina")) or nil
    end

    -- Courage & capacity & morale limit
    local courage = (CuraEqui.Debug.ReadHorseCourage and select(1, CuraEqui.Debug.ReadHorseCourage(h))) or nil
    local cap     = (CuraEqui.Debug.ReadHorseCapacity and select(1, CuraEqui.Debug.ReadHorseCapacity(h))) or nil
    local hml     = (CuraEqui.Debug.ReadHorseMoraleLimit and CuraEqui.Debug.ReadHorseMoraleLimit(h)) or nil

    local preset  = (CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.preset) or "custom"

    local parts   = {}
    if hp ~= nil then parts[#parts + 1] = ("HP=%d"):format(math.floor(hp + 0.5)) end
    if stamCur ~= nil then
        if stamMax and stamMax > 0 then
            parts[#parts + 1] = ("STA=%d/%d"):format(math.floor(stamCur + 0.5), math.floor(stamMax + 0.5))
        else
            parts[#parts + 1] = ("STA=%d"):format(math.floor(stamCur + 0.5))
        end
    end
    if courage ~= nil then parts[#parts + 1] = ("COU=%d"):format(math.floor(courage + 0.5)) end
    if cap ~= nil then parts[#parts + 1] = ("CAP=%.1f"):format(cap) end
    if hml ~= nil then parts[#parts + 1] = ("HML=%.1f"):format(hml) end
    parts[#parts + 1] = ("preset=%s"):format(preset)

    System.LogAlways("[CuraEqui][HorseStats] " .. table.concat(parts, " | "))
end

-- Console binding (once)
if System and System.AddCCommand then
    System.AddCCommand("curaequi_horse_stats", "CuraEqui.Debug.DumpHorseStats()", "Dump current horse stats")
end

function CuraEqui.Debug.ReadHorseCourage(h)
    h = h or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
    local s = _soul(h); if not s then return nil, nil end
    -- try state first (Stat_Courage), then levels
    local v, src = _gs(s, "courage"), "state:courage"
    if v == nil then v, src = _gl(s, "courage"), "level:courage" end
    if v == nil then v, src = _gl(s, "cou"), "level:cou" end
    return v, src
end

function CuraEqui.Debug.ReadHorseCapacity(h)
    h = h or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
    local s = _soul(h); if not s then return nil, nil end
    -- DerivStat_InventoryCapacity → "cap"
    local cap = _gd(s, "cap", {}) -- context empty unless your build needs it
    return cap, "derived:cap"
end

function CuraEqui.Debug.ReadHorseMoraleLimit(h)
    h = h or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
    local s = (h and (h.soul or (h.GetSoul and h:GetSoul()))) or nil
    if not (s and s.GetDerivedStat) then return nil end
    local ok, v = pcall(function() return s:GetDerivedStat("hml", {}, nil) end)
    return ok and v or nil
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

-- === Tutorial card: Horse Status (left lane) ================================
function CuraEqui.Debug.ShowHorseStatsTutorial()
    local UI = CuraEqui.UI; if not (UI and UI.Toast) then return end

    local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h then return end
    local S                = (CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h)) or {}

    -- Preset + hunger/sated
    local preset           = (CuraEqui.Config and CuraEqui.Config.Hunger and CuraEqui.Config.Hunger.preset) or "custom"
    local now              = (Script and Script.GetTime and Script.GetTime()) or os.clock()
    local hval             = math.floor(tonumber(S.hunger or 0) or 0)
    local rem              = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

    -- Reads
    local stamCur, stamMax = nil, nil
    if CuraEqui.Debug and CuraEqui.Debug.ReadHorseStamina then
        stamCur, stamMax = CuraEqui.Debug.ReadHorseStamina(h)
    end
    local capMax      = (CuraEqui.Debug.ReadHorseCapacity and select(1, CuraEqui.Debug.ReadHorseCapacity(h))) or nil

    local soul        = (h and (h.soul or (h.GetSoul and h:GetSoul()))) or nil
    local hp          = (soul and soul.GetState and soul:GetState("health")) or nil
    local courage     = (CuraEqui.Debug.ReadHorseCourage and select(1, CuraEqui.Debug.ReadHorseCourage(h))) or nil

    -- Build once
    local lines       = {}
    lines[#lines + 1] = "Horse Status"
    lines[#lines + 1] = ("Preset: %s"):format(preset)
    lines[#lines + 1] = ("Hunger: %d%%"):format(hval)
    lines[#lines + 1] = ("Sated: %.0fs"):format(rem)
    if hp then lines[#lines + 1] = ("Health: %d"):format(math.floor(hp + 0.5)) end
    if stamCur then
        if stamMax and stamMax > 0 then
            lines[#lines + 1] = ("Stamina: %d / %d"):format(math.floor(stamCur + 0.5), math.floor(stamMax + 0.5))
        else
            lines[#lines + 1] = ("Stamina: %d"):format(math.floor(stamCur + 0.5))
        end
    end
    if capMax then lines[#lines + 1] = ("Capacity: %.1f"):format(capMax) end
    if courage then lines[#lines + 1] = ("Courage: %d"):format(math.floor(courage + 0.5)) end

    local body = table.concat(lines, "\n")
    if body == "" then return end

    CuraEqui._dbg = CuraEqui._dbg or {}
    local last = CuraEqui._dbg.lastStatsTut or 0
    if (now - last) < 10 then return end
    CuraEqui._dbg.lastStatsTut = now

    UI.Toast(body, 12000, 0, "CuraEqui_HorseStats", "tutorial")
end

if System and System.AddCCommand then
    System.AddCCommand("curaequi_stats_tutorial", "CuraEqui.Debug.ShowHorseStatsTutorial()", "Show horse stats card")
end

-- Robust stamina reader: returns cur, max, srcTag
function CuraEqui.Debug.ReadHorseStamina(h)
    h = h or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve())
    if not h then return nil end

    -- soul
    local s = (h.soul or (h.GetSoul and h:GetSoul())) or nil
    if not s or not s.GetState then return nil end

    local function GS(key)
        local ok, v = pcall(function() return s:GetState(key) end)
        return ok and v or nil
    end

    -- current stamina probe
    local cur = GS("stamina") or GS("endurance") or GS("stam")

    -- explicit max (if engine exposes any of these)
    local max = GS("stamina_max") or GS("max_stamina") or GS("staminaMax") or GS("endurance_max")

    -- fallback: session snapshot + learn-up
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or {}
    S._snap = S._snap or {}

    -- learn-up: if we see a larger current than our snap, elevate the snap
    if cur and (not max) then
        if (not S._snap.staminaMax) or (cur > S._snap.staminaMax) then
            S._snap.staminaMax = cur
        end
        max = S._snap.staminaMax
    end

    local src = (max and "state:max") or (S._snap.staminaMax and "snap:max") or nil
    return cur, max, src
end

if System and System.AddCCommand then
    System.AddCCommand("curaequi_snap_stamina", [[
    (function()
      local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
      if not h then System.LogAlways("[CuraEqui] no horse"); return end
      local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h)
      if not S then return end
      local cur = CuraEqui.Debug and CuraEqui.Debug.ReadHorseStamina and select(1, CuraEqui.Debug.ReadHorseStamina(h))
      if cur then
        S._snap = S._snap or {}; S._snap.staminaMax = cur
        System.LogAlways(("[CuraEqui] stamina snap set to %d"):format(math.floor(cur+0.5)))
      end
    end)()
  ]], "Snapshot current stamina as max")
end

-- ==== CuraEqui Debug Cheats: Hunger & Sated ================================
CuraEqui.Debug = CuraEqui.Debug or {}

local function _now()
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end

local function _horse_and_state()
    local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h then return nil, nil end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
    return h, S
end

local function _sync(h, S)
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then
        pcall(CuraEqui.Buffs.SyncAll, h, S)
    end
end

local function _toast(msg)
    if CuraEqui.UI and CuraEqui.UI.Toast then
        CuraEqui.UI.Toast(msg, 2000, 0, "CuraEqui_Debug", "notification")
    end
    System.LogAlways("[CuraEqui][Cheat] " .. msg)
end

-- Set absolute hunger percent [0..100]
function CuraEqui.Debug.SetHunger(p)
    local h, S = _horse_and_state(); if not (h and S) then
        _toast("No horse."); return
    end
    local v = math.max(0, math.min(100, tonumber(p) or 0))
    S.hunger = v
    -- clearing sated if you're forcing hunger up is typically desired (optional):
    -- if v >= (S.hunger or 0) then S.satedUntil = 0 end
    _sync(h, S)
    _toast(("Hunger set to %d%%"):format(math.floor(v + 0.5)))
end

-- Add (or subtract) delta hunger points; clamps to [0..100]
function CuraEqui.Debug.AddHunger(d)
    local h, S = _horse_and_state(); if not (h and S) then
        _toast("No horse."); return
    end
    local cur = math.floor(tonumber(S.hunger or 0) or 0)
    local v = math.max(0, math.min(100, cur + (tonumber(d) or 0)))
    S.hunger = v
    _sync(h, S)
    _toast(("Hunger %d → %d"):format(cur, v))
end

-- Set sated seconds from now (0 to clear)
function CuraEqui.Debug.SetSated(sec)
    local h, S = _horse_and_state(); if not (h and S) then
        _toast("No horse."); return
    end
    local s = math.max(0, tonumber(sec) or 0)
    S.satedUntil = (s > 0) and (_now() + s) or 0
    _sync(h, S)
    _toast((s > 0) and ("Sated for %.0fs"):format(s) or "Sated cleared")
end

-- Clear sated quickly
function CuraEqui.Debug.ClearSated()
    return CuraEqui.Debug.SetSated(0)
end

-- Optional: force a tier name for a short window (for UI testing)
-- tier must be one of your HUD tiers ("ok","minor","moderate","critical","sated")
function CuraEqui.Debug.ForceTierForSeconds(tier, seconds)
    local h, S = _horse_and_state(); if not (h and S) then
        _toast("No horse."); return
    end
    local now = _now()
    S._debugForceTier = tostring(tier or "")
    S._debugForceUntil = now + (tonumber(seconds) or 5)
    _sync(h, S)
    _toast(("Tier forced to '%s' for %.0fs"):format(S._debugForceTier, (S._debugForceUntil - now)))
end

-- Hook: let _pickTierName honor the debug force (place once)
if CuraEqui.Buffs and CuraEqui.Buffs._pickTierName and not CuraEqui.Buffs._pickTierName__wrapped then
    local _orig = CuraEqui.Buffs._pickTierName
    CuraEqui.Buffs._pickTierName = function(hunger, satedUntil)
        local h, S = _horse_and_state()
        local now = _now()
        if S and S._debugForceTier and (tonumber(S._debugForceUntil or 0) or 0) > now then
            return S._debugForceTier
        end
        return _orig(hunger, satedUntil)
    end
    CuraEqui.Buffs._pickTierName__wrapped = true
end

if System and System.AddCCommand then
    System.AddCCommand("curaequi_set_hunger", "CuraEqui.Debug.SetHunger(%1)", "Set horse hunger percent [0..100]")
    System.AddCCommand("curaequi_add_hunger", "CuraEqui.Debug.AddHunger(%1)",
        "Add delta to horse hunger (negative allowed)")
    System.AddCCommand("curaequi_set_sated", "CuraEqui.Debug.SetSated(%1)", "Set sated seconds from now (0 clears)")
    System.AddCCommand("curaequi_clr_sated", "CuraEqui.Debug.ClearSated()", "Clear sated")
    System.AddCCommand("curaequi_force_tier", "CuraEqui.Debug.ForceTierForSeconds(%1,%2)", "Force HUD tier for N seconds")
end
