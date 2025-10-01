-- Scripts/CuraEqui/Config.lua
CuraEqui = CuraEqui or {}

CuraEqui.Config = {
    UI = {
        hudElement = "HUD",
        fallbackToNotification = true,
        feed = {
            lane = "infotext", -- "infotext" | "tutorial" | "notification"
            sec  = 2.0,        -- default duration for center messages (seconds)
            prio = 0,          -- priority for the lane
            msg  = {
                onFull       = "@curaequi_horse_full",
                onRefusal    = "@curaequi_horse_refuse",
                onLeftovers  = "@curaequi_feed_leftovers",
                onSatedBlock = "@curaequi_horse_not_hungry_yet"
            },
        }
    },
    Debug = {
        enabled = true,
        distanceTrace = true,
        distanceTraceStepM = 500.0,
        hud = { enabled = true, lane = "notification", id = "CuraEqui_DebugHUD", refresh = 10000 },
        hungerTrace = true, -- log a compact hunger line each tick
        hungerTraceEvery = 10000,
        mountTrace = true,
        feedTrace = true,
        persistTrace = true,      -- log saving
        tickTrace = true,
        buffTraceVerbose = false, -- false = log only when buff changes
        staminaSnapshot = true,   -- capture a reference staminaMax (debug only)
    },

    Hunger = {
        preset                   = "dev", -- "hardcore" | "real_life" | "moderate" | "laidback"
        tickSec                  = 10,
        hungerStart              = 50,
        hungerMax                = 100,
        debuffAt                 = 70,
        -- Rates
        ratePerMinIdle           = 0.15, -- horse idle (includes mounted-but-standing)
        ratePerMinMounted        = 0.35, -- horse mounted & moving: time drift while ridden
        ratePerKmMounted         = 0.5,  -- extra drain per ridden kilometer
        speedIdleMps             = 0.2,  -- below this → idle
        -- Sated
        satedDrainMul            = 0.75,
        satedSecPerNutrition     = 5, -- x per nutrition
        satedCapSec              = 600,
        -- Sated feeding policy
        -- If you want “block whenever sated is active, set satedBlockIfRemainingSec = 1
        -- If you want a softer rule (“block only if ≥ 10 min left”), set 600.
        satedHardBlock           = true,                      -- if true, block feeding while plenty of sated time remains
        satedBlockIfRemainingSec = 1,                         -- threshold in seconds; 0 disables blocking (used only if satedHardBlock=true)-- 10 min max
        -- Grazing
        grazePerMinIdleUnmtd     = -0.12,                     -- negative recovers while unmounted & idle
        grazeSatedMul            = 1.0,                       -- sated multiplier applied to grazing
        grazingPerSession        = 10,                        -- set 0 or nil to disable (max hunger points recovered per idle-unmounted session)
        grazeRamp                = { start = 10, full = 35 }, -- % hunger: 0% effect at 10, 100% effect at 35+
        -- Grazing - Night
        night                    = {
            disableGrazing   = true,
            timeDrainMul     = 1.0, -- 1.0 keeps same time drain at night (raise if you want nights a bit harsher)
            maxDeltaPerNight = 35,  -- absolute cap on hunger gained from sunset→sunrise

        },
        waitCatchup              = { enabled = true, maxCatchupSec = 6 * 3600 }
    },
    Presets = {
        Hunger = {
            hardcore = {
                ratePerMinIdle       = 0.35,  -- +21/h
                ratePerMinMounted    = 0.7,   -- +42/h
                ratePerKmMounted     = 1.0,   -- +1.0/km
                grazePerMinIdleUnmtd = -0.08, -- -4.8/h (still helps, but weaker)
                night                = { disableGrazing = true, timeDrainMul = 1.2, maxDeltaPerNight = 30 },
            },
            real_life = {
                -- Slow passive build, forage is meaningful. Night still accumulates some hunger but capped.
                ratePerMinIdle       = 0.12,  -- +7.2/h
                ratePerMinMounted    = 0.35,  -- +21/h
                ratePerKmMounted     = 0.6,   -- +0.6/km
                grazePerMinIdleUnmtd = -0.10, -- -6/h (day grazing offsets most idle)
                night                = { disableGrazing = false, timeDrainMul = 1.0, maxDeltaPerNight = 18 },
            },
            moderate = {
                ratePerMinIdle       = 0.2,   -- +12/h
                ratePerMinMounted    = 0.5,   -- +30/h
                ratePerKmMounted     = 0.7,   -- +0.7/km
                grazePerMinIdleUnmtd = -0.12, -- -7.2/h
                night                = { disableGrazing = true, timeDrainMul = 1.0, maxDeltaPerNight = 25 },
            },
            laidback = {
                ratePerMinIdle       = 0.1,   -- +6/h
                ratePerMinMounted    = 0.25,  -- +15/h
                ratePerKmMounted     = 0.4,   -- +0.4/km
                grazePerMinIdleUnmtd = -0.12, -- -7.2/h (day idle nearly nets to zero)
                night                = { disableGrazing = true, timeDrainMul = 0.9, maxDeltaPerNight = 12 },
            },
            dev = {
                ratePerMinIdle       = 0.05,
                ratePerMinMounted    = 0.15,
                ratePerKmMounted     = 0.2,
                grazePerMinIdleUnmtd = -0.06,
                night                = { disableGrazing = true, timeDrainMul = 1.0, maxDeltaPerNight = 35 },
            },
        },
    },

    Diet = {
        strict               = "guid+token", -- "guid-only" | "guid+token" | "guid+token+keywords"
        allowKeywordFallback = false,        -- set false to require explicit map from DietData.lua
        keywordNutrition     = 10
    },

    HUD = {
        showWhenMounted   = true,
        nearRadiusM       = 20.0,
        refresh           = 5,
        playerStatusTiers = {
            { name = "sated",    uidd = "1a638e4c-e931-415d-b3bd-c8402ed836ea" },
            { name = "minor",    uidd = "3329d630-3aa6-4d65-b7bb-8257fdecb66c" },
            { name = "moderate", uidd = "11a47968-997f-41a4-a9f7-ad5a99b1d737" },
            { name = "critical", uidd = "5b57061a-3425-460e-9848-a26afbd060a4" },
            { name = "ok",       uidd = "f3d4b5e2-7f8a-4d6b-9a31-8b0d1c9a7c52" },
        },
        horseDebuffTiers  = {
            { name = "sated",    uidd = "7d3c2a91-8c6b-4f3f-9a6e-2b1d3e94a6b0" },
            { name = "minor",    uidd = "c4b7f9d2-1e35-4a07-8b3a-1b6e9b2a0c18" },
            { name = "moderate", uidd = "e1a5c0f7-2d4c-41f9-8d45-7a9f0c3e1b72" },
            { name = "critical", uidd = "9f2e6b84-3a10-4719-b6d9-5d0c8f2a4c63" },
        },
        thresholds        = {
            minor = 50,
            moderate = 70,
            critical = 90
        },
        -- pretty names per tier (fallbacks provided in code if you skip this)
        hungerNames       = {
            ok       = "OK",
            minor    = "Mild",
            moderate = "Hungry",
            critical = "Starving",
            sated    = "Sated",
        },
    },
    Feeding = {
        filtersMulti           = "food.vegetable.*|food.fruit.*|food.nut.*",
        overfeedPolicy         = "allow", -- "allow" | "skip"  (what to do if a single item would overshoot need)
        removeItems            = true,    -- ← keep false until you verify removal works on your build
        -- Sated Mode (goal-based planning; picker path)
        needMode               = "sated", -- "hunger" | "sated"
        needCapPerFeed         = 25,
        satedMinSec            = 300,
        satedMaxSec            = 900,
        satedSecPerPoint       = 6,
        satedAlsoReducesHunger = true,
        -- Toasts (dev-style, no localization)
        toastOnDone            = true,
        toastLane              = "notification", -- "notification" (right) | "tutorial" | "infotext"
        toastSec               = 2.0,
        -- Feeding settings for Presets
        hardcore               = { needCapPerFeed = 20, satedSecPerPoint = 5, satedMaxSec = 600 },
        real_life              = { needCapPerFeed = 25, satedSecPerPoint = 7, satedMaxSec = 1200 },
        moderate               = { needCapPerFeed = 25, satedSecPerPoint = 6, satedMaxSec = 900 },
        laidback               = { needCapPerFeed = 30, satedSecPerPoint = 8, satedMaxSec = 1500 },

    },
    Drinking = {
        sources = {
            { class = "WaterTubeActionTrigger" },                                           -- laundry/wash tubes
            { class = "SmartObjectHolder",     nameMatch = "Water/waterResource" },         -- wash areas
            { class = "TriggerArea",           nameMatch = "Water/waterResource" },
            { class = "SmartObjectHolder",     nameMatch = "animalcare/horseParkingSpot" }, -- stone/wood troughs
        }
    },
    Audio = {
        enabled       = true,
        allowFallback = true,                     -- keep legacy fallback if ATL fails
        feedTrigger   = "a_o_horse_eating",       -- ATL trigger name (atl_name in XML)
        feedTrigger1  = "a_o_horse_eating_grass", -- ATL trigger name (atl_name in XML)
        feedTrigger3  = "a_o_horse_snort2",       -- ATL trigger name (atl_name in XML)
        feedTrigger4  = "a_o_horse_snort3",       -- ATL trigger name (atl_name in XML)
        pathHints     = { "horse" },              -- NEW: folders to try as prefixes
    },
    Buffs = {
        applyDelaySec = 1.2,
    }
}

-- DELETE THIS LATER WHEN OLD VARIABLES HAVE BEEN REMOVED
do
    local C = CuraEqui.Config or {}
    if C.FeedScan then
        CuraEqui.Config.UI       = CuraEqui.Config.UI or {}
        CuraEqui.Config.UI.feed  = CuraEqui.Config.UI.feed or {}
        local UF                 = CuraEqui.Config.UI.feed
        UF.lane                  = UF.lane or C.FeedScan.toastLane
        UF.sec                   = UF.sec or C.FeedScan.toastSec
        UF.prio                  = UF.prio or C.FeedScan.toastPrio
        UF.msg                   = UF.msg or {}
        UF.msg.onFull            = UF.msg.onFull or C.FeedScan.toastOnFull
        -- We intentionally do NOT migrate onStart/onEat/windowEnded (scanner-only)
        CuraEqui.Config.FeedScan = nil
    end
end

if CuraEqui and CuraEqui.ApplyPreset then
    CuraEqui.ApplyPreset("overwrite") -- or "fill" if you prefer config wins
end
