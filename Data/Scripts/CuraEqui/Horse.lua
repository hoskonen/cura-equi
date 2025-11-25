-- Scripts/CuraEqui/Horse.lua
CuraEqui.Horse = CuraEqui.Horse or { playerHorseId = nil }
CuraEqui.HorseState = CuraEqui.HorseState or {}
CuraEqui.HorseCfg = CuraEqui.HorseCfg or
    { hungerMax = 100, hungerStart = 30, tickSec = 10, debuffAt = 70 }

-- logging ---------------------------------------------------------------
local function FeedLog(fmt, ...)
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    if not (D and D.feedTrace) then return end
    CuraEqui.Log("Feed", fmt, ...)
end

-- Logging helper for horse-related traces
local function QH(fmt, ...)
    local D = CuraEqui.Config and CuraEqui.Config.Debug
    -- while debugging, you probably want this always on:
    -- if not (D and D.horseTrace) then return end
    if D and D.horseTrace then
        CuraEqui.Log("Horse", fmt, ...)
    end
end

local function _log_feed_cap(S, needPoints, used, usedEff, overshoot, consumedUnits, selectedUnits, addSec, bucketSec)
    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if not (D and D.feedTrace) then return end

    System.LogAlways(("[CuraEqui][Feed] cap=%d used=%.0f applied=%.0f overshoot=%.0f units=%d sel=%d → +%ds (bucket=%ds)")
        :format(
            tonumber(needPoints or 0) or 0,
            tonumber(used or 0) or 0,
            tonumber(usedEff or 0) or 0,
            tonumber(overshoot or 0) or 0,
            tonumber(consumedUnits or 0) or 0,
            tonumber(selectedUnits or 0) or 0,
            tonumber(addSec or 0) or 0,
            tonumber(bucketSec or 0) or 0
        ))
end

-- Pretty summary for feed → sated timers, showing clamp if any.
local function _log_sated_summary(used, rawSec, bucketSec, buffSec)
    -- used: total nutrition consumed this feed
    -- rawSec: pre-clamp remain (post-add, pre-bucket), seconds
    -- bucketSec: chosen bucket (what UI shows as full tier), seconds
    -- buffSec: actual timed buff duration applied (usually = bucketSec), seconds

    local u         = math.floor(tonumber(used) or 0)
    local raw       = math.max(0, tonumber(rawSec or 0) or 0)
    local buck      = math.max(0, tonumber(bucketSec or 0) or 0)
    local buff      = math.max(0, tonumber(buffSec or bucketSec or 0) or 0)

    -- Round to readable ints for logging
    local rawI      = math.floor(raw + 0.5)
    local buckI     = math.floor(buck + 0.5)
    local buffI     = math.floor(buff + 0.5)

    local clampPart = ""
    -- Only show the clamp arrow when bucket differs from raw by ~0.5s or more
    if buckI ~= rawI and buckI > 0 and rawI > 0 then
        clampPart = (" (%ds \226\134\146 %ds)"):format(rawI, buckI) -- "87s → 100s"
    end

    System.LogAlways(("[CuraEqui][Feed] Ate %d nutrition \226\134\146 Sated %ds%s (applied buff=%ds)")
        :format(u, buckI, clampPart, buffI))
end

local function _feed_toast_cfg()
    local F = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
    local lane = F.toastLane or "infotext"
    local ms = math.max(200, math.floor((tonumber(F.toastSec) or 2.0) * 1000))
    return lane, ms
end

-- ——— WUID → item info (classId, names, qty) ———
local function _inv_get_info(wuid)
    local t = nil
    if ItemManager and ItemManager.GetItem then
        local ok, obj = pcall(ItemManager.GetItem, wuid); if ok and type(obj) == "table" then t = obj end
    end
    if not t then return { wuid = tostring(wuid) } end

    local classId = t.classId or t.class or t.class_id or t.type or t.kind
    local ui, db = nil, nil
    if classId and ItemManager then
        pcall(function() ui = ItemManager.GetItemUIName(classId) end)
        pcall(function() db = ItemManager.GetItemName(classId) end)
    end

    -- qty: prefer field 'amount', then method 'GetAmount' (Smith’s Reach pattern)
    local amt = rawget(t, "amount") or rawget(t, "Amount")
    if amt == nil then
        local getter = rawget(t, "GetAmount") or rawget(t, "getAmount")
        if type(getter) == "function" then
            local ok, q = pcall(getter, t); if ok then amt = q end
        end
    end
    if type(amt) ~= "number" then amt = tonumber(amt) or 1 end
    if amt < 1 then amt = 1 end

    local info = {
        wuid    = tostring(wuid),
        classId = classId,
        uiName  = ui,
        dbName  = db,
        qty     = amt
    }

    return info
end

-- Per-unit nutrition resolver: DietData.byGuid → keyword map/list → default
local function _per_unit_from_info(info)
    local label  = info.uiName or info.dbName or "food"

    -- 1) exact class match from DietData (tolerant keys)
    local DD     = CuraEqui.DietData or CuraEqui.Diet or {}
    local byGuid = DD.byGuid or DD.ByGuid or {}
    local gid    = info.classId or info.class or info.cid

    if gid then
        local g1 = tostring(gid)
        local g2 = g1:lower()
        local g3 = g1:upper()

        local rec = byGuid[g1] or byGuid[g2] or byGuid[g3]
        if not rec and byGuid.guid then
            rec = byGuid.guid[g1] or byGuid.guid[g2] or byGuid.guid[g3]
        end

        if rec then
            local v = tonumber(rec.nutrition or 0) or 0
            if v > 0 then
                return v, (rec.token or label), (rec.horseFood == true)
            end
        end
    end

    -- keyword fallback (only if explicitly allowed in config)
    local DCFG = (CuraEqui.Config and CuraEqui.Config.Diet) or {}
    local allowKW = (DCFG.allowKeywordFallback == true)
    if allowKW then
        local name = tostring(label):lower()
        local kws  = DCFG.allowKeywords or { "apple", "bread", "carrot" }
        if #kws > 0 then
            local perKW = tonumber(DCFG.keywordNutrition or 10) or 10
            for _, kw in ipairs(kws) do
                kw = tostring(kw):lower()
                if kw ~= "" and name:find(kw, 1, true) then
                    return perKW, kw
                end
            end
        else
            for kw, val in pairs(kws) do
                local kwl = tostring(kw):lower()
                if kwl ~= "" and name:find(kwl, 1, true) then
                    local v = tonumber(val) or 0
                    if v > 0 then return v, kw end
                end
            end
        end
    end

    return 0, label, false
end

local function _sated_cfg()
    local F    = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
    local H    = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}

    local per  = tonumber(H.satedSecPerNutrition) or tonumber(F.satedSecPerPoint) or 6
    local perH = tonumber(F.satedSecPerPointHorse) or per -- horse seconds per point (default=per)
    local maxS = tonumber(H.satedCapSec) or tonumber(F.satedMaxSec) or 600
    local minS = tonumber(F.satedMinSec) or 0
    local capP = tonumber(F.needCapPerFeed) or 25
    local also = (F.satedAlsoReducesHunger ~= false)

    -- simple inline clamps (“validator”)
    per        = math.max(1, per)
    perH       = math.max(per, perH) -- never less than normal
    capP       = math.max(1, math.min(200, capP))

    return { minSec = minS, maxSec = maxS, perPt = per, perPtHorse = perH, capPts = capP, alsoHun = also }
end

local function _calc_need_points(S, mode)
    local F   = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
    local cap = tonumber(F.needCapPerFeed or 25) or 25

    if mode == "sated" then
        local C          = _sated_cfg() -- {minSec, maxSec, perPt, capPts, alsoHun}
        local now        = (CuraEqui.Now and CuraEqui.Now()) or 0
        local remS       = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)

        -- points needed to reach the minimum sated target (minSec)
        local missingSec = math.max(0, (C.minSec or 0) - remS)
        local perPt      = math.max(1, C.perPt or 1)
        local sNeedPt    = math.ceil(missingSec / perPt)

        local capPts     = math.min(C.capPts or cap, cap)

        if C.alsoHun then
            local hNeedPt = math.max(0, tonumber(S.hunger or 0) or 0)
            return math.max(0, math.min(math.max(sNeedPt, hNeedPt), capPts))
        else
            return math.max(0, math.min(sNeedPt, capPts))
        end
    end

    -- hunger mode
    local h = math.max(0, tonumber(S.hunger or 0) or 0)
    return math.min(h, cap)
end

local function _plan_remove(picks, needPoints, over)
    local removePlan, used = {}, 0
    for _, info in ipairs(picks or {}) do
        if used >= needPoints then break end

        local per, label, isHorse = _per_unit_from_info(info)
        if per > 0 then
            local maxUnits  = tonumber(info.qty or 1) or 1
            local remaining = math.max(0, needPoints - used)
            local wantUnits = math.floor(remaining / per)

            -- allow slight overshoot by one unit if policy says so
            if (wantUnits * per) < remaining and (over == "allow") then
                wantUnits = wantUnits + 1
            end

            wantUnits = math.max(0, math.min(wantUnits, maxUnits))
            if wantUnits > 0 then
                local key = info.wuidStr or tostring(info._wuid)
                local rec = removePlan[key]
                if not rec then
                    rec = {
                        wuid    = info._wuid,
                        classId = info.classId,
                        units   = 0,
                        label   = label,
                        per     = per,
                        horse   = isHorse,
                    }
                    removePlan[key] = rec
                end

                rec.units = rec.units + wantUnits
                used = used + wantUnits * per
            end
        end
    end

    -- totals
    local selectedUnits = 0
    for _, info in ipairs(picks or {}) do
        selectedUnits = selectedUnits + (tonumber(info.qty) or 0)
    end

    local consumedUnits = 0
    for _, rec in pairs(removePlan or {}) do
        consumedUnits = consumedUnits + (tonumber(rec.units) or 0)
    end

    -- overshoot handling:
    -- when 'over' == "allow", KEEP the last extra unit that crosses the cap (simple + predictable).
    -- when 'over' ~= "allow", preserve the old behavior and clamp back to needPoints.
    if over ~= "allow" and used > needPoints then
        local excess = used - needPoints
        for k, rec in pairs(removePlan) do
            if excess <= 0 then break end
            if rec.per > 0 and rec.units > 0 then
                local drop = math.min(rec.units, math.ceil(excess / rec.per))
                if drop > 0 then
                    rec.units = rec.units - drop
                    used = used - drop * rec.per
                    if rec.units == 0 then removePlan[k] = nil end
                    excess = used - needPoints
                end
            end
        end
    end

    return removePlan, used, selectedUnits, consumedUnits
end

local function _apply_feed(S, mode, used)
    local beforeH = math.max(0, tonumber(S.hunger or 0) or 0)
    local newH    = beforeH
    if mode == "sated" then
        local C     = _sated_cfg()
        local now   = (CuraEqui.Now and CuraEqui.Now()) or 0
        local add   = used * C.perPt
        local base  = math.max(now, tonumber(S.satedUntil or 0) or 0)
        local capA  = now + C.maxSec
        local next  = math.min(base + add, capA)
        local floor = now + C.minSec
        if next < floor then next = math.min(floor, capA) end
        S.satedUntil = next
        if C.alsoHun then
            newH = math.max(0, beforeH - used); S.hunger = newH
        end
    else
        newH = math.max(0, beforeH - used); S.hunger = newH
    end
    return newH
end

local function _emit_feed_toasts(removePlan, used, mode, S)
    local F = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
    if not (F.toastOnDone and CuraEqui.UI and CuraEqui.UI.Toast) then return end
    local lane, ms = _feed_toast_cfg()
    local parts = {}
    for _, rec in pairs(removePlan) do
        parts[#parts + 1] = {
            label = rec.label,
            units = rec.units,
            total = rec.units *
                rec.per
        }
    end
    for i = 1, #parts do
        local p = parts[i]
        CuraEqui.UI.Toast(string.format("%s x%d (-%d)", p.label, p.units, p.total), ms, 0, "CuraEqui_FeedType", lane)
    end
    local msg
    if mode == "sated" then
        local now  = (CuraEqui.Now and CuraEqui.Now()) or 0
        local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
        msg        = string.format("Fed %d type(s) (-%d) → Sated %.0fs", #parts, used, remS)
    else
        msg = string.format("Fed %d type(s) (-%d) → %d%%", #parts, used, math.floor(tonumber(S.hunger or 0) or 0))
    end
    CuraEqui.UI.Toast(msg, ms, 0, "CuraEqui_FeedSummary", lane)
end

function CuraEqui.Horse.Debug_LogPlayerHorseHandles()
    local function log(label, ok, val)
        local t = type(val)
        System.LogAlways(("[CuraEqui][Horse][dbg] %s -> ok=%s type=%s val=%s")
            :format(label, tostring(ok), t, tostring(val)))
    end

    -- Try all likely bindings (dot/colon/legacy) + the player form
    local ok, v

    if Game and Game.GetPlayerHorse then
        ok, v = pcall(Game.GetPlayerHorse, Game); log("Game:GetPlayerHorse(dot)", ok, v)
    end
    if Game and Game.GetPlayerHorse then
        ok, v = pcall(Game.GetPlayerHorse, Game); log("Game:GetPlayerHorse(colon)", ok, v)
    end
    if g_gameRules and g_gameRules.game and g_gameRules.game.GetPlayerHorse then
        ok, v = pcall(g_gameRules.game.GetPlayerHorse, g_gameRules.game); log("g_gameRules.game:GetPlayerHorse", ok, v)
    end
    if player and player.player and player.player.GetPlayerHorse then
        ok, v = pcall(player.player.GetPlayerHorse, player.player); log("player.player:GetPlayerHorse (WUID expected)",
            ok, v)
    end

    -- Player->HorseId fallback
    if player and player.actor and player.actor.GetHorseId then
        ok, v = pcall(player.actor.GetHorseId, player.actor); log("player.actor:GetHorseId (entityId)", ok, v)
    end
end

function CuraEqui.Horse.Has()
    local h = CuraEqui.Horse.Resolve()
    if h and h.id and System.GetEntity(h.id) then
        return true, h
    end
    return false
end

-- Returns the player's horse entity or nil. Caches id when found.
function CuraEqui.Horse.Resolve()
    local ent

    -- 0) cached
    if CuraEqui.Horse.playerHorseId then ent = System.GetEntity(CuraEqui.Horse.playerHorseId) end
    if ent then return ent end

    -- helper: coerce various handles into an entity
    local function asEnt(handle)
        if not handle then return nil end
        local ty = type(handle)
        if ty == "number" then return System.GetEntity(handle) end
        if ty == "table" and handle.id then return handle end
        -- WUID path (string/userdata depending on binding)
        if XGenAIModule and (ty == "string" or ty == "userdata") then
            local id = XGenAIModule.GetEntityIdByWUID(handle)
            if id and id ~= 0 then return System.GetEntity(id) end
            local e = XGenAIModule.GetEntityByWUID(handle)
            if e and e.id then return e end
        end
        return nil
    end

    -- 1) prefer player.player:GetPlayerHorse() → WUID (as in NoHorseTeleport)
    if player and player.player and player.player.GetPlayerHorse then
        local ok, wuid = pcall(player.player.GetPlayerHorse, player.player)
        if ok then ent = asEnt(wuid) end
    end

    -- 2) engine helpers (dot/colon/legacy variants)
    if not ent and Game and Game.GetPlayerHorse then
        local ok, h = pcall(Game.GetPlayerHorse, Game); if ok then ent = asEnt(h) end
        if not ent then
            ok, h = pcall(Game.GetPlayerHorse, Game); if ok then ent = asEnt(h) end
        end
    end
    if not ent and g_gameRules and g_gameRules.game and g_gameRules.game.GetPlayerHorse then
        local ok, h = pcall(g_gameRules.game.GetPlayerHorse, g_gameRules.game); if ok then ent = asEnt(h) end
    end

    -- 3) fallback: player.actor:GetHorseId() → entity id
    if not ent and player and player.actor and player.actor.GetHorseId then
        local ok, hid = pcall(player.actor.GetHorseId, player.actor)
        if ok then ent = asEnt(hid) end
    end

    if ent and ent.id then
        CuraEqui.Horse.playerHorseId = ent.id
        return ent
    end
    return nil
end

function CuraEqui.HorseStateGet(horse)
    if not (horse and horse.id) then return nil end
    local S = CuraEqui.HorseState[horse.id]
    if not S then
        S = {
            hunger        = CuraEqui.HorseCfg.hungerStart,
            lastFedAt     = os.time(),
            dist          = 0.0, -- meters within current km
            totalDist     = 0.0, -- meters total (debug/UX)
            feedHistory   = {},
            _lastPos      = nil,
            _warned       = nil,
            _dbgNextLogAt = 100.0,
        }
        CuraEqui.HorseState[horse.id] = S
    end
    return S
end

function CuraEqui.Horse.IsMounted()
    local ok, v = pcall(function()
        if player and player.human and player.human.IsMounted then
            return player.human:IsMounted()
        end
        -- fallback if needed
        if player and player.actor and player.actor.IsMounted then
            return player.actor:IsMounted()
        end
        return false
    end)
    return (ok and v) and true or false
end

-- Collect selected items - store light info for logs & nutrition
function Horse:OnInventoryItemUsed(id)
    self._feedSel = self._feedSel or {}
    local info    = _inv_get_info(id)
    info._wuid    = id           -- keep the real handle for DeleteItem
    info.wuidStr  = tostring(id) -- for logs
    table.insert(self._feedSel, info)

    FeedLog(("Picked: %s (class=%s, qty=%s)")
        :format(tostring(info.uiName or info.dbName or info.wuidStr), tostring(info.classId), tostring(info.qty)))
end

-- Vanilla-style: simulate feeding on close (no removal yet)
function Horse:OnInventoryClosed()
    -- 1) Snapshot selection FIRST, then clear the field
    local picks   = self._feedSel or {}
    self._feedSel = nil

    -- 2) Early-out: user canceled / nothing actually selected (no toast)
    do
        local totalQty = 0
        for _, info in ipairs(picks) do
            totalQty = totalQty + (tonumber(info.qty or 0) or 0)
        end
        if totalQty <= 0 then
            FeedLog("Picker closed (no selection).")
            return
        end
    end

    -- Partition selection (quality disabled): just keep items with qty > 0
    local good = picks

    local CFG  = CuraEqui.Config or {}; local FCFG = CFG.Feeding or {}
    local UF   = (CFG.UI and CFG.UI.feed) or {}

    local S    = CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(self); if not S then return end
    local mode = (FCFG.needMode or "hunger")

    -- HARD BLOCK safety inside close handler (covers inventory-driven feed)
    do
        local F      = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
        local H      = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
        local hard   = (H.satedHardBlock ~= nil) and H.satedHardBlock or F.satedHardBlock
        local thrSec = tonumber((H.satedBlockIfRemainingSec ~= nil) and H.satedBlockIfRemainingSec or
            F.satedBlockIfRemainingSec or 0) or 0
        if hard and thrSec > 0 then
            local now  = (CuraEqui.Now and CuraEqui.Now()) or 0
            local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
            if remS >= thrSec then
                local pickedAny = false
                for _, info in ipairs(picks) do
                    if (tonumber(info.qty or 0) or 0) > 0 then
                        pickedAny = true; break
                    end
                end
                if pickedAny and CuraEqui.UI and CuraEqui.UI.Toast then
                    local UF   = (CuraEqui.Config.UI and CuraEqui.Config.UI.feed) or {}
                    local lane = UF.lane or "infotext"
                    local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
                    local txt  = (UF.msg and (UF.msg.onSatedBlock or UF.msg.onFull)) or "@curaequi_horse_not_hungry_yet"
                    CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
                end
                FeedLog("Blocked: sated hard-block active (rem=" .. tostring(remS) .. "s)")
                return
            end
        end
    end

    -- only toast full when truly full
    local needPoints = _calc_need_points(S, mode)
    if needPoints <= 0 then
        local pickedAny = false
        for _, info in ipairs(picks) do
            local q = tonumber(info.qty or 0) or 0
            if q > 0 then
                pickedAny = true; break
            end
        end

        local hungerNow = math.floor(tonumber(S.hunger or 0) or 0)
        if pickedAny and hungerNow == 0 and CuraEqui.UI and CuraEqui.UI.Toast then
            local lane = UF.lane or "infotext"
            local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
            local txt  = (UF.msg and UF.msg.onFull) or "@curaequi_horse_full"
            CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
        end
        FeedLog(pickedAny and "Picker: need=0 (selection) hunger=" .. tostring(hungerNow) or
            "Picker closed (no selection).")
        return
    end

    if #good == 0 then
        -- Nothing with qty>0 survived selection normalization → treat as cancel
        FeedLog("Picker had no positive-qty items (treat as cancel).")
        return
    end

    do
        local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
        if D and D.feedTrace then
            for i, it in ipairs(good or {}) do
                local per, label = _per_unit_from_info(it)
                System.LogAlways(("[CuraEqui][Feed] pick#%d class=%s qty=%s → per=%s label=%s")
                    :format(i, tostring(it.classId or it.class or "-"),
                        tostring(it.qty or 0),
                        tostring(per), tostring(label)))
            end
        end
    end

    local removePlan, used, selectedUnits, consumedUnits =
        _plan_remove(good, needPoints, FCFG.overfeedPolicy or "allow")

    -- Compute how many points (not units) of the APPLIED cap came from horse vs normal foods,
    -- preserving the user's selection order. We walk the original 'picks' so order is deterministic.
    local function _split_applied_points(removePlan, picks, capPts)
        local got = 0
        local horsePts, normalPts = 0, 0

        -- quick lookup: wuidStr -> rec
        local byWuid = {}
        for _, rec in pairs(removePlan or {}) do
            if rec and rec.wuid then byWuid[tostring(rec.wuid)] = rec end
        end

        for _, info in ipairs(picks or {}) do
            if got >= capPts then break end
            local rec = byWuid[tostring(info._wuid)]
            if rec and rec.units and rec.units > 0 and rec.per and rec.per > 0 then
                -- points contributed by this item’s planned units
                local pts = rec.units * rec.per
                local take = math.min(pts, capPts - got)
                if take > 0 then
                    if rec.horse then horsePts = horsePts + take else normalPts = normalPts + take end
                    got = got + take
                end
            end
        end

        return horsePts, normalPts
    end

    -- Cap-aware application (simple “always fill cap” policy)
    local capPts              = math.floor(tonumber(needPoints or 0) or 0)
    local usedPts             = math.floor(tonumber(used or 0) or 0)
    local appliedPts          = math.min(usedPts, capPts)         -- what we actually apply
    local overshoot           = math.max(0, usedPts - appliedPts) -- points wasted

    -- Seconds to add (mirror _apply_feed logic)
    local C                   = _sated_cfg()
    local perNorm             = math.max(1, tonumber(C and C.perPt or 10) or 10)
    local perHorse            = math.max(perNorm, tonumber((C and C.perPtHorse) or 0) or 0) -- clamp: horse ≥ normal

    -- Split applied points by source (horse vs normal)
    local horsePts, normalPts = _split_applied_points(removePlan, good, appliedPts)

    -- Seconds gained = normPts*perNorm + horsePts*perHorse
    local addSec              = (normalPts * perNorm) + (horsePts * perHorse)


    -- Predict bucket we will show (ceil on post-feed remainder)
    local bucketSec = 0
    if CuraEqui.Buffs and CuraEqui.Buffs.PredictBucketSecAfterAdd then
        bucketSec = CuraEqui.Buffs.PredictBucketSecAfterAdd(S, addSec)
    end

    local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
    if D and D.feedTraceVerbose then
        local n = 0
        for _, rec in pairs(removePlan or {}) do
            n = n + 1
            System.LogAlways(("[CuraEqui][Feed] Plan#%d cid=%s wuid=%s units=%s per=%s")
                :format(n,
                    tostring(rec.classId or rec.class or rec.cid or "-"),
                    tostring(rec.wuid or "-"),
                    tostring(rec.units or 0),
                    tostring(rec.per or "-")))
        end
    end

    -- Nothing consumed on this close
    if (used or 0) <= 0 then
        local pickedAny = (tonumber(selectedUnits or 0) or 0) > 0
        if pickedAny and CuraEqui.UI and CuraEqui.UI.Toast then
            local UF   = (CuraEqui.Config and CuraEqui.Config.UI and CuraEqui.Config.UI.feed) or {}
            local lane = UF.lane or "infotext"
            local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
            local txt  = (UF.msg and UF.msg.onRefusal) or "@curaequi_horse_refuse"
            CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
        end
        FeedLog(pickedAny and "Refusal: all selections resolved to 0."
            or "Picker closed without selection.")
        return
    end

    -- before applying feed effects
    local beforeH = math.floor(tonumber(S.hunger or 0) or 0)

    -- Single, authoritative cap log
    _log_feed_cap(S, capPts, usedPts, appliedPts, overshoot, consumedUnits, selectedUnits, addSec, bucketSec)

    -- log horse bonus from horse food
    do
        local horsePts, _ = _split_applied_points(removePlan, good, appliedPts)
        if (horsePts or 0) > 0 then
            local C = _sated_cfg()
            System.LogAlways(("[CuraEqui][Feed] horse bonus: %.0fpts × %ds/pt = +%ds")
                :format(horsePts, math.floor(C.perPtHorse or 0), math.floor((C.perPtHorse or 0) * horsePts)))
        end
    end

    -- Apply hunger-only if sated also reduces hunger
    do
        local C = _sated_cfg()
        if C.alsoHun then
            -- use the hunger path so satedUntil isn't touched here
            _apply_feed(S, "hunger", appliedPts)
        end
    end

    -- Now apply sated seconds using the composition-aware addSec we computed
    do
        local C     = _sated_cfg()
        local now   = (CuraEqui.Now and CuraEqui.Now()) or 0
        local base  = math.max(now, tonumber(S.satedUntil or 0) or 0)
        local capA  = now + (C.maxSec or 0)
        local next  = math.min(base + (addSec or 0), capA)
        local floor = now + (C.minSec or 0)
        if next < floor then next = math.min(floor, capA) end
        S.satedUntil = next
    end


    -- Round 'rem' up to the next visible bucket (from Buffs.SATED_TIERS) and clamp internal sated
    -- Why? Because we are using fixed durations from the buff.xml so we clamp to the nearest buff
    do
        local now = (CuraEqui.Now and CuraEqui.Now()) or 0
        local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
        local BL  = CuraEqui.Buffs and CuraEqui.Buffs.SATED_TIERS

        if BL and #BL > 0 then
            -- tiers are defined as {sec=500},{400},{300},{200},{100} (desc)
            local target = nil
            for i = #BL, 1, -1 do
                -- iterate ascending so we can "ceil" to the first >= rem
                local sec = tonumber(BL[i].sec) or 0
                if sec >= rem then
                    target = sec
                    break
                end
            end
            -- if rem above max bucket, snap to largest
            if not target then
                target = tonumber(BL[1].sec) or math.max(0, rem)
            end

            if target and target > 0 then
                local buffDur = math.floor(target + 0.5)
                S.satedUntil  = math.floor(now + buffDur + 0.5)

                -- optional neat one-liner in logs
                if _log_sated_summary then
                    _log_sated_summary(used, rem, buffDur, buffDur)
                end

                -- refresh visible timer to this exact bucket
                pcall(CuraEqui.Buffs.SyncSatedTimer, self, S, { cause = "feed", force = true })
            end
        end
    end

    -- player feedback of succesfully eaten food
    do
        local UF = (CuraEqui.Config and CuraEqui.Config.UI and CuraEqui.Config.UI.feed) or {}
        if CuraEqui.UI and CuraEqui.UI.Toast and (tonumber(used) or 0) > 0 then
            local lane = UF.lane or "infotext"
            local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
            local txt  = (UF.msg and UF.msg.onEat) or "@curaequi_horse_eats_happily"
            CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
        end
    end

    if CuraEqui.Config.Debug and CuraEqui.Config.Debug.feedTrace then
        System.LogAlways(("[CuraEqui][Feed] Apply: mode=%s applied=%d (consumed=%d, overshoot=%d) hunger=%d→%d satedNow=%.0fs")
            :format(
                mode,
                appliedPts, usedPts, overshoot,
                beforeH, math.floor(tonumber(S.hunger or 0) or 0),
                math.max(0,
                    ((tonumber(S.satedUntil or 0) or 0) - ((CuraEqui.Now and CuraEqui.Now()) or 0)))
            )
        )
    end

    -- Persist immediately on successful feed so players never lose the effect
    do
        if CuraEqui.Persist and CuraEqui.Persist.Save then
            CuraEqui.Persist.Save(S.hunger, S.satedUntil)
            if CuraEqui.Config and CuraEqui.Config.Debug and CuraEqui.Config.Debug.persistTrace then
                local now = (CuraEqui.Now and CuraEqui.Now()) or 0
                local h   = math.floor(tonumber(S.hunger or 0) or 0)
                local rem = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                System.LogAlways(("[CuraEqui][Persist] Saved (feed) hunger=%d satedRemain=%.0f"):format(h, rem))
            end
        end
    end

    -- after successful feed - reset grazing cap
    local HC = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
    if HC.grazingPerSession and HC.grazingPerSession > 0 then
        S._grazeBudget = HC.grazingPerSession
    end

    if CuraEqui.Buffs and CuraEqui.Buffs.SyncAll then pcall(CuraEqui.Buffs.SyncAll, self, S) end

    -- Partial feed (cap/sated limited): some submitted units weren’t consumed
    if (consumedUnits or 0) < (selectedUnits or 0) and CuraEqui.UI and CuraEqui.UI.Toast then
        local lane = UF.lane or "infotext"
        local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
        local txt  = (UF.msg and UF.msg.onLeftovers) or "@curaequi_feed_leftovers"
        CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
    end

    _emit_feed_toasts(removePlan, used, mode, S)
    FeedLog("Fed %d type(s) (-%d) mode=%s",
        (function()
            local n = 0; for _ in pairs(removePlan) do n = n + 1 end; return n
        end)(),
        used, mode)

    -- ===== Removal guard (exact class delete, then fallback) =====
    if FCFG.removeItems then
        -- 1) get the inventory the same way the working branch does
        local inv = (player and player.inventory) or nil
        if not inv then
            System.LogAlways("[CuraEqui][Feed][WARN] inventory not available; keeping items.")
            return
        end

        -- 2) aggregate by classId (make sure the plan records carry classId)
        local byClass = {} -- classId -> total units
        for _, rec in pairs(removePlan or {}) do
            local n   = tonumber(rec.units) or 0
            local cid = rec.classId or rec.class or rec.cid
            if n > 0 and cid then
                byClass[cid] = (byClass[cid] or 0) + n
            end
        end

        local removed, failed = 0, 0
        local xfer = {} -- classId -> actually removed (for transfer toasts)

        -- 3) prefer DeleteItemOfClass (your API), normalize its return
        for cid, need in pairs(byClass) do
            local took = 0
            if inv.DeleteItemOfClass then
                local ok, ret = pcall(inv.DeleteItemOfClass, inv, cid, need)
                if ok then
                    if type(ret) == "number" then
                        took = ret
                    elseif ret ~= false then
                        took = need
                    end
                end
            end

            -- 4) fallback: per-item deletion if class call wasn’t available or short
            if took < need then
                local want = need - took
                -- walk planned WUIDs for this class to delete the remainder
                for _, rec in pairs(removePlan or {}) do
                    if want <= 0 then break end
                    if (rec.classId or rec.class or rec.cid) == cid and rec.wuid and (rec.units or 0) > 0 then
                        local step = math.min(rec.units, want)
                        for i = 1, step do
                            local okD, r = pcall(inv.DeleteItem, inv, rec.wuid)
                            if okD and r ~= false then
                                took = took + 1
                                want = want - 1
                            else
                                break
                            end
                        end
                    end
                end
            end

            if took > 0 then
                removed   = removed + took
                xfer[cid] = (xfer[cid] or 0) + took
            end
            if took < need then
                failed = failed + (need - took)
            end
        end

        if failed > 0 then
            System.LogAlways(("[CuraEqui][Feed][WARN] Remove: %d ok, %d fail via inventory"):format(removed, failed))
        else
            System.LogAlways(("[CuraEqui][Feed] Remove: %d unit(s) ok via inventory"):format(removed))
        end

        -- optional: vanilla-style transfer toasts (largest first)
        local UI_F = ((CuraEqui.Config or {}).UI or {}).feed or {}
        local NT   = UI_F.notif or {}
        if (NT.showTransfers ~= false) and next(xfer) and Game and Game.ShowItemsTransfer then
            local list = {}
            for cid, n in pairs(xfer) do list[#list + 1] = { cid = tostring(cid), n = tonumber(n) or 0 } end
            table.sort(list, function(a, b) return a.n > b.n end)
            local maxN = NT.maxItems or 8
            for i = 1, math.min(#list, maxN) do
                local it = list[i]
                pcall(Game.ShowItemsTransfer, it.cid, -it.n) -- negative → removal
            end
        end
    end
end

function Horse:OnFeedHorse(user)
    local my = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve()
    if not (my and self and my.id == self.id) then
        System.LogAlways("[CuraEqui][Feed] blocked: not your horse"); return
    end

    System.LogAlways("[CuraEqui][Feed] OnFeedHorse")

    -- Early gate: optionally block feeding if already sated enough
    do
        local F    = (CuraEqui.Config and CuraEqui.Config.Feeding) or {}
        local UF   = (CuraEqui.Config and CuraEqui.Config.UI and CuraEqui.Config.UI.feed) or {}
        local skip = (F.skipPickerWhenFull ~= false)

        -- existing full gate (hunger-based)
        if skip then
            local h = CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
            local S = h and CuraEqui.HorseStateGet and CuraEqui.HorseStateGet(h) or nil
            if S then
                -- HARD BLOCK (optional)
                do
                    local H      = (CuraEqui.Config and CuraEqui.Config.Hunger) or {}
                    local hard   = (H.satedHardBlock ~= nil) and H.satedHardBlock or F.satedHardBlock
                    local thrSec = tonumber((H.satedBlockIfRemainingSec ~= nil) and H.satedBlockIfRemainingSec or
                        F.satedBlockIfRemainingSec or 0) or 0
                    if hard and thrSec > 0 then
                        local now  = (CuraEqui.Now and CuraEqui.Now()) or 0
                        local remS = math.max(0, (tonumber(S.satedUntil or 0) or 0) - now)
                        if remS >= thrSec then
                            if CuraEqui.UI and CuraEqui.UI.Toast then
                                local UF   = (CuraEqui.Config.UI and CuraEqui.Config.UI.feed) or {}
                                local lane = UF.lane or "infotext"
                                local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
                                local txt  = (UF.msg and (UF.msg.onSatedBlock or UF.msg.onFull)) or
                                    "@curaequi_horse_not_hungry_yet"
                                CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
                            end
                            return
                        end
                    end
                end

                -- classic “full” (hunger 0) skip
                local cap  = tonumber(F.needCapPerFeed or 25) or 25
                local curH = tonumber(S.hunger or 0) or 0
                local need = math.max(0, math.min(cap, curH))
                if need <= 0 then
                    if CuraEqui.UI and CuraEqui.UI.Toast then
                        local lane = UF.lane or "infotext"
                        local ms   = math.floor(((UF.sec or 2.0) * 1000) + 0.5)
                        local txt  = (UF.msg and UF.msg.onFull) or "@curaequi_horse_full"
                        CuraEqui.UI.Toast(txt, ms, UF.prio or 0, "CuraEquiFeed", lane)
                    end
                    return
                end
            end
        end
    end

    -- Open multi-select picker (no scan/arming)
    local F = CuraEqui.Config and CuraEqui.Config.Feeding or {}
    local filter = F.filtersMulti or "food.vegetable.*|food.fruit.*|food.nut.*"

    local opened = false
    if user and user.actor and user.actor.OpenItemMultiselectionFilter then
        opened = pcall(user.actor.OpenItemMultiselectionFilter, user.actor, self.id, filter)
        System.LogAlways("[CuraEqui][Feed] OpenItemMultiselectionFilter → " .. tostring(opened) .. " filter=" .. filter)
    end

    -- Fallback: open inventory if picker API missing
    if not opened and UIAction and UIAction.CallFunction then
        pcall(UIAction.CallFunction, "ApseInventoryList", -1, "fc_activate")
    end
end

function CuraEqui.OnPlayerMountedHorseInternal(h)
    -- Always have a state table
    CuraEqui.state = CuraEqui.state or {}
    local ST       = CuraEqui.state

    -- Route identity through central ownership scaffolding
    if CuraEqui.SetOwnedHorse then
        CuraEqui.SetOwnedHorse(h, { reason = "mount-internal" })

        -- Optional: debug whether this horse is "ownable" per whitelist
        local nm      = CuraEqui._HorseName and CuraEqui._HorseName(h) or nil
        local ownable = true

        if nm and CuraEqui.HorseOwnership and CuraEqui.HorseOwnership.IsHorseStormNameOwnable then
            ownable = CuraEqui.HorseOwnership.IsHorseStormNameOwnable(nm)
        end

        local D = CuraEqui.Config and CuraEqui.Config.Debug or {}
        if D.horseIdentityTrace then
            System.LogAlways(("[CuraEqui][OWNDBG] name=%s ownable=%s"):
            format(tostring(nm), tostring(ownable)))
        end

        if CuraEqui.DebugLogHorseIdentity then
            CuraEqui.DebugLogHorseIdentity(h, { tag = "mount-internal" })
        end
    else
        -- Legacy fallback (should never be used in this branch, but safe)
        ST.hasHorse       = true
        ST.lastHorseEnt   = h
        ST.lastHorseId    =
            (CuraEqui._HorseGuid and CuraEqui._HorseGuid(h))
            or (h and h.id)
            or ST.lastHorseId

        ST.lastHorseFp    = (CuraEqui._HorseFingerprint and CuraEqui._HorseFingerprint(h)) or ST.lastHorseFp
        ST.lastHorseFpExt = (CuraEqui._HorseFpExt and CuraEqui._HorseFpExt(h)) or ST.lastHorseFpExt
    end

    -- Mark that in THIS session we have mounted our owned horse at least once
    ST.hasMountedOwnedHorseOnce = true

    System.LogAlways(("[CuraEqui][Horse] Player mounted horse id=%s name=%s → session hasHorse=true")
        :format(
            tostring(h and h.id or "nil"),
            (h and h.GetName and h.GetName()) and h:GetName() or "Horse"
        ))

    -- Kick the hunger watcher AFTER horse identity is fully known
    local okSw, errSw = pcall(function()
        if CuraEqui.StartWatching then
            CuraEqui.StartWatching()
        end
    end)
    if not okSw then
        System.LogAlways("[CuraEqui][Horse][Mount] StartWatching ERROR: " .. tostring(errSw))
    end
end

do
    local H = _G.Horse
    if H and type(H.GetActions) == "function" and not H.__curaequi_feed_wrapped then
        local _Get = H.GetActions
        function H.GetActions(self, user, firstFast)
            local actions = _Get(self, user, firstFast) or {}

            -- only on living horses
            local alive = self and self.actor and self.actor.GetHealth and (self.actor:GetHealth() > 0) or false
            if not alive then return actions end

            -- don’t double-inject
            for i = 1, #actions do
                local a = actions[i]
                if a and a.func == H.OnFeedHorse then return actions end
            end

            -- only allow feeding your own horse unless explicitly enabled
            local allowAny = CuraEqui.Config and CuraEqui.Config.Feeding and CuraEqui.Config.Feeding.allowAnyHorse
            if not allowAny then
                local mine = CuraEqui.Horse and CuraEqui.Horse.Resolve and CuraEqui.Horse.Resolve() or nil
                if not (mine and self and mine.id == self.id) then
                    return actions
                end
            end

            -- compute max uiOrder to append after existing actions
            local maxOrder = 0
            for i = 1, #actions do
                local o = actions[i] and actions[i].uiOrder or 0
                if o and o > maxOrder then maxOrder = o end
            end

            -- find the correct interaction lane (vanilla horse lanes)
            local lane = rawget(_G, "inr_horseInspect") or rawget(_G, "inr_horseMount")
            if not lane then return actions end

            -- build the action (press)
            local A = Action()
                :hint("@curaequi_feed_horse")
                :action("use_horse")
                :hintType(AHT_PRESS)
                :func(H.OnFeedHorse)
                :interaction(lane)
                :uiOrder(maxOrder + 1)
                :enabled(true)

            AddInteractorAction(actions, firstFast, A)

            if not self.__curaequi_feed_logged then
                CuraEqui.Log("Feed", "Injected (lane=%s order=%d)", tostring(lane), maxOrder + 1)
                self.__curaequi_feed_logged = true
            end

            return actions
        end

        H.__curaequi_feed_wrapped = true
        System.LogAlways("[CuraEqui][Feed] ✅ Wrapped Horse.GetActions")
    end
end

-- Hook Horse.OnMount so we know when the player mounts an owned horse
do
    local H = _G.Horse
    if H and type(H.OnMount) == "function" and not H.__curaequi_mount then
        local base = H.OnMount

        function H:OnMount(user, ...)
            -- Always call original first
            local r = base(self, user, ...)

            -- Only care if the *player* mounted
            if player and user and user.id == player.id then
                -- cache id for Resolve()
                CuraEqui.Horse.playerHorseId = self.id

                -- debug log
                QH("OnMount → %s", tostring(self.id))

                -- Protect the internal handler with xpcall
                local ok, err = xpcall(function()
                    if CuraEqui and CuraEqui.OnPlayerMountedHorseInternal then
                        CuraEqui.OnPlayerMountedHorseInternal(self)
                    else
                        System.LogAlways("[CuraEqui][Horse][OnMount] OnPlayerMountedHorseInternal is nil")
                    end
                end, debug and debug.traceback or nil)

                if not ok then
                    System.LogAlways("[CuraEqui][Horse][OnMount][ERROR] " .. tostring(err))
                end
            end

            return r
        end

        H.__curaequi_mount = true
        System.LogAlways("[CuraEqui][Horse] ✅ Wrapped Horse.OnMount")
    end
end
