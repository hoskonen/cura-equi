-- Scripts/CuraEqui/Utils.lua

-- Root namespace for the mod
CuraEqui = CuraEqui or {}

-- One and only Utils table
CuraEqui.Utils = CuraEqui.Utils or {}
local M = CuraEqui.Utils -- local alias for this file only

-- ─────────────────────────────────────────────────────────────────────────────
-- Time
-- ─────────────────────────────────────────────────────────────────────────────

-- One gameplay clock for everyone
CuraEqui = CuraEqui or {}
CuraEqui.Now = CuraEqui.Now or function()
    if GetCurrTime then return GetCurrTime() end
    if System and System.GetCurrTime then return System.GetCurrTime() end
    if Calendar and Calendar.GetGameTime then return Calendar.GetGameTime() end
    return (Script and Script.GetTime and Script.GetTime()) or os.clock()
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Player/entity helpers
-- ─────────────────────────────────────────────────────────────────────────────

function M.GetPlayer()
    -- Keep your usual resolution order; extend if needed.
    return System.GetEntityByName("Henry")
        or System.GetEntityByName("dude")
        or _G.player
        or nil
end

function M.GetPlayerInventory()
    local p = M.GetPlayer()
    if not p then return nil end

    -- common bindings across builds
    if p.inventory then return p.inventory end

    if p.GetInventory then
        local ok, inv = pcall(p.GetInventory, p)
        if ok and inv then return inv end
    end

    if p.actor and p.actor.GetInventory then
        local ok, inv = pcall(p.actor.GetInventory, p.actor)
        if ok and inv then return inv end
    end

    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Logging helpers (optional but handy)
-- ─────────────────────────────────────────────────────────────────────────────
function M.Log(tag, fmt, ...)
    System.LogAlways(("[CuraEqui][%s] " .. tostring(fmt)):format(tag, ...))
end

-- Tiny one-shot inspector while debugging inventory availability
function M.LogInventoryIntrospection()
    local inv = M.GetPlayerInventory()
    System.LogAlways(("[CuraEqui][Inspect] inv=%s DeleteItem=%s DeleteItemOfClass=%s FindItem=%s")
        :format(tostring(inv),
            tostring(inv and inv.DeleteItem),
            tostring(inv and inv.DeleteItemOfClass),
            tostring(inv and inv.FindItem)))
end

function M.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function M.vlen2(a, b)
    if not (a and b) then return 0 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Treat small numbers as seconds (≤60), larger as ms → seconds
function M.ms_to_s(v)
    local n = tonumber(v or 0) or 0
    if n <= 60 then return math.max(0.1, n) end
    return math.max(0.1, n / 1000.0)
end

-- Returns true only when enough time passed for this key.
-- Usage: if M.throttle("tick-fired", 10) then System.LogAlways("fired") end
-- throttle
do
    local _next = {}
    function M.throttle(key, intervalSec)
        local now = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
        local t   = tonumber(intervalSec or 1) or 1
        local nxt = _next[key] or 0
        if now >= nxt then
            _next[key] = now + t; return true
        end
        return false
    end
end

-- hunger_label
function M.hunger_label(hungerPct, satedUntil)
    local HUD   = CuraEqui.Config and CuraEqui.Config.HUD or {}
    local th    = HUD.thresholds or { minor = 20, moderate = 50, critical = 80 }
    local names = HUD.hungerNames or { ok = "OK", minor = "Mild", moderate = "Hungry", critical = "Starving", sated =
    "Sated" }

    local now   = (CuraEqui and CuraEqui.Now and CuraEqui.Now()) or os.clock()
    local rem   = math.max(0, (tonumber(satedUntil or 0) or 0) - now)
    if rem > 0 then return names.sated, "sated" end

    local h = tonumber(hungerPct or 0) or 0
    local tier = (h >= (th.critical or 80)) and "critical"
        or (h >= (th.moderate or 50)) and "moderate"
        or (h >= (th.minor or 20)) and "minor"
        or "ok"
    return names[tier] or tier, tier
end

-- ==== Drinking utils: match & fast find (class-filtered with fallback) =====
do
    local function _match(ent, rule)
        if not ent or not rule then return false end
        if (ent.class or "") ~= rule.class then return false end
        if not rule.nameMatch then return true end
        local nm = (ent.GetName and ent:GetName()) or ""
        return nm:find(rule.nameMatch, 1, true) ~= nil
    end

    local function _collectByRule(center, radius, rule, out, seen)
        out, seen = out or {}, seen or {}
        local list
        if System.GetEntitiesInSphereByClass then
            list = System.GetEntitiesInSphereByClass(center, radius, rule.class) or {}
        else
            -- fallback: full sphere → filter by class
            local all = System.GetEntitiesInSphere(center, radius) or {}
            list = {}
            for _, e in ipairs(all) do if e and e.class == rule.class then list[#list + 1] = e end end
        end
        for _, e in ipairs(list) do
            local id = tostring(e.id)
            if not seen[id] and _match(e, rule) then
                seen[id] = true
                out[#out + 1] = e
            end
        end
        return out, seen
    end

    local function _posOf(ent)
        return ent and ent.GetWorldPos and ent:GetWorldPos() or nil
    end

    -- Public: find all configured sources around a world position
    function M.Drinking_FindAt(pos, radius)
        local cfg = (CuraEqui.Config and CuraEqui.Config.Drinking and CuraEqui.Config.Drinking.sources) or {}
        if not pos or not cfg or #cfg == 0 then return {} end
        local hits, seen = {}, {}
        for _, rule in ipairs(cfg) do _collectByRule(pos, radius, rule, hits, seen) end
        -- sort by distance
        table.sort(hits, function(a, b)
            local pa, pb = _posOf(a), _posOf(b)
            if not (pa and pb) then return false end
            local dx, dy, dz = pa.x - pos.x, pa.y - pos.y, pa.z - pos.z
            local da = dx * dx + dy * dy + dz * dz
            dx, dy, dz = pb.x - pos.x, pb.y - pos.y, pb.z - pos.z
            local db = dx * dx + dy * dy + dz * dz
            return da < db
        end)
        return hits
    end

    -- Convenience: around player / around entity
    function M.Drinking_FindAroundPlayer(radius)
        local p = M.GetPlayer and M.GetPlayer() or nil
        local pos = p and p.GetWorldPos and p:GetWorldPos() or nil
        if not pos then return {} end
        return M.Drinking_FindAt(pos, tonumber(radius) or 12.0)
    end

    function M.Drinking_FindAroundEntity(ent, radius)
        local pos = _posOf(ent); if not pos then return {} end
        return M.Drinking_FindAt(pos, tonumber(radius) or 12.0)
    end

    -- Boolean helper for gameplay code
    function M.Drinking_IsNear(pos, radius)
        local t = M.Drinking_FindAt(pos, radius)
        return t and #t > 0
    end
end
