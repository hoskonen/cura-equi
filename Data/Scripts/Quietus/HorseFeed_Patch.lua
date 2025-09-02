-- ==== Discovery + safe injection for horses even if Horse.GetActions doesn't exist ====
Quietus = Quietus or {}
Quietus.DEBUG = true
local function Q(fmt, ...) if Quietus.DEBUG then System.LogAlways(("[Quietus][HorseFeed] " .. fmt):format(...)) end end

-- Attempt to detect “is this a horse entity?”
local function isHorse(self)
    if not self then return false end
    -- Common patterns; adapt if your class names differ.
    if self.class == "Horse" then return true end
    if self.horse ~= nil then return true end
    -- Some builds keep horse flags on actor params:
    if self.actor and self.actor.IsMountable and self.actor:IsMountable() then return true end
    return false
end

-- Prevent duplicate injection per output array
local function hasFeedAction(out, func)
    for i = 1, #out do
        local a = out[i]
        if a and (a.func == func or a.hint == "@ui_hud_feed_horse") then return true end
    end
    return false
end

-- Delete everything that landed in the horse's inventory during this feed
local function Quietus_ConsumeHorseInventory(horse, feeder)
    if not horse or not horse.inventory then return end
    local removed = 0

    -- API shape differs per build; do your best to iterate stacks
    -- Try a few common patterns (all protected with pcall)
    local stacks = {}
    pcall(function()
        if horse.inventory.GetAllItems then
            stacks = horse.inventory:GetAllItems() or {}
        end
    end)

    -- If GetAllItems isn’t available, try a slot enum pattern
    if #stacks == 0 then
        pcall(function()
            if horse.inventory.EnumItems then
                horse.inventory:EnumItems(function(itemId, count)
                    table.insert(stacks, { id = itemId, count = count or 1 })
                    return true -- continue
                end)
            end
        end)
    end

    -- Consume (delete) everything we find
    for _, s in ipairs(stacks) do
        local id    = s.id
        local count = (s.count and s.count > 0) and s.count or 1
        if id then
            pcall(function() horse.inventory:DeleteItem(id, count) end)
            removed = removed + count
        end
    end

    System.LogAlways(("[Quietus][HorseFeed] Consumed %d item(s) from %s"):format(
        removed, tostring(horse.GetName and horse:GetName() or "horse")))
end

-- Some builds send this to the *target* entity when exchange closes
function Horse:OnItemExchangeClosed()
    if self.__quietus_feed_active then
        Quietus_ConsumeHorseInventory(self, self.__quietus_feed_user or player)
    end
    self.__quietus_feed_active = nil
    self.__quietus_feed_user   = nil
end

-- Other builds reuse the generic inventory close callback name
function Horse:OnInventoryClosed()
    if self.__quietus_feed_active then
        Quietus_ConsumeHorseInventory(self, self.__quietus_feed_user or player)
    end
    self.__quietus_feed_active = nil
    self.__quietus_feed_user   = nil
end

-- Our handler stubs
local function OnFeedHorse(self, user, slot)
    Q("OnFeedHorse fired for %s", tostring(self.class or "entity"))
    if user and user.actor and user.actor.OpenItemMultiselectionFilter then
        user.actor:OpenItemMultiselectionFilter(self.id, "")
    elseif user and user.actor and user.actor.OpenItemSelectionFilter then
        user.actor:OpenItemSelectionFilter(self.id, "")
    else
        Q("Item selection UI not available in this build (no OpenItem*Filter)")
    end
    -- Minimal consume path (you can wire OnInventoryItemUsed/Closed later if this fires)
end

function Horse:OnFeedHorse(user, slot)
    System.LogAlways("[Quietus][HorseFeed] OnFeedHorse → " ..
        tostring(self.GetName and self:GetName() or self.class or "horse"))

    -- mark that we're in a feed exchange so we only consume when *we* opened it
    self.__quietus_feed_active = true
    self.__quietus_feed_user   = user

    -- Open the standard exchange window (same as loot but for a living actor it’s “give/take”)
    if self.actor and self.actor.RequestItemExchange and user and user.id then
        self.actor:RequestItemExchange(user.id)
    else
        System.LogAlways("[Quietus][HorseFeed] RequestItemExchange not available — falling back to selection UI")
        -- Fallback to selection UI if your build lacks RequestItemExchange for horse
        if user and user.actor and user.actor.OpenItemMultiselectionFilter then
            user.actor:OpenItemMultiselectionFilter(self.id, "")
        elseif user and user.actor and user.actor.OpenItemSelectionFilter then
            user.actor:OpenItemSelectionFilter(self.id, "")
        end
    end
end

-- Try to inject “Feed horse” into the current output list
local function tryInjectFeed(self, user, firstFast, out)
    -- Prefer the horse “inspect” lane if present; else fall back to mount lane; else give up.
    local hasInspectLane = (rawget(_G, "inr_horseInspect") ~= nil)
    local hasMountLane   = (rawget(_G, "inr_horseMount") ~= nil)
    local lane           = hasInspectLane and inr_horseInspect or hasMountLane and inr_horseMount or nil
    if not (Action and AddInteractorAction and lane) then
        Q("Cannot inject: Action/AddInteractorAction/lane missing (inspect=%s mount=%s)", tostring(hasInspectLane),
            tostring(hasMountLane))
        return
    end
    if hasFeedAction(out, OnFeedHorse) then return end

    AddInteractorAction(out, firstFast,
        Action()
        :hint("@ui_hud_feed_horse")
        :action("use_horse") -- safe generic; lane decides grouping
        :hintType(AHT_PRESS)
        :func(OnFeedHorse)
        :interaction(lane)
        :uiOrder(2)
        :enabled(true)
    )
    Q("Injected Feed horse on lane %s", (lane == inr_horseInspect) and "inspect" or "mount")
end

-- Wrap EVERY table that has :GetActions and log calls for horses
local wrapped = {}
local function wrapHost(name, host)
    if wrapped[name] then return end
    local GA = rawget(host, "GetActions")
    if type(GA) ~= "function" then return end

    host.GetActions = function(self, user, firstFast)
        local out = GA(self, user, firstFast) or {}
        if isHorse(self) then
            -- Log once per host so we know who owns it
            if not host.__quietus_horse_logged then
                Q("GetActions call for horse is coming from table: %s", tostring(name))
                host.__quietus_horse_logged = true
            end
            -- Try to inject the feed action
            tryInjectFeed(self, user, firstFast, out)
        end
        return out
    end
    wrapped[name] = true
    Q("✅ Wrapped %s.GetActions (discovery)", tostring(name))
end

-- Scan globals now and a few times later for late load
local tries = 0
local function scanLoop()
    tries = tries + 1
    for k, v in pairs(_G) do
        if type(v) == "table" then wrapHost(k, v) end
    end
    if tries < 20 then
        Script.SetTimer(500, scanLoop) -- retry for ~10s total to catch late loads
    else
        Q("Discovery settled")
    end
end
scanLoop()
