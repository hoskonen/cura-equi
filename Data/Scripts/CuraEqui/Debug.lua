-- Scripts/CuraEqui/Debug.lua
CuraEqui.Debug = CuraEqui.Debug or {}
-- Enable/disable distance milestone logs and set step size (meters).
CuraEqui.DEBUG_DISTANCE = CuraEqui.DEBUG_DISTANCE or false

-- Simple anim logger state
CuraEqui.AnimProbe = CuraEqui.AnimProbe or { last = {}, enabled = false }

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

function CuraEqui.Debug.DietLookup(key)
    local D = CuraEqui.Diet or {}; if not D then return end
    key = tostring(key or "")
    local row = D.byGuid[key] or D.byToken[string.lower(key)]
    if row then
        System.LogAlways(("[CuraEqui][Diet] lookup %s → n=%s source=%s token=%s guid=%s")
            :format(key, tostring(row.nutrition), tostring(row.source), tostring(row.token), tostring(row.guid)))
    else
        System.LogAlways(("[CuraEqui][Diet] lookup %s → nil"):format(key))
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
    return (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
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
    -- Speed (collect first, append later)
    local sp      = CuraEqui.Debug.ReadHorseSpeed and CuraEqui.Debug.ReadHorseSpeed(h) or nil

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

    -- Append speed AFTER parts exists
    if sp then
        if sp.pick and sp.pickSrc == "rms" then
            parts[#parts + 1] = ("SPD=%.3fx"):format(sp.pick)
        elseif sp.pick then
            parts[#parts + 1] = ("SPD=%.2f(%s)"):format(sp.pick, sp.pickSrc)
        end
    end

    parts[#parts + 1] = ("preset=%s"):format(preset)

    System.LogAlways("[CuraEqui][HorseStats] " .. table.concat(parts, " | "))
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
    local now              = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local hval             = math.floor(tonumber(S.hunger or 0) or 0)
    local rem              = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

    -- Reads
    local stamCur, stamMax = nil, nil
    if CuraEqui.Debug and CuraEqui.Debug.ReadHorseStamina then
        stamCur, stamMax = CuraEqui.Debug.ReadHorseStamina(h)
    end
    local capMax                                                                  = (CuraEqui.Debug.ReadHorseCapacity and select(1, CuraEqui.Debug.ReadHorseCapacity(h))) or
        nil
    local soul                                                                    = (h and (h.soul or (h.GetSoul and h:GetSoul()))) or
        nil
    local hp                                                                      = (soul and soul.GetState and soul:GetState("health")) or
        nil
    local courage                                                                 = (CuraEqui.Debug.ReadHorseCourage and select(1, CuraEqui.Debug.ReadHorseCourage(h))) or
        nil
    local sp                                                                      = CuraEqui.Debug.ReadHorseSpeed and
        CuraEqui.Debug.ReadHorseSpeed(h) or nil

    -- Derived: horse-related (enable/disable via Config.Debug.horseDerived)
    local showDer                                                                 = (CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.horseDerived) ~=
        false
    local dSRG, dMST, dHCM, dHML2, dNRW, dRTM, dRSB, dRMS, dMOR, dNRS, dNSB, dRSA = nil, nil, nil, nil, nil, nil, nil,
        nil, nil, nil, nil, nil
    if showDer and soul then
        dSRG = _gd(soul, "srg")  -- stamina regen
        dMST = _gd(soul, "mst")  -- stamina pool
        dHCM = _gd(soul, "hcm")  -- HorseCourageMod
        dHML2 = _gd(soul, "hml") -- ThrowDownMoraleLimit
        dNRW = _gd(soul, "nrw")  -- stamina recovery
        dRTM = _gd(soul, "rtm")  -- RiderThreatsToHorseMorale
        dRSB = _gd(soul, "rsb")  -- RunSpeedBase
        dRMS = _gd(soul, "rms")  -- RealMoveSpeedMod
        dMOR = _gd(soul, "mor")  -- Morale
        dNRS = _gd(soul, "nrs")  -- DerivStat_NormalizedRunSpeed
        dNSB = _gd(soul, "nsb")  -- DerivStat_NormalizedRunSpeedBase
        dRSA = _gd(soul, "rsa")  -- DerivStat_RelativeMovementSpeedAddition
    end

    local function fmt(x) return (x == nil) and "—" or string.format("%.3f", x) end

    -- Build once (declare BEFORE appending)
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
    if sp and sp.pick then
        if sp.pickSrc == "rms" then
            lines[#lines + 1] = ("Speed (RMS): %.3fx"):format(sp.pick)
        else
            lines[#lines + 1] = ("Speed: %.2f (%s)"):format(sp.pick, sp.pickSrc)
        end
    end

    -- Derived block (only append if values exist)
    if showDer then
        if dSRG ~= nil then lines[#lines + 1] = ("Stamina Regen: %s"):format(fmt(dSRG)) end
        if dMST ~= nil then lines[#lines + 1] = ("Stamina Pool: %s"):format(fmt(dMST)) end
        if dHCM ~= nil then lines[#lines + 1] = ("Courage Mod: %s"):format(fmt(dHCM)) end
        if dHML2 ~= nil then lines[#lines + 1] = ("Throw Down Morale Lim: %s"):format(fmt(dHML2)) end
        if dNRW ~= nil then lines[#lines + 1] = ("Stamina Recovery: %s"):format(fmt(dNRW)) end
        if dRTM ~= nil then lines[#lines + 1] = ("Rider Threat→Morale: %s"):format(fmt(dRTM)) end
        if dRSB ~= nil then lines[#lines + 1] = ("Run Speed Base (RSB): %s"):format(fmt(dRSB)) end
        if dRMS ~= nil then lines[#lines + 1] = ("Real Move Speed (RMS): %s"):format(fmt(dRMS)) end
        if dMOR ~= nil then lines[#lines + 1] = ("Morale (MOR): %s"):format(fmt(dMOR)) end
        if dNRS ~= nil then lines[#lines + 1] = ("Normalized Run Speed (NRS): %s"):format(fmt(dNRS)) end
        if dNSB ~= nil then lines[#lines + 1] = ("Normalized Run Speed Base (NSB): %s"):format(fmt(dNSB)) end
        if dRSA ~= nil then lines[#lines + 1] = ("Relative Movement Speed Addition (RSA): %s"):format(fmt(dRSA)) end
    end

    local body = table.concat(lines, "\n")
    if body == "" then return end

    CuraEqui._dbg = CuraEqui._dbg or {}
    local last = CuraEqui._dbg.lastStatsTut or 0
    if (now - last) < 10 then return end
    CuraEqui._dbg.lastStatsTut = now

    UI.Toast(body, 12000, 0, "CuraEqui_HorseStats", "tutorial")
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
    local h   = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
    local S   = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
    local now = (CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local s   = tonumber(sec) or 0

    if not (h and S) then
        System.LogAlways("[CuraEqui][Cheat] set_sated: no horse"); return
    end

    -- set internal
    S.satedUntil = (s > 0) and (now + s) or now

    -- hard clear then force re-apply the correct tier
    if CuraEqui.Buffs and CuraEqui.Buffs.ClearSated then pcall(CuraEqui.Buffs.ClearSated, h) end
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncSatedTimer then
        pcall(CuraEqui.Buffs.SyncSatedTimer, h, S, { cause = "cheat", force = true })
    end
    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then pcall(CuraEqui.Buffs.SyncAll, h, S) end

    -- optional persist
    if CuraEqui.Persist and CuraEqui.Persist.Save then
        pcall(CuraEqui.Persist.Save, S.hunger, S.satedUntil, "cheat")
    end

    System.LogAlways(("[CuraEqui][Cheat] sated set to %ds"):format(s))
end

-- Clear sated quickly
function CuraEqui.Debug.ClearSated()
    return CuraEqui.Debug.SetSated(0)
end

-- Add/override a diet token -> GUID at runtime
function CuraEqui.Debug.DietAdd(token, guid)
    CuraEqui.DietData = CuraEqui.DietData or {}
    token             = tostring(token or ""):lower()
    guid              = tostring(guid or "")
    if token == "" or guid == "" then
        System.LogAlways("[CuraEqui][Diet] Usage: curaequi_diet_add <token> <guid>")
        return
    end
    CuraEqui.DietData[token] = { classId = guid }
    System.LogAlways(("[CuraEqui][Diet] Mapped %s -> %s"):format(token, guid))
end

-- Resolve a token or guid and print the result
function CuraEqui.Debug.DietResolve(spec)
    local function looks_like_guid(s)
        return type(s) == "string" and
            s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    end
    local s = tostring(spec or "")
    if looks_like_guid(s) then
        System.LogAlways(("[CuraEqui][Diet] %s is a GUID"):format(s))
        return s
    end
    local token = s:lower()
    local row = (CuraEqui.DietData and CuraEqui.DietData[token])
        or (_G.DietData and (_G.DietData[token] or _G.DietData[s]))
    local gid = row and (row.classId or row.class or row.cid or row.guid)
    System.LogAlways(("[CuraEqui][Diet] %s -> %s"):format(token, tostring(gid)))
    return gid
end

-- List current DietData mappings (first N)
function CuraEqui.Debug.DietList(max)
    local t, n = CuraEqui.DietData or {}, 0
    max = tonumber(max or 50) or 50
    System.LogAlways("[CuraEqui][Diet] ---- current mappings ----")
    for k, v in pairs(t) do
        local gid = v and (v.classId or v.class or v.cid or v.guid)
        System.LogAlways(("  %s -> %s"):format(tostring(k), tostring(gid)))
        n = n + 1; if n >= max then break end
    end
    System.LogAlways(("[CuraEqui][Diet] ---- total=%d (showing up to %d) ----"):format(n, max))
end

-- Scripts/CuraEqui/Debug.lua
-- Uses DietData.byToken -> guid (from DietData.lua) and falls back to GUID input.
function CuraEqui.Debug.SpawnFoodStrict(spec, qty, health)
    -- guards
    if not System or not System.GetEntity or not g_localActorId then
        System.LogAlways("[CuraEqui][Spawn] System/GetEntity unavailable"); return
    end
    local player = System.GetEntity(g_localActorId)
    if not (player and player.inventory) then
        System.LogAlways("[CuraEqui][Spawn] Player or inventory missing"); return
    end
    local inv = player.inventory
    if not (inv and (inv.CreateItem or inv.AddItem)) then
        System.LogAlways("[CuraEqui][Spawn] Inventory API missing (CreateItem/AddItem)"); return
    end

    -- normalize
    spec = tostring(spec or "")
    if spec == "" then
        System.LogAlways("[CuraEqui][Spawn] Missing <token|guid>"); return
    end
    qty    = math.max(1, math.floor(tonumber(qty or 1) + 0.5))
    health = tonumber(health); if health == nil then health = 1.0 end
    if health > 1 then health = health / 100.0 end
    if health < 0 or health > 1 then
        System.LogAlways("[CuraEqui][Spawn] health must be 0..1 (or 0..100)"); return
    end

    -- DietData resolution (byToken/byGuid from DietData.lua)
    local function looks_like_guid(s)
        return type(s) == "string" and
            s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    end

    local classId
    local D       = CuraEqui.DietData or {} -- has byGuid & byToken populated
    local byToken = D.byToken or {}         -- token -> { guid, nutrition }
    local byGuid  = D.byGuid or {}          -- guid  -> { token, nutrition }

    if looks_like_guid(spec) then
        -- GUID given directly; accept even if not present in byGuid
        classId = spec
    else
        local row = byToken[spec:lower()] or byToken[spec]
        classId = row and row.guid
    end

    if not classId or classId == "" then
        System.LogAlways(("[CuraEqui][Spawn] No GUID for '%s'. Add mapping to DietData.byToken or pass a GUID.")
            :format(spec))
        return
    end

    -- Prefer CreateItem (health-aware), fall back to AddItem fresh
    if inv.CreateItem then
        local ok, ret = pcall(inv.CreateItem, inv, classId, health, qty)
        if ok and ret ~= false then
            System.LogAlways(("[CuraEqui][Spawn] OK: %dx %s at health=%.2f (CreateItem)"):format(qty, classId, health))
            return
        else
            System.LogAlways("[CuraEqui][Spawn] CreateItem failed or returned false; falling back to AddItem (fresh)")
        end
    end

    if inv.AddItem then
        local spawned = 0
        for i = 1, qty do
            if inv:AddItem(classId, 1) then spawned = spawned + 1 end
        end
        if spawned > 0 then
            System.LogAlways(("[CuraEqui][Spawn] OK: %dx %s (AddItem fallback, fresh)"):format(spawned, classId))
        else
            System.LogAlways("[CuraEqui][Spawn] AddItem fallback failed")
        end
        return
    end

    System.LogAlways("[CuraEqui][Spawn] No usable spawn path executed")
end

function CuraEqui.Debug.SpawnRottenStrict(spec, qty)
    return CuraEqui.Debug.SpawnFoodStrict(spec, qty, 0.10)
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

-- === Debug console: command registry + help + aliases =======================
CuraEqui.Debug = CuraEqui.Debug or {}
CuraEqui.Debug._cmds = CuraEqui.Debug._cmds or {}

local function _add_cmd(name, handler, help)
    if not (System and System.AddCCommand) then return end
    if not name or not handler then return end
    -- avoid double-register
    if not CuraEqui.Debug._cmds[name] then
        System.AddCCommand(name, handler, help or "")
        CuraEqui.Debug._cmds[name] = { handler = handler, help = help or "" }
        -- short alias: ce_<tail>
        local short = name:gsub("^curaequi_", "ce_")
        if short ~= name and not CuraEqui.Debug._cmds[short] then
            System.AddCCommand(short, handler, "(alias) " .. (help or ""))
            CuraEqui.Debug._cmds[short] = { handler = handler, help = "(alias) " .. (help or "") }
        end
    end
end

-- If you have the preset switcher (in Presets.lua), expose an alias here:
if CuraEqui.ApplyPreset then
    _add_cmd("curaequi_preset", "CuraEqui.ApplyPreset(%1)",
        "Apply hunger/feeding preset: hardcore|real_life|moderate|laidback|author")
end

-- Implement SnapStaminaMax via the reader (so help can bind to a function name)
function CuraEqui.Debug.SnapStaminaMax()
    local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h then
        System.LogAlways("[CuraEqui] no horse"); return
    end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h); if not S then return end
    local cur = CuraEqui.Debug.ReadHorseStamina and select(1, CuraEqui.Debug.ReadHorseStamina(h))
    if cur then
        S._snap = S._snap or {}; S._snap.staminaMax = cur
        System.LogAlways(("[CuraEqui] stamina snap set to %d"):format(math.floor(cur + 0.5)))
    end
end

-- Unified help
local function _help_line(name, meta)
    local pad = (name:len() < 24) and string.rep(" ", 24 - name:len()) or " "
    return string.format("%s%s- %s", name, pad, meta.help or "")
end

function CuraEqui.Debug.Help(pattern)
    local p = pattern and tostring(pattern):lower() or nil
    local names = {}
    for k in pairs(CuraEqui.Debug._cmds) do
        if (not p) or k:lower():find(p, 1, true) then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    System.LogAlways("[CuraEqui][Help] Available commands:")
    for _, k in ipairs(names) do
        System.LogAlways("  " .. _help_line(k, CuraEqui.Debug._cmds[k]))
    end
    -- brief on-screen toast (right corner)
    if CuraEqui.UI and CuraEqui.UI.Toast then
        CuraEqui.UI.Toast("CuraEqui: Help printed to console", 2500, 0, "CuraEqui_Help", "notification")
    end
end

-- Returns a table of whatever the build exposes + a preferred "speed" pick
-- Debug.lua
function CuraEqui.Debug.ReadHorseSpeed(h)
    h = h or (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    local s = h and (h.soul or (h.GetSoul and h:GetSoul())) or nil
    if not (s and s.GetDerivedStat) then return nil end

    local function gd(key)
        local ok, v = pcall(function() return s:GetDerivedStat(key, {}, nil) end)
        return ok and v or nil
    end

    local t = {
        nrs = gd("nrs"), -- NormalizedRunSpeed
        rsb = gd("rsb"), -- RunSpeedBase
        nsb = gd("nsb"), -- NormalizedRunSpeedBase
        rsa = gd("rsa"), -- RelativeMovementSpeedAddition
        rms = gd("rms"), -- RealMoveSpeedMod
    }

    -- pick current “best” to display
    local pick, src
    if t.rms then
        pick, src = t.rms, "rms" -- multiplier (e.g., 0.95x)
    elseif t.nrs then
        pick, src = t.nrs, "nrs" -- normalized run speed
    elseif t.rsb then
        pick, src = t.rsb, "rsb" -- base run
    elseif t.nsb then
        pick, src = t.nsb, "nsb" -- base normalized
    elseif t.rsa then
        pick, src = t.rsa, "rsa" -- relative add
    else
        pick, src = nil, nil
    end

    t.pick, t.pickSrc = pick, src
    return t
end

function CuraEqui.Debug.MaybeResnapStamina(h)
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    if not (D and D.staminaSnapshot) then return end
    local S = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h)
    if not S then return end
    local cur = CuraEqui.Debug.ReadHorseStamina and select(1, CuraEqui.Debug.ReadHorseStamina(h))
    if cur then
        S._snap = S._snap or {}
        S._snap.staminaMax = math.max(S._snap.staminaMax or 0, cur)
    end
end

-- Resolve target: "player" | "horse"
local function _resolveTarget(which)
    which = tostring(which or "player")
    if which == "horse" and CuraEqui.Horse and CuraEqui.Horse.Resolve then
        return CuraEqui.Horse.Resolve()
    end
    -- fallback to player
    return System.GetEntity(Game.GetPlayerId and Game.GetPlayerId() or 0)
end

-- Poll current anim (name via Entity.GetCurAnimation, state via Actor.GetCurrentAnimationState)
local function _sampleAnim(e)
    if not e then return nil end
    local curName = nil
    local ok, nameOrIdx = pcall(function() return e.GetCurAnimation and e:GetCurAnimation() end)
    if ok then curName = tostring(nameOrIdx or "") end

    local state = nil
    if e.GetCurrentAnimationState then
        local ok2, st = pcall(function() return e:GetCurrentAnimationState() end)
        if ok2 then state = tostring(st or "") end
    end
    return curName, state
end

-- #anim_watch [player|horse] [interval_ms]
function anim_watch(which, intervalMs)
    local e = _resolveTarget(which)
    if not e then
        System.LogAlways("[AnimProbe] target not found"); return
    end
    intervalMs = tonumber(intervalMs) or 250
    CuraEqui.AnimProbe.enabled = true
    System.LogAlways(string.format("[AnimProbe] watching %s (every %d ms)", which or "player", intervalMs))

    local key = (which or "player")
    local function tick()
        if not CuraEqui.AnimProbe.enabled then return end
        local cur, st = _sampleAnim(e)
        local L = CuraEqui.AnimProbe.last[key] or { name = "", state = "" }
        if cur ~= L.name or st ~= L.state then
            System.LogAlways(string.format("[AnimProbe] %s anim change → name='%s' state='%s'",
                key, tostring(cur or ""), tostring(st or "")))
            CuraEqui.AnimProbe.last[key] = { name = cur or "", state = st or "" }
        end
        Script.SetTimer(intervalMs, tick)
    end
    Script.SetTimer(intervalMs, tick)
end

-- #anim_stop
function anim_stop()
    CuraEqui.AnimProbe.enabled = false
    System.LogAlways("[AnimProbe] stopped")
end

-- === Minimal player resolver (no Utils) + probe ============================
local function _ce_get_player()
    if System.GetEntityByName then
        local p = System.GetEntityByName("Henry") or System.GetEntityByName("dude")
        if p then return p end
    end
    if Game and Game.GetPlayerId then
        local ok, pid = pcall(Game.GetPlayerId, Game)
        if ok and pid then
            local p = System.GetEntity and System.GetEntity(pid)
            if p then return p end
        end
    end
    if System.GetEntitiesByClass then
        local t = System.GetEntitiesByClass("Player") or {}
        if #t > 0 then return t[1] end
    end
    return nil
end

function CuraEqui.Debug.WhoAmI()
    local p = _ce_get_player()
    if not p then
        System.LogAlways("[CuraEqui] whoami: no player"); return
    end
    local n   = p.GetName and p:GetName() or "?"
    local pos = p.GetWorldPos and p:GetWorldPos() or { x = 0, y = 0, z = 0 }
    System.LogAlways(string.format("[CuraEqui] whoami: %s id=%s pos=(%.2f,%.2f,%.2f)", n, tostring(p.id), pos.x, pos.y,
        pos.z))
end

function CuraEqui.Debug.ProbeNear(radius)
    local R = tonumber(radius) or 12.0
    local p = _ce_get_player()
    if not p or not p.GetWorldPos then
        System.LogAlways("[Probe] no player"); return
    end
    local pos  = p:GetWorldPos()
    local ents = System.GetEntitiesInSphere(pos, R) or {}
    System.LogAlways(string.format("[Probe] %d ents within %.1fm", #ents, R))
    for i, e in ipairs(ents) do
        local name  = (e.GetName and e:GetName()) or "?"
        local class = e.class or "?"
        local ep    = e.GetWorldPos and e:GetWorldPos() or { x = 0, y = 0, z = 0 }
        System.LogAlways(string.format(" [%02d] id=%s  %s  class=%s  (%.2f,%.2f,%.2f)",
            i, tostring(e.id), name, class, ep.x, ep.y, ep.z))
    end
end

-- ==== Water scan commands ===================================================
function CuraEqui.Debug.ProbeWater(radius)
    local U = CuraEqui.Utils or {}
    local list = (U.Drinking_FindAroundPlayer and U.Drinking_FindAroundPlayer(radius)) or {}
    System.LogAlways(string.format("[WaterProbe] %d match(es) within %.1fm",
        #list, tonumber(radius) or 12.0))
    for i, e in ipairs(list) do
        local nm = (e.GetName and e:GetName()) or "?"
        System.LogAlways(string.format(" [%02d] %s  class=%s", i, nm, e.class or "?"))
    end
end

function CuraEqui.Debug.ProbeWaterHorse(radius)
    local h = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    if not h or not h.GetWorldPos then
        System.LogAlways("[WaterProbe] no horse"); return
    end
    local U = CuraEqui.Utils or {}
    local list = (U.Drinking_FindAroundEntity and U.Drinking_FindAroundEntity(h, radius)) or {}
    System.LogAlways(string.format("[WaterProbe] near horse: %d match(es) within %.1fm",
        #list, tonumber(radius) or 12.0))
    for i, e in ipairs(list) do
        local nm = (e.GetName and e:GetName()) or "?"
        System.LogAlways(string.format("  - %s  class=%s", nm, e.class or "?"))
    end
end

function CuraEqui.Debug.DumpHorseDerived()
    local h = (CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()) or nil
    if not h then
        System.LogAlways("[CuraEqui][HorseDerived] no horse"); return
    end
    local soul = (h.soul or (h.GetSoul and h:GetSoul())) or nil
    if not (soul and soul.GetDerivedStat) then
        System.LogAlways("[CuraEqui][HorseDerived] no soul/derived"); return
    end

    local function L(tag, key)
        local v = _gd(soul, key, {})
        System.LogAlways(("[CuraEqui][HorseDerived] %s (%s) = %s"):format(tag, key, tostring(v)))
    end
    L("stamina regen", "srg")
    L("stamina pool", "mst")
    L("courage mod", "hcm")
    L("morale limit", "hml")
    L("stam recovery", "nrw")
    L("rider threat→morale", "rtm")
    L("run speed base", "rsb")
    L("real move speed mod", "rms")
    L("morale", "mor")
    L("normalized run speed", "nrs")
    L("normalized run speed base", "nsb")
    L("relative movement speed addition", "rsa")
end

function CuraEqui.Debug.NukeSated()
    if CuraEqui.Buffs and CuraEqui.Buffs.ClearSatedTimers then
        pcall(CuraEqui.Buffs.ClearSatedTimers)
    end
    if CuraEqui.Buffs then
        CuraEqui.Buffs._lastPlayerUuid = nil
    end
    System.LogAlways("[CuraEqui][Debug] NUKED all sated timers (player).")
end

-- Console bindings
if System and System.AddCCommand then
    -- Register (or rebind) all existing commands here:
    _add_cmd("curaequi_stats_tutorial", "CuraEqui.Debug.ShowHorseStatsTutorial()", "Show Horse Status tutorial card")
    _add_cmd("curaequi_set_hunger", "CuraEqui.Debug.SetHunger(%1)", "Set horse hunger percent [0..100]")
    _add_cmd("curaequi_add_hunger", "CuraEqui.Debug.AddHunger(%1)", "Add delta to horse hunger (negative allowed)")
    _add_cmd("curaequi_set_sated", "CuraEqui.Debug.SetSated(%1)", "Set sated seconds from now (0 clears)")
    _add_cmd("curaequi_clr_sated", "CuraEqui.Debug.ClearSated()", "Clear sated")
    _add_cmd("curaequi_force_tier", "CuraEqui.Debug.ForceTierForSeconds(%1,%2)", "Force HUD hunger tier for N seconds")
    _add_cmd("curaequi_snap_stamina", "CuraEqui.Debug.SnapStaminaMax()", "Snapshot current stamina as session max")
    _add_cmd("curaequi_hunger_trace", "CuraEqui.Debug_EnableHungerTrace(%1,%2)",
        "Toggle hunger trace (enabled, everyNTicks)")
    _add_cmd("curaequi_distance_trace", "CuraEqui.Debug_EnableDistanceTrace(%1,%2)",
        "Toggle distance trace (enabled, stepMeters)")
    _add_cmd("curaequi_diet_bind", "CuraEqui.Debug.DietBind(%1,%2)", "Bind diet key/GUID to nutrition value (dev)")
    _add_cmd("curaequi_diet_lookup", "CuraEqui.Debug.DietLookup(%1)", "Lookup diet row by GUID/token (dev)")
    _add_cmd("curaequi_help", "CuraEqui.Debug.Help(%1)", "List commands (optionally filter: curaequi_help preset)")
    _add_cmd("curaequi_whoami", "CuraEqui.Debug.WhoAmI()", "Log resolved player entity")
    _add_cmd("curaequi_probe", "CuraEqui.Debug.ProbeNear(%1)", "Scan entities around player (meters)")
    _add_cmd("curaequi_probe_water", "CuraEqui.Debug.ProbeWater(%1)", "Scan water sources around player (m)")
    _add_cmd("curaequi_probe_water_horse", "CuraEqui.Debug.ProbeWaterHorse(%1)",
        "Scan water sources around current horse (m)")
    _add_cmd("curaequi_horse_stats", "CuraEqui.Debug.DumpHorseStats()", "Dump current horse stats")
    _add_cmd("curaequi_stats_tutorial", "CuraEqui.Debug.ShowHorseStatsTutorial()", "Show horse stats card")
    _add_cmd("curaequi_horse_derived", "CuraEqui.Debug.DumpHorseDerived()", "Dump horse-related derived stats")
    _add_cmd("curaequi_nuke_sated", "CuraEqui.Debug.NukeSated()", "Nuked Sated Status Buffs")

    _add_cmd("curaequi_spawn_food_strict",
        "CuraEqui.Debug.SpawnFoodStrict(%1,%2,%3)",
        "STRICT: spawn food <token|class> <qty> <health 0..1>")

    _add_cmd("curaequi_spawn_rotten_strict",
        "CuraEqui.Debug.SpawnRottenStrict(%1,%2)",
        "STRICT: spawn rotten <token|class> <qty> (health=0.10)")

    _add_cmd("curaequi_spawn_food",
        "CuraEqui.Debug.SpawnFoodStrict(%1)",
        "Spawn food <token|class> [qty defaults 1, health 1.0]")

    _add_cmd("curaequi_spawn_rotten",
        "CuraEqui.Debug.SpawnRottenStrict(%1)",
        "Spawn rotten <token|class> [qty defaults 1]")

    _add_cmd("curaequi_diet_add",
        "CuraEqui.Debug.DietAdd(%1,%2)",
        "Map diet token to GUID: <token> <guid>")

    _add_cmd("curaequi_diet_resolve",
        "CuraEqui.Debug.DietResolve(%1)",
        "Resolve token/guid and print resolved GUID")

    _add_cmd("curaequi_diet_list",
        "CuraEqui.Debug.DietList(%1)",
        "List current diet mappings [max=50]")
end
